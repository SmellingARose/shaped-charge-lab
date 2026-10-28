import Foundation
import Metal
import simd

/// Imperfections that only a full 3D run can show.
struct Asymmetry: Equatable {
    var initiationOffset: Float = 0     // mm, detonator off the axis
    var wallVariation: Float = 0        // fraction, liner thicker on one side
}

private struct P3 {
    var gmin: SIMD4<Float>
    var gdim: SIMD4<UInt32>
    var box: SIMD4<Float>
    var misc: SIMD4<Float>
    var cnt: SIMD4<UInt32>
    var quant: SIMD4<Float>
    var quant2: SIMD4<Float>
}

struct SolverState {
    var time: Float = 0
    var dt: Float = 0
    var linerZ: Float = 0
    var penZ: Float = 0
    var awake = false
    var tipV: Float = 0
    var coreTipZ: Float = 0
    var used = 0
    var footprintMaxVz: Float = 0
}

/// Geometry and quantisation needed to draw recorded frames.
struct Frame3DInfo {
    var n = 0
    var quantMin = SIMD3<Float>(0, 0, 0)
    var quantXY: Float = 1
    var quantZ: Float = 1
    var dpFine: Float = 0.3
    var dpCoarse: Float = 0.6
    var scene = SceneInfo()
}

final class Solver3D {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let cfg: SimConfig
    let asym: Asymmetry
    let n: Int
    let dpF: Float, dpC: Float, dpT: Float
    let CD: Float, R: Float, L: Float, zApex: Float, zFace: Float, zBack: Float, RT: Float
    let info: Frame3DInfo
    private var params: P3
    private var pos, vel, st, S0, S1, aux, flags: MTLBuffer
    private var pos2, vel2, st2, S02, S12, aux2, flags2: MTLBuffer
    private var G0, G1, G2, G02, G12, G22: MTLBuffer
    private let L0, L1, L2: MTLBuffer
    private let acc, r0, dS0, dS1, cellOf, rank, sorted: MTLBuffer
    private let cnt, start, sums, sumsScanned, scratch, stateBuf, matBuf, frameBuf: MTLBuffer
    private let ncells1: Int
    private var pso: [String: MTLComputePipelineState] = [:]

    static func estimate(cfg: SimConfig) -> Int {
        let CD = cfg.chargeDiameter, R = CD / 2
        let dpF = cfg.linerThicknessFrac * CD / Float(cfg.layers), dpC = 2 * dpF
        let a = cfg.coneAngleDeg / 2 * .pi / 180
        let H = R / tan(a), L = H + cfg.headHeightCD * CD
        let he = (Float.pi * R * R * L - Float.pi * R * R * H / 3) / (dpC * dpC * dpC)
        let liner = Float.pi * R * (R / sin(a)) * cfg.linerThicknessFrac * CD / (dpF * dpF * dpF)
        let RT = cfg.targetRadiusCD * CD
        let tgt = Float.pi * RT * RT * cfg.targetThicknessCD * CD / (dpC * dpC * dpC)
        return Int(he + liner + tgt)
    }

    init?(cfg: SimConfig, asym: Asymmetry, device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        self.cfg = cfg
        self.asym = asym
        CD = cfg.chargeDiameter
        R = CD / 2
        let alpha = cfg.coneAngleDeg / 2 * .pi / 180
        let linerT = cfg.linerThicknessFrac * CD
        dpF = linerT / Float(cfg.layers)
        dpC = 2 * dpF
        dpT = cfg.fineTarget3D ? dpF : dpC
        let H = R / tan(alpha)
        L = H + cfg.headHeightCD * CD
        zApex = L - H
        zFace = L + cfg.standoffCD * CD
        RT = cfg.targetRadiusCD * CD
        zBack = zFace + cfg.targetThicknessCD * CD
        let sa = sin(alpha), ca = cos(alpha)
        let mats = [Material.explosive(detonationVelocity: cfg.detonationVelocity),
                    { var m = cfg.liner.material; m.failStrain = log(max(cfg.breakupStretch, 1.05)); return m }(),
                    cfg.target.material]

        // ---------- particles ----------
        struct Q { var p: SIMD3<Float>; var m: Float; var mat: UInt32; var fl: UInt32 }
        var pts: [Q] = []
        var rng = SystemRandomNumberGenerator()
        let F_ACTIVE: UInt32 = 256, F_FIXED: UInt32 = 512, F_SLEEP: UInt32 = 2048, F_COARSE: UInt32 = 8192
        let fF = dpF
        // liner: rings laid on the cone, wall thickness may vary with angle
        var liner: [Q] = []
        let S = R / sa
        for j in 0..<cfg.layers {
            var s = 0.5 * fF
            while s <= S {
                let rMid = s * sa - (Float(j) + 0.5) * fF * ca
                if rMid > 0.3 * fF {
                    let nth = max(1, Int((2 * Float.pi * rMid / fF).rounded()))
                    let phase = Float.random(in: 0..<1, using: &rng)
                    for k in 0..<nth {
                        let th = 2 * Float.pi * (Float(k) + phase) / Float(nth)
                        let scale = 1 + asym.wallVariation * cos(th)
                        let d = (Float(j) + 0.5) * fF * scale
                        let rc = s * sa - d * ca
                        let zc = zApex + s * ca + d * sa
                        if rc < 0.3 * fF || zc > L + 0.5 * fF { continue }
                        let m = mats[1].rho0 * fF * fF * scale * (2 * Float.pi * rc / Float(nth))
                        liner.append(Q(p: SIMD3(rc * cos(th), rc * sin(th), zc), m: m, mat: 1, fl: F_ACTIVE))
                    }
                }
                s += fF
            }
        }
        // solid apex near the axis
        let zIn = zApex + linerT / sa
        var zz = zApex
        while zz < zIn + fF {
            for ix in -2...1 { for iy in -2...1 {
                let px = (Float(ix) + 0.5) * fF, py = (Float(iy) + 0.5) * fF
                let r = (px * px + py * py).squareRoot()
                let dn = (zz - zApex) * sa - r * ca
                if dn < 0 || dn > linerT { continue }
                let p = SIMD3(px, py, zz)
                if liner.contains(where: { simd_distance_squared($0.p, p) < 0.45 * fF * fF }) { continue }
                liner.append(Q(p: p, m: mats[1].rho0 * fF * fF * fF, mat: 1, fl: F_ACTIVE))
            } }
            zz += fF
        }
        // explosive (coarse lattice)
        let nr = Int(R / dpC) + 1
        let nzHE = Int(L / dpC)
        for k in 0..<nzHE {
            let pz = (Float(k) + 0.5) * dpC
            for ix in -nr..<nr { for iy in -nr..<nr {
                let px = (Float(ix) + 0.5) * dpC, py = (Float(iy) + 0.5) * dpC
                let r = (px * px + py * py).squareRoot()
                if r > R { continue }
                let dn = (pz - zApex) * sa - r * ca
                if dn > -0.5 * dpC { continue }
                pts.append(Q(p: SIMD3(px, py, pz), m: mats[0].rho0 * dpC * dpC * dpC, mat: 0, fl: F_ACTIVE | F_COARSE))
            } }
        }
        pts.append(contentsOf: liner)
        // target (coarse lattice), asleep until the jet arrives
        let nrt = Int(RT / dpT) + 1
        let nzT = Int(cfg.targetThicknessCD * CD / dpT)
        for k in 0..<nzT {
            let pz = zFace + (Float(k) + 0.5) * dpT
            for ix in -nrt..<nrt { for iy in -nrt..<nrt {
                let px = (Float(ix) + 0.5) * dpT, py = (Float(iy) + 0.5) * dpT
                let r = (px * px + py * py).squareRoot()
                if r > RT { continue }
                var fl = F_SLEEP | (cfg.fineTarget3D ? 0 : F_COARSE)
                if r > RT - 2 * dpT { fl |= F_FIXED }
                pts.append(Q(p: SIMD3(px, py, pz), m: mats[2].rho0 * dpT * dpT * dpT, mat: 2, fl: fl))
            } }
        }
        let used = pts.count
        let spare = cfg.jetRefinement > 0 ? liner.count * 3 : 0
        n = used + spare

        // ---------- grid & quantisation ----------
        let boxR = 1.5 * CD
        let zMin = -0.75 * CD, zMax = zBack + 0.5 * CD
        var cs = 2 * 1.3 * dpC
        var nx = 0, nz = 0
        repeat {
            nx = Int(2 * boxR / cs) + 1
            nz = Int((zMax - zMin) / cs) + 1
            if nx * nx * nz + 1 <= 1024 * 1024 { break }
            cs *= 1.08
        } while true
        let ncells = nx * nx * nz
        ncells1 = ncells + 1
        params = P3(gmin: SIMD4(-boxR, -boxR, zMin, cs),
                    gdim: SIMD4(UInt32(nx), UInt32(nx), UInt32(nz), UInt32(ncells)),
                    box: SIMD4(boxR - 0.5 * cs, zMin + 0.5 * cs, zMax - 0.5 * cs, zFace),
                    misc: SIMD4(RT, dpF, 2 * 2.6 * dpC + 2 * dpF, RT - 3 * dpC),
                    cnt: SIMD4(UInt32(n), UInt32(cfg.jetRefinement), 0, 0),
                    quant: SIMD4(-boxR, -boxR, zMin, 2 * boxR),
                    quant2: SIMD4(zMax - zMin, 0.15 * CD, 0, 0))
        var fi = Frame3DInfo()
        fi.n = n
        fi.quantMin = SIMD3(-boxR, -boxR, zMin)
        fi.quantXY = 2 * boxR
        fi.quantZ = zMax - zMin
        fi.dpFine = dpF
        fi.dpCoarse = dpC
        fi.scene = SceneInfo(axi: true, L: L, zFace: zFace, zBack: zBack, R: R, RT: RT, CD: CD, tipZ: L,
                             linerKind: Float(LinerMaterial.allCases.firstIndex(of: cfg.liner) ?? 0),
                             targetKind: Float(TargetMaterial.allCases.firstIndex(of: cfg.target) ?? 0), count: n)
        info = fi

        // ---------- buffers ----------
        func buf(_ bytes: Int) -> MTLBuffer { device.makeBuffer(length: max(bytes, 16), options: .storageModeShared)! }
        let f4 = n * 16
        pos = buf(f4); vel = buf(f4); st = buf(f4); S0 = buf(f4); S1 = buf(f4); aux = buf(f4)
        acc = buf(f4); r0 = buf(f4); dS0 = buf(f4); dS1 = buf(f4)
        pos2 = buf(f4); vel2 = buf(f4); st2 = buf(f4); S02 = buf(f4); S12 = buf(f4); aux2 = buf(f4); flags2 = buf(n * 4)
        G0 = buf(f4); G1 = buf(f4); G2 = buf(f4); G02 = buf(f4); G12 = buf(f4); G22 = buf(f4)
        L0 = buf(f4); L1 = buf(f4); L2 = buf(f4)
        flags = buf(n * 4); cellOf = buf(n * 4); rank = buf(n * 4); sorted = buf(n * 4)
        cnt = buf(ncells1 * 4); start = buf((ncells1 + 1) * 4); scratch = buf(ncells1 * 4)
        sums = buf(1024 * 4 * 2); sumsScanned = buf(1024 * 4 * 2)
        stateBuf = buf(64)
        matBuf = buf(3 * 80)
        frameBuf = buf(n * 12)

        let D = mats[0].detVel
        let init0 = SIMD3<Float>(asym.initiationOffset, 0, 0)
        let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let V = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let ST = st.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let AX = aux.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let FL = flags.contents().bindMemory(to: UInt32.self, capacity: n)
        let v0 = cfg.approachSpeed / 1000
        for i in used..<n { P[i] = SIMD4(0, 0, -1e4, 1.3 * dpF); V[i] = SIMD4(0, 0, 0, 1e-9); ST[i] = SIMD4(1, 0, 0, 1); AX[i] = .zero; FL[i] = 0 }
        for (i, q) in pts.enumerated() {
            let fine = q.fl & F_COARSE == 0
            P[i] = SIMD4(q.p, 1.3 * (fine ? dpF : dpC))
            V[i] = SIMD4(0, 0, q.mat == 2 ? 0 : v0, q.m)
            ST[i] = SIMD4(mats[Int(q.mat)].rho0, 0, 0, 1)
            AX[i] = SIMD4(0, q.mat == 0 ? simd_distance(q.p, init0) / D : 0, 0, 0)
            FL[i] = q.mat | q.fl
        }
        memset(S0.contents(), 0, f4); memset(S1.contents(), 0, f4)
        let GR = [G0, G1, G2].map { $0.contents().bindMemory(to: SIMD4<Float>.self, capacity: n) }
        for i in 0..<n { GR[0][i] = SIMD4(1, 0, 0, 0); GR[1][i] = SIMD4(0, 1, 0, 0); GR[2][i] = SIMD4(0, 0, 1, 0) }
        let MB = matBuf.contents().bindMemory(to: Float.self, capacity: 60)
        for (k, m) in mats.enumerated() {
            let vals: [Float] = [m.rho0, m.c0, m.s, m.grun, m.G, m.yA, m.yB, m.yN, m.yMax, m.cv, m.meltE, m.spall,
                                 m.failStrain, m.detVel, m.gammaGas, m.e0]
            for (o, v) in vals.enumerated() { MB[k * 20 + o] = v }
            MB[k * 20 + 16] = Float(bitPattern: UInt32(m.kind.rawValue))
            MB[k * 20 + 17] = m.tbSigma0; MB[k * 20 + 18] = m.tbK; MB[k * 20 + 19] = 0
        }
        let SB = stateBuf.contents().bindMemory(to: UInt32.self, capacity: 16)
        for k in 0..<16 { SB[k] = 0 }
        SB[1] = Float(1e-3).bitPattern
        SB[2] = Float(0.05).bitPattern
        SB[8] = UInt32(used)

        do {
            let lib = try device.makeLibrary(source: solver3DSource, options: nil)
            for name in ["gClear", "gAssign", "gScan", "gAddSums", "gScatter", "kEOS", "kRates", "kForces",
                         "kFinalizeDt", "kIntegrate", "kAdvance", "kPack", "kPermute", "kSplit"] {
                pso[name] = try device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
            }
        } catch {
            print("3D solver compile failed: \(error)")
            return nil
        }
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, _ name: String, _ count: Int, _ bufs: [MTLBuffer], bytes: Bool = true) {
        let p = pso[name]!
        e.setComputePipelineState(p)
        for (k, b) in bufs.enumerated() { e.setBuffer(b, offset: 0, index: k) }
        if bytes { e.setBytes(&params, length: MemoryLayout<P3>.stride, index: bufs.count) }
        let w = min(p.maxTotalThreadsPerThreadgroup, 256)
        e.dispatchThreads(MTLSize(width: max(count, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    private func scan(_ e: MTLComputeCommandEncoder) {
        // exclusive scan of cnt[0...ncells] into start; ncells1 ≤ 1024²
        var len = UInt32(ncells1)
        let blocks = (ncells1 + 1023) / 1024
        e.setComputePipelineState(pso["gScan"]!)
        e.setBuffer(cnt, offset: 0, index: 0); e.setBuffer(start, offset: 0, index: 1); e.setBuffer(sums, offset: 0, index: 2)
        e.setBytes(&len, length: 4, index: 3)
        e.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        var blen = UInt32(blocks)
        e.setBuffer(sums, offset: 0, index: 0); e.setBuffer(sumsScanned, offset: 0, index: 1); e.setBuffer(scratch, offset: 0, index: 2)
        e.setBytes(&blen, length: 4, index: 3)
        e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        e.setComputePipelineState(pso["gAddSums"]!)
        e.setBuffer(start, offset: 0, index: 0); e.setBuffer(sumsScanned, offset: 0, index: 1)
        e.setBytes(&len, length: 4, index: 2)
        e.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
    }

    private func encodeStep(_ e: MTLComputeCommandEncoder) {
        dispatch(e, "gClear", ncells1, [cnt])
        dispatch(e, "gAssign", n, [pos, flags, cellOf, rank, cnt])
        scan(e)
        dispatch(e, "gScatter", n, [cellOf, rank, start, sorted])
        dispatch(e, "kPermute", n, [sorted, pos, pos2, vel, vel2, st, st2, S0, S02, S1, S12, aux, aux2, flags, flags2,
                                    G0, G02, G1, G12, G2, G22])
        swap(&pos, &pos2); swap(&vel, &vel2); swap(&st, &st2); swap(&S0, &S02); swap(&S1, &S12)
        swap(&aux, &aux2); swap(&flags, &flags2)
        swap(&G0, &G02); swap(&G1, &G12); swap(&G2, &G22)
        dispatch(e, "kEOS", n, [st, aux, flags, matBuf])
        dispatch(e, "kRates", n, [pos, vel, st, S0, S1, flags, r0, dS0, dS1, start, sorted, matBuf, L0, L1, L2])
        dispatch(e, "kForces", n, [pos, vel, st, S0, S1, flags, acc, start, sorted, stateBuf])
        dispatch(e, "kFinalizeDt", 1, [stateBuf], bytes: false)
        dispatch(e, "kIntegrate", n, [pos, vel, st, S0, S1, flags, aux, acc, r0, dS0, dS1, stateBuf, matBuf, L0, L1, L2, G0, G1, G2])
        dispatch(e, "kAdvance", 1, [stateBuf])
    }

    /// Runs `steps` solver steps on the GPU and waits. Returns GPU milliseconds per step.
    private var stepCounter = 0

    @discardableResult
    func run(steps: Int) -> Double {
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return 0 }
        for _ in 0..<steps {
            encodeStep(e)
            stepCounter += 1
            if cfg.jetRefinement > 0 && stepCounter % 10 == 0 {
                dispatch(e, "kSplit", n, [pos, vel, st, S0, S1, aux, flags, L0, L1, L2, G0, G1, G2, stateBuf])
            }
        }
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return (cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(max(steps, 1))
    }

    func readState() -> SolverState {
        let SB = stateBuf.contents().bindMemory(to: UInt32.self, capacity: 16)
        var s = SolverState()
        s.time = Float(bitPattern: SB[0])
        s.dt = Float(bitPattern: SB[1])
        s.linerZ = SB[3] == 0 ? 0 : Float(bitPattern: SB[3]) - 1000
        s.penZ = SB[4] == 0 ? zFace : Float(bitPattern: SB[4]) - 1000
        s.awake = SB[5] != 0
        s.tipV = Float(bitPattern: SB[6])
        s.coreTipZ = SB[7] == 0 ? s.linerZ : Float(bitPattern: SB[7]) - 1000
        s.used = Int(min(SB[8], UInt32(n)))
        s.footprintMaxVz = Float(bitPattern: SB[9])
        return s
    }

    /// Debug snapshot: (x, y, z, vx, vy, vz, rho, mat, flags) for live particles.
    func debugParticles() -> [(SIMD3<Float>, SIMD3<Float>, Float, UInt32, UInt32)] {
        let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let V = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let ST = st.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let FL = flags.contents().bindMemory(to: UInt32.self, capacity: n)
        var out: [(SIMD3<Float>, SIMD3<Float>, Float, UInt32, UInt32)] = []
        for i in 0..<n where FL[i] & 256 != 0 {
            out.append((SIMD3(P[i].x, P[i].y, P[i].z), SIMD3(V[i].x, V[i].y, V[i].z), ST[i].x, FL[i] & 255, FL[i]))
        }
        return out
    }

    /// Packs the current state into 12 bytes per particle.
    func packFrame() -> Data {
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return Data() }
        dispatch(e, "kPack", n, [pos, vel, st, S1, aux, flags, frameBuf, matBuf])
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Data(bytes: frameBuf.contents(), count: n * 12)
    }
}
