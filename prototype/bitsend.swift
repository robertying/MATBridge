// bitsend <file.spdif> [fourcc] [loops] [device-name]
// The original proof of concept for MATBridge. Plays a raw IEC 61937 stream (16-bit LE stereo frames, as written
// by `ffmpeg -f spdif`) bit-exact to an HDMI output in exclusive mode with an encoded physical format
// (default 'mtct' = Dolby MAT at 768 kHz; 'cac3' = AC-3, 'cec3' = E-AC-3). The device is the first output that
// offers that format, or the first whose name contains [device-name].
// Run: swift prototype/bitsend.swift file.spdif mtct
// Takes hog mode, turns mixing off, sets the encoded format, plays, then restores the original
// physical format, mixing and hog mode. Ctrl-C stops early and still restores.
import CoreAudio
import Foundation

func ts() -> String { ISO8601DateFormatter().string(from: Date()) }
func say(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func ids(_ o: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var a = a; var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var v = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : []
}
func name(_ o: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &s) == noErr ? (s!.takeRetainedValue() as String) : "?"
}
func fourcc(_ v: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)" }
func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func physical(_ s: AudioStreamID) -> AudioStreamBasicDescription {
    var a = addr(kAudioStreamPropertyPhysicalFormat); var f = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(s, &a, 0, nil, &size, &f); return f
}
func setPhysical(_ s: AudioStreamID, _ f: AudioStreamBasicDescription) -> OSStatus {
    var a = addr(kAudioStreamPropertyPhysicalFormat); var f = f
    return AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &f)
}
func d(_ f: AudioStreamBasicDescription) -> String { "'\(fourcc(f.mFormatID))' \(f.mChannelsPerFrame)ch \(f.mBitsPerChannel)-bit \(Int(f.mSampleRate))Hz" }
func getI32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Int32? {
    var a = addr(sel); var v: Int32 = 0; var size: UInt32 = 4
    return AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func setI32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: Int32) -> OSStatus {
    var a = addr(sel); var v = v
    return AudioObjectSetPropertyData(o, &a, 0, nil, 4, &v)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { say("usage: bitsend <file.spdif> [fourcc] [loops]"); exit(2) }
let want = code(args.count > 1 ? args[1] : "mtct")
let loops = args.count > 2 ? max(1, Int(args[2]) ?? 1) : 1
let wantName = args.count > 3 ? args[3] : nil

func formats(_ stream: AudioStreamID) -> [AudioStreamBasicDescription] {
    var a = addr(kAudioStreamPropertyAvailablePhysicalFormats); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(stream, &a, 0, nil, &size)
    var avail = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride)
    AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &avail)
    return avail.map(\.mFormat)
}
let candidates = ids(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices)).compactMap { d -> (AudioObjectID, AudioStreamID)? in
    guard let s = ids(d, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)).first else { return nil }
    return (d, s)
}
guard let (dev, stream) = candidates.first(where: { wantName.map(name($0.0).contains) ?? formats($0.1).contains { $0.mFormatID == want } }) else {
    say(wantName.map { "no output named '\($0)'" } ?? "no output offers '\(fourcc(want))' (is an HDMI/eARC sink connected?)"); exit(1)
}
guard let target = formats(stream).first(where: { $0.mFormatID == want }) else { say("format '\(fourcc(want))' not offered by '\(name(dev))'"); exit(1) }

let original = physical(stream)
let hogBefore = getI32(dev, kAudioDevicePropertyHogMode) ?? -1
say("device \(dev) '\(name(dev))' stream \(stream): physical \(d(original)), hog=\(hogBefore)")
if hogBefore != -1 && hogBefore != getpid() { say("device is hogged by pid \(hogBefore); not taking it"); exit(1) }

// Restore everything we changed, in reverse order. Safe to call more than once.
var procID: AudioDeviceIOProcID?
var tookHog = false, changedMixing = false, changedFormat = false
func restore() {
    if let p = procID { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p); procID = nil }
    if changedFormat { say("restore format -> \(d(original)) status \(setPhysical(stream, original))"); changedFormat = false }
    if changedMixing { _ = setI32(dev, kAudioDevicePropertySupportsMixing, 1); changedMixing = false }
    if tookHog { _ = setI32(dev, kAudioDevicePropertyHogMode, -1); tookHog = false; say("released hog (now \(getI32(dev, kAudioDevicePropertyHogMode) ?? -99))") }
}
var stopRequested = false
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let sigSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main); s.setEventHandler { stopRequested = true }; s.resume(); return s
}
_ = sigSources

// 1. hog
var st = setI32(dev, kAudioDevicePropertyHogMode, getpid())
tookHog = (getI32(dev, kAudioDevicePropertyHogMode) == getpid())
say("hog -> status \(st), owner now \(getI32(dev, kAudioDevicePropertyHogMode) ?? -99)")
guard tookHog else { restore(); exit(1) }
// 2. mixing off (not every device exposes it)
var settable: DarwinBoolean = false; var ma = addr(kAudioDevicePropertySupportsMixing)
if AudioObjectIsPropertySettable(dev, &ma, &settable) == noErr, settable.boolValue {
    st = setI32(dev, kAudioDevicePropertySupportsMixing, 0); changedMixing = (st == noErr); say("mixing off -> status \(st)")
}
// 3. encoded physical format
st = setPhysical(stream, target); changedFormat = true
for _ in 0..<30 where physical(stream).mFormatID != want { Thread.sleep(forTimeInterval: 0.1) }
say("format -> \(d(target)) status \(st); now \(d(physical(stream)))")
guard physical(stream).mFormatID == want else { restore(); exit(1) }

// 4. play the raw bytes `loops` times
let total = data.count * loops
var offset = 0
let finished = DispatchSemaphore(value: 0)
var signalled = false
let bytes = [UInt8](data)
st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, DispatchQueue(label: "bitsend.io", qos: .userInteractive)) { _, _, _, out, _ in
    let abl = UnsafeMutableAudioBufferListPointer(out)
    for buf in abl {
        guard let dst = buf.mData?.assumingMemoryBound(to: UInt8.self) else { continue }
        let n = Int(buf.mDataByteSize)
        var w = 0
        while w < n && offset < total {
            let pos = offset % bytes.count
            let chunk = min(n - w, bytes.count - pos, total - offset)
            bytes.withUnsafeBufferPointer { src in (dst + w).update(from: src.baseAddress! + pos, count: chunk) }
            w += chunk; offset += chunk
        }
        if w < n { (dst + w).update(repeating: 0, count: n - w) }
    }
    if offset >= total && !signalled { signalled = true; finished.signal() }
}
guard st == noErr, procID != nil else { say("IOProc create failed \(st)"); restore(); exit(1) }
st = AudioDeviceStart(dev, procID)
say("playing \(path) x\(loops) (\(String(format: "%.1f", Double(total) / (target.mSampleRate * 4))) s) status \(st)")

while finished.wait(timeout: .now() + 0.1) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    if stopRequested { say("stop requested"); break }
}
Thread.sleep(forTimeInterval: 0.3)
restore()
say("done; physical now \(d(physical(stream)))")
