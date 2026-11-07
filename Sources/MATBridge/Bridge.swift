// The worker: owns the pipeline, keeps it healthy, and hands the TV to Apple Music while it plays.
import AppKit
import CoreAudio
import Foundation
import Synchronization

final class Bridge {
    enum Mode: String { case waiting, active, handedOff }

    let config: Config
    private(set) var mode = Mode.waiting
    private var pipeline: Pipeline?
    private var sender: TVSender?
    private var capture: Capture?
    private var encoder: EncoderThread?
    private var testData: Data?

    private var lastFailure = ""
    private var nextAttempt = Date.distantPast
    private var lastOutCallbacks: Int64 = -1, lastCapCallbacks: Int64 = -1
    private var stalledTicks = 0
    private var lastStats = Date()
    private var musicPlaying = false
    private var musicFromProbe = false    // handed off at startup because Music was already playing
    private var musicQuietTicks = 0
    private var asleep = false
    private var activatedOnce = false
    private var reclaim: DispatchWorkItem?
    private var listeners: [PropertyListener] = []
    private var hogListener: PropertyListener?
    private var hogListenerDev: AudioObjectID = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private let parentPID = getppid()

    init(_ config: Config) throws {
        self.config = config
        if let f = config.testFile {
            guard let d = FileManager.default.contents(atPath: f) else { throw ConfigError("cannot read \(f)") }
            testData = d
        }
    }

    // MARK: lifecycle

    func start() {
        listeners.append(contentsOf: [
            PropertyListener(systemObject, addr(kAudioHardwarePropertyDevices)) { [weak self] in self?.devicesChanged() },
            PropertyListener(systemObject, addr(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.defaultOutputChanged() },
            PropertyListener(systemObject, addr(kAudioHardwarePropertyDefaultSystemOutputDevice)) { [weak self] in self?.defaultOutputChanged() },
        ].compactMap { $0 })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("system going to sleep")
            asleep = true
            if mode == .active { deactivate("system sleep") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("system woke")
            asleep = false
            if mode == .waiting { nextAttempt = Date().addingTimeInterval(2) }
        })
        if config.musicHandoff {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
                self?.musicChanged(n.userInfo?["Player State"] as? String ?? "?")
            })
            // Music only announces changes, so one already playing when we start would otherwise lose the TV to us.
            if CA.musicOutputState() == .sending {
                log("Apple Music is already sending audio")
                musicChanged("Playing", fromProbe: true)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    /// Clean shutdown: release the TV and point the default output at it.
    func shutdown() {
        timer?.invalidate()
        if mode == .active { deactivate("shutting down") }
        mode = .waiting
        Recovery.run(config, moveDefaultOutput: true)
    }

    // MARK: activation

    private func activate() {
        guard let tvDev = config.findTV(savedUID: SavedState.load()?.tvUID) else { return fail("no TV: \(config.tvDescription) not present") }
        watchHog(tvDev)
        var src: AudioObjectID?
        var channels = config.channelMap ?? [0, 1, 2, 3, 4, 5]
        if testData == nil {
            guard let s = Capture.findDevice() else {
                return fail("the MATBridge virtual device is not installed (scripts/build-driver.sh, scripts/install-driver.sh)")
            }
            src = s
            if CA.f64(s, kAudioDevicePropertyNominalSampleRate) != Double(config.rate) {
                let st = CA.setF64(s, kAudioDevicePropertyNominalSampleRate, Double(config.rate))
                for _ in 0..<20 where CA.f64(s, kAudioDevicePropertyNominalSampleRate) != Double(config.rate) { Thread.sleep(forTimeInterval: 0.05) }
                log("'\(CA.name(s))' sample rate -> \(config.rate) (status \(st))")
            }
            if config.channelMap == nil { channels = speakerMap(s) }
        }
        do {
            let p = try Pipeline(rate: config.rate, targetMs: config.targetMs)
            p.mute = config.mute
            var cap: Capture?
            if let src { cap = try Capture(dev: src, channels: channels); capture = cap }  // validates before the TV is touched
            let tv = try TVSender(dev: tvDev)
            sender = tv
            try tv.acquire(pipeline: p)
            let enc = try EncoderThread(p, testData: testData)
            enc.workgroupDevice = src ?? tvDev
            enc.realtime = config.realtime
            enc.start()
            pipeline = p; encoder = enc  // from here on teardown() must stop it, even if capture fails below
            if let cap, let src {
                try cap.start(pipeline: p)
                _ = cap.mixAdvanced()  // baseline for the health check
                // Take the system output the first time, and later only back from the TV or the built-in speakers
                // (where the hand-off or macOS put it), never from a device the user picked meanwhile.
                let def = CA.defaultOutput()
                if config.manageDefaultOutput, def != src, !activatedOnce || def == nil || def == tvDev || def == CA.builtInOutput() {
                    log("default output '\(CA.defaultOutput().map(CA.name) ?? "?")' -> '\(CA.name(src))' status \(CA.setDefaultOutput(src))")
                }
            }
            mode = .active; activatedOnce = true; lastFailure = ""; lastOutCallbacks = -1; lastCapCallbacks = -1; stalledTicks = 0
            let inMs = (cap?.latency ?? 0) * 1000, outMs = tv.latency * 1000
            log(String(format: "ACTIVE: %@ -> TrueHD 5.1 %d Hz -> MAT -> '%@'. Latency: capture %.1f + pipeline %.0f (+ encoder burst grouping, included) + TV output %.1f = %.0f ms, plus the soundbar's own decode delay",
                       src.map { "'\(CA.name($0))'" } ?? "test file", config.rate, CA.name(tvDev), inMs, config.targetMs, outMs, inMs + config.targetMs + outMs))
            if let src {
                let rep = (Double(CA.u32(src, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0)
                    + Double(CA.u32(src, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)) / Double(config.rate) * 1000
                log(String(format: "'%@' reports %.1f ms output latency to apps (players add this for A/V sync)", CA.name(src), rep))
            }
        } catch {
            teardown()
            fail("\(error)")
        }
    }

    /// FL FR FC LFE SL SR -> source channel numbers, from the speaker layout set in Audio MIDI Setup.
    private func speakerMap(_ s: AudioObjectID) -> [Int] {
        let fallback = [0, 1, 2, 3, 4, 5]
        guard let labels = CA.preferredChannelLabels(s, kAudioObjectPropertyScopeOutput) else {
            log("speaker layout of '\(CA.name(s))' unknown; assuming channels 1-6 = L R C LFE Ls Rs"); return fallback
        }
        let want: [[AudioChannelLabel]] = [
            [kAudioChannelLabel_Left], [kAudioChannelLabel_Right], [kAudioChannelLabel_Center], [kAudioChannelLabel_LFEScreen],
            [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft],
            [kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight],
        ]
        let m = want.map { ls in ls.lazy.compactMap { labels.firstIndex(of: $0) }.first }
        let desc = labels.map(labelName).joined(separator: " ")
        guard m.allSatisfy({ $0 != nil }) else {
            log("speaker layout of '\(CA.name(s))' is [\(desc)], not 5.1; assuming channels 1-6 = L R C LFE Ls Rs. Set it to 5.1 in Audio MIDI Setup > Configure Speakers.")
            return fallback
        }
        let map = m.map { $0! }
        log("speaker layout [\(desc)] -> FL FR FC LFE SL SR from channels \(map.map { String($0 + 1) }.joined(separator: " "))")
        return map
    }

    /// When another app (Apple Music) holds the TV exclusively, take it back the moment it lets go instead of
    /// waiting for the next retry.
    private func watchHog(_ tv: AudioObjectID) {
        guard hogListenerDev != tv else { return }
        hogListener = PropertyListener(tv, addr(kAudioDevicePropertyHogMode)) { [weak self] in
            guard let self, mode == .waiting, !asleep, lastFailure.contains("hogged"),
                  CA.i32(tv, kAudioDevicePropertyHogMode) == -1 else { return }
            log("TV released by the other app; taking it back")
            nextAttempt = .distantPast
            activate()
        }
        hogListenerDev = hogListener == nil ? 0 : tv
    }

    private func fail(_ why: String) {
        if why != lastFailure { log("not active: \(why) (will keep retrying)"); lastFailure = why }
        nextAttempt = Date().addingTimeInterval(2)
    }

    private func teardown() {
        capture?.stop(); capture = nil
        encoder?.stop(); encoder = nil
        sender?.release(); sender = nil
        pipeline = nil
    }

    private func deactivate(_ why: String) {
        log("deactivating: \(why)")
        logStats()
        teardown()
        mode = .waiting
        if why.contains("went away") { hogListener = nil; hogListenerDev = 0 }  // device IDs may be reused after coreaudiod restarts
    }

    // MARK: health

    private func tick() {
        if getppid() != parentPID { log("supervisor is gone; exiting"); shutdown(); exit(0) }
        if asleep { return }
        switch mode {
        case .handedOff:
            // Music announces pause and stop, but not quitting by crash or force quit, and when we handed off at
            // startup it may have been paused with its output still running. So also watch Music itself: gone, or
            // (after a startup hand-off) not sending audio, for 3 ticks in a row (rides out the switch of its output
            // from the virtual device to the TV). Not "idle" after a notified hand-off: Music playing to AirPlay
            // can look idle, and taking the TV back then would flap on every track change.
            guard musicPlaying else { return }
            let m = CA.musicOutputState()
            let quiet = m == .notRunning || (musicFromProbe && m == .idle)
            musicQuietTicks = quiet ? musicQuietTicks + 1 : 0
            if musicQuietTicks >= 3 { musicChanged(m == .notRunning ? "Stopped (Music quit)" : "Stopped (no longer sending audio)") }
        case .waiting:
            if Date() >= nextAttempt { activate() }
        case .active:
            if let why = unhealthy() {
                deactivate(why)
                nextAttempt = Date().addingTimeInterval(1)
            } else if Date().timeIntervalSince(lastStats) >= config.statsInterval { logStats() }
        }
    }

    /// Devices still there? No side effects, so it is safe to call from listeners at any rate.
    private func gone() -> String? {
        guard let sender else { return nil }
        let alive = CA.u32(sender.dev, kAudioDevicePropertyDeviceIsAlive) ?? 0
        if alive == 0 || !CA.devices().contains(sender.dev) { return "TV went away" }
        if let c = capture, CA.u32(c.dev, kAudioDevicePropertyDeviceIsAlive) != 1 { return "virtual device went away" }
        return nil
    }

    /// Full check, once per tick (the stall test compares IO counters with the previous tick).
    private func unhealthy() -> String? {
        guard let sender, let pipeline else { return "no pipeline" }
        if let why = gone() { return why }
        if !sender.stillOurs { return "TV hog/format changed underneath us (hog \(CA.i32(sender.dev, kAudioDevicePropertyHogMode) ?? -99), format \(CA.describe(CA.physicalFormat(sender.stream))))" }
        let out = pipeline.outCallbacks.load(ordering: .relaxed), cap = pipeline.capCallbacks.load(ordering: .relaxed)
        let outStalled = out == lastOutCallbacks, capStalled = capture != nil && cap == lastCapCallbacks
        let mixStalled = !(capture?.mixAdvanced() ?? true)
        stalledTicks = outStalled || capStalled || mixStalled ? stalledTicks + 1 : 0
        lastOutCallbacks = out; lastCapCallbacks = cap
        if stalledTicks >= 3 { return outStalled ? "TV IO stopped" : capStalled ? "capture IO stopped" : "driver stopped writing the shared mix" }
        if let c = capture, CA.f64(c.dev, kAudioDevicePropertyNominalSampleRate) != Double(config.rate) { return "virtual device sample rate changed" }
        if !(encoder?.isExecuting ?? false) { return "encoder thread stopped" }
        return nil
    }

    private func devicesChanged() {
        if mode == .active, let why = gone() { deactivate(why); nextAttempt = Date().addingTimeInterval(1) }
        else if mode == .waiting { nextAttempt = min(nextAttempt, Date().addingTimeInterval(1)) }
    }

    /// While Music holds the TV exclusively, macOS moves the system output to the next device on its list, which
    /// is usually the virtual device (used most recently). Nothing reads it during the hand-off, so other apps
    /// would be silent; send them to the Mac's built-in speakers instead, as macOS does without MATBridge.
    private func defaultOutputChanged() {
        guard mode == .handedOff, config.manageDefaultOutput,
              let src = Capture.findDevice() else { return }
        let def = CA.defaultOutput(), sys = CA.u32(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice)
        guard def == src || sys == src else { return }
        let tv = config.findTV(savedUID: SavedState.load()?.tvUID)
        let outs = CA.devices().filter { CA.channelCount($0, kAudioObjectPropertyScopeOutput) > 0 && $0 != src && $0 != tv }
        guard let fallback = CA.builtInOutput() ?? outs.first else { return }
        log("macOS moved the output to '\(CA.name(src))' while Music holds the TV; using '\(CA.name(fallback))' instead (status \(CA.setDefaultOutput(fallback)))")
    }

    private func logStats() {
        lastStats = Date()
        guard let p = pipeline else { return }
        func l(_ a: borrowing Atomic<Int64>) -> Int64 { a.load(ordering: .relaxed) }
        log(String(format: "stats: buffer avg %.1f ms (target %.0f), drift corr %lld ppm, dropped %lld / repeated %lld frames, underruns %lld, burst skips %lld, overflows pcm %lld burst %lld, shared-mix frames lost %lld",
                   Double(l(p.avgLevelMicros)) / 1000, config.targetMs, l(p.correctionPPM), l(p.droppedFrames), l(p.dupedFrames),
                   l(p.underruns), l(p.skips), l(p.pcmOverflows), l(p.burstOverflows), l(p.mixLost)))
    }

    // MARK: Apple Music hand-off

    private func musicChanged(_ state: String, fromProbe: Bool = false) {
        log("Music: \(state)")
        musicPlaying = state == "Playing"
        musicFromProbe = fromProbe; musicQuietTicks = 0
        reclaim?.cancel(); reclaim = nil
        if musicPlaying {
            guard mode != .handedOff else { return }
            if mode == .active { deactivate("Apple Music is playing; handing the TV to Music") }
            mode = .handedOff
            // Point the system output at the TV so Music follows it there, unless the user picked another output.
            if let tv = config.findTV(savedUID: SavedState.load()?.tvUID) { Recovery.restoreDefaultOutput(config, tv: tv) }
        } else if mode == .handedOff {
            let w = DispatchWorkItem { [weak self] in
                guard let self, !musicPlaying, mode == .handedOff else { return }
                log("Music no longer playing; taking the TV back")
                mode = .waiting; nextAttempt = .distantPast; tick()  // while asleep, tick() waits for wake
            }
            reclaim = w
            DispatchQueue.main.asyncAfter(deadline: .now() + config.handoffDelay, execute: w)
        }
    }
}
