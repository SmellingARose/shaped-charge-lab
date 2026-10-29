# Convergence study log

Default charge: 40 mm, 60° copper cone, 2.5% wall, 8 km/s explosive, 3 CD standoff, armor steel.
Penetration measured at t = 110 µs. 1D modified-Bernoulli model for this jet: ≈ 2.0 CD.

## 2026-10-28 — Swift prototype (deformation-gradient splitting, Tuler–Butcher spall)

| Solver | Particles across liner | Crater (mm) | Crater (CD) | Notes |
|---|---|---|---|---|
| 2D axisymmetric | 3 | 78.9 | 1.97 | |
| 2D axisymmetric | 4 | 79.4 | 1.98 | |
| 2D axisymmetric | 5 | 102.9 | 2.57 | still drilling at 110 µs |
| 3D | 2 | 65.8 | 1.65 | refinement budget exhausted (spare = 3× liner) |
| 3D | 3 | 62.0 | 1.55 | refinement budget exhausted |

Conclusion: not converged. 3D runs were under-refined because the split budget ran out; fixed in the C++
core by sizing spare slots as (2^levels − 1) × liner and reporting exhaustion. Re-run with the C++ core.

## 2026-10-28 — C++ core (shared physics header), 3D

| Backend | Particles across liner | Crater (mm) | Crater (CD) | Notes |
|---|---|---|---|---|
| Metal (M4) | 2 | 56.6 | 1.41 | ran to the physical stop rule at 145 µs; refinement budget not exhausted; jet tip 6.42 km/s, 10.5% of liner |
| CPU vs Metal | 2 | — | — | jet tip at ~6.5 µs: CPU 7.14 km/s, Metal 7.13 km/s (same physics source) |
