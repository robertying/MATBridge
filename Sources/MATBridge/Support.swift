// Logging, configuration, persisted recovery state.
import CTrueHD
import CoreAudio
import Foundation

private let tsFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
}()
private let logLock = NSLock()
var logPrefix = ""
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    print("[\(tsFormatter.string(from: Date()))]\(logPrefix) \(s)")
    fflush(stdout)
}

struct Config {
    var tvName: String? = nil         // nil: auto-detect the output that offers Dolby MAT
    var tvUID: String? = nil
    var codec = Codec.truehd
    var rate = 48000
    var targetMs = 70.0               // buffered audio between capture and the TV IOProc
    var musicHandoff = true
    var handoffDelay = 0.5            // seconds after Music pauses/stops or releases the TV before taking it back
    var manageDefaultOutput = true
    var channelMap: [Int]? = nil      // source channel index for FL FR FC LFE SL SR
    var testFile: String? = nil       // raw s32le 6ch file instead of capture (loops)
    var mute = false                  // diagnostics: capture and encode digital silence
    var realtime = true               // diagnostics: --no-realtime runs the encoder thread at normal priority
    var statsInterval = 60.0

    static let usage = """
    MATBridge — system audio -> Dolby TrueHD 5.1 (MAT, bit-exact) or Dolby Digital 5.1 -> HDMI, exclusive mode

    usage: MATBridge <command> [options]
      run        run the bridge (a supervisor that restarts the worker and cleans up after it)
      recover    restore the HDMI output: release hog, mixing on, original PCM format, system output -> it
      status     show the HDMI output, virtual device, shared mix and saved state
      devices    list audio devices (marks outputs that accept Dolby MAT)

    options:
      --tv NAME             HDMI output name substring (default: the one used last time, else the first
                            output that accepts Dolby MAT)
      --tv-uid UID          HDMI output UID (takes precedence over --tv)
      --codec C             truehd (default: lossless, in Dolby MAT) or ac3 (Dolby Digital 5.1 at 640 kb/s:
                            lossy, but the format every Dolby decoder has handled for decades; 48 kHz only)
      --rate HZ             48000 (default), 96000 or 192000 (TrueHD only)
      --target-ms MS        pipeline buffer target (default 70)
      --no-music-handoff    keep the HDMI output even while Apple Music plays
      --handoff-delay S     seconds to wait after Music pauses/stops or lets go of the TV (default 0.5)
      --no-default-output   never change the system default output device
      --channel-map a,b,c,d,e,f   source channel (0-based) for FL,FR,FC,LFE,SL,SR (default: from the
                            virtual device's speaker layout in Audio MIDI Setup)
      --test-file PATH      play a raw s32le 6ch (FL FR FC LFE SL SR) file in a loop instead of capturing
      --mute                diagnostics: run everything but send digital silence
      --no-realtime         diagnostics: encoder thread at normal priority (for A/B tests)
      --stats-interval S    seconds between stats lines in the log (default 60)
    """

    static func parse(_ args: [String]) throws -> Config {
        var c = Config(); var i = 0
        func next() throws -> String {
            i += 1; guard i < args.count else { throw ConfigError("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--tv": c.tvName = try next()
            case "--tv-uid": c.tvUID = try next()
            case "--codec":
                guard let v = Codec(rawValue: try next()) else { throw ConfigError("--codec must be truehd or ac3") }
                c.codec = v
            case "--rate":
                guard let r = Int(try next()), [48000, 96000, 192000].contains(r) else { throw ConfigError("--rate must be 48000, 96000 or 192000 (the 48 kHz family; MAT runs at 768 kHz)") }
                c.rate = r
            case "--target-ms": guard let v = Double(try next()), v >= 20, v <= 500 else { throw ConfigError("--target-ms must be 20...500") }; c.targetMs = v
            case "--no-music-handoff": c.musicHandoff = false
            case "--handoff-delay": guard let v = Double(try next()), v >= 0 else { throw ConfigError("bad --handoff-delay") }; c.handoffDelay = v
            case "--no-default-output": c.manageDefaultOutput = false
            case "--channel-map":
                let m = try next().split(separator: ",").compactMap { Int($0) }
                guard m.count == 6, m.allSatisfy({ $0 >= 0 }) else { throw ConfigError("--channel-map needs 6 comma-separated 0-based channel numbers") }
                c.channelMap = m
            case "--test-file": c.testFile = try next()
            case "--mute": c.mute = true
            case "--no-realtime": c.realtime = false
            case "--stats-interval": guard let v = Double(try next()), v >= 1 else { throw ConfigError("bad --stats-interval") }; c.statsInterval = v
            default: throw ConfigError("unknown option \(args[i])")
            }
            i += 1
        }
        if c.codec == .ac3, c.rate != 48000 { throw ConfigError("AC-3 runs at 48000 Hz only; drop --rate") }
        return c
    }
}

extension Config {
    /// The HDMI output to send MAT to: --tv-uid, else --tv name, else the one used last time, else the first output offering Dolby MAT
    /// ('mtct') at 768 kHz. That format is only offered while an HDMI/eARC sink that accepts it is connected.
    /// Never the MATBridge virtual device: it lists the TV's Dolby formats too (for Apple Music), MAT included.
    func findTV(savedUID: String? = nil) -> AudioObjectID? {
        func output(_ uid: String?) -> AudioObjectID? {
            guard let uid, uid != Capture.deviceUID, let d = CA.device(uid: uid) else { return nil }
            return CA.channelCount(d, kAudioObjectPropertyScopeOutput) > 0 ? d : nil
        }
        let candidates = CA.devices().filter { CA.uid($0) != Capture.deviceUID && CA.channelCount($0, kAudioObjectPropertyScopeOutput) > 0 }
        if let tvUID { return output(tvUID) }
        if let n = tvName { return candidates.first { CA.name($0).localizedCaseInsensitiveContains(n) } }
        if let d = output(savedUID) { return d }  // the TV used last time, even while another app holds it
        return candidates.first { Self.accepts($0, codec) }
    }

    static func accepts(_ d: AudioObjectID, _ codec: Codec) -> Bool {
        guard let s = CA.streams(d, kAudioObjectPropertyScopeOutput).first else { return false }
        return CA.availablePhysicalFormats(s).contains { $0.mFormatID == codec.formatID && $0.mSampleRate == codec.physicalRate }
    }
    var tvDescription: String { tvName.map { "'\($0)'" } ?? "an HDMI output offering \(codec.formatName)" }
}

/// What MATBridge encodes to. Both reach the TV as IEC 61937 bursts in a 2-channel 16-bit physical format.
enum Codec: String {
    case truehd, ac3

    var c: thb_codec { self == .ac3 ? THB_CODEC_AC3 : THB_CODEC_TRUEHD }
    /// The TV's physical format: Dolby MAT at 768 kHz, or IEC 60958 AC-3 at 48 kHz.
    var formatID: AudioFormatID { self == .ac3 ? code("cac3") : code("mtct") }
    var physicalRate: Double { self == .ac3 ? 48000 : 768000 }
    var formatName: String { self == .ac3 ? "Dolby Digital ('cac3')" : "Dolby MAT ('mtct')" }
    var burstBytes: Int { Int(self == .ac3 ? THB_AC3_BURST_BYTES : THB_MAT_BURST_BYTES) }
    /// PCM frames per burst: one AC-3 frame, or 20 ms of MAT.
    func burstFrames(rate: Int) -> Int { self == .ac3 ? Int(THB_AC3_BURST_FRAMES) : rate / 50 }
    /// For the log: "TrueHD 5.1 48000 Hz -> MAT".
    func describe(rate: Int) -> String { self == .ac3 ? "Dolby Digital 5.1 640 kb/s 48000 Hz" : "TrueHD 5.1 \(rate) Hz -> MAT" }
}

struct ConfigError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

/// What we changed on the TV, so `recover` (or the supervisor after a crash) can undo it.
struct SavedState: Codable {
    var tvUID: String
    var formatID: UInt32, sampleRate: Double, formatFlags: UInt32, bytesPerPacket: UInt32, framesPerPacket: UInt32
    var bytesPerFrame: UInt32, channels: UInt32, bits: UInt32
    var workerPID: Int32
    var dirty: Bool? = nil             // true while the TV is (possibly) changed by us and not yet restored

    init(tvUID: String, format f: AudioStreamBasicDescription, pid: Int32) {
        self.tvUID = tvUID; formatID = f.mFormatID; sampleRate = f.mSampleRate; formatFlags = f.mFormatFlags
        bytesPerPacket = f.mBytesPerPacket; framesPerPacket = f.mFramesPerPacket; bytesPerFrame = f.mBytesPerFrame
        channels = f.mChannelsPerFrame; bits = f.mBitsPerChannel; workerPID = pid
    }
    var format: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: formatFlags, mBytesPerPacket: bytesPerPacket,
                                    mFramesPerPacket: framesPerPacket, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
                                    mBitsPerChannel: bits, mReserved: 0)
    }

    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MATBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }
    static func load() -> SavedState? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) } }
    func save() { try? JSONEncoder().encode(self).write(to: SavedState.url, options: .atomic) }
}
