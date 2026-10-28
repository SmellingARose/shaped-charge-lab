import Foundation

/// The jet as an ideal stretching rod: every element moves at constant speed
/// from a "virtual origin" (z_vo, t_vo), so at time t an element of speed v sits at
/// z = z_vo + v·(t − t_vo). Measured from the SPH run once the jet has formed.
struct JetProfile {
    var vTip: Float
    var vTail: Float
    var zVO: Float
    var tVO: Float
    var tMeasured: Float
    var jetMassFraction: Float
    var chargeLength: Float
    var chargeDiameter: Float
    var rhoJet: Float

    static func measure(_ s: Simulation) -> JetProfile? {
        var vs: [Float] = [], zs: [Float] = [], ms: [Float] = []
        var totalLiner: Float = 0
        let F = s.flags.p, MAT = s.mat.p, Z = s.z.p, VZ = s.vz.p, M = s.mass.p
        for i in 0..<s.n where MAT[i] == 1 && F[i] & PF.vented == 0 {
            totalLiner += M[i]
            vs.append(VZ[i]); zs.append(Z[i]); ms.append(M[i])
        }
        guard let vmax = vs.max(), vmax > 1 else { return nil }
        let sorted = vs.sorted()
        let vTip = sorted[Int(Float(sorted.count - 1) * 0.995)]
        // jet = material clearly faster than the slug
        let cut = max(0.3 * vTip, 1.5)
        var sw: Float = 0, sv: Float = 0, sz: Float = 0, svv: Float = 0, svz: Float = 0, jm: Float = 0
        var vTail = vTip
        for k in 0..<vs.count where vs[k] > cut && vs[k] <= vTip * 1.02 {
            let w = ms[k]
            sw += w; sv += w * vs[k]; sz += w * zs[k]
            svv += w * vs[k] * vs[k]; svz += w * vs[k] * zs[k]
            jm += w
            vTail = min(vTail, vs[k])
        }
        guard sw > 0 else { return nil }
        let den = sw * svv - sv * sv
        guard abs(den) > 1e-9 else { return nil }
        let B = (sw * svz - sv * sz) / den       // = t − t_vo
        let A = (sz - B * sv) / sw               // = z_vo
        return JetProfile(vTip: vTip, vTail: max(vTail, cut), zVO: A, tVO: s.time - max(B, 0.5),
                          tMeasured: s.time, jetMassFraction: jm / max(totalLiner, 1e-9),
                          chargeLength: s.L, chargeDiameter: s.CD, rhoJet: s.mats[1].rho0)
    }
}

/// One-dimensional penetration model (modified Bernoulli / DPE) applied to the measured jet.
extension JetProfile {
    /// Breakup time for a jet that particulates after stretching by `lambda` from its measured state.
    func breakupTime(stretch lambda: Float) -> Float { tVO + lambda * (tMeasured - tVO) }
}

struct PenetrationModel {
    var jet: JetProfile
    var rhoTarget: Float
    var resistance: Float      // GPa
    var breakupTime: Float     // µs after detonation
    var driftSpeed: Float      // km/s lateral drift of fragments
    var holeRadius: Float      // mm

    func penetrationVelocity(_ v: Float) -> Float {
        let rj = jet.rhoJet, rt = rhoTarget, Rt = resistance
        if rj * v * v <= 2 * Rt { return 0 }
        let a = rj - rt
        if abs(a) < 1e-3 { return (rj * v * v - 2 * Rt) / (2 * rj * v) }
        let disc = rj * rj * v * v - a * (rj * v * v - 2 * Rt)
        return max((rj * v - disc.squareRoot()) / a, 0)
    }

    /// Depth (mm) for a target face `standoff` mm in front of the charge.
    func penetration(standoff S: Float) -> Float {
        let zf = jet.chargeLength + S
        var zc = zf
        var tcur: Float = 0
        let dv: Float = 0.02
        var v = jet.vTip
        while v - dv >= jet.vTail {
            let vm = v - 0.5 * dv
            let tArr = max(tcur, jet.tVO + (zc - jet.zVO) / v)
            let tl = min(tArr, breakupTime)
            var len = dv * max(tl - jet.tVO, 0)
            if tArr > breakupTime {
                let lateral = driftSpeed * (tArr - breakupTime)
                len *= exp(-(lateral / holeRadius) * (lateral / holeRadius))
            }
            let u = penetrationVelocity(vm)
            if u > 0 && len > 0 {
                let tau = len / (vm - u)
                zc += u * tau
                tcur = tArr + tau
            } else {
                tcur = tArr
            }
            v -= dv
        }
        return zc - zf
    }

    func curve(maxCD: Float = 10, step: Float = 0.1) -> [(Float, Float)] {
        let cd = jet.chargeDiameter
        var out: [(Float, Float)] = []
        var s: Float = 0.25
        while s <= maxCD + 1e-4 {
            out.append((s, penetration(standoff: s * cd) / cd))
            s += step
        }
        return out
    }
}
