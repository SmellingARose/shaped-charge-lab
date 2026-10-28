import Foundation
import SwiftUI

struct SimStats {
    var time: Float = 0
    var phase = "Ready"
    var tipV: Float = 0
    var tipTravel: Float = 0
    var penetration: Float = 0
    var msPerStep: Double = 0
    var stepsPerSec: Double = 0
    var active = 0
    var particles = 0
    var fragments = 0
    var done = false
    var targetAwake = false
}

struct JetPoint: Identifiable {
    let id: Int
    let z: Float
    let v: Float
    let isJet: Bool
}

struct CurvePoint: Identifiable {
    var id: Float { standoff }
    let standoff: Float
    let penetration: Float
}

/// Runs the solver on its own thread and feeds stats/particles back.
final class SimRunner {
    let feed: RenderFeed
    private let lock = NSLock()
    private var sim: Simulation
    private var running = false
    private var threadCount = 4
    private var pace: Float = 0           // simulated µs per wall second, 0 = as fast as possible
    var onStats: ((SimStats, [JetPoint]?, JetProfile?) -> Void)?
    var onFinished: ((Float) -> Void)?

    init(sim: Simulation, feed: RenderFeed) {
        self.sim = sim
        self.feed = feed
        feed.publish(sim)
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInitiated
        t.name = "SPH solver"
        t.start()
    }

    func replace(_ s: Simulation) {
        lock.lock()
        s.threads = threadCount
        sim = s
        running = false
        lock.unlock()
        feed.publish(s)
        publish(force: true)
    }

    func setRunning(_ r: Bool) { lock.lock(); running = r; wallStart = nil; lock.unlock() }
    func setThreads(_ n: Int) { lock.lock(); threadCount = n; sim.threads = n; lock.unlock() }
    func setPace(_ p: Float) { lock.lock(); pace = p; wallStart = nil; lock.unlock() }
    func step(_ n: Int) {
        lock.lock()
        for _ in 0..<n where !sim.isDone { sim.step() }
        lock.unlock()
        feed.publish(sim)
        publish(force: true)
    }

    private var wallStart: Date?
    private var simStart: Float = 0
    private var lastRender = Date.distantPast
    private var lastStats = Date.distantPast
    private var stepWindow: [Date] = []
    private var lastJetSample = Date.distantPast

    private func loop() {
        while true {
            lock.lock()
            guard running else { lock.unlock(); Thread.sleep(forTimeInterval: 0.02); continue }
            let now = Date()
            if pace > 0 {
                if wallStart == nil { wallStart = now; simStart = sim.time }
                let allowed = simStart + pace * Float(now.timeIntervalSince(wallStart!))
                if sim.time > allowed { lock.unlock(); Thread.sleep(forTimeInterval: 0.004); continue }
            }
            sim.step()
            stepWindow.append(now)
            let done = sim.isDone
            if done { running = false }
            let s = sim
            lock.unlock()

            if now.timeIntervalSince(lastRender) > 1.0 / 60 || done {
                lastRender = now
                feed.publish(s)
            }
            if now.timeIntervalSince(lastStats) > 0.1 || done {
                lastStats = now
                publish(force: false, sim: s)
            }
            if done {
                let pen = s.penetration
                DispatchQueue.main.async { self.onFinished?(pen) }
            }
        }
    }

    private func publish(force: Bool, sim s0: Simulation? = nil) {
        let s: Simulation
        if let s0 { s = s0 } else { lock.lock(); s = sim; lock.unlock() }
        let now = Date()
        stepWindow.removeAll { now.timeIntervalSince($0) > 1 }
        var st = SimStats()
        st.time = s.time
        st.phase = s.stepCount == 0 ? "Ready" : s.phase
        st.tipV = s.tipV
        st.tipTravel = s.tipZ - s.L
        st.penetration = s.penetration
        st.msPerStep = s.lastStepMs
        st.stepsPerSec = Double(stepWindow.count)
        st.active = s.nActive
        st.particles = s.n
        st.fragments = s.jetFragments
        st.done = s.isDone
        st.targetAwake = s.targetAwake
        var jet: [JetPoint]?
        if force || now.timeIntervalSince(lastJetSample) > 0.25 {
            lastJetSample = now
            jet = s.linerSamples(max: 900).enumerated().map { JetPoint(id: $0.offset, z: $0.element.0, v: $0.element.1, isJet: $0.element.2) }
        }
        let a = s.analysis
        DispatchQueue.main.async { self.onStats?(st, jet, a) }
    }
}

@MainActor
final class SimController: ObservableObject {
    @Published var config = SimConfig() { didSet { if config != oldValue { rebuild() } } }
    @Published var running = false
    @Published var threads: Double = Double(max(1, ProcessInfo.processInfo.activeProcessorCount - 2)) {
        didSet { runner.setThreads(Int(threads)) }
    }
    @Published var paceIndex: Double = 4 { didSet { runner.setPace(SimController.paces[Int(paceIndex)]) } }
    @Published var stats = SimStats()
    @Published var jetPoints: [JetPoint] = []
    @Published var profile: JetProfile?
    @Published var driftSpeed: Double = 20      // m/s
    @Published var sweepResults: [CurvePoint] = []
    @Published var sweeping = false
    @Published var sweepQueue: [Float] = []

    // view
    @Published var colorMode: Int = 0 { didSet { view.colorMode = UInt32(colorMode) } }
    @Published var cutaway: Double = 90 { didSet { view.cutawayDeg = Float(cutaway) } }
    @Published var showGas = true { didSet { view.showGas = showGas } }
    @Published var showExplosive = true { didSet { view.showExplosive = showExplosive } }
    @Published var showTarget = true { didSet { view.showTarget = showTarget } }
    @Published var showGround = true { didSet { view.showGround = showGround } }
    @Published var bloom = true { didSet { view.bloom = bloom } }
    @Published var follow = false { didSet { view.follow = follow } }
    @Published var sliceOnly = false { didSet { view.sliceOnly = sliceOnly } }

    // full 3D: record offline, then play back
    @Published var mode3D = false { didSet { view.mode3D = mode3D; if !mode3D { playing = false } } }
    @Published var asym = Asymmetry()
    @Published var layers3D: Double = 2
    @Published var recording = false
    @Published var progress = RecordProgress()
    @Published var frameCount = 0
    @Published var frameIndex: Double = 0 { didSet { showFrame(Int(frameIndex)) } }
    @Published var playing = false
    @Published var playbackFPS: Double = 30
    @Published var loop = true
    @Published var frameStats: Frame3D?
    @Published var results3D: [CurvePoint] = []
    let feed3D = Feed3D()
    let recorder = Recorder3D()
    private var playTimer: Timer?
    private var recordedConfig: SimConfig?
    private var followLive = false

    static let paces: [Float] = [0.25, 0.5, 1, 2, 0]
    static let paceLabels = ["¼ µs/s", "½ µs/s", "1 µs/s", "2 µs/s", "Max"]

    let feed = RenderFeed()
    let view = ViewSettings()
    let runner: SimRunner
    private var profiles: [String: JetProfile] = [:]
    private var sphResults: [String: [CurvePoint]] = [:]

    let cores = ProcessInfo.processInfo.activeProcessorCount
    let perfCores: Int = SimController.sysctlInt("hw.perflevel0.physicalcpu")
    let effCores: Int = SimController.sysctlInt("hw.perflevel1.physicalcpu")

    init() {
        let s = Simulation(cfg: SimConfig())
        runner = SimRunner(sim: s, feed: feed)
        s.threads = Int(threads)
        runner.setThreads(Int(threads))
        runner.setPace(SimController.paces[Int(paceIndex)])
        runner.onStats = { [weak self] st, jet, a in
            guard let self else { return }
            self.stats = st
            if let jet { self.jetPoints = jet }
            if let a {
                let key = self.config.chargeKey
                if self.profiles[key] == nil { self.profiles[key] = a }
                self.profile = self.profiles[key]
            }
        }
        runner.onFinished = { [weak self] pen in self?.finished(pen) }
    }

    private static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    func rebuild() {
        running = false
        let s = Simulation(cfg: config)
        runner.replace(s)
        profile = profiles[config.chargeKey]
        sweepResults = sphResults[config.chargeKey + "|" + config.target.rawValue] ?? []
    }

    var config3D: SimConfig {
        var c = config
        c.layers = Int(layers3D)
        c.targetThicknessCD = min(c.targetThicknessCD, 5)
        return c
    }

    var estimated3DParticles: Int { Solver3D.estimate(cfg: config3D) }

    /// Rough wall-clock estimate from measured GPU throughput on an M4 (~13 ns per particle-step at full load).
    var estimated3DMinutes: Double {
        let c = config3D
        let dpF = c.linerThicknessFrac * c.chargeDiameter / Float(c.layers)
        let steps = 110 / (0.03 * Double(dpF))
        return Double(estimated3DParticles) * 13e-9 * steps / 60
    }

    func toggleRecord() {
        if recording { recorder.cancel(); return }
        playing = false
        recording = true
        frameCount = 0
        frameStats = nil
        feed3D.clear()
        let cfg = config3D
        recordedConfig = cfg
        recorder.start(cfg: cfg, asym: asym,
            onProgress: { [weak self] p in self?.progress = p },
            onFrame: { [weak self] f, info in
                guard let self else { return }
                self.frameCount = self.recorder.frameCount
                // follow the newest frame unless the user is playing back or scrubbing earlier frames
                if !self.playing && Int(self.frameIndex) >= self.frameCount - 2 {
                    self.feed3D.set(f, info: info)
                    self.frameStats = f
                    self.followLive = true
                    self.frameIndex = Double(self.frameCount - 1)
                }
            },
            onDone: { [weak self] pen, completed in
                guard let self else { return }
                self.recording = false
                self.frameCount = self.recorder.frameCount
                if completed, let cfg = self.recordedConfig {
                    self.results3D.removeAll { abs($0.standoff - cfg.standoffCD) < 1e-3 }
                    self.results3D.append(CurvePoint(standoff: cfg.standoffCD, penetration: pen / cfg.chargeDiameter))
                    self.results3D.sort { $0.standoff < $1.standoff }
                }
                if !self.playing && self.frameCount > 0 { self.frameIndex = 0; self.togglePlay() }
            })
    }

    func togglePlay() {
        guard frameCount > 0 else { return }
        playing.toggle()
        playTimer?.invalidate()
        guard playing else { return }
        if Int(frameIndex) >= frameCount - 1 { frameIndex = 0 }
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / playbackFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing else { return }
                let next = Int(self.frameIndex) + 1
                if next >= self.frameCount {
                    if self.loop { self.frameIndex = 0 } else { self.playing = false; self.playTimer?.invalidate() }
                } else {
                    self.frameIndex = Double(next)
                }
            }
        }
    }

    func setPlaybackFPS(_ v: Double) {
        playbackFPS = v
        if playing { playing = false; togglePlay() }
    }

    private func showFrame(_ i: Int) {
        if followLive { followLive = false; return }
        guard let f = recorder.frame(i) else { return }
        feed3D.set(f, info: recorder.info)
        frameStats = f
    }

    func toggleRun() {
        if stats.done { rebuild() }
        running.toggle()
        runner.setRunning(running)
    }

    func reset() {
        sweeping = false
        sweepQueue = []
        rebuild()
    }

    func stepOnce() { running = false; runner.setRunning(false); runner.step(20) }

    func startSweep() {
        sweeping = true
        sweepQueue = [1, 2, 3, 4, 6, 8]
        nextSweep()
    }

    private func nextSweep() {
        guard sweeping, !sweepQueue.isEmpty else { sweeping = false; return }
        let s = sweepQueue.removeFirst()
        config.standoffCD = s     // rebuilds
        running = true
        runner.setRunning(true)
    }

    private func finished(_ pen: Float) {
        running = false
        let key = config.chargeKey + "|" + config.target.rawValue
        var arr = sphResults[key] ?? []
        arr.removeAll { abs($0.standoff - config.standoffCD) < 1e-3 }
        arr.append(CurvePoint(standoff: config.standoffCD, penetration: pen / config.chargeDiameter))
        arr.sort { $0.standoff < $1.standoff }
        sphResults[key] = arr
        sweepResults = arr
        if sweeping { nextSweep() }
    }

    // MARK: - 1D penetration model from the measured jet

    var model: PenetrationModel? {
        guard let p = profile else { return nil }
        let t = config.target.material
        return PenetrationModel(jet: p, rhoTarget: t.rho0, resistance: t.bernoulliR,
                                breakupTime: p.breakupTime(stretch: config.breakupStretch),
                                driftSpeed: Float(driftSpeed) / 1000, holeRadius: 0.13 * config.chargeDiameter)
    }

    var curve: [CurvePoint] {
        guard let m = model else { return [] }
        return m.curve(maxCD: 10, step: 0.1).map { CurvePoint(standoff: $0.0, penetration: $0.1) }
    }

    var optimum: CurvePoint? { curve.max { $0.penetration < $1.penetration } }

    var predictedHere: Float? {
        guard let m = model else { return nil }
        return m.penetration(standoff: config.standoffCD * config.chargeDiameter) / config.chargeDiameter
    }

    var estimatedParticles: Int {
        let c = config
        let CD = c.chargeDiameter, R = CD / 2
        let dp = c.linerThicknessFrac * CD / Float(c.layers)
        let a = c.coneAngleDeg / 2 * .pi / 180
        let H = R / tan(a), L = H + c.headHeightCD * CD
        let he = (R * L - 0.5 * R * H) / (dp * dp)
        let tgt = c.targetRadiusCD * CD * c.targetThicknessCD * CD / (dp * dp)
        return Int(he + tgt)
    }

    var cjPressure: Float {
        let D = config.detonationVelocity
        return 1.70 * D * D / 4
    }
}
