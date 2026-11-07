// The TV side (exclusive, encoded format) and the capture side (the virtual device's shared mix).
import CTrueHD
import CoreAudio
import Foundation

/// Takes the TV exclusively and streams MAT bursts to it. Generalized from prototype/bitsend.swift.
final class TVSender {
    let dev: AudioObjectID
    let stream: AudioStreamID
    let target: AudioStreamBasicDescription
    private(set) var original: AudioStreamBasicDescription
    private var procID: AudioDeviceIOProcID?
    private var tookHog = false, changedMixing = false, changedFormat = false

    static let matFormat = code("mtct")

    init(dev: AudioObjectID) throws {
        self.dev = dev
        guard let s = CA.streams(dev, kAudioObjectPropertyScopeOutput).first else { throw ConfigError("TV has no output stream") }
        stream = s
        guard let t = CA.availablePhysicalFormats(s).first(where: { $0.mFormatID == TVSender.matFormat && $0.mSampleRate == 768000 }) else {
            throw ConfigError("TV does not offer 'mtct' (Dolby MAT) at 768 kHz right now")
        }
        target = t
        original = CA.physicalFormat(s)
    }

    func acquire(pipeline: Pipeline) throws {
        let me = getpid()
        if let owner = CA.i32(dev, kAudioDevicePropertyHogMode), owner != -1, owner != me {
            throw ConfigError("TV is hogged by pid \(owner)")
        }
        // Remember the LPCM format to restore. If a previous run did not get to restore the TV (crash, kill -9: the
        // state is still dirty, or the TV is still on an encoded format), the format saved then is still the truth.
        let current = CA.physicalFormat(stream)
        var state: SavedState
        if let s = SavedState.load(), s.tvUID == CA.uid(dev), s.dirty == true || current.mFormatID != kAudioFormatLinearPCM {
            state = s
        } else {
            state = SavedState(tvUID: CA.uid(dev), format: current, pid: me)
        }
        original = state.format
        state.workerPID = me; state.dirty = true; state.save()

        var st = CA.setI32(dev, kAudioDevicePropertyHogMode, me)
        tookHog = CA.i32(dev, kAudioDevicePropertyHogMode) == me
        guard tookHog else { throw ConfigError("could not take hog mode (status \(st))") }
        if CA.isSettable(dev, kAudioDevicePropertySupportsMixing) {
            st = CA.setU32(dev, kAudioDevicePropertySupportsMixing, 0); changedMixing = st == noErr
        }
        st = CA.setPhysicalFormat(stream, target); changedFormat = true
        for _ in 0..<30 where !formatIsTarget { Thread.sleep(forTimeInterval: 0.1) }
        guard formatIsTarget else { throw ConfigError("TV did not switch to \(CA.describe(target)) (status \(st), now \(CA.describe(CA.physicalFormat(stream))))") }

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, _, _, out, _ in
            for buf in UnsafeMutableAudioBufferListPointer(out) {
                guard let d = buf.mData?.assumingMemoryBound(to: UInt8.self) else { continue }
                pipeline.render(d, Int(buf.mDataByteSize))
            }
        }
        guard st == noErr, procID != nil else { throw ConfigError("TV IOProc create failed (\(st))") }
        st = AudioDeviceStart(dev, procID)
        guard st == noErr else { throw ConfigError("TV IOProc start failed (\(st))") }
        log("TV '\(CA.name(dev))' exclusive: \(CA.describe(original)) -> \(CA.describe(CA.physicalFormat(stream)))")
    }

    var formatIsTarget: Bool {
        let f = CA.physicalFormat(stream); return f.mFormatID == target.mFormatID && f.mSampleRate == target.mSampleRate
    }
    var stillOurs: Bool { CA.i32(dev, kAudioDevicePropertyHogMode) == getpid() && formatIsTarget }

    /// Undo everything, in reverse order. Safe to call more than once and on a device that has vanished.
    func release() {
        if let p = procID { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p); procID = nil }
        let alive = CA.u32(dev, kAudioDevicePropertyDeviceIsAlive) == 1
        if changedFormat {
            let st = CA.setPhysicalFormat(stream, original); changedFormat = false
            for _ in 0..<20 where alive && CA.physicalFormat(stream).mFormatID != kAudioFormatLinearPCM { Thread.sleep(forTimeInterval: 0.05) }
            log("TV format -> \(CA.describe(original)) status \(st)")
        }
        if changedMixing { CA.setU32(dev, kAudioDevicePropertySupportsMixing, 1); changedMixing = false }
        if tookHog { CA.setI32(dev, kAudioDevicePropertyHogMode, -1); tookHog = false; log("TV hog released (owner now \(CA.i32(dev, kAudioDevicePropertyHogMode) ?? -99))") }
        if var s = SavedState.load(), s.dirty == true, CA.physicalFormat(stream).mFormatID == kAudioFormatLinearPCM { s.dirty = false; s.save() }
    }

    /// Output-side latency in seconds: device latency + safety offset + IO buffer + stream latency.
    var latency: Double {
        let fr = (CA.u32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0)
            + (CA.u32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)
            + (CA.u32(dev, kAudioDevicePropertyBufferFrameSize) ?? 0)
            + (CA.u32(stream, kAudioStreamPropertyLatency) ?? 0)
        return Double(fr) / target.mSampleRate
    }
}

/// Reads the system mix from the MATBridge virtual device.
///
/// The driver copies every output mix it receives into a shared-memory ring (`matbridge_shm.h`). We run one IOProc on
/// the device with its input streams switched off: it writes silence (which adds nothing to the mix), keeps the
/// device's IO and clock running, and wakes us once per IO cycle to move the new frames into the pipeline. Because no
/// input stream is ever used, macOS does not treat MATBridge as recording audio.
final class Capture {
    let dev: AudioObjectID
    private let shm: OpaquePointer
    private let offsets: [Int]       // source channel for FL FR FC LFE SL SR within a ring frame
    private let channels: Int        // channels per ring frame
    private var procID: AudioDeviceIOProcID?
    private let scratchFrames = 2048
    private let floats: UnsafeMutablePointer<Float32>
    private let scratch: UnsafeMutablePointer<Int32>
    private var lastWrites: UInt64 = .max

    /// UID of the device scripts/build-driver.sh builds.
    static let deviceUID = "MATBridge_UID"
    static func findDevice() -> AudioObjectID? {
        CA.device(uid: deviceUID).flatMap { CA.channelCount($0, kAudioObjectPropertyScopeOutput) > 0 ? $0 : nil }
    }

    /// - Parameter channels: source channel index (0-based) for FL FR FC LFE SL SR.
    init(dev: AudioObjectID, channels: [Int]) throws {
        self.dev = dev
        var err = [CChar](repeating: 0, count: 256)
        var h = thb_shm_open(&err, 256)
        if h == nil, errno == ENOENT {
            // The driver creates the ring when the device's IO first starts (after a reboot or coreaudiod restart,
            // nothing may have played yet). Start IO the same way capture does and wait for it.
            h = Capture.startIOBriefly(dev) { thb_shm_open(&err, 256) }
        }
        guard let h else { throw ConfigError("virtual device: \(String(cString: err))") }
        let ch = Int(thb_shm_channels(h))
        guard let mx = channels.max(), mx < ch else {
            thb_shm_close(h); throw ConfigError("the shared mix has \(ch) channels; need channel \((channels.max() ?? 0) + 1)")
        }
        shm = h; offsets = channels; self.channels = ch
        floats = .allocate(capacity: scratchFrames * ch)
        scratch = .allocate(capacity: scratchFrames * encChannels)
    }
    deinit { stop(); floats.deallocate(); scratch.deallocate(); thb_shm_close(shm) }

    func start(pipeline: Pipeline) throws {
        // Small IO buffer = less latency and jitter; ~5 ms.
        CA.setU32(dev, kAudioDevicePropertyBufferFrameSize, UInt32(max(128, pipeline.rate / 200)))
        let shm = self.shm, offsets = self.offsets, ch = channels, floats = self.floats, scratch = self.scratch, sf = scratchFrames
        var st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, _, _, out, _ in
            Capture.silence(out)
            pipeline.pull(shm, offsets: offsets, channels: ch, floats: floats, scratch: scratch, scratchFrames: sf)
        }
        guard st == noErr, let proc = procID else { throw ConfigError("capture IOProc create failed (\(st))") }
        st = Capture.disableInputStreams(dev, proc)
        guard st == noErr else { stop(); throw ConfigError("could not turn off input streams for the capture IOProc (\(st))") }
        st = AudioDeviceStart(dev, proc)
        guard st == noErr else { stop(); throw ConfigError("capture start failed (\(st))") }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p); procID = nil }
    }

    /// False if the driver wrote nothing since the previous call.
    func mixAdvanced() -> Bool {
        let w = thb_shm_writes(shm); defer { lastWrites = w }
        return w != lastWrites
    }

    /// How old the audio is when it reaches the pipeline, in seconds: the driver publishes each mix for an output time
    /// about one IO buffer ahead, and we read it at our next IO cycle, so roughly one IO buffer.
    var latency: Double {
        Double(CA.u32(dev, kAudioDevicePropertyBufferFrameSize) ?? 0) / (CA.f64(dev, kAudioDevicePropertyNominalSampleRate) ?? 48000)
    }

    private static func silence(_ out: UnsafeMutablePointer<AudioBufferList>) {
        for buf in UnsafeMutableAudioBufferListPointer(out) { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
    }

    /// Runs a silent, input-off IOProc on `dev` for up to 1 s, calling `attempt` until it returns non-nil.
    private static func startIOBriefly(_ dev: AudioObjectID, _ attempt: () -> OpaquePointer?) -> OpaquePointer? {
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil, { _, _, _, out, _ in silence(out) }) == noErr, let proc else { return nil }
        defer { AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc) }
        guard disableInputStreams(dev, proc) == noErr, AudioDeviceStart(dev, proc) == noErr else { return nil }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)
            if let h = attempt() { return h }
        }
        return nil
    }

    /// By default the HAL hands every IOProc the device's input streams too, and that alone counts as recording
    /// (kAudioProcessPropertyIsRunningInput = 1, the orange indicator). Switch them all off for `proc`.
    private static func disableInputStreams(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        var a = addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size)
        guard st == noErr else { return st }
        guard size >= UInt32(MemoryLayout<AudioHardwareIOProcStreamUsage>.size) else { return noErr }  // no input streams
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        st = AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw)
        guard st == noErr else { return st }
        let n = Int(usage.pointee.mNumberStreams)
        withUnsafeMutablePointer(to: &usage.pointee.mStreamIsOn) {
            $0.withMemoryRebound(to: UInt32.self, capacity: n) { for i in 0..<n { $0[i] = 0 } }
        }
        return AudioObjectSetPropertyData(dev, &a, 0, nil, size, raw)
    }
}
