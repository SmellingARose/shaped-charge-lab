import Foundation
import Metal

struct Frame3D {
    let time: Float
    let data: Data
    let penetration: Float
    let tipV: Float
    let tipTravel: Float
    let phase: String
}

struct RecordProgress {
    var time: Float = 0
    var estimatedEnd: Float = 100
    var msPerStep: Double = 0
    var frames = 0
    var megabytes = 0
    var penetration: Float = 0
    var particles = 0
    var phase = ""
}

/// Latest 3D frame handed to the renderer.
final class Feed3D {
    private let lock = NSLock()
    private var data = Data()
    private(set) var info = Frame3DInfo()
    private var tipZ: Float = 0
    private(set) var version = 0

    func set(_ frame: Frame3D, info i: Frame3DInfo) {
        lock.lock(); defer { lock.unlock() }
        data = frame.data
        info = i
        tipZ = i.scene.L + frame.tipTravel
        version += 1
    }

    func clear() { lock.lock(); data = Data(); version += 1; lock.unlock() }

    /// Copies the frame into `buffer` if it changed since `seen`; returns particle count and scene.
    func copy(into buffer: MTLBuffer, seen: inout Int) -> (Int, Frame3DInfo, Float) {
        lock.lock(); defer { lock.unlock() }
        let count = min(data.count / 12, buffer.length / 12)
        if seen != version {
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress { memcpy(buffer.contents(), base, count * 12) }
            }
            seen = version
        }
        return (count, info, tipZ)
    }

    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return data.count }
}

/// Runs a full 3D simulation offline and stores frames for playback.
final class Recorder3D {
    private let lock = NSLock()
    private var frames: [Frame3D] = []
    private var cancelled = false
    private(set) var info = Frame3DInfo()
    var budgetBytes = 3_000_000_000

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func frame(_ i: Int) -> Frame3D? {
        lock.lock(); defer { lock.unlock() }
        return frames.indices.contains(i) ? frames[i] : nil
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func start(cfg: SimConfig, asym: Asymmetry,
               onProgress: @escaping (RecordProgress) -> Void,
               onFrame: @escaping (Frame3D, Frame3DInfo) -> Void,
               onDone: @escaping (Float, Bool) -> Void) {
        lock.lock(); frames = []; cancelled = false; lock.unlock()
        let t = Thread { [weak self] in
            guard let self else { return }
            guard let dev = MTLCreateSystemDefaultDevice(), let s = Solver3D(cfg: cfg, asym: asym, device: dev) else {
                DispatchQueue.main.async { onDone(0, false) }
                return
            }
            self.info = s.info
            let frameBytes = s.n * 12
            let maxFrames = max(40, self.budgetBytes / max(frameBytes, 1))
            var interval: Float = 0.5
            var nextFrame: Float = 0
            var best: Float = 0, wakeTime: Float = -1
            var lastReport = Date.distantPast
            let apexTime = s.zApex / cfg.detonationVelocity
            let estEnd = apexTime + 6 + (s.zFace - s.zApex) / 6.5 + cfg.targetThicknessCD * s.CD / 3.0 * 0.6 + 20
            var ms: Double = 0
            var stepsPerBatch = 10

            func phase(_ st: SolverState, _ pen: Float) -> String {
                if st.time < apexTime { return "Detonation" }
                if st.coreTipZ < s.L + 0.1 * s.CD { return "Liner collapse" }
                if !st.awake || pen < 0.05 { return "Jet stretching" }
                return "Penetrating"
            }
            func capture(_ st: SolverState, _ pen: Float, final: Bool = false) {
                let f = Frame3D(time: st.time, data: s.packFrame(), penetration: pen, tipV: st.tipV,
                                tipTravel: st.coreTipZ - s.L, phase: final ? "Complete" : phase(st, pen))
                self.lock.lock()
                self.frames.append(f)
                if self.frames.count > maxFrames {
                    self.frames = self.frames.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                    interval *= 2
                }
                self.lock.unlock()
                let info = self.info
                DispatchQueue.main.async { onFrame(f, info) }
            }

            while true {
                self.lock.lock(); let stop = self.cancelled; self.lock.unlock()
                if stop { break }
                ms = s.run(steps: stepsPerBatch)
                stepsPerBatch = ms < 5 ? 20 : 10
                let st = s.readState()
                if !st.time.isFinite { break }
                let pen = max(st.penZ - s.zFace, 0)
                if st.awake && wakeTime < 0 { wakeTime = st.time }
                best = max(best, pen)
                if st.time >= nextFrame {
                    capture(st, best)
                    nextFrame = st.time + interval
                }
                // stop once nothing over the target moves fast enough to penetrate (½ρ_jet·v² = R_target)
                let vCut = (2 * cfg.target.material.bernoulliR / cfg.liner.material.rho0).squareRoot()
                let done = (wakeTime >= 0 && st.time - wakeTime > 5 && st.footprintMaxVz < vCut)
                    || best >= cfg.targetThicknessCD * s.CD - 2 * s.dpC || st.time > 500
                if Date().timeIntervalSince(lastReport) > 0.15 || done {
                    lastReport = Date()
                    var p = RecordProgress()
                    p.time = st.time
                    p.estimatedEnd = max(estEnd, st.time + (done ? 0 : 5))
                    p.msPerStep = ms
                    p.frames = self.frameCount
                    p.megabytes = p.frames * frameBytes / 1_000_000
                    p.penetration = best
                    p.particles = s.n
                    p.phase = phase(st, best)
                    DispatchQueue.main.async { onProgress(p) }
                }
                if done {
                    capture(st, best, final: true)
                    break
                }
            }
            self.lock.lock(); let wasCancelled = self.cancelled; self.lock.unlock()
            DispatchQueue.main.async { onDone(best, !wasCancelled) }
        }
        t.qualityOfService = .userInitiated
        t.name = "3D recorder"
        t.start()
    }
}
