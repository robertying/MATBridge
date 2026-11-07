// The TV side (exclusive, encoded format) and the capture side (virtual device input).
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
        // Remember the LPCM format to restore. If the TV is already on an encoded format (left over from a crash),
        // keep whatever was saved before.
        // If a previous run did not get to restore the TV (crash, kill -9), its saved original is still the truth.
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

/// Reads the first six speaker channels from the virtual device's input (loopback) side.
final class Capture {
    let dev: AudioObjectID
    let map: [(Int, Int, Int)]
    private var procID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchFrames = 2048

    /// - Parameter channels: source channel index (0-based, across the input buffers) for FL FR FC LFE SL SR.
    init(dev: AudioObjectID, channels: [Int]) throws {
        self.dev = dev
        guard let s = CA.streams(dev, kAudioObjectPropertyScopeInput).first else { throw ConfigError("source has no input stream") }
        let f = CA.virtualFormat(s)
        guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mBitsPerChannel == 32 else {
            throw ConfigError("source input format is \(CA.describe(f)), expected Float32")
        }
        // Map device channel numbers to (buffer, offset, channels-in-buffer) using the stream configuration.
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw)
        var layout: [(Int, Int, Int)] = []
        for (bi, b) in UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).enumerated() {
            for c in 0..<Int(b.mNumberChannels) { layout.append((bi, c, Int(b.mNumberChannels))) }
        }
        guard let mx = channels.max(), mx < layout.count else { throw ConfigError("source has \(layout.count) input channels; need channel \((channels.max() ?? 0) + 1)") }
        map = channels.map { layout[$0] }
        scratch = .allocate(capacity: scratchFrames * encChannels)
    }
    deinit { stop(); scratch.deallocate() }

    func start(pipeline: Pipeline) throws {
        // Small IO buffer = less latency and jitter; ~5 ms.
        CA.setU32(dev, kAudioDevicePropertyBufferFrameSize, UInt32(max(128, pipeline.rate / 200)))
        let map = self.map, scratch = self.scratch, sf = scratchFrames
        var st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, input, _, _, _ in
            pipeline.capture(input, map: map, scratch: scratch, scratchFrames: sf)
        }
        guard st == noErr, procID != nil else { throw ConfigError("capture IOProc create failed (\(st))") }
        st = AudioDeviceStart(dev, procID)
        guard st == noErr else { throw ConfigError("capture start failed (\(st))") }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p); procID = nil }
    }

    /// Input-side latency in seconds: what the app wrote is this old when our IOProc sees it.
    var latency: Double {
        let rate = CA.f64(dev, kAudioDevicePropertyNominalSampleRate) ?? 48000
        let fr = (CA.u32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) ?? 0)
            + (CA.u32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput) ?? 0)
            + (CA.u32(dev, kAudioDevicePropertyBufferFrameSize) ?? 0)
        return Double(fr) / rate
    }
}
