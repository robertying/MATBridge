import CoreAudio
import Foundation

// `run` = supervisor: spawns `worker`, forwards SIGINT/SIGTERM/SIGHUP, and after the worker exits for any reason
// (including a crash or SIGKILL) restores the TV. Restarts a crashed worker unless it crash-loops.

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
let config: Config
do { config = try Config.parse(Array(argv.dropFirst())) } catch {
    FileHandle.standardError.write("\(error)\n\n\(Config.usage)\n".data(using: .utf8)!); exit(2)
}

var signalSources: [DispatchSourceSignal] = []  // global: must outlive the run loop
func onSignals(_ sigs: [Int32], _ handler: @escaping (Int32) -> Void) -> [DispatchSourceSignal] {
    sigs.map { sig in
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { handler(sig) }; s.resume(); return s
    }
}

switch command {
case "recover":
    exit(Recovery.run(config, moveDefaultOutput: true) ? 0 : 1)

case "status":
    Recovery.status(config)

case "devices":
    Recovery.listDevices()

case "worker":
    logPrefix = " [worker \(getpid())]"
    let bridge: Bridge
    do { bridge = try Bridge(config) } catch { log("\(error)"); exit(2) }
    signalSources = onSignals([SIGINT, SIGTERM, SIGHUP]) { sig in
        log("signal \(sig); stopping")
        bridge.shutdown()
        exit(0)
    }
    bridge.start()
    RunLoop.main.run()

case "run":
    logPrefix = " [supervisor \(getpid())]"
    // When stdout is a log file (the login item), start it over once it passes 10 MB. It is opened for
    // appending, so writes simply continue at the new end.
    var st = stat()
    if fstat(STDOUT_FILENO, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 10_000_000 {
        ftruncate(STDOUT_FILENO, 0); log("log file was over 10 MB; started over")
    }
    let supervisor = Supervisor(config: config, workerArgs: Array(argv.dropFirst()))
    signalSources = onSignals([SIGINT, SIGTERM, SIGHUP]) { sig in supervisor.stop(signal: sig) }
    supervisor.spawn()
    dispatchMain()

default:
    print(Config.usage)
    exit(command == "help" || command == "--help" || command == "-h" ? 0 : 2)
}

/// Runs the worker, restores the TV whenever it exits, and restarts it after a crash. All state is touched on the
/// main queue only.
final class Supervisor: @unchecked Sendable {
    let config: Config
    let workerArgs: [String]
    let exe = Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    var child: pid_t = 0
    var stopping = false
    var crashes: [Date] = []

    init(config: Config, workerArgs: [String]) { self.config = config; self.workerArgs = workerArgs }

    func spawn() {
        var cargs = ([exe, "worker"] + workerArgs).map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        let st = posix_spawn(&child, exe, nil, nil, &cargs, environ)
        if st != 0 { log("spawn failed: \(String(cString: strerror(st)))"); Recovery.run(config, moveDefaultOutput: true); exit(1) }
        log("started worker pid \(child)")
        let pid = child
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async { self.workerExited(pid, status) }
        }
    }

    func stop(signal sig: Int32) {
        log("signal \(sig); stopping worker")
        stopping = true
        if child > 0 { kill(child, SIGTERM) }
        // If the worker does not exit in time, kill it; workerExited() then restores the TV.
        let pid = child
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if pid > 0 { kill(pid, SIGKILL) } }
    }

    private func workerExited(_ pid: pid_t, _ status: Int32) {
        let signaled = status & 0x7f != 0 && status & 0x7f != 0x7f
        let code = (status >> 8) & 0xff
        log("worker \(pid) exited (\(signaled ? "signal \(status & 0x7f)" : "status \(code)"))")
        if stopping || (!signaled && code == 0) {
            Recovery.run(config, moveDefaultOutput: true)  // normally a no-op; the worker cleans up itself
            exit(0)
        }
        // Crash: make the TV usable again right away, then restart unless we are crash-looping.
        Recovery.run(config, moveDefaultOutput: false)
        crashes = crashes.filter { $0.timeIntervalSinceNow > -120 } + [Date()]
        if crashes.count >= 5 || code == 2 {
            log(code == 2 ? "worker reported a configuration error; giving up" : "worker crashed 5 times in 2 minutes; giving up")
            Recovery.run(config, moveDefaultOutput: true)
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !self.stopping { self.spawn() } }
    }
}
