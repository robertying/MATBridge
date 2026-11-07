// While MATBridge has released the TV for Apple Music's Dolby passthrough, whatever else plays to the virtual device
// (other apps, and Music itself when it does not pass through) goes out as stereo PCM: to the TV while it is free
// (at the TV's current format; Core Audio converts the rate), else (Music holds it) to the Mac's built-in speakers.
import AudioToolbox
import CTrueHD
import CoreAudio
import Foundation
import Synchronization

/// The encoded formats the TV offers, mirrored onto the virtual device (driver/hdmi-passthrough.patch). Apple Music
/// only passes Dolby through when the default output (the virtual device) reports HDMI and lists them.
enum DolbyFormats {
    static let selector = code("mbdf")  // MATB_DOLBY_FORMATS_SELECTOR
    private static var warned = false

    /// Copies the TV's encoded formats to the virtual device: none without a TV. Cheap; safe to call every tick.
    static func sync(src: AudioObjectID, tv: AudioObjectID?) {
        let want = tv.flatMap { CA.streams($0, kAudioObjectPropertyScopeOutput).first }
            .map { CA.availablePhysicalRanged($0).filter { $0.mFormat.mFormatID != kAudioFormatLinearPCM } } ?? []
        let wantData = want.withUnsafeBytes { Data($0) }
        guard let have = current(src) else {
            if !warned { warned = true; log("the virtual device has no Dolby format list (old driver?); Music will not pass Dolby through. Reinstall the driver: scripts/build-driver.sh, scripts/install-driver.sh") }
            return
        }
        guard have != wantData else { return }
        var a = addr(selector)
        let cf = wantData as CFData
        var ref = Unmanaged.passUnretained(cf)   // the property value is a CFDataRef
        let st = withExtendedLifetime(cf) { AudioObjectSetPropertyData(src, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFData>>.size), &ref) }
        let names = Set(want.map { fourcc($0.mFormat.mFormatID) }).sorted().joined(separator: " ")
        log("virtual device now lists the TV's Dolby formats: [\(names)] (status \(st))")
    }

    /// The format IDs the virtual device lists for Apple Music now (nil: a driver without the list).
    static func listed(_ src: AudioObjectID) -> [String]? {
        current(src).map { d in
            let n = d.count / MemoryLayout<AudioStreamRangedDescription>.stride
            let ids = d.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<AudioStreamRangedDescription>.stride, as: AudioStreamRangedDescription.self).mFormat.mFormatID } }
            return Set(ids.map(fourcc)).sorted()
        }
    }

    private static func current(_ src: AudioObjectID) -> Data? {
        var a = addr(selector)
        guard AudioObjectHasProperty(src, &a) else { return nil }
        var cf: Unmanaged<CFData>?; var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(src, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as Data
    }
}

final class Router: @unchecked Sendable {
    private let src: AudioObjectID
    private let tv: AudioObjectID?
    private let offsets: [Int]          // source channel for FL FR FC LFE SL SR
    private let shm: OpaquePointer
    private let channels: Int
    private var unit: AudioUnit?
    private(set) var dest: AudioObjectID = 0
    private(set) var rate = 0.0

    // Render state (real-time thread only).
    private let ring: OpaquePointer     // interleaved stereo Float32
    private let scratchFrames = 4096
    private let floats: UnsafeMutablePointer<Float32>
    private let stereo: UnsafeMutablePointer<Float32>
    private var prefilling = true
    private var target = 0, window = 0
    let underruns = Atomic<Int64>(0), adjusted = Atomic<Int64>(0)

    init(src: AudioObjectID, tv: AudioObjectID?, offsets: [Int]) throws {
        self.src = src; self.tv = tv; self.offsets = offsets
        var err = [CChar](repeating: 0, count: 256)
        guard let h = thb_shm_open(&err, 256) else { throw ConfigError("virtual device: \(String(cString: err))") }
        channels = Int(thb_shm_channels(h))
        guard let mx = offsets.max(), mx < channels, offsets.count == 6 else {
            thb_shm_close(h); throw ConfigError("the shared mix has \(channels) channels; need channel \((offsets.max() ?? 0) + 1)")
        }
        shm = h
        ring = thb_ring_create(192000 * 2 * 4)!   // 1 s at 192 kHz
        floats = .allocate(capacity: scratchFrames * channels)
        stereo = .allocate(capacity: scratchFrames * 2)
    }
    deinit { stop(); thb_ring_destroy(ring); floats.deallocate(); stereo.deallocate(); thb_shm_close(shm) }

    /// Where the audio should go now: the TV while no other app holds it, else the built-in speakers.
    private func wantedDest() -> AudioObjectID? {
        if let tv, CA.u32(tv, kAudioDevicePropertyDeviceIsAlive) == 1, CA.i32(tv, kAudioDevicePropertyHogMode) == -1 { return tv }
        return CA.builtInOutput()
    }

    /// (Re)starts output if the destination or the virtual device's rate changed. Call on the main queue.
    func check() {
        let want = wantedDest() ?? 0
        let r = CA.f64(src, kAudioDevicePropertyNominalSampleRate) ?? 48000
        if want == dest, r == rate, unit != nil { return }
        stopUnit()
        dest = want; rate = r
        guard want != 0 else { log("router: no output for other apps' sound"); return }
        do { try startUnit(want, r) } catch { log("router: \(error)"); stopUnit() }
        let why = want == tv ? "" : tv.flatMap { CA.i32($0, kAudioDevicePropertyHogMode) }.map { " (the TV is held by pid \($0))" } ?? " (no TV)"
        log(String(format: "router: virtual device (%.1f kHz) -> '%@' as stereo%@", r / 1000, CA.name(want), why))
    }

    func stop() { stopUnit(); dest = 0 }

    // MARK: output unit

    private func startUnit(_ dev: AudioObjectID, _ r: Double) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw ConfigError("no HAL output unit") }
        var u: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &u)
        guard st == noErr, let u else { throw ConfigError("output unit (\(st))") }
        unit = u
        var d = dev
        st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, 4)
        guard st == noErr else { throw ConfigError("output unit device (\(st))") }
        var fmt = AudioStreamBasicDescription(mSampleRate: r, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                                              mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard st == noErr else { throw ConfigError("output unit format (\(st))") }
        var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, io in
            Unmanaged<Router>.fromOpaque(refCon).takeUnretainedValue().render(Int(frames), io)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        st = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard st == noErr else { throw ConfigError("output unit callback (\(st))") }
        target = Int(r * 0.05); window = Int(r * 0.01)   // keep ~50 ms buffered, +-10 ms before correcting drift
        prefilling = true
        thb_ring_skip(ring, thb_ring_readable(ring))
        st = AudioUnitInitialize(u)
        guard st == noErr else { throw ConfigError("output unit init (\(st))") }
        st = AudioOutputUnitStart(u)
        guard st == noErr else { throw ConfigError("output unit start (\(st))") }
    }

    private func stopUnit() {
        guard let u = unit else { return }
        AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
        unit = nil
    }

    // MARK: real-time

    private func render(_ n: Int, _ io: UnsafeMutablePointer<AudioBufferList>?) {
        guard let io, let out = UnsafeMutableAudioBufferListPointer(io).first?.mData?.assumingMemoryBound(to: Float32.self) else { return }
        pull()
        let level = thb_ring_readable(ring) / 8
        if prefilling {
            if level < target { out.update(repeating: 0, count: n * 2); return }
            prefilling = false
        }
        if level < n {
            underruns.add(1, ordering: .relaxed); prefilling = true
            out.update(repeating: 0, count: n * 2); return
        }
        if level > target + 10 * window { thb_ring_skip(ring, (level - target) * 8) }  // after a stall: jump back to target
        else if level > target + window, n > 1 { thb_ring_skip(ring, 8); adjusted.add(1, ordering: .relaxed) }  // drop one frame
        else if level < target - window, n > 1 {  // repeat one frame
            let got = thb_ring_read(ring, out, (n - 1) * 8) / 8
            (out + got * 2).update(from: out + max(0, got - 1) * 2, count: 2)
            if got + 1 < n { (out + (got + 1) * 2).update(repeating: 0, count: (n - got - 1) * 2) }
            adjusted.add(1, ordering: .relaxed); return
        }
        let got = thb_ring_read(ring, out, n * 8) / 8
        if got < n { (out + got * 2).update(repeating: 0, count: (n - got) * 2) }
    }

    /// Moves new frames from the driver's shared mix into the stereo ring, folding 5.1 down to stereo.
    private func pull() {
        var lost: Int64 = 0
        let fl = offsets[0], fr = offsets[1], fc = offsets[2], sl = offsets[4], sr = offsets[5], ch = channels
        let k: Float32 = 0.70710678
        while true {
            let n = Int(thb_shm_read(shm, floats, Int32(scratchFrames), &lost))
            if n == 0 { break }
            for i in 0..<n {
                let f = floats + i * ch
                let c = f[fc] * k
                stereo[2 * i] = max(-1, min(1, f[fl] + c + f[sl] * k))
                stereo[2 * i + 1] = max(-1, min(1, f[fr] + c + f[sr] * k))
            }
            _ = thb_ring_write_all(ring, stereo, n * 8)  // full ring (output stopped): drop
        }
    }
}
