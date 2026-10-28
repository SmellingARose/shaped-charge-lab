import Foundation
import Dispatch

enum ChargeGeometry: String, CaseIterable, Identifiable {
    case conical = "Conical"
    case linear = "Linear"
    var id: String { rawValue }
}

struct SimConfig: Equatable {
    var geometry: ChargeGeometry = .conical
    var chargeDiameter: Float = 40          // mm
    var coneAngleDeg: Float = 60            // full apex angle
    var linerThicknessFrac: Float = 0.025   // of charge diameter
    var headHeightCD: Float = 0.5           // explosive behind the apex
    var standoffCD: Float = 3
    var targetThicknessCD: Float = 7
    var targetRadiusCD: Float = 0.4
    var liner: LinerMaterial = .copper
    var target: TargetMaterial = .steel
    var layers: Int = 4                     // particles across the liner wall
    var breakupStretch: Float = 6.0         // jet elongation at which it fails (λ)
    var detonationVelocity: Float = 8.0     // km/s — sets explosive energy and pressure
    var approachSpeed: Float = 0            // m/s — charge flying toward the target when it fires
    var fineTarget3D = false
    var jetRefinement: Int = 3              // times a stretched liner particle may split in two

    /// Everything that changes the jet itself (not where the target sits).
    var chargeKey: String {
        "\(geometry.rawValue)|\(coneAngleDeg)|\(linerThicknessFrac)|\(headHeightCD)|\(liner.rawValue)|\(layers)|\(breakupStretch)|\(detonationVelocity)|\(approachSpeed)|\(jetRefinement)"
    }
}

enum PF {
    static let active: UInt8 = 1
    static let fixed: UInt8 = 2
    static let damaged: UInt8 = 4
    static let sleeping: UInt8 = 8
    static let vented: UInt8 = 16
    static let surf0: UInt8 = 32
}

final class Buf<T> {
    let p: UnsafeMutablePointer<T>
    let count: Int
    init(_ n: Int, _ v: T) {
        p = .allocate(capacity: max(n, 1))
        p.initialize(repeating: v, count: max(n, 1))
        count = n
    }
    deinit { p.deallocate() }
}

/// Matches `RP` in the Metal shader (9 × 4 bytes).
struct RenderParticle {
    var x: Float
    var z: Float
    var radius: Float
    var temp: Float
    var speed: Float
    var pressure: Float
    var strain: Float
    var aux: Float
    var matFlags: UInt32
}

enum RF {
    static let surface: UInt32 = 1
    static let gas: UInt32 = 2
    static let damaged: UInt32 = 4
    static let fixed: UInt32 = 8
}

// 2D cubic spline kernel
@inline(__always) func kW(_ r: Float, _ h: Float) -> Float {
    let q = r / h
    let sig = 10 / (7 * Float.pi * h * h)
    if q < 1 { return sig * (1 - 1.5 * q * q + 0.75 * q * q * q) }
    if q < 2 { let t = 2 - q; return sig * 0.25 * t * t * t }
    return 0
}

@inline(__always) func kDW(_ r: Float, _ h: Float) -> Float {
    let q = r / h
    let sig = 10 / (7 * Float.pi * h * h * h)
    if q < 1 { return sig * (-3 * q + 2.25 * q * q) }
    if q < 2 { let t = 2 - q; return -sig * 0.75 * t * t }
    return 0
}

final class Simulation {
    let cfg: SimConfig
    let mats: [Material]          // 0 explosive, 1 liner, 2 target
    private let matBuf: Buf<Material>
    let axi: Bool
    let dp: Float
    let h0: Float
    let hcap: Float
    let kappa: Float = 1.3
    let CD: Float, R: Float, L: Float, zApex: Float, zFace: Float, zBack: Float, RT: Float
    let linerT: Float, alpha: Float
    private(set) var n: Int
    let nMax: Int
    let cap: Int
    private(set) var splits = 0
    let maxN = 200
    var threads: Int = 4

    let x, z, vx, vz, ax, az, rho, drho, e, de: Buf<Float>
    let sxx, szz, sxz, dsxx, dszz, dsxz: Buf<Float>
    let p, c, h, mt, mass, epsP, epsT, burn, tdet, dtl, x0, z0: Buf<Float>
    let mat, flags: Buf<UInt8>
    let gen: Buf<UInt8>
    // velocity gradient (from the rates pass) and deformation gradient F, both in the r–z plane
    let lxx, lxz, lzx, lzz: Buf<Float>
    let fxx, fxz, fzx, fzz: Buf<Float>
    let tbD: Buf<Float>
    let nbr: Buf<Int32>
    let nbrCount: Buf<Int32>
    let active: Buf<Int32>
    var nActive = 0
    var nGhost = 0
    let gridList: Buf<Int32>
    let cellOfList: Buf<Int32>
    let sortedList: Buf<Int32>
    private var cellStart: Buf<Int32>
    private var gx0: Float = 0, gz0: Float = 0
    private var gnx = 1, gnz = 1
    let cs: Float
    private var hmax: Float

    private(set) var time: Float = 0
    private(set) var stepCount = 0
    private(set) var dt: Float = 1e-3
    private(set) var targetAwake = false
    private(set) var wakeTime: Float = -1
    private(set) var penetration: Float = 0
    private var lastPenGain: Float = 0
    private(set) var lastStepMs: Double = 0
    private(set) var jetFragments = 0
    private(set) var breakupTime: Float?
    private(set) var tipZ: Float = 0
    private(set) var tipV: Float = 0
    /// fastest forward-moving liner material inside the target footprint
    private(set) var footprintMaxVz: Float = 0
    private(set) var analysis: JetProfile?
    private(set) var apexDetTime: Float = 0

    init(cfg: SimConfig) {
        self.cfg = cfg
        axi = cfg.geometry == .conical
        var liner = cfg.liner.material
        liner.failStrain = log(max(cfg.breakupStretch, 1.05))
        mats = [Material.explosive(detonationVelocity: cfg.detonationVelocity), liner, cfg.target.material]
        matBuf = Buf(3, mats[0])
        for k in 0..<3 { matBuf.p[k] = mats[k] }

        CD = cfg.chargeDiameter
        R = CD / 2
        alpha = cfg.coneAngleDeg / 2 * .pi / 180
        linerT = cfg.linerThicknessFrac * CD
        dp = linerT / Float(cfg.layers)
        h0 = kappa * dp
        hcap = 2.5 * h0
        cs = 2 * h0
        hmax = h0
        let H = R / tan(alpha)
        L = H + cfg.headHeightCD * CD
        zApex = L - H
        zFace = L + cfg.standoffCD * CD
        RT = cfg.targetRadiusCD * CD
        zBack = zFace + cfg.targetThicknessCD * CD

        // ---------- particle generation ----------
        struct P0 { var x: Float; var z: Float; var m: UInt8; var f: UInt8 }
        var pts: [P0] = []
        let sa = sin(alpha), ca = cos(alpha)
        let dpv = dp
        // liner, laid out along the cone so the wall is cleanly resolved
        var linerPts: [P0] = []
        let S = R / sa
        for j in 0..<cfg.layers {
            let d = (Float(j) + 0.5) * dpv
            var s = 0.5 * dpv
            while s <= S {
                let px = s * sa - d * ca
                let pz = zApex + s * ca + d * sa
                if px >= 0.3 * dpv && pz <= L + 0.5 * dpv {
                    linerPts.append(P0(x: px, z: pz, m: 1, f: PF.active | PF.surf0))
                }
                s += dpv
            }
        }
        // fill the solid apex near the axis
        let zApexIn = zApex + linerT / sa
        var zz = zApex
        while zz < zApexIn + dpv {
            for i in 0..<3 {
                let px = (Float(i) + 0.5) * dpv
                let dn = (zz - zApex) * sa - px * ca
                if dn < 0 || dn > linerT { continue }
                var near = false
                for q in linerPts where abs(q.z - zz) < dpv && abs(q.x - px) < dpv {
                    if (q.x - px) * (q.x - px) + (q.z - zz) * (q.z - zz) < 0.55 * dpv * dpv { near = true; break }
                }
                if !near { linerPts.append(P0(x: px, z: zz, m: 1, f: PF.active | PF.surf0)) }
            }
            zz += dpv
        }
        // explosive fill
        let nxHE = Int(R / dpv), nzHE = Int(L / dpv)
        for k in 0..<nzHE {
            let pz = (Float(k) + 0.5) * dpv
            for i in 0..<nxHE {
                let px = (Float(i) + 0.5) * dpv
                let dn = (pz - zApex) * sa - px * ca
                if dn > -0.5 * dpv { continue }
                var f = PF.active
                if px > R - 1.5 * dpv || pz < 1.5 * dpv || pz > L - 1.5 * dpv || dn > -1.6 * dpv { f |= PF.surf0 }
                pts.append(P0(x: px, z: pz, m: 0, f: f))
            }
        }
        pts.append(contentsOf: linerPts)
        // target block
        let nxT = Int(RT / dpv), nzT = Int(cfg.targetThicknessCD * CD / dpv)
        for k in 0..<nzT {
            let pz = zFace + (Float(k) + 0.5) * dpv
            for i in 0..<nxT {
                let px = (Float(i) + 0.5) * dpv
                var f = PF.sleeping
                if px > RT - 3 * dpv { f |= PF.fixed }
                if px > RT - 1.5 * dpv || k < 2 || k >= nzT - 2 { f |= PF.surf0 }
                pts.append(P0(x: px, z: pz, m: 2, f: f))
            }
        }

        let nPts = pts.count
        let linerCount = linerPts.count
        let budget = cfg.jetRefinement > 0 ? min(linerCount * ((1 << cfg.jetRefinement) - 1), 400_000) : 0
        let nAll = nPts + budget
        let capN = nAll * 2 + 16
        n = nPts
        nMax = nAll
        cap = capN
        let fb: (Float) -> Buf<Float> = { v in Buf(capN, v) }
        x = fb(0); z = fb(0); vx = fb(0); vz = fb(0); ax = fb(0); az = fb(0)
        rho = fb(1); drho = fb(0); e = fb(0); de = fb(0)
        sxx = fb(0); szz = fb(0); sxz = fb(0); dsxx = fb(0); dszz = fb(0); dsxz = fb(0)
        p = fb(0); c = fb(1); h = fb(kappa * linerT / Float(cfg.layers)); mt = fb(0); mass = fb(0); epsP = fb(0); epsT = fb(0)
        burn = fb(0); tdet = fb(0); dtl = fb(0); x0 = fb(0); z0 = fb(0)
        mat = Buf(capN, 0); flags = Buf(capN, 0)
        nbr = Buf(nAll * 200, 0); nbrCount = Buf(nAll, 0)
        active = Buf(nAll, 0); gen = Buf(nAll, 0)
        lxx = fb(0); lxz = fb(0); lzx = fb(0); lzz = fb(0)
        fxx = fb(1); fxz = fb(0); fzx = fb(0); fzz = fb(1); tbD = fb(0)
        gridList = Buf(capN, 0); cellOfList = Buf(capN, 0); sortedList = Buf(capN, 0)
        cellStart = Buf(1024, 0)

        let D = mats[0].detVel
        for (i, q) in pts.enumerated() {
            let m = mats[Int(q.m)]
            x.p[i] = q.x; z.p[i] = q.z; x0.p[i] = q.x; z0.p[i] = q.z
            mat.p[i] = q.m; flags.p[i] = q.f
            rho.p[i] = m.rho0
            mass.p[i] = axi ? m.rho0 * dpv * dpv * q.x : m.rho0 * dpv * dpv
            if q.m == 0 { tdet.p[i] = sqrt(q.x * q.x + q.z * q.z) / D }
            if q.m != 2 { vz.p[i] = cfg.approachSpeed / 1000 }
        }
        apexDetTime = zApex / D
        tipZ = L
    }

    // MARK: - parallel helper

    @inline(__always) private func parallel(_ count: Int, _ body: (Int, Int) -> Void) {
        let nt = max(1, threads)
        let chunk = 192
        let nChunks = (count + chunk - 1) / chunk
        if nt == 1 || nChunks <= 1 { body(0, count); return }
        DispatchQueue.concurrentPerform(iterations: min(nt, nChunks)) { w in
            var ci = w
            while ci < nChunks {
                let a = ci * chunk
                body(a, min(count, a + chunk))
                ci += nt
            }
        }
    }

    // MARK: - step

    func step() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        buildActive()
        updateEOS()
        buildGhosts()
        buildGrid()
        buildNeighbors()
        computeRates()
        computeForces()
        integrate()
        time += dt
        stepCount += 1
        if cfg.jetRefinement > 0 && stepCount % 10 == 0 { refineJet() }
        postStep()
        lastStepMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    private func buildActive() {
        var k = 0
        let F = flags.p, A = active.p
        for i in 0..<n where F[i] & PF.active != 0 {
            A[k] = Int32(i); k += 1
        }
        nActive = k
    }

    private func updateEOS() {
        let A = active.p, X = x.p, RHO = rho.p, E = e.p, P = p.p, C = c.p, H = h.p, MT = mt.p
        let M = mass.p, MAT = mat.p, F = flags.p, B = burn.p, MP = matBuf.p
        let axi = self.axi, kappa = self.kappa, h0 = self.h0, hcap = self.hcap
        let xfloor = 0.1 * dp
        parallel(nActive) { a, b in
            for k in a..<b {
                let i = Int(A[k])
                let xi = max(X[i], xfloor)
                let mti = axi ? M[i] / xi : M[i]
                MT[i] = mti
                let r = max(RHO[i], 1e-5)
                H[i] = min(max(kappa * (mti / r).squareRoot(), h0), hcap)
                let m = MP[Int(MAT[i])]
                let (pp, cc) = Simulation.eos(m, rho: r, e: E[i], burn: B[i], damaged: F[i] & PF.damaged != 0)
                P[i] = pp; C[i] = cc
            }
        }
        var hm = h0
        for k in 0..<nActive { hm = max(hm, H[Int(A[k])]) }
        hmax = hm
    }

    @inline(__always) static func eos(_ m: Material, rho: Float, e: Float, burn: Float, damaged: Bool) -> (Float, Float) {
        if m.kind == .explosive {
            let g = m.gammaGas
            let pg = (g - 1) * rho * max(e, 0)
            let mu = rho / m.rho0 - 1
            let un = 1 - burn
            let cu = m.c0
            let pu = un * m.rho0 * cu * cu * max(mu, 0)
            let c2 = g * pg / rho + un * cu * cu
            return (pg + pu, max(c2, 0.01).squareRoot())
        }
        let mu = rho / m.rho0 - 1
        var pr: Float
        var c2: Float
        if mu > 0 {
            let den = max(1 - (m.s - 1) * mu, 0.4)
            pr = m.rho0 * m.c0 * m.c0 * mu * (1 + (1 - m.grun / 2) * mu) / (den * den) + m.grun * m.rho0 * e
            c2 = m.c0 * m.c0 * (1 + 2 * (m.s - 1) * mu) / (den * den)
        } else {
            pr = m.rho0 * m.c0 * m.c0 * mu + m.grun * m.rho0 * e
            c2 = m.c0 * m.c0
        }
        if damaged { pr = max(pr, 0) } else { c2 += 4 * m.G / (3 * rho) }
        return (pr, max(c2, 0.25 * m.c0 * m.c0).squareRoot())
    }

    private func buildGhosts() {
        var g = 0
        let A = active.p
        let X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, RHO = rho.p, P = p.p, C = c.p, H = h.p, MT = mt.p
        let SXX = sxx.p, SZZ = szz.p, SXZ = sxz.p, MAT = mat.p, F = flags.p, E = e.p
        let hm = hmax
        for k in 0..<nActive {
            let i = Int(A[k])
            if X[i] < 0.5 * (H[i] + hm) {
                let j = n + g
                X[j] = -X[i]; Z[j] = Z[i]; VX[j] = -VX[i]; VZ[j] = VZ[i]
                RHO[j] = RHO[i]; P[j] = P[i]; C[j] = C[i]; H[j] = H[i]; MT[j] = MT[i]
                SXX[j] = SXX[i]; SZZ[j] = SZZ[i]; SXZ[j] = -SXZ[i]
                MAT[j] = MAT[i]; F[j] = F[i]; E[j] = E[i]
                g += 1
            }
        }
        nGhost = g
    }

    private func buildGrid() {
        let A = active.p, GL = gridList.p
        let total = nActive + nGhost
        for k in 0..<nActive { GL[k] = A[k] }
        for g in 0..<nGhost { GL[nActive + g] = Int32(n + g) }
        let X = x.p, Z = z.p
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for k in 0..<total {
            let i = Int(GL[k])
            let xi = X[i], zi = Z[i]
            minX = min(minX, xi); maxX = max(maxX, xi)
            minZ = min(minZ, zi); maxZ = max(maxZ, zi)
        }
        gx0 = minX - 1e-3; gz0 = minZ - 1e-3
        gnx = Int((maxX - gx0) / cs) + 1
        gnz = Int((maxZ - gz0) / cs) + 1
        let ncell = gnx * gnz
        if cellStart.count < ncell + 1 { cellStart = Buf(ncell + 1 + ncell / 2, 0) }
        let CSt = cellStart.p
        let COL = cellOfList.p
        let gx0 = self.gx0, gz0 = self.gz0, gnx = self.gnx, cs = self.cs
        parallel(total) { a, b in
            for k in a..<b {
                let i = Int(GL[k])
                let cx = Int((X[i] - gx0) / cs), cz = Int((Z[i] - gz0) / cs)
                COL[k] = Int32(cz * gnx + cx)
            }
        }
        for q in 0...ncell { CSt[q] = 0 }
        for k in 0..<total { CSt[Int(COL[k]) + 1] += 1 }
        for q in 0..<ncell { CSt[q + 1] += CSt[q] }
        let SL = sortedList.p
        let cur = UnsafeMutablePointer<Int32>.allocate(capacity: ncell)
        cur.update(from: CSt, count: ncell)
        for k in 0..<total {
            let cidx = Int(COL[k])
            SL[Int(cur[cidx])] = GL[k]
            cur[cidx] += 1
        }
        cur.deallocate()
    }

    private func buildNeighbors() {
        let A = active.p, X = x.p, Z = z.p, H = h.p, F = flags.p
        let NB = nbr.p, NC = nbrCount.p, CSt = cellStart.p, SL = sortedList.p
        let gx0 = self.gx0, gz0 = self.gz0, gnx = self.gnx, gnz = self.gnz, cs = self.cs
        let hm = hmax, maxN = self.maxN
        parallel(nActive) { a, b in
            for k in a..<b {
                let i = Int(A[k])
                if F[i] & PF.fixed != 0 { NC[i] = 0; continue }
                let xi = X[i], zi = Z[i], hi = H[i]
                let rc = Int(((hi + hm) / cs).rounded(.up))
                let cx = Int((xi - gx0) / cs), cz = Int((zi - gz0) / cs)
                var cnt = 0
                let base = i * maxN
                for qz in max(0, cz - rc)...min(gnz - 1, cz + rc) {
                    let row = qz * gnx
                    for qx in max(0, cx - rc)...min(gnx - 1, cx + rc) {
                        let cell = row + qx
                        var q = Int(CSt[cell])
                        let qe = Int(CSt[cell + 1])
                        while q < qe {
                            let j = Int(SL[q])
                            q += 1
                            if j == i { continue }
                            let dx = xi - X[j], dz = zi - Z[j]
                            let s = hi + H[j]
                            if dx * dx + dz * dz < s * s && cnt < maxN {
                                NB[base + cnt] = Int32(j)
                                cnt += 1
                            }
                        }
                    }
                }
                NC[i] = Int32(cnt)
            }
        }
    }

    private func computeRates() {
        let A = active.p, X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, H = h.p, F = flags.p
        let RHO = rho.p, MT = mt.p, P = p.p, MAT = mat.p, MP = matBuf.p
        let SXX = sxx.p, SZZ = szz.p, SXZ = sxz.p
        let DRHO = drho.p, DE = de.p, DSXX = dsxx.p, DSZZ = dszz.p, DSXZ = dsxz.p
        let NB = nbr.p, NC = nbrCount.p, maxN = self.maxN, axi = self.axi
        let LXX = lxx.p, LXZ = lxz.p, LZX = lzx.p, LZZ = lzz.p
        parallel(nActive) { a, b in
            for k in a..<b {
                let i = Int(A[k])
                if F[i] & PF.fixed != 0 {
                    DRHO[i] = 0; DE[i] = 0; DSXX[i] = 0; DSZZ[i] = 0; DSXZ[i] = 0
                    continue
                }
                let xi = X[i], zi = Z[i], hi = H[i], vxi = VX[i], vzi = VZ[i]
                var mxx: Float = 0, mxz: Float = 0, mzx: Float = 0, mzz: Float = 0
                var gxx: Float = 0, gxz: Float = 0, gzx: Float = 0, gzz: Float = 0
                let base = i * maxN
                let cnt = Int(NC[i])
                for q in 0..<cnt {
                    let j = Int(NB[base + q])
                    let dx = xi - X[j], dz = zi - Z[j]
                    let r = max((dx * dx + dz * dz).squareRoot(), 1e-7)
                    let hij = 0.5 * (hi + H[j])
                    let dw = kDW(r, hij)
                    let wx = dw * dx / r, wz = dw * dz / r
                    let Vj = MT[j] / RHO[j]
                    mxx -= Vj * dx * wx; mxz -= Vj * dx * wz
                    mzx -= Vj * dz * wx; mzz -= Vj * dz * wz
                    let dvx = VX[j] - vxi, dvz = VZ[j] - vzi
                    gxx += Vj * dvx * wx; gxz += Vj * dvx * wz
                    gzx += Vj * dvz * wx; gzz += Vj * dvz * wz
                }
                // Kernel-gradient correction only when the neighbourhood is well conditioned;
                // near free surfaces and on the axis the plain SPH estimate is more robust.
                let det = mxx * mzz - mzx * mxz
                var dvxdx = gxx, dvxdz = gxz, dvzdx = gzx, dvzdz = gzz
                if det > 0.6 && det < 1.6 && mxz * mxz < 0.04 && mzx * mzx < 0.04 {
                    let inv = 1 / det
                    dvxdx = (mzz * gxx - mzx * gxz) * inv
                    dvxdz = (-mxz * gxx + mxx * gxz) * inv
                    dvzdx = (mzz * gzx - mzx * gzz) * inv
                    dvzdz = (-mxz * gzx + mxx * gzz) * inv
                }
                // volume change from the uncorrected (conservative) form
                let divPlanar = gxx + gzz
                // How much of the kernel is filled radially (≈1 in bulk, <1 near surfaces).
                // The hoop rate is exact, the planar terms are not, so scale it to match.
                let cxx = min(max(mxx, 0.3), 1.0)
                let exx = dvxdx, ezz = dvzdz
                LXX[i] = dvxdx; LXZ[i] = dvxdz; LZX[i] = dvzdx; LZZ[i] = dvzdz
                let exz = 0.5 * (dvxdz + dvzdx)
                let wxz = 0.5 * (dvxdz - dvzdx)
                var ett: Float = 0
                if axi {
                        ett = cxx * vxi / max(xi, hi)
                }
                let div = divPlanar + ett
                let r = RHO[i]
                DRHO[i] = -r * div

                let m = MP[Int(MAT[i])]
                let sx = SXX[i], sz = SZZ[i], sxz_ = SXZ[i]
                let st = -(sx + sz)
                let pr = P[i]
                if m.kind == .solid && F[i] & PF.damaged == 0 {
                    let g2 = 2 * m.G
                    let d3 = div / 3
                    DSXX[i] = g2 * (exx - d3) + 2 * sxz_ * wxz
                    DSZZ[i] = g2 * (ezz - d3) - 2 * sxz_ * wxz
                    DSXZ[i] = g2 * exz + wxz * (sz - sx)
                    DE[i] = (-pr * div + sx * exx + sz * ezz + st * ett + 2 * sxz_ * exz) / r
                } else {
                    DSXX[i] = 0; DSZZ[i] = 0; DSXZ[i] = 0
                    DE[i] = -pr * div / r
                }
            }
        }
    }

    private func computeForces() {
        let A = active.p, X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, H = h.p, F = flags.p
        let RHO = rho.p, MT = mt.p, P = p.p, C = c.p, MAT = mat.p
        let SXX = sxx.p, SZZ = szz.p, SXZ = sxz.p
        let AX = ax.p, AZ = az.p, DE = de.p, DTL = dtl.p
        let NB = nbr.p, NC = nbrCount.p, maxN = self.maxN, axi = self.axi, kappa = self.kappa
        let alphaAV: Float = 1.0, betaAV: Float = 2.0
        parallel(nActive) { a, b in
            for k in a..<b {
                let i = Int(A[k])
                if F[i] & PF.fixed != 0 { AX[i] = 0; AZ[i] = 0; DTL[i] = 1e9; continue }
                let xi = X[i], zi = Z[i], hi = H[i], vxi = VX[i], vzi = VZ[i]
                let ri = RHO[i], pi = P[i], ci = C[i]
                let ri2 = 1 / (ri * ri)
                let sxxi = (-pi + SXX[i]) * ri2, szzi = (-pi + SZZ[i]) * ri2, sxzi = SXZ[i] * ri2
                let isSolid = MAT[i] != 0
                let Ri: Float = (isSolid && pi < 0) ? 0.3 * (-pi) * ri2 : 0
                var axi_: Float = 0, azi_: Float = 0, heat: Float = 0, mumax: Float = 0
                let base = i * maxN
                let cnt = Int(NC[i])
                for q in 0..<cnt {
                    let j = Int(NB[base + q])
                    let dx = xi - X[j], dz = zi - Z[j]
                    let r2 = dx * dx + dz * dz
                    let r = max(r2.squareRoot(), 1e-7)
                    let hij = 0.5 * (hi + H[j])
                    let dw = kDW(r, hij)
                    let wx = dw * dx / r, wz = dw * dz / r
                    let rj = RHO[j], pj = P[j]
                    let rj2 = 1 / (rj * rj)
                    var txx = sxxi + (-pj + SXX[j]) * rj2
                    var tzz = szzi + (-pj + SZZ[j]) * rj2
                    let txz = sxzi + SXZ[j] * rj2
                    // artificial viscosity
                    let dvx = vxi - VX[j], dvz = vzi - VZ[j]
                    let vr = dvx * dx + dvz * dz
                    if vr < 0 {
                        let mu = hij * vr / (r2 + 0.01 * hij * hij)
                        let cb = 0.5 * (ci + C[j])
                        let rb = 0.5 * (ri + rj)
                        let piv = (-alphaAV * cb * mu + betaAV * mu * mu) / rb
                        txx -= piv; tzz -= piv
                        heat += 0.5 * MT[j] * piv * (dvx * wx + dvz * wz)
                        mumax = max(mumax, -mu)
                    }
                    // tensile-instability artificial stress (Monaghan)
                    let Rj: Float = (MAT[j] != 0 && pj < 0) ? 0.3 * (-pj) * rj2 : 0
                    if Ri + Rj > 0 {
                        let f = kW(r, hij) / kW(hij / kappa, hij)
                        let f2 = f * f
                        let rr = (Ri + Rj) * f2 * f2
                        txx -= rr; tzz -= rr
                    }
                    let mj = MT[j]
                    axi_ += mj * (txx * wx + txz * wz)
                    azi_ += mj * (txz * wx + tzz * wz)
                }
                if axi && isSolid {
                    let xs = max(xi, 0.5 * hi)
                    let st = -(SXX[i] + SZZ[i])
                    axi_ += (SXX[i] - st) / (ri * xs)
                    azi_ += SXZ[i] / (ri * xs)
                }
                AX[i] = axi_; AZ[i] = azi_
                DE[i] += heat
                let acc = (axi_ * axi_ + azi_ * azi_).squareRoot()
                let d1 = hi / (ci + 1.2 * (alphaAV * ci + betaAV * mumax))
                let d2 = acc > 0 ? (hi / acc).squareRoot() : 1e9
                DTL[i] = min(0.3 * d1, 0.25 * d2)
            }
        }
        var m: Float = 0.05
        for k in 0..<nActive { m = min(m, DTL[Int(A[k])]) }
        dt = min(max(m, 1e-6), dt * 1.25)
    }

    private func integrate() {
        let A = active.p, X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, F = flags.p
        let RHO = rho.p, P = p.p, MAT = mat.p, MP = matBuf.p, E = e.p, B = burn.p, TD = tdet.p
        let SXX = sxx.p, SZZ = szz.p, SXZ = sxz.p, EP = epsP.p, ET = epsT.p
        let AX = ax.p, AZ = az.p, DE = de.p, DRHO = drho.p, DSXX = dsxx.p, DSZZ = dszz.p, DSXZ = dsxz.p
        let LXX = lxx.p, LXZ = lxz.p, LZX = lzx.p, LZZ = lzz.p
        let FXX = fxx.p, FXZ = fxz.p, FZX = fzx.p, FZZ = fzz.p, TBD = tbD.p
        let dt = self.dt, tnew = time + dt
        let xfloor = 0.1 * dp
        let burnW = 2 * h0
        let xMaxBox = 2.5 * CD, zMinBox = -1.2 * CD, zMaxBox = zBack + 0.5 * CD
        parallel(nActive) { a, b in
            for k in a..<b {
                let i = Int(A[k])
                var f = F[i]
                if f & PF.fixed != 0 { continue }
                var vxi = VX[i] + AX[i] * dt
                let vzi = VZ[i] + AZ[i] * dt
                var xi = X[i] + vxi * dt
                let zi = Z[i] + vzi * dt
                if xi < xfloor { xi = xfloor; if vxi < 0 { vxi = 0 } }
                VX[i] = vxi; VZ[i] = vzi; X[i] = xi; Z[i] = zi
                let mi = Int(MAT[i])
                let m = MP[mi]
                // multiplicative update keeps density positive; cap the per-step change
                let rate = min(max(DRHO[i] / max(RHO[i], 1e-6) * dt, -0.05), 0.05)
                let lo: Float = m.kind == .explosive ? 1e-3 : 0.5 * m.rho0
                let hi: Float = m.kind == .explosive ? 4 * m.rho0 : 2.2 * m.rho0
                RHO[i] = min(max(RHO[i] * exp(rate), lo), hi)
                var ei = E[i] + DE[i] * dt
                let out = xi > xMaxBox || zi < zMinBox || zi > zMaxBox
                if m.kind == .explosive {
                    if B[i] < 1 {
                        let fb = min(max((tnew - TD[i]) * m.detVel / burnW, 0), 1)
                        if fb > B[i] { ei += (fb - B[i]) * m.e0; B[i] = fb }
                    }
                    ei = max(ei, 0)
                    if (B[i] >= 1 && RHO[i] < 0.01 * m.rho0) || out { f = (f & ~PF.active) | PF.vented }
                } else {
                    // deformation gradient: dF/dt = L·F
                    let a = FXX[i], b = FXZ[i], c2 = FZX[i], d = FZZ[i]
                    FXX[i] = a + (LXX[i] * a + LXZ[i] * c2) * dt
                    FXZ[i] = b + (LXX[i] * b + LXZ[i] * d) * dt
                    FZX[i] = c2 + (LZX[i] * a + LZZ[i] * c2) * dt
                    FZZ[i] = d + (LZX[i] * b + LZZ[i] * d) * dt
                    if f & PF.damaged == 0 {
                        var sx = SXX[i] + DSXX[i] * dt
                        var sz = SZZ[i] + DSZZ[i] * dt
                        var sxz_ = SXZ[i] + DSXZ[i] * dt
                        let st = -(sx + sz)
                        let j2 = 0.5 * (sx * sx + sz * sz + st * st) + sxz_ * sxz_
                        let seq = (3 * j2).squareRoot()
                        let soft = max(0, 1 - max(ei, 0) / m.meltE)
                        let y = min(m.yA + m.yB * pow(max(EP[i], 1e-6), m.yN), m.yMax) * soft
                        if seq > y {
                            let sc = seq > 1e-9 ? y / seq : 0
                            let dep = (seq - y) / (3 * m.G)
                            sx *= sc; sz *= sc; sxz_ *= sc
                            EP[i] += dep
                            if P[i] < 0 { ET[i] += dep }
                        }
                        SXX[i] = sx; SZZ[i] = sz; SXZ[i] = sxz_
                        let tension = -P[i]
                        if tension > m.tbSigma0 { TBD[i] += (tension - m.tbSigma0) * (tension - m.tbSigma0) * dt }
                        if TBD[i] >= m.tbK || ET[i] > m.failStrain {
                            f |= PF.damaged
                            SXX[i] = 0; SZZ[i] = 0; SXZ[i] = 0
                        }
                    }
                    if out { f = (f & ~PF.active) | PF.vented }
                }
                E[i] = ei
                F[i] = f
            }
        }
    }

    // MARK: - adaptive refinement

    /// Splits liner particles whose material element has been stretched to twice its size.
    /// The stretch comes from the deformation gradient F (dF/dt = L·F): the largest principal stretch is
    /// √λ of B = F·Fᵀ, along its eigenvector n. Each child takes one half of the element, placed at ±¼ of
    /// its stretched length along n. Mass is conserved exactly (axisymmetric halves are weighted by radius so
    /// both keep the parent's density), momentum is conserved, and each child's F has its stretch along n halved.
    private func refineJet() {
        let X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, M = mass.p, MAT = mat.p, F = flags.p, G = gen.p
        let LXX = lxx.p, LXZ = lxz.p, LZX = lzx.p, LZZ = lzz.p
        let FXX = fxx.p, FXZ = fxz.p, FZX = fzx.p, FZZ = fzz.p
        let xfloor = 0.1 * dp
        let limit = UInt8(cfg.jetRefinement)
        let count = n
        for i in 0..<count {
            guard MAT[i] == 1, F[i] & PF.active != 0, G[i] < limit, n < nMax else { continue }
            let a = FXX[i], b = FXZ[i], c = FZX[i], d = FZZ[i]
            // B = F Fᵀ
            let bxx = a * a + b * b, bxz = a * c + b * d, bzz = c * c + d * d
            let half = 0.5 * (bxx + bzz)
            let lam = half + (0.25 * (bxx - bzz) * (bxx - bzz) + bxz * bxz).squareRoot()
            let stretch = lam.squareRoot()
            if stretch < 2 { continue }
            var nx = bxz, nz = lam - bxx
            if abs(nx) + abs(nz) < 1e-9 { nx = lam - bzz; nz = bxz }
            if abs(nx) + abs(nz) < 1e-9 { nx = 0; nz = 1 }
            let nl = (nx * nx + nz * nz).squareRoot()
            nx /= nl; nz /= nl
            let delta = 0.25 * stretch * dp
            let x1 = max(X[i] - delta * nx, xfloor), x2 = max(X[i] + delta * nx, xfloor)
            let m = M[i]
            let m1 = axi ? m * x1 / (x1 + x2) : 0.5 * m
            let m2 = m - m1
            // velocity change across the half-element, split so momentum is conserved
            let dvx = (LXX[i] * nx + LXZ[i] * nz) * delta
            let dvz = (LZX[i] * nx + LZZ[i] * nz) * delta
            let j = n
            n += 1
            copyParticle(from: i, to: j)
            X[i] = x1; Z[i] = Z[i] - delta * nz
            X[j] = x2; Z[j] = Z[j] + delta * nz
            VX[i] -= 2 * m2 / m * dvx; VZ[i] -= 2 * m2 / m * dvz
            VX[j] += 2 * m1 / m * dvx; VZ[j] += 2 * m1 / m * dvz
            M[i] = m1; M[j] = m2
            // halve the stretch along n: F ← F − ½ n (nᵀF)
            let ta = nx * a + nz * c, tb = nx * b + nz * d
            for k in [i, j] {
                FXX[k] = a - 0.5 * nx * ta; FXZ[k] = b - 0.5 * nx * tb
                FZX[k] = c - 0.5 * nz * ta; FZZ[k] = d - 0.5 * nz * tb
            }
            G[i] += 1; G[j] = G[i]
            splits += 1
        }
    }

    private func copyParticle(from i: Int, to j: Int) {
        for b in [x, z, vx, vz, ax, az, rho, drho, e, de, sxx, szz, sxz, dsxx, dszz, dsxz, p, c, h, mt, mass, epsP, epsT, burn, tdet, dtl, x0, z0,
                  lxx, lxz, lzx, lzz, fxx, fxz, fzx, fzz, tbD] {
            b.p[j] = b.p[i]
        }
        mat.p[j] = mat.p[i]; flags.p[j] = flags.p[i]
    }

    // MARK: - diagnostics

    private func postStep() {
        let A = active.p, Z = z.p, VZ = vz.p, MAT = mat.p, X = x.p
        let core = 0.15 * CD, inside = RT - 3 * dp
        var tz: Float = -1e9, tv: Float = 0, anyZ: Float = -1e9, penZ: Float = -1e9, fmax: Float = 0
        for k in 0..<nActive {
            let i = Int(A[k])
            guard MAT[i] == 1 else { continue }
            let zi = Z[i], xi = X[i]
            anyZ = max(anyZ, zi)
            if xi < core && zi > tz { tz = zi; tv = VZ[i] }
            if xi < inside {
                if zi > penZ { penZ = zi }
                fmax = max(fmax, VZ[i])
            }
        }
        if tz < -1e8 { tz = anyZ }
        tipZ = tz; tipV = tv
        footprintMaxVz = fmax

        if !targetAwake && anyZ > zFace - (2 * hcap + 2 * dp) {
            let F = flags.p, MATp = mat.p
            for i in 0..<n where MATp[i] == 2 {
                F[i] = (F[i] & ~PF.sleeping) | PF.active
            }
            targetAwake = true
            wakeTime = time
            lastPenGain = time
        }
        if analysis == nil && (tz > L + 0.6 * CD || targetAwake) && time > apexDetTime + 2 {
            analysis = JetProfile.measure(self)
        }
        if targetAwake {
            let pen = min(max(penZ - zFace, 0), zBack - zFace)
            if pen > penetration + 0.05 { penetration = pen; lastPenGain = time }
        } else if stepCount % 25 == 0 && time > apexDetTime + 4 {
            countFragments()
        }
    }

    private func countFragments() {
        let A = active.p, Z = z.p, VZ = vz.p, MAT = mat.p, H = h.p, X = x.p
        let core = 0.1 * CD
        var vtip: Float = 0
        for k in 0..<nActive { let i = Int(A[k]); if MAT[i] == 1 { vtip = max(vtip, VZ[i]) } }
        var items: [(Float, Float)] = []
        for k in 0..<nActive {
            let i = Int(A[k])
            if MAT[i] == 1 && X[i] < core && VZ[i] > 0.35 * vtip { items.append((Z[i], H[i])) }
        }
        guard items.count > 4 else { return }
        items.sort { $0.0 < $1.0 }
        var segs = 1
        for q in 1..<items.count where items[q].0 - items[q - 1].0 > items[q].1 + items[q - 1].1 {
            segs += 1
        }
        jetFragments = segs
        if breakupTime == nil && segs >= 4 { breakupTime = time }
    }

    /// Slowest jet speed that can still penetrate the target: ½ρ_jet·v² = R_target (modified Bernoulli).
    var cutoffVelocity: Float { (2 * mats[2].bernoulliR / mats[1].rho0).squareRoot() }

    /// The run is over once no liner material over the target is moving fast enough to penetrate,
    /// or the target is perforated.
    var isDone: Bool {
        if time > 900 { return true }
        guard targetAwake, time - wakeTime > 5 else { return false }
        if penetration >= (zBack - zFace) - 2 * dp { return true }
        return footprintMaxVz < cutoffVelocity
    }

    var phase: String {
        if time < apexDetTime { return "Detonation" }
        if tipZ < L + 0.1 * CD { return "Liner collapse" }
        if !targetAwake || penetration < 0.05 { return breakupTime == nil ? "Jet stretching" : "Jet particulating" }
        return isDone ? "Complete" : "Penetrating"
    }

    // MARK: - rendering export

    /// Writes particles for drawing; returns count.
    func fillRender(_ out: UnsafeMutablePointer<RenderParticle>) -> Int {
        var k = 0
        let X = x.p, Z = z.p, VX = vx.p, VZ = vz.p, F = flags.p, MAT = mat.p, RHO = rho.p, M = mass.p
        let E = e.p, P = p.p, EP = epsP.p, B = burn.p, H = h.p, NC = nbrCount.p, X0 = x0.p, Z0 = z0.p
        let xfloor = 0.1 * dp
        for i in 0..<n {
            let f = F[i]
            if f & PF.vented != 0 { continue }
            let mi = MAT[i]
            let m = mats[Int(mi)]
            var rf: UInt32 = 0
            var radius: Float
            let xi = X[i]
            let mti = axi ? M[i] / max(xi, xfloor) : M[i]
            let area = mti / max(RHO[i], 1e-5)
            radius = min(max(0.62 * area.squareRoot(), 0.5 * dp), 3 * dp)
            var temp: Float = 300 + max(E[i], 0) / m.cv
            if mi == 0 {
                if B[i] > 0.5 {
                    rf |= RF.gas
                    radius = 1.25 * H[i]
                    temp = 300 + max(E[i], 0) * 900
                } else if f & PF.surf0 != 0 { rf |= RF.surface }
            } else if mi == 1 {
                rf |= RF.surface
            } else {
                if f & PF.fixed != 0 { rf |= RF.fixed }
                if f & (PF.sleeping | PF.fixed) != 0 {
                    if f & PF.surf0 != 0 { rf |= RF.surface }
                } else {
                    let ddx = xi - X0[i], ddz = Z[i] - Z0[i]
                    if f & PF.surf0 != 0 || NC[i] < 15 || ddx * ddx + ddz * ddz > 0.5 * dp * dp { rf |= RF.surface }
                }
            }
            if f & PF.damaged != 0 { rf |= RF.damaged }
            out[k] = RenderParticle(x: xi, z: Z[i], radius: radius, temp: temp,
                                    speed: (VX[i] * VX[i] + VZ[i] * VZ[i]).squareRoot(),
                                    pressure: P[i], strain: EP[i], aux: B[i],
                                    matFlags: UInt32(mi) | (rf << 8))
            k += 1
        }
        return k
    }

    /// Liner particle (z, vz) pairs for the velocity-profile chart.
    func linerSamples(max count: Int) -> [(Float, Float, Bool)] {
        var out: [(Float, Float, Bool)] = []
        let F = flags.p, MAT = mat.p, Z = z.p, VZ = vz.p
        var idx: [Int] = []
        for i in 0..<n where MAT[i] == 1 && F[i] & PF.vented == 0 { idx.append(i) }
        let stride = max(1, idx.count / max(count, 1))
        var q = 0
        while q < idx.count {
            let i = idx[q]
            out.append((Z[i] - L, VZ[i], VZ[i] > 2.0))
            q += stride
        }
        return out
    }
}
