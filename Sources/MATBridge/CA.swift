// Small CoreAudio HAL helpers.
import AudioToolbox
import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}

func fourcc(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
    return b.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(bytes: b, encoding: .ascii)! : "\(v)"
}
func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

enum CA {
    static func ids(_ o: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = a; var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var v = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : []
    }

    static func string(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel); var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(o, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }
    enum MusicOutput { case notRunning, idle, sending }
    /// Whether Apple Music is running and has audio output running (to any device). Core Audio's process objects need
    /// no permission.
    static func musicOutputState() -> MusicOutput {
        let procs = ids(systemObject, addr(kAudioHardwarePropertyProcessObjectList)).filter { string($0, kAudioProcessPropertyBundleID) == "com.apple.Music" }
        if procs.isEmpty { return .notRunning }
        return procs.contains { u32($0, kAudioProcessPropertyIsRunningOutput) == 1 } ? .sending : .idle
    }
    static func builtInOutput() -> AudioObjectID? {
        devices().first { uid($0).hasPrefix("BuiltIn") && channelCount($0, kAudioObjectPropertyScopeOutput) > 0 }
    }
    static func name(_ o: AudioObjectID) -> String { string(o, kAudioObjectPropertyName) ?? "?" }
    static func uid(_ o: AudioObjectID) -> String { string(o, kAudioDevicePropertyDeviceUID) ?? "" }

    static func u32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(sel, sc); var v: UInt32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func i32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Int32? {
        var a = addr(sel); var v: Int32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    @discardableResult
    static func setU32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: UInt32, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var a = addr(sel, sc); var v = v
        return AudioObjectSetPropertyData(o, &a, 0, nil, 4, &v)
    }
    @discardableResult
    static func setI32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: Int32) -> OSStatus {
        var a = addr(sel); var v = v
        return AudioObjectSetPropertyData(o, &a, 0, nil, 4, &v)
    }
    static func f64(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
        var a = addr(sel); var v: Float64 = 0; var size: UInt32 = 8
        return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    @discardableResult
    static func setF64(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: Double) -> OSStatus {
        var a = addr(sel); var v = v
        return AudioObjectSetPropertyData(o, &a, 0, nil, 8, &v)
    }
    static func isSettable(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool {
        var a = addr(sel); var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(o, &a, &s) == noErr && s.boolValue
    }

    static func devices() -> [AudioObjectID] { ids(systemObject, addr(kAudioHardwarePropertyDevices)) }
    static func streams(_ dev: AudioObjectID, _ sc: AudioObjectPropertyScope) -> [AudioStreamID] { ids(dev, addr(kAudioDevicePropertyStreams, sc)) }
    static func channelCount(_ dev: AudioObjectID, _ sc: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, sc); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Finds a device by name substring. `scope` requires channels in that direction.
    static func find(nameContains: String, scope: AudioObjectPropertyScope) -> AudioObjectID? {
        devices().first { channelCount($0, scope) > 0 && name($0).localizedCaseInsensitiveContains(nameContains) }
    }
    static func device(uid: String) -> AudioObjectID? {
        devices().first { CA.uid($0) == uid }
    }

    static func defaultOutput() -> AudioObjectID? { u32(systemObject, kAudioHardwarePropertyDefaultOutputDevice) }
    /// Sets both the output and the system (alert) output.
    static func setDefaultOutput(_ d: AudioObjectID) -> OSStatus {
        let s = setU32(systemObject, kAudioHardwarePropertyDefaultOutputDevice, d)
        setU32(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, d)
        return s
    }

    static func physicalFormat(_ s: AudioStreamID) -> AudioStreamBasicDescription {
        var a = addr(kAudioStreamPropertyPhysicalFormat); var f = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(s, &a, 0, nil, &size, &f); return f
    }
    @discardableResult
    static func setPhysicalFormat(_ s: AudioStreamID, _ f: AudioStreamBasicDescription) -> OSStatus {
        var a = addr(kAudioStreamPropertyPhysicalFormat); var f = f
        return AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &f)
    }
    static func availablePhysicalFormats(_ s: AudioStreamID) -> [AudioStreamBasicDescription] {
        availablePhysicalRanged(s).map(\.mFormat)
    }
    static func availablePhysicalRanged(_ s: AudioStreamID) -> [AudioStreamRangedDescription] {
        var a = addr(kAudioStreamPropertyAvailablePhysicalFormats); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(s, &a, 0, nil, &size) == noErr else { return [] }
        var v = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride)
        guard AudioObjectGetPropertyData(s, &a, 0, nil, &size, &v) == noErr else { return [] }
        return Array(v.prefix(Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride))
    }

    /// The device's preferred speaker layout (what Audio MIDI Setup "Configure Speakers" sets), as one label per channel.
    static func preferredChannelLabels(_ dev: AudioObjectID, _ sc: AudioObjectPropertyScope) -> [AudioChannelLabel]? {
        var a = addr(kAudioDevicePropertyPreferredChannelLayout, sc); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return nil }
        var layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        var expanded: UnsafeMutableRawPointer?
        defer { expanded?.deallocate() }
        if layout.pointee.mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions {
            // Expand a layout tag into channel descriptions (bitmaps are not used by speaker setups).
            var tag = layout.pointee.mChannelLayoutTag
            if tag == kAudioChannelLayoutTag_UseChannelBitmap { return nil }
            var esize: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &esize) == noErr, esize > 0 else { return nil }
            let e = UnsafeMutableRawPointer.allocate(byteCount: Int(esize), alignment: 16); expanded = e
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &esize, e) == noErr else { return nil }
            layout = e.assumingMemoryBound(to: AudioChannelLayout.self)
        }
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        return withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) { p in
            p.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { d in (0..<n).map { d[$0].mChannelLabel } }
        }
    }

    static func describe(_ f: AudioStreamBasicDescription) -> String {
        "'\(fourcc(f.mFormatID))' \(f.mChannelsPerFrame)ch \(f.mBitsPerChannel)-bit \(Int(f.mSampleRate))Hz"
    }

    static func pidAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
}

func labelName(_ l: AudioChannelLabel) -> String {
    switch l {
    case kAudioChannelLabel_Left: return "L"
    case kAudioChannelLabel_Right: return "R"
    case kAudioChannelLabel_Center: return "C"
    case kAudioChannelLabel_LFEScreen: return "LFE"
    case kAudioChannelLabel_LeftSurround: return "Ls"
    case kAudioChannelLabel_RightSurround: return "Rs"
    case kAudioChannelLabel_LeftSurroundDirect: return "Lsd"
    case kAudioChannelLabel_RightSurroundDirect: return "Rsd"
    case kAudioChannelLabel_RearSurroundLeft: return "Rls"
    case kAudioChannelLabel_RearSurroundRight: return "Rrs"
    case kAudioChannelLabel_Unused: return "-"
    case kAudioChannelLabel_Unknown: return "?"
    default: return "#\(l)"
    }
}

/// Listens to a HAL property and calls `handler` on the main queue. Keep the returned token alive.
final class PropertyListener {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        self.object = object; self.address = address
        block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr else { return nil }
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}
