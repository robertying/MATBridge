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
    private var router: Router?           // while handed off: other apps' sound -> TV (free) or Mac speakers
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
    private var musicLog: MusicLog?       // Music's AudioQueue formats: release the TV only for Dolby
    private var musicHeldTV = false       // handed off, and Music (or another app) has taken the TV since
    private var awaitingMusicSince: Date?  // released the TV for a Dolby queue; Music hasn't taken it yet
    private var hogReclaim = false        // the pending `reclaim` is for Music releasing the TV (not a pause)
    private var defaultMoved = false      // macOS moved the default output since the last hand-off
    private var ignoreDolbyUntil = Date.distantPast  // Music didn't take the TV last time: back off
    private var listeners: [PropertyListener] = []
    private var hogListener: PropertyListener?
    private var hogListenerDev: AudioObjectID = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastLayoutLog = ""
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
            router?.stop()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("system woke")
            asleep = false
            if mode == .waiting { nextAttempt = Date().addingTimeInterval(2) }
        })
        if config.musicHandoff {
            let ml = MusicLog()
            ml.onFormat = { [weak self] f in self?.musicFormat(f) }
            ml.onAvailability = { [weak self] ok in
                guard let self, !ok, musicPlaying, mode != .handedOff else { return }
                handOff("Apple Music is playing (no format watch); handing the TV to Music")
            }
            musicLog = ml
            ml.start()
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
        musicLog?.stop()
        if mode == .active { deactivate("shutting down") }
        stopRouter()
        mode = .waiting
        Recovery.run(config, moveDefaultOutput: true)
    }

    // MARK: activation

    private func activate() {
        guard let tvDev = findTV() else { return fail("no TV: \(config.tvDescription) not present") }
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
        let line = "speaker layout [\(desc)] -> FL FR FC LFE SL SR from channels \(map.map { String($0 + 1) }.joined(separator: " "))"
        if line != lastLayoutLog { log(line); lastLayoutLog = line }  // once, not on every take-back
        return map
    }

    /// When another app (Apple Music) holds the TV exclusively, take it back the moment it lets go instead of
    /// waiting for the next retry.
    private func watchHog(_ tv: AudioObjectID) {
        guard hogListenerDev != tv else { return }
        hogListener = PropertyListener(tv, addr(kAudioDevicePropertyHogMode)) { [weak self] in
            if let self, mode == .handedOff, !asleep { hogChangedWhileHandedOff(tv); return }  // Music took or released the TV
            guard let self, mode == .waiting, !asleep, lastFailure.contains("hogged"),
                  CA.i32(tv, kAudioDevicePropertyHogMode) == -1 else { return }
            log("TV released by the other app; taking it back")
            nextAttempt = .distantPast
            activate()
        }
        hogListenerDev = hogListener == nil ? 0 : tv
    }

    /// The HDMI output: as configured, else the one used last time, else the first that accepts Dolby MAT.
    private func findTV() -> AudioObjectID? { config.findTV(savedUID: SavedState.load()?.tvUID) }

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
        if let src = Capture.findDevice() { DolbyFormats.sync(src: src, tv: findTV()) }
        switch mode {
        case .handedOff:
            // Backstop for a missed hog notification: Music had the TV and let go.
            if musicHeldTV, reclaim == nil, let tv = findTV() { hogChangedWhileHandedOff(tv) }
            router?.check()
            if let t = awaitingMusicSince, !musicHeldTV, reclaim == nil, Date().timeIntervalSince(t) > 10 {
                // Music built a Dolby queue but never took the TV (it fell back to decoding into the virtual device).
                ignoreDolbyUntil = Date().addingTimeInterval(30)
                takeBack("Music didn't take the TV within 10 s; taking it back (not releasing it for Dolby again for 30 s)")
                return
            }
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

    /// When we release the TV for Music, macOS makes it the system output again (it is "preferred" and just became
    /// available). Music then checks the TV (which this Mac may report as DisplayPort) instead of the virtual device and
    /// decodes Dolby itself, so put the output back on the virtual device. A device the user picked is left alone.
    /// On hand-off (`handingOff`) also take it back from the built-in speakers, where a restart may have left it.
    private func defaultOutputChanged(handingOff: Bool = false) {
        guard mode == .handedOff, config.manageDefaultOutput, let src = Capture.findDevice(),
              let tv = findTV() else { return }
        let def = CA.defaultOutput(), sys = CA.u32(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice)
        if handingOff, def != src, def == nil || def == CA.builtInOutput() {
            log("default output '\(def.map(CA.name) ?? "?")' -> '\(CA.name(src))' status \(CA.setDefaultOutput(src))"); return
        }
        guard def == tv || sys == tv else { return }
        defaultMoved = true
        log("macOS moved the output to '\(CA.name(tv))' while Music plays; back to '\(CA.name(src))' (status \(CA.setDefaultOutput(src)))")
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

    private func startRouter() {
        guard router == nil, testData == nil, let src = Capture.findDevice() else { return }
        do {
            let r = try Router(src: src, tv: findTV(), offsets: config.channelMap ?? speakerMap(src))
            router = r
            r.check()
        } catch { log("router: \(error)") }
    }

    private func stopRouter() {
        guard let r = router else { return }
        r.stop(); router = nil
        log("router stopped (underruns \(r.underruns.load(ordering: .relaxed)), drift corrections \(r.adjusted.load(ordering: .relaxed)))")
    }

    /// True while Music's AudioQueue formats are known (log stream running): then MATBridge keeps the TV while
    /// Music plays and releases it only for Dolby. Otherwise it releases it whenever Music plays.
    private var watchingFormats: Bool { musicLog?.available ?? false }

    private var tvHeldByOther: Bool {
        guard let tv = findTV(), let h = CA.i32(tv, kAudioDevicePropertyHogMode) else { return false }
        return h != -1 && h != getpid()
    }

    /// Releases the TV for Music. The system output stays on the virtual device: it reports HDMI and lists the TV's
    /// Dolby formats, which is what makes Music pass Dolby Atmos through to the TV (Music opens the TV itself).
    /// Everything that still plays to the virtual device (other apps; Music when it does not pass through) the router
    /// sends to the TV as stereo while the TV is free, or to the Mac's speakers while Music holds it.
    private func handOff(_ why: String) {
        reclaim?.cancel(); reclaim = nil
        if mode == .active { deactivate(why) } else { log(why) }
        mode = .handedOff
        awaitingMusicSince = nil
        let tv = findTV()
        if let tv { watchHog(tv) }  // not yet installed when we start up with Music already holding the TV
        musicHeldTV = (tv.flatMap { CA.i32($0, kAudioDevicePropertyHogMode) } ?? -1) != -1
        startRouter()
        defaultOutputChanged(handingOff: true)
    }

    private func takeBack(_ why: String) {
        reclaim?.cancel(); reclaim = nil; hogReclaim = false
        guard mode == .handedOff else { return }
        log(why)
        stopRouter()
        mode = .waiting; nextAttempt = .distantPast; tick()  // while asleep, tick() waits for wake
    }

    /// After `handoffDelay`, take the TV back if `still()` holds then.
    private func scheduleTakeBack(_ why: String, hog: Bool, if still: @escaping () -> Bool) {
        reclaim?.cancel()
        hogReclaim = hog
        let w = DispatchWorkItem { [weak self] in
            guard let self, mode == .handedOff else { return }
            reclaim = nil; hogReclaim = false
            guard still() else { router?.check(); return }
            takeBack(why)
        }
        reclaim = w
        DispatchQueue.main.asyncAfter(deadline: .now() + config.handoffDelay, execute: w)
    }

    private func hogChangedWhileHandedOff(_ tv: AudioObjectID) {
        let hog = CA.i32(tv, kAudioDevicePropertyHogMode) ?? -1
        if hog != -1 {
            musicHeldTV = true; awaitingMusicSince = nil
            if musicPlaying { reclaim?.cancel(); reclaim = nil; hogReclaim = false }  // released and taken again (track change): stay handed off
            router?.check()
        } else if watchingFormats, musicHeldTV {
            // Music let go: a pause (also announced), or the next track has no Atmos and plays into the virtual
            // device. Wait out the hand-off delay so a quick release and re-take on a track change doesn't flap.
            musicHeldTV = false
            scheduleTakeBack("TV released by Music; taking it back", hog: true) { CA.i32(tv, kAudioDevicePropertyHogMode) == -1 }
        } else if reclaim == nil {
            router?.check()
        }
    }

    /// Music built an AudioQueue. Dolby while we hold the TV: hand the TV over, and Music switches to passthrough.
    private func musicFormat(_ f: String) {
        let dolby = MusicLog.isDolby(f)
        log("Music audio queue: '\(f)'\(dolby ? " (Dolby)" : "")")
        guard dolby else { return }
        if mode == .handedOff { if musicPlaying { reclaim?.cancel(); reclaim = nil; hogReclaim = false }; return }
        guard musicPlaying else { return }  // Music rebuilds its queue for a moment after pausing
        if Date() < ignoreDolbyUntil { log("not releasing the TV: Music didn't take it last time"); return }
        defaultMoved = false
        handOff("Apple Music is starting Dolby ('\(f)'); handing the TV to Music")
        awaitingMusicSince = Date()
        // Music only re-evaluates passthrough when the default output changes. Releasing the TV usually makes macOS
        // move the output to it (and defaultOutputChanged moves it back), but not always; then do that ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, mode == .handedOff, !musicHeldTV, !defaultMoved, config.manageDefaultOutput,
                  let src = Capture.findDevice(), CA.defaultOutput() == src,
                  let tv = findTV() else { return }
            log("nudging the default output (-> '\(CA.name(tv))' and back) so Music re-evaluates passthrough (status \(CA.setDefaultOutput(tv)))")
        }
    }

    private func musicChanged(_ state: String, fromProbe: Bool = false) {
        log("Music: \(state)")
        musicPlaying = state == "Playing"
        musicFromProbe = fromProbe; musicQuietTicks = 0
        // A track change announces "Stopped"/"Playing" around Music letting go of the TV for a stereo track: keep the
        // take-back that the release scheduled (it checks the TV is still free when it fires).
        if !hogReclaim { reclaim?.cancel(); reclaim = nil }
        if musicPlaying {
            // With the format watch, keep the TV: Music's stereo and its decoded Atmos (5.1) are encoded like any
            // other app's sound, and a Dolby queue hands the TV over (musicFormat).
            guard mode != .handedOff else { return }
            if !watchingFormats { handOff("Apple Music is playing; handing the TV to Music") }
            else if tvHeldByOther { handOff("Apple Music is playing and holds the TV") }
        } else if mode == .handedOff, !hogReclaim {
            scheduleTakeBack("Music no longer playing; taking the TV back", hog: false) { [weak self] in !(self?.musicPlaying ?? true) }
        }
    }
}
