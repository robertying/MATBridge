// Tells MATBridge which format Apple Music is about to play, from Music's own unified log. Music writes a line each
// time it builds an AudioQueue ("Creating AudioQueue with format:'qec3' ..."). A Dolby format there means the track
// has Atmos: MATBridge then releases the TV, and Music switches to passing Dolby through within ~60 ms. Stereo and
// lossless formats ('qlac', 'aac ') play into the virtual device like any other app, so MATBridge keeps the TV.
//
// Reads `log stream` as a child process: it works unprivileged for admin users (the lines are public, Default
// level). Non-admin accounts can't stream the log; then `available` stays false and the Bridge falls back to
// releasing the TV whenever Music plays.
import Foundation

final class MusicLog: @unchecked Sendable {   // all state on the main queue
    /// Called on the main queue with the four-char format of each new Music AudioQueue.
    var onFormat: ((String) -> Void)?
    /// Called on the main queue when `available` changes.
    var onAvailability: ((Bool) -> Void)?
    /// False once `log stream` has failed to start (until it works again). Optimistic before the first try settles.
    private(set) var available = true

    private var process: Process?
    private var startedAt = Date()
    private var buffer = Data()
    private var warned = false
    private var stopped = false
    private var restart: DispatchWorkItem?

    // Apple's Music app only: any program can be named "Music", but not live in /System/Applications.
    static let predicate = #"process == "Music" AND processImagePath BEGINSWITH "/System/Applications/Music.app/" AND eventMessage CONTAINS "subaq_buildCAAudioQueue" AND eventMessage CONTAINS "Creating AudioQueue""#

    /// E-AC-3, AC-3 and Dolby Atmos/MAT IDs, as Music logs them: 'q' + the format when it decodes ('qec3', 'qac3'),
    /// and the passthrough variants ('qc+3', 'cec3', 'mtc+'...).
    static func isDolby(_ f: String) -> Bool {
        let s = f.lowercased()
        return s.contains("ac3") || s.contains("ec3") || s.contains("c-3") || s.contains("c+3") || s.contains("d+3") || s.contains("mtc") || s.hasPrefix("mt")
    }

    /// The format of the most recent Music AudioQueue in the last few hours, or nil. Calls back on the main queue.
    /// For a Music that was already playing when MATBridge started: its queue was built before `log stream` ran.
    static func lastFormat(_ done: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", "3h", "--style", "compact", "--predicate", predicate]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var f: String?
            if (try? p.run()) != nil {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                f = text.split(separator: "\n").reversed().lazy.compactMap { format(in: String($0)) }.first
            }
            DispatchQueue.main.async { done(f) }
        }
    }

    /// A Dolby queue that Music passes through to the TV ('qc+3'), not one it decodes itself ('qec3', 'qac3').
    static func isPassthrough(_ f: String) -> Bool {
        isDolby(f) && !["qec3", "qac3"].contains(f.lowercased())
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restart?.cancel(); restart = nil
        if let p = process { p.terminationHandler = nil; p.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil; p.terminate() }
        process = nil
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }  // EOF
            DispatchQueue.main.async { self?.received(d) }
        }
        p.terminationHandler = { [weak self] proc in
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.exited(proc, status, msg) }
        }
        startedAt = Date()
        do {
            try p.run()
        } catch {
            exited(nil, -1, "\(error)")
            return
        }
        process = p; buffer.removeAll()
        // `log stream` refuses non-admin users right away; still running after 2 s means it works.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, process === p, p.isRunning else { return }
            if warned { log("Music format watch: log stream works again") }
            warned = false
            setAvailable(true)
        }
    }

    private func exited(_ p: Process?, _ status: Int32, _ msg: String) {
        if let p, process !== p { return }
        process = nil
        guard !stopped else { return }
        let quick = Date().timeIntervalSince(startedAt) < 2
        if quick {
            setAvailable(false)
            if !warned {
                warned = true
                log("Music format watch: 'log stream' failed (status \(status)\(msg.isEmpty ? "" : ": \(msg)")); MATBridge will release the TV whenever Music plays (it can't tell Atmos from stereo). Retrying every minute.")
            }
        } else {
            log("Music format watch: log stream exited (status \(status)); restarting")
        }
        let w = DispatchWorkItem { [weak self] in self?.restart = nil; self?.launch() }
        restart = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 60 : 1), execute: w)
    }

    private func setAvailable(_ a: Bool) {
        guard a != available else { return }
        available = a
        onAvailability?(a)
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let f = Self.format(in: line) { onFormat?(f) }
        }
        if buffer.count > 1 << 20 { buffer.removeAll() }
    }

    /// "... Creating AudioQueue with format:'qec3', ..." -> "qec3"
    static func format(in line: String) -> String? {
        guard line.contains("Creating AudioQueue"), let r = line.range(of: "format:'") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let f = String(rest[..<end])
        return f.isEmpty || f.count > 8 ? nil : f
    }
}
