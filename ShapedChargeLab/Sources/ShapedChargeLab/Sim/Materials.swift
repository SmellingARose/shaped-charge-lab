import Foundation

// Unit system used everywhere in the solver:
//   length mm, time µs, mass mg  →  velocity km/s, density g/cm³,
//   pressure/stress GPa, specific energy MJ/kg.

enum MaterialKind: Int32 {
    case explosive = 0
    case solid = 1
}

struct Material {
    var name: String
    var kind: MaterialKind
    var rho0: Float
    // Mie–Grüneisen (linear Us–up Hugoniot)
    var c0: Float
    var s: Float
    var grun: Float
    // Strength: J2 plasticity with Johnson–Cook-style hardening and linear thermal softening
    var G: Float
    var yA: Float
    var yB: Float
    var yN: Float
    var yMax: Float
    var cv: Float        // MJ/(kg·K)
    var meltE: Float     // specific energy at which strength is gone
    var spall: Float     // spall strength for a ~1 µs tension pulse (GPa)
    var failStrain: Float // plastic strain accumulated in tension before failure
    var bernoulliR: Float // target resistance used by the 1D penetration model (GPa)
    // Explosive (gamma-law products, programmed burn)
    var detVel: Float = 0
    var gammaGas: Float = 3
    var e0: Float = 0

    /// Generic explosive described only by its detonation velocity D (km/s).
    // Tuler–Butcher cumulative spall damage: D = ∫ (σ − σ0)² dt over σ > σ0, failure at D = K.
    // σ0 = ⅔·spall and K = (spall/3)²·1 µs, so a 1 µs pulse fails exactly at the spall strength.
    var tbSigma0: Float { spall * 2 / 3 }
    var tbK: Float { (spall / 3) * (spall / 3) }

    static func explosive(detonationVelocity D: Float = 8.0) -> Material {
        let g: Float = 3.0
        // Energy consistent with a gamma-law CJ state: Q = D² / (2(γ²−1))
        return Material(name: "High explosive (γ-law)", kind: .explosive, rho0: 1.70,
                        c0: 2.5, s: 0, grun: 0, G: 0, yA: 0, yB: 0, yN: 1, yMax: 0,
                        cv: 1e-3, meltE: 1, spall: 0, failStrain: 0, bernoulliR: 0,
                        detVel: D, gammaGas: g, e0: D * D / (2 * (g * g - 1)))
    }
}

enum LinerMaterial: String, CaseIterable, Identifiable {
    case copper = "Copper"
    case tantalum = "Tantalum"
    case aluminum = "Aluminum"
    var id: String { rawValue }

    var material: Material {
        switch self {
        case .copper:
            return Material(name: "Copper", kind: .solid, rho0: 8.93, c0: 3.94, s: 1.49, grun: 2.0,
                            G: 46, yA: 0.09, yB: 0.29, yN: 0.31, yMax: 0.6, cv: 0.383e-3, meltE: 0.40,
                            spall: 1.5, failStrain: 1.1, bernoulliR: 0)
        case .tantalum:
            return Material(name: "Tantalum", kind: .solid, rho0: 16.65, c0: 3.41, s: 1.20, grun: 1.67,
                            G: 69, yA: 0.35, yB: 0.30, yN: 0.28, yMax: 1.0, cv: 0.14e-3, meltE: 0.42,
                            spall: 3.0, failStrain: 1.1, bernoulliR: 0)
        case .aluminum:
            return Material(name: "Aluminum", kind: .solid, rho0: 2.70, c0: 5.35, s: 1.34, grun: 2.0,
                            G: 26, yA: 0.32, yB: 0.11, yN: 0.42, yMax: 0.5, cv: 0.89e-3, meltE: 0.56,
                            spall: 1.2, failStrain: 1.1, bernoulliR: 0)
        }
    }
}

enum TargetMaterial: String, CaseIterable, Identifiable {
    case steel = "Armor steel"
    case aluminum = "Aluminum 6061"
    var id: String { rawValue }

    var material: Material {
        switch self {
        case .steel:
            return Material(name: "Armor steel", kind: .solid, rho0: 7.85, c0: 4.57, s: 1.49, grun: 1.93,
                            G: 81.8, yA: 0.79, yB: 0.51, yN: 0.26, yMax: 1.8, cv: 0.477e-3, meltE: 0.71,
                            spall: 3.0, failStrain: 1.0, bernoulliR: 6.0)
        case .aluminum:
            return Material(name: "Aluminum 6061", kind: .solid, rho0: 2.70, c0: 5.35, s: 1.34, grun: 2.0,
                            G: 26, yA: 0.32, yB: 0.11, yN: 0.42, yMax: 0.5, cv: 0.89e-3, meltE: 0.56,
                            spall: 1.2, failStrain: 1.0, bernoulliR: 2.0)
        }
    }
}
