// Capture (virtual device input) -> PCM ring -> encoder thread (drift control, TrueHD/MAT) -> burst ring -> TV IOProc.
import CTrueHD
import CoreAudio
import Foundation
import Synchronization

let burstBytes = Int(THB_MAT_BURST_BYTES)
let encChannels = Int(THB_CHANNELS)

final class Pipeline: @unchecked Sendable {
    let rate: Int
    let bytesPerFrame: Int64      // MAT bytes per PCM frame (61440 bytes = 20 ms of audio)
    let targetFrames: Int64
    let pcmRing: OpaquePointer    // interleaved int32 x6
    let burstRing: OpaquePointer  // whole MAT bursts
    let silence: UnsafeMutablePointer<UInt8>
    let wake = DispatchSemaphore(value: 0)
    var mute = false

    // Counters shared between threads.
    let inFrames = Atomic<Int64>(0)        // PCM frames handed to the encoder (after drift correction)
    let liveBytesOut = Atomic<Int64>(0)    // bytes of real (non-filler) bursts consumed by the TV, or skipped
    let outCallbacks = Atomic<Int64>(0)
    let capCallbacks = Atomic<Int64>(0)
    let underruns = Atomic<Int64>(0)
    let skips = Atomic<Int64>(0)
    let burstOverflows = Atomic<Int64>(0)
    let pcmOverflows = Atomic<Int64>(0)
    let droppedFrames = Atomic<Int64>(0)
    let dupedFrames = Atomic<Int64>(0)
    let correctionPPM = Atomic<Int64>(0)
    let avgLevelMicros = Atomic<Int64>(0)
    let playing = Atomic<Bool>(false)      // false while (re)filling the buffer before playback; no drift control then

    // Output IOProc state (only touched on the TV's IO thread).
    private var burstPos = 0
    private var burstLive = false
    private var prefilling = true

    init(rate: Int, targetMs: Double) throws {
        self.rate = rate
        bytesPerFrame = Int64(burstBytes / (rate / 50))
        targetFrames = Int64(targetMs * Double(rate) / 1000)
        pcmRing = thb_ring_create(rate * encChannels * 4)!            // 1 s
        burstRing = thb_ring_create(burstBytes * 16)!                 // 320 ms
        silence = .allocate(capacity: burstBytes)
        try Pipeline.makeSilenceBurst(rate: rate, into: silence)
    }

    deinit {
        thb_ring_destroy(pcmRing); thb_ring_destroy(burstRing); silence.deallocate()
    }

    /// Encodes a bit of digital silence and keeps one steady-state burst, used as filler on underrun so the
    /// soundbar stays locked to MAT instead of seeing nothing.
    static func makeSilenceBurst(rate: Int, into dst: UnsafeMutablePointer<UInt8>) throws {
        final class Box { var count = 0; let dst: UnsafeMutablePointer<UInt8>; init(_ d: UnsafeMutablePointer<UInt8>) { dst = d } }
        let box = Box(dst)
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        guard let enc = thb_enc_create(Int32(rate), { ctx, burst, len in
            let b = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            b.dst.update(from: burst!, count: Int(len)); b.count += 1
        }, ctx, &err, 256) else { throw ConfigError("encoder: \(String(cString: err))") }
        defer { thb_enc_destroy(enc) }
        let zeros = [Int32](repeating: 0, count: rate / 10 * encChannels)
        while box.count < 4 { _ = thb_enc_push(enc, zeros, Int32(rate / 10)) }
    }

    /// Buffered audio between the encoder input and the TV, in PCM frames.
    var level: Int64 { inFrames.load(ordering: .relaxed) - liveBytesOut.load(ordering: .relaxed) / bytesPerFrame }

    // MARK: TV IOProc (real-time thread)

    func render(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) {
        outCallbacks.add(1, ordering: .relaxed)
        var w = 0
        while w < n {
            if burstPos == 0 { startBurst() }
            let chunk = min(n - w, burstBytes - burstPos)
            if burstLive {
                let got = thb_ring_read(burstRing, dst + w, chunk)
                if got < chunk { (dst + w + got).update(repeating: 0, count: chunk - got) }  // cannot happen: whole bursts only
                liveBytesOut.add(Int64(got), ordering: .relaxed)
            } else {
                (dst + w).update(from: silence + burstPos, count: chunk)
            }
            w += chunk
            burstPos = (burstPos + chunk) % burstBytes
        }
    }

    private func startBurst() {
        let readable = thb_ring_readable(burstRing)
        if prefilling {
            burstLive = readable >= burstBytes && level >= targetFrames
            if burstLive { prefilling = false; playing.store(true, ordering: .relaxed) }
            return
        }
        if readable < burstBytes {
            underruns.add(1, ordering: .relaxed)
            prefilling = true; burstLive = false; playing.store(false, ordering: .relaxed)
            return
        }
        // Way too much buffered (e.g. after a stall): drop a whole burst rather than drift down for minutes.
        if level > targetFrames + Int64(rate) * 45 / 1000, readable >= 2 * burstBytes {
            thb_ring_skip(burstRing, burstBytes)
            liveBytesOut.add(Int64(burstBytes), ordering: .relaxed)
            skips.add(1, ordering: .relaxed)
        }
        burstLive = true
    }

    // MARK: capture IOProc (real-time thread)

    /// `map[i]` = (buffer index, channel offset in that buffer, channels in that buffer) for output channel i.
    func capture(_ abl: UnsafePointer<AudioBufferList>, map: [(Int, Int, Int)], scratch: UnsafeMutablePointer<Int32>, scratchFrames: Int) {
        capCallbacks.add(1, ordering: .relaxed)
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard let first = bufs.first, first.mNumberChannels > 0 else { return }
        var frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        var start = 0
        while frames > 0 {
            let n = min(frames, scratchFrames)
            for (c, m) in map.enumerated() {
                guard m.0 < bufs.count, let p = bufs[m.0].mData?.assumingMemoryBound(to: Float32.self) else {
                    for i in 0..<n { scratch[i * encChannels + c] = 0 }; continue
                }
                let stride = m.2
                var src = p + (start * stride + m.1)
                for i in 0..<n {
                    let v = Double(src.pointee) * 2147483648.0
                    // Clamp; NaN (a misbehaving app) becomes 0 instead of trapping in Int32(v).
                    scratch[i * encChannels + c] = v >= 2147483647 ? .max : (v <= -2147483648 ? .min : (v.isNaN ? 0 : Int32(v)))
                    src += stride
                }
            }
            if mute { scratch.update(repeating: 0, count: n * encChannels) }
            if thb_ring_write_all(pcmRing, scratch, n * encChannels * 4) == 0 { pcmOverflows.add(1, ordering: .relaxed) }
            frames -= n; start += n
        }
        wake.signal()
    }
}

/// Encoder thread: pulls PCM, applies drift correction, encodes, pushes whole MAT bursts.
final class EncoderThread: Thread, @unchecked Sendable {
    let p: Pipeline
    let testData: Data?   // loop this raw s32le 6ch file instead of reading captured PCM
    private var enc: OpaquePointer?
    private let stopFlag = Atomic<Bool>(false)
    let done = DispatchSemaphore(value: 0)

    init(_ p: Pipeline, testData: Data?) throws {
        self.p = p; self.testData = testData
        super.init()
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(p).toOpaque()
        enc = thb_enc_create(Int32(p.rate), { ctx, burst, len in
            let p = Unmanaged<Pipeline>.fromOpaque(ctx!).takeUnretainedValue()
            if thb_ring_write_all(p.burstRing, burst, Int(len)) == 0 {
                p.burstOverflows.add(1, ordering: .relaxed)
                p.liveBytesOut.add(Int64(len), ordering: .relaxed)  // that audio is gone; keep the level honest
            }
        }, ctx, &err, 256)
        guard enc != nil else { throw ConfigError("encoder: \(String(cString: err))") }
        name = "truehd-encoder"
        qualityOfService = .userInteractive
    }

    func stop() { stopFlag.store(true, ordering: .relaxed); p.wake.signal(); done.wait() }

    /// Device whose real-time IO workgroup this thread joins (the capture device, else the TV).
    var workgroupDevice: AudioObjectID = 0
    var realtime = true

    override func main() {
        defer { thb_enc_destroy(enc); enc = nil; done.signal() }
        // Real-time scheduling, so CPU load (builds, video decoding) cannot starve the encoder and empty the TV's
        // buffer. Joining the audio device's IO workgroup keeps it on performance cores on Apple silicon.
        if realtime { EncoderThread.makeRealtime(periodMs: 5, computationMs: 1.5) }
        let wg = realtime && workgroupDevice != 0 ? thb_wg_join_device(workgroupDevice) : nil
        if realtime, workgroupDevice != 0, wg == nil { log("encoder: could not join the audio IO workgroup") }
        defer { thb_wg_leave(wg) }
        let chunk = max(256, p.rate / 100)
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: (chunk + 1) * encChannels)
        defer { buf.deallocate() }
        if let testData { runTestFile(testData, buf, chunk); return }

        var acc = 0.0, ppm = 0.0
        var levelSum = 0.0, levelN = 0.0, lastAdjust = Date()
        let frameBytes = encChannels * 4
        while !stopFlag.load(ordering: .relaxed) {
            _ = p.wake.wait(timeout: .now() + .milliseconds(100))
            while !stopFlag.load(ordering: .relaxed) {
                let n = thb_ring_read(p.pcmRing, buf, chunk * frameBytes) / frameBytes
                if n == 0 { break }
                var frames = n
                // Clock drift between the virtual device and the HDMI clock: drop or repeat single frames. Only once
                // playback runs: while the buffer (re)fills, its level says nothing about drift.
                if !p.playing.load(ordering: .relaxed) { acc = 0; ppm = 0; levelSum = 0; levelN = 0 }
                acc += ppm * 1e-6 * Double(n)
                if acc >= 1, frames > 1 { frames -= 1; acc -= 1; p.droppedFrames.add(1, ordering: .relaxed) }
                else if acc <= -1 {
                    (buf + frames * encChannels).update(from: buf + (frames - 1) * encChannels, count: encChannels)
                    frames += 1; acc += 1; p.dupedFrames.add(1, ordering: .relaxed)
                }
                if thb_enc_push(enc, buf, Int32(frames)) < 0 { log("encoder: push failed"); return }
                p.inFrames.add(Int64(frames), ordering: .relaxed)
                if p.playing.load(ordering: .relaxed) { levelSum += Double(p.level); levelN += 1 }
            }
            if Date().timeIntervalSince(lastAdjust) >= 0.5, levelN > 0 {
                let avgMs = levelSum / levelN * 1000 / Double(p.rate)
                let errMs = avgMs - Double(p.targetFrames) * 1000 / Double(p.rate)
                ppm = max(-1000, min(1000, 50 * errMs))
                p.correctionPPM.store(Int64(ppm), ordering: .relaxed)
                p.avgLevelMicros.store(Int64(avgMs * 1000), ordering: .relaxed)
                levelSum = 0; levelN = 0; lastAdjust = Date()
            }
        }
    }

    static func makeRealtime(periodMs: Double, computationMs: Double) {
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        func abs(_ ms: Double) -> UInt32 { UInt32(ms * 1_000_000 * Double(tb.denom) / Double(tb.numer)) }
        var policy = thread_time_constraint_policy_data_t(period: abs(periodMs), computation: abs(computationMs),
                                                          constraint: abs(periodMs), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if kr != KERN_SUCCESS { log("encoder: real-time scheduling not granted (\(kr))") }
    }

    /// Test mode: no capture device; feed a file, paced by how fast the TV consumes.
    private func runTestFile(_ data: Data, _ buf: UnsafeMutablePointer<Int32>, _ chunk: Int) {
        let frameBytes = encChannels * 4
        let total = data.count / frameBytes
        guard total > 0 else { log("test file is empty"); return }
        var pos = 0
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int32.self).baseAddress!
            while !stopFlag.load(ordering: .relaxed) {
                if p.level < p.targetFrames + Int64(p.rate / 200) {
                    let n = min(chunk, total - pos)
                    if thb_enc_push(enc, src + pos * encChannels, Int32(n)) < 0 { log("encoder: push failed"); return }
                    p.inFrames.add(Int64(n), ordering: .relaxed)
                    pos = (pos + n) % total
                } else {
                    usleep(2000)
                }
                p.avgLevelMicros.store(p.level * 1_000_000 / Int64(p.rate), ordering: .relaxed)
            }
        }
    }
}
