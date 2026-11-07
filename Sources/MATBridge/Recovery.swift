// Puts the HDMI output back into normal shared PCM mode. Safe to run any time, any number of times.
import CTrueHD
import CoreAudio
import Foundation

enum Recovery {
    /// - Parameters:
    ///   - moveDefaultOutput: if the system output is the virtual device (nothing reads it once the bridge stops) or
    ///     the built-in speakers macOS fell back to while the TV was held, point it at the TV, or at the built-in
    ///     speakers when the TV is gone or held by another app.
    /// - Returns: true if the TV is (now) in a normal state.
    @discardableResult
    static func run(_ config: Config, moveDefaultOutput: Bool) -> Bool {
        var saved = SavedState.load()
        guard let tv = config.findTV(savedUID: saved?.tvUID),
              let stream = CA.streams(tv, kAudioObjectPropertyScopeOutput).first else {
            log("recover: no TV (\(config.tvDescription)) present; nothing to restore on it")
            if moveDefaultOutput { restoreDefaultOutput(config, tv: nil) }
            return false
        }
        let me = getpid()
        if let owner = CA.i32(tv, kAudioDevicePropertyHogMode), owner != -1 {
            if owner == me || !CA.pidAlive(owner) || owner == saved?.workerPID {
                let st = CA.setI32(tv, kAudioDevicePropertyHogMode, -1)
                log("recover: released hog held by pid \(owner) -> status \(st), now \(CA.i32(tv, kAudioDevicePropertyHogMode) ?? -99)")
            } else {
                log("recover: TV is hogged by another live process (pid \(owner)); leaving it alone")
                if moveDefaultOutput { restoreDefaultOutput(config, tv: nil) }
                return false
            }
        }
        if CA.isSettable(tv, kAudioDevicePropertySupportsMixing), CA.u32(tv, kAudioDevicePropertySupportsMixing) == 0 {
            log("recover: mixing on -> status \(CA.setU32(tv, kAudioDevicePropertySupportsMixing, 1))")
        }
        // Restore the exact original format if we left the TV changed (crash), or any LPCM format if it is
        // still on an encoded one. A TV the user reconfigured themselves (state not dirty) is left alone.
        let cur = CA.physicalFormat(stream)
        let dirty = saved?.dirty == true && saved?.tvUID == CA.uid(tv)
        let avail = CA.availablePhysicalFormats(stream).filter { $0.mFormatID == kAudioFormatLinearPCM }
        func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
            a.mFormatID == b.mFormatID && a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
        }
        var target: AudioStreamBasicDescription? = nil
        if let s = saved?.format, dirty || cur.mFormatID != kAudioFormatLinearPCM { target = avail.first { same($0, s) } }
        if target == nil, cur.mFormatID != kAudioFormatLinearPCM {
            let at48 = avail.filter { $0.mSampleRate == 48000 }
            target = at48.max { a, b in a.mChannelsPerFrame != b.mChannelsPerFrame ? a.mChannelsPerFrame < b.mChannelsPerFrame : a.mBitsPerChannel < b.mBitsPerChannel } ?? avail.first
        }
        if let target, !same(cur, target) {
            let st = CA.setPhysicalFormat(stream, target)
            for _ in 0..<30 where !same(CA.physicalFormat(stream), target) { Thread.sleep(forTimeInterval: 0.1) }
            log("recover: physical format \(CA.describe(cur)) -> \(CA.describe(target)) status \(st); now \(CA.describe(CA.physicalFormat(stream)))")
        }
        let ok = CA.physicalFormat(stream).mFormatID == kAudioFormatLinearPCM
        if ok, dirty { saved!.dirty = false; saved!.save() }
        if moveDefaultOutput { restoreDefaultOutput(config, tv: tv) }
        return ok
    }

    /// Points the system output at `tv`, or at the built-in speakers when `tv` is nil. Only replaces the virtual
    /// device or the built-in speakers (what MATBridge or macOS put there), never a device the user picked.
    static func restoreDefaultOutput(_ config: Config, tv: AudioObjectID?) {
        guard config.manageDefaultOutput, let def = CA.defaultOutput() else { return }
        let src = Capture.findDevice()
        let builtIn = CA.devices().first { CA.uid($0).hasPrefix("BuiltIn") && CA.channelCount($0, kAudioObjectPropertyScopeOutput) > 0 }
        guard let want = tv ?? builtIn, want != def, def == src || def == builtIn else { return }
        log("recover: default output '\(CA.name(def))' -> '\(CA.name(want))' status \(CA.setDefaultOutput(want))")
    }

    static func status(_ config: Config) {
        let saved = SavedState.load()
        if let tv = config.findTV(savedUID: saved?.tvUID),
           let stream = CA.streams(tv, kAudioObjectPropertyScopeOutput).first {
            let hog = CA.i32(tv, kAudioDevicePropertyHogMode) ?? -99
            print("TV:      '\(CA.name(tv))' uid \(CA.uid(tv))")
            print("         physical \(CA.describe(CA.physicalFormat(stream))), hog \(hog == -1 ? "none" : "pid \(hog)\(CA.pidAlive(hog) ? "" : " (dead)")"), mixing \(CA.u32(tv, kAudioDevicePropertySupportsMixing).map(String.init) ?? "n/a")")
            let lat = CA.u32(tv, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0
            let so = CA.u32(tv, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0
            print("         device latency \(lat) frames, safety offset \(so) frames")
        } else { print("TV:      not found (\(config.tvDescription))") }
        if let src = Capture.findDevice() {
            let labels = CA.preferredChannelLabels(src, kAudioObjectPropertyScopeOutput)?.map(labelName).joined(separator: " ") ?? "unknown"
            print("Source:  '\(CA.name(src))' uid \(CA.uid(src)), \(Int(CA.f64(src, kAudioDevicePropertyNominalSampleRate) ?? 0)) Hz, speaker layout: \(labels)")
        } else { print("Source:  not found — is the MATBridge driver installed? (scripts/build-driver.sh, scripts/install-driver.sh)") }
        var err = [CChar](repeating: 0, count: 256)
        if let h = thb_shm_open(&err, 256) {
            print("Shared mix: \(thb_shm_channels(h)) ch, \(thb_shm_rate(h)) Hz, \(thb_shm_writes(h)) writes so far")
            thb_shm_close(h)
        } else { print("Shared mix: \(String(cString: err))") }
        if let d = CA.defaultOutput() { print("Default output: '\(CA.name(d))'") }
        if let saved { print("Saved state: TV original format \(CA.describe(saved.format)), last worker pid \(saved.workerPID)\(CA.pidAlive(saved.workerPID) ? " (running)" : ""), TV \(saved.dirty == true ? "possibly still changed by the bridge" : "restored")") }
    }

    static func listDevices() {
        for d in CA.devices() {
            let i = CA.channelCount(d, kAudioObjectPropertyScopeInput), o = CA.channelCount(d, kAudioObjectPropertyScopeOutput)
            let mat = CA.streams(d, kAudioObjectPropertyScopeOutput).first.map { s in
                CA.availablePhysicalFormats(s).contains { $0.mFormatID == TVSender.matFormat && $0.mSampleRate == 768000 }
            } ?? false
            print(String(format: "%5d  in %2d  out %2d  ", d, i, o) + "\(CA.name(d))  [\(CA.uid(d))]\(mat ? "  <- accepts Dolby MAT (TrueHD)" : "")")
        }
    }
}
