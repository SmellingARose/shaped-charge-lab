import Foundation
import Metal

func runHeadless(_ args: [String]) {
    setvbuf(stdout, nil, _IOLBF, 0)
    var cfg = SimConfig()
    func arg(_ k: String) -> Float? {
        guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
        return Float(args[i + 1])
    }
    if let v = arg("--standoff") { cfg.standoffCD = v }
    if let v = arg("--layers") { cfg.layers = Int(v) }
    if let v = arg("--angle") { cfg.coneAngleDeg = v }
    if args.contains("--linear") { cfg.geometry = .linear }
    if let v = arg("--refine") { cfg.jetRefinement = Int(v) }
    let tmax = arg("--tmax") ?? 1000
    let sim = Simulation(cfg: cfg)
    sim.threads = Int(arg("--threads") ?? 10)
    print("particles \(sim.n)  dp \(sim.dp)  L \(sim.L)  zFace \(sim.zFace)")
    let start = Date()
    var nextPrint: Float = 0
    while !sim.isDone && sim.time < tmax {
        sim.step()
        if sim.time >= nextPrint {
            nextPrint += 5
            print(String(format: "t %6.1f  dt %.4f  steps %6d  act %6d gh %5d  tipZ %7.1f tipV %5.2f  pen %6.1f  frag %3d  %@  %.2fms",
                         sim.time, sim.dt, sim.stepCount, sim.nActive, sim.nGhost, sim.tipZ, sim.tipV,
                         sim.penetration, sim.jetFragments, sim.phase, sim.lastStepMs))
        }
        if args.contains("--debug") && (sim.stepCount % 50 == 0 || (sim.time > (arg("--dbgfrom") ?? 1e9))) {
            var pmaxHE: Float = 0, vmaxL: Float = 0, vminL: Float = 0, nb: Float = 0, cnt = 0, burned = 0
            var worst = 0; var worstV: Float = 0
            for i in 0..<sim.n where sim.flags.p[i] & PF.active != 0 {
                if sim.mat.p[i] == 0 { pmaxHE = max(pmaxHE, sim.p.p[i]); if sim.burn.p[i] >= 1 { burned += 1 } }
                if sim.mat.p[i] == 1 { vmaxL = max(vmaxL, sim.vz.p[i]); vminL = min(vminL, sim.vx.p[i]); nb += Float(sim.nbrCount.p[i]); cnt += 1 }
                let sp = abs(sim.ax.p[i]) + abs(sim.az.p[i]); if sp > worstV && sim.flags.p[i] & PF.fixed == 0 { worstV = sp; worst = i }
            }
            print(String(format: "   dbg pHE %.1f burned %d  liner vzmax %.2f vxmin %.2f nbr %.1f  maxacc #%d mat %d a %.1f vx %.2f vz %.2f x %.3f z %.2f rho %.2f p %.2f h %.2f nc %d sxx %.2f szz %.2f dmg %d", pmaxHE, burned, vmaxL, vminL, nb/Float(max(cnt,1)), worst, sim.mat.p[worst], worstV, sim.vx.p[worst], sim.vz.p[worst], sim.x.p[worst], sim.z.p[worst], sim.rho.p[worst], sim.p.p[worst], sim.h.p[worst], sim.nbrCount.p[worst], sim.sxx.p[worst], sim.szz.p[worst], Int(sim.flags.p[worst] & PF.damaged)))
        }
        if args.contains("--dmgtrace") && sim.stepCount % 40 == 0 {
            var nL = 0, dmg = 0, spallLike = 0, strainLike = 0
            var minP: Float = 0
            for i in 0..<sim.n where sim.mat.p[i] == 1 && sim.flags.p[i] & PF.active != 0 {
                nL += 1
                minP = min(minP, sim.p.p[i])
                if sim.flags.p[i] & PF.damaged != 0 {
                    dmg += 1
                    if sim.epsT.p[i] > sim.mats[1].failStrain { strainLike += 1 } else { spallLike += 1 }
                }
            }
            print(String(format: "   dmg t %5.2f  liner %d damaged %d (tension-strain %d, spall %d)  min p %.1f GPa", sim.time, nL, dmg, strainLike, spallLike, minP))
        }
        if !sim.tipZ.isFinite || sim.tipV.isNaN { print("NaN!"); break }
    }
    if args.contains("--dump") {
        var rows: [(Float, Float, Float, Float, Int32, Float, Float)] = []
        for i in 0..<sim.n where sim.mat.p[i] == 1 && sim.flags.p[i] & PF.active != 0 {
            rows.append((sim.z.p[i], sim.x.p[i], sim.vz.p[i], sim.vx.p[i], sim.nbrCount.p[i], sim.rho.p[i], sim.x0.p[i]))
        }
        rows.sort { $0.0 > $1.0 }
        for r in rows.prefix(Int(arg("--dump") ?? 30)) { print(String(format: "z %7.2f x %6.3f vz %5.2f vx %6.2f nc %3d rho %5.2f x0 %5.2f", r.0, r.1, r.2, r.3, r.4, r.5, r.6))
        }
        do {
            var best = 0; var bz: Float = -1e9
            for i in 0..<sim.n where sim.mat.p[i] == 1 && sim.flags.p[i] & PF.active != 0 && sim.z.p[i] > bz { bz = sim.z.p[i]; best = i }
            print("tip #\(best) h \(sim.h.p[best]) mt \(sim.mt.p[best]) flags \(sim.flags.p[best]) p \(sim.p.p[best]) ax \(sim.ax.p[best]) az \(sim.az.p[best])")
            let nc = Int(sim.nbrCount.p[best]); var tc = 0
            for q in 0..<nc { let j = Int(sim.nbr.p[best*sim.maxN+q]); if j < sim.n && sim.mat.p[j] == 2 { tc += 1 } }
            print("  neighbours \(nc), target \(tc)")
            var near = 0
            for j in 0..<sim.n where sim.mat.p[j] == 2 { let dx = sim.x.p[j]-sim.x.p[best], dz = sim.z.p[j]-sim.z.p[best]; if dx*dx+dz*dz < 1 { near += 1; if near < 4 { print("  tgt x \(sim.x.p[j]) z \(sim.z.p[j]) flags \(sim.flags.p[j]) rho \(sim.rho.p[j]) vz \(sim.vz.p[j]) h \(sim.h.p[j])") } } }
            print("  target within 1mm: \(near)") }
    }
    if let a = sim.analysis {
        print("jet: vtip \(a.vTip) vtail \(a.vTail) zvo \(a.zVO) tvo \(a.tVO) tmeas \(a.tMeasured) jetFrac \(a.jetMassFraction)")
        let tb = a.breakupTime(stretch: arg("--lambda") ?? 6)
        let m = PenetrationModel(jet: a, rhoTarget: sim.mats[2].rho0, resistance: sim.mats[2].bernoulliR,
                                 breakupTime: tb, driftSpeed: 0.02, holeRadius: 0.13 * sim.CD)
        print("tb \(tb) (sph \(String(describing: sim.breakupTime)))")
        for (s, pcd) in m.curve(step: 0.5) { print(String(format: "  S %.2f CD -> P %.2f CD", s, pcd)) }
    }
    print("splits \(sim.splits)  n \(sim.n)")
    print(String(format: "done t=%.1f pen=%.1f mm (%.2f CD) wall %.1fs", sim.time, sim.penetration, sim.penetration / sim.CD, Date().timeIntervalSince(start)))
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--headless3d") { runHeadless3D(args); return }
        if args.contains("--headless") { runHeadless(args); return }
        runApp()
    }
}


func runHeadless3D(_ args: [String]) {
    setvbuf(stdout, nil, _IOLBF, 0)
    func arg(_ k: String) -> Float? {
        guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
        return Float(args[i + 1])
    }
    var cfg = SimConfig()
    cfg.layers = Int(arg("--layers") ?? 3)
    cfg.standoffCD = arg("--standoff") ?? 3
    cfg.targetThicknessCD = arg("--thick") ?? 4
    cfg.jetRefinement = Int(arg("--refine") ?? 3)
    cfg.fineTarget3D = args.contains("--tfine")
    if let r = arg("--trad") { cfg.targetRadiusCD = r }
    let dev = MTLCreateSystemDefaultDevice()!
    let t0 = Date()
    guard let s = Solver3D(cfg: cfg, asym: Asymmetry(), device: dev) else { print("init failed"); return }
    print("3D particles \(s.n)  dpF \(s.dpF)  setup \(Date().timeIntervalSince(t0))s")
    let tmax = arg("--tmax") ?? 40
    var next: Float = 0
    while true {
        let ms = s.run(steps: 20)
        let st = s.readState()
        if st.time >= next || st.time >= tmax || !st.time.isFinite {
            next += 2
            print(String(format: "t %6.2f dt %.4f  tipZ %7.1f tipV %5.2f  linerZ %7.1f pen %6.1f awake %d used %d  %.2f ms/step",
                         st.time, st.dt, st.coreTipZ, st.tipV, st.linerZ, max(st.penZ - s.zFace, 0), st.awake ? 1 : 0, st.used, ms))
        }
        if st.time >= tmax || !st.time.isFinite { break }
    }
    print("wall \(Date().timeIntervalSince(t0))s")
    if args.contains("--jetdump") {
        let ps = s.debugParticles().filter { $0.3 == 1 && $0.1.z > 2.0 }
        print("fast liner particles: \(ps.count)")
        var bins = [Int](repeating: 0, count: 12)
        var rhoSum: [Float] = Array(repeating: 0, count: 12)
        for p in ps {
            let r = (p.0.x * p.0.x + p.0.y * p.0.y).squareRoot()
            let b = min(Int(r / 0.5), 11)
            bins[b] += 1; rhoSum[b] += p.2
        }
        for b in 0..<12 { print(String(format: "  r %4.1f-%4.1f mm: %5d  mean rho %.2f", Float(b) * 0.5, Float(b + 1) * 0.5, bins[b], bins[b] > 0 ? rhoSum[b] / Float(bins[b]) : 0)) }
        let vr = ps.map { p -> Float in let r = (p.0.x * p.0.x + p.0.y * p.0.y).squareRoot(); return r > 1e-3 ? (p.0.x * p.1.x + p.0.y * p.1.y) / r : 0 }
        print("  mean radial speed \(vr.reduce(0, +) / Float(max(vr.count, 1))) km/s, max \(vr.max() ?? 0)")
        let dmg = ps.filter { $0.4 & 1024 != 0 }.count
        print("  damaged \(dmg)")
    }
}
