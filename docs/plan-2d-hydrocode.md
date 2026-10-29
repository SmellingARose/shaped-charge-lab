# Plan: a realistic, fast 2D axisymmetric solver

Goal: replace the 2D SPH prototype (`ShapedChargeLab/Sources/ShapedChargeLab/Sim/Simulation.swift`) with a 2D
axisymmetric solver built like the codes labs use for this problem class, converged with resolution and checked
against published experiments, running in minutes on one GPU. The 3D SPH solver stays, for asymmetric charges
(initiation offset, wall variation, yaw), jet particulation and the visuals.

Status today (see [convergence.md](convergence.md)): jet tip speed (6.4–7.1 km/s) and jet mass fraction (~10%) are
plausible; the optimal standoff (1.8–2.4 CD) and the depth (~1–1.5 CD) are not, and depth still moves with
resolution.

## 1. Why the current approach cannot get there

| Limit | Cause |
|---|---|
| Resolution | SPH needs ~3 particles per smoothing length; 2–5 particles across a 1 mm liner is far below the 20–50 cells per thickness that converged liner collapse needs. |
| Early jet breakup | SPH tensile instability and particle disorder break a thinning jet numerically; the breakup slider papers over it. |
| Interfaces | Explosive/liner/target boundaries are smeared over a kernel width; no sharp contact or slip. |
| Explosive | γ-law products with programmed burn: wrong expansion isentrope, so wrong liner drive. |
| Strength | One hardening law, no strain-rate term, ad hoc thermal softening. |
| Determinism | Atomic splitting and reductions: ±7% run-to-run spread. |

## 2. Method choice

| Option | Used by | Fit for this problem | GPU fit |
|---|---|---|---|
| Lagrangian (Wilkins) | HEMP, early 2D codes | Excellent until the jet forms, then the mesh tangles | Good |
| Multi-material ALE (Lagrange + rezone + remap, MOF interfaces) | ALE3D, ALEGRA, FLAG | Excellent, most accurate interfaces | Harder: unstructured mesh, remap and relaxation logic |
| **Eulerian Lagrange-plus-remap on a fixed grid, mixed cells, interface reconstruction, AMR** | CTH-class codes | **Standard for jet formation and penetration; handles any deformation** | **Excellent: structured blocks** |
| Diffuse-interface Eulerian Godunov (hyperelastic) | research codes (Barton et al.) | Good, modern, cell-centred; interfaces need sharpening | Excellent |

**Choice: Eulerian, structured (r, z) grid with block adaptive mesh refinement, Lagrange-plus-remap, multi-material
mixed cells with sharp interface reconstruction.** It is the validated route for this problem class, it never
tangles, and fixed structured blocks are the best possible layout for a GPU. Keep the cell-centred Godunov
alternative in reserve (section 8): if the remap step proves to be the bottleneck or too diffusive, the material
models carry over unchanged.

## 3. Physics, by component

| Component | Model | Notes |
|---|---|---|
| Geometry | 2D axisymmetric (r, z), area-weighted (cylindrical) finite volumes | Correct hoop terms on the axis; regularity condition at r = 0 |
| Hydro step | Staggered or cell-centred Lagrangian step, edge-centred artificial viscosity (tensor, limiter-based), then second-order remap (van Leer / MUSCL) back to the fixed grid | Monotone remap of every conserved and history variable |
| Mixed cells | Per-material volume fraction, density, energy, stress and history; pressure–velocity relaxation closure | No averaging of incompatible materials |
| Interfaces | PLIC (VOF) reconstruction first, moment-of-fluid (MOF) later for three-material cells | MOF is the most accurate reconstruction in comparative studies |
| Explosive | JWL products equation of state; programmed burn (lighting times from the detonation point, finite front width) | Published parameter sets per explosive; optional reactive burn later |
| Metal pressure | Mie–Grüneisen (shock Hugoniot reference), tabulated EOS optional | Already used; carries over |
| Metal strength | Hypoelastic–plastic, Jaumann (or Green–Naghdi) rate, radial return; Johnson–Cook flow stress, Steinberg–Guinan as an alternative; pressure- and temperature-dependent shear modulus | Published constants for OFHC copper, tantalum, steels; compare models (they diverge at the highest rates) |
| Temperature | Specific heat from EOS, plastic work heating | Drives thermal softening and melt |
| Failure | Johnson–Cook damage; spall by a cumulative (Tuler–Butcher) or Grady criterion; void opening in Eulerian cells | Jet breakup should come from strength, necking and resolution, not a slider |
| Penetration | Same solver through the target (no separate 1D model needed) | Keep the 1D model as a cross-check and for instant standoff curves |

## 4. Making it fast

Targets: RX 6700 XT (HIP), Apple M4 (Metal), NVIDIA (CUDA), CPU fallback, sharing one physics source as today.

| Technique | Effect |
|---|---|
| Structured blocks (e.g. 32 × 32 cells + ghost layers) | Coalesced loads, no neighbour search at all (the dominant cost of SPH) |
| Block AMR: fine cells only around liner, jet, interfaces and shocks | 5–20× fewer cells than a uniform fine grid |
| Time subcycling per refinement level | Coarse regions take few, large steps; the fine jet region sets only its own step |
| Structure of arrays per material, compact mixed-cell lists | Only mixed cells pay the multi-material cost |
| Kernel fusion (Lagrange step + EOS + strength in one pass per block) | Fewer passes over memory, the real limit on GPUs |
| FP32 state, FP64 for time and accumulated positions | Full speed on consumer GPUs (FP64 is 1/16 rate on RDNA2) |
| Deterministic reductions (fixed order, no atomics on results) | Bit-reproducible runs: removes the ±7% spread and makes regression testing exact |
| Fixed memory pools, no per-step allocation | Stable throughput |

Budget for the default charge (40 mm, 1 mm liner, 3 CD standoff, 4 CD target): 25 µm cells (40 across the liner)
over r ≤ 60 mm, z ≈ 400 mm would be 38M cells uniform; with AMR roughly 2–5M active cells. At ~2.5 ns time steps,
≈ 60,000 steps to 150 µs. At ~10⁹ cell updates per second on the RX 6700 XT that is minutes per run, so a standoff
sweep or a convergence study is an evening, not a week.

## 5. Validation (what makes it "realistic")

Each model is checked on its own before the full charge:

| Test | Checks | Reference |
|---|---|---|
| Sod, Noh, Sedov | Hydro step, remap, axis treatment | Exact solutions |
| Plate impact (flyer) | Mie–Grüneisen Hugoniot, spall strength | Published Hugoniot and spall data |
| Taylor anvil (copper rod impact) | Strength model at high rate | Published final shapes |
| Cylinder expansion test | JWL products and burn | Published wall velocity histories |
| Full charge: open-literature precision charges (e.g. the BRL 81 mm charge) | Jet tip speed, velocity gradient, breakup time, penetration versus standoff | Published flash X-ray and penetration data |

Convergence: run each case at three resolutions (e.g. 10, 20, 40 cells across the liner) and report Richardson-
extrapolated values with error bars in `docs/convergence.md`. A result counts only when it has stopped changing.

## 6. Phases

| Phase | Deliverable | Done when |
|---|---|---|
| 0. Harness | Exact-solution and regression tests in CI; `scl_stephash`-style bit check | Tests run on CPU and GPU |
| 1. Single-material hydro, uniform grid | Lagrange step + remap, axisymmetric, CPU + one GPU backend | Sod/Noh/Sedov converge at the expected order |
| 2. Multi-material | Volume fractions, PLIC interfaces, mixed-cell closure, JWL + programmed burn | Cylinder test matches published wall velocity |
| 3. Solids | Elastic–plastic stress, Johnson–Cook / Steinberg–Guinan, damage, spall | Taylor anvil and plate-impact spall match |
| 4. Full charge | Liner collapse, jet, penetration on a uniform grid | Converges across three resolutions |
| 5. AMR + subcycling | Block AMR, per-level time steps, load balancing | Same answers as uniform, ≥ 5× faster |
| 6. All backends | HIP, Metal, CUDA, CPU from one source; deterministic | Bit-identical across runs on each backend |
| 7. App integration | 2D results shown in the 3D view by revolving the axisymmetric fields; 3D SPH kept for asymmetry | Users choose "accurate (2D)" or "asymmetric (3D)" |
| 8. Validation report | Section 5 cases written up with sources and error bars | Published in docs |

## 7. Risks

| Risk | Mitigation |
|---|---|
| Remap diffusion smears the thin jet | Second-order remap, interface reconstruction, AMR on the jet |
| Mixed-cell closure instabilities (three materials, voids) | Start with two-material cells; well-tested relaxation closures from the ALE literature |
| Material constants calibrated outside the jet's strain rates (10⁵–10⁷ s⁻¹) | Compare two strength models; report the spread instead of a single answer |
| Lab-calibrated data is not public | Validate only against open experiments and say so in the app |
| AMR complexity on three GPU backends | Uniform grid first (phases 1–4); AMR only after the physics is validated |

## 8. Alternative kept in reserve

Cell-centred Godunov, diffuse-interface hyperelastic formulation (Barton and co-workers): one kernel per cell, no
separate remap, very GPU-friendly, with interface sharpening to counter smearing. Same EOS, strength and failure
models. Worth prototyping in phase 1 alongside Lagrange-plus-remap if the remap cost dominates.

## References

- Multi-material ALE and interface reconstruction:
  [comparative study of interface reconstruction methods](https://www.osti.gov/biblio/21333942),
  [2D staggered multi-material ALE with MOF](https://ojs.global-sci.org/index.php/nmtma/article/view/14337),
  [MOF in axisymmetric coordinates (Lipnikov et al.)](https://internationalmeshingroundtable.com/assets/papers/2021/07-Lipnikov.pdf),
  [cell-centred DG multi-material ALE](https://global-sci.com/article/79728/a-high-order-cell-centered-discontinuous-galerkin-multi-material-arbitrary-lagrangian-eulerian-method)
- Eulerian solid mechanics: [multi-material hyperelastic diffuse interface](https://unpaywall.org/10.1016%2Fj.jcp.2015.04.024),
  [3D diffuse-interface solids and fluids (Wallis, Barton, Nikiforakis)](https://arxiv.org/abs/2011.05569v2),
  [unified Eulerian multimaterial framework](https://ar5iv.labs.arxiv.org/html/1904.03712),
  [Eulerian hydrocode with plasticity (LANL)](https://www.osti.gov/biblio/1963620)
- Strength models: [comparison of flow stress models on OFHC copper (Banerjee)](https://arxiv.org/abs/cond-mat/0512466),
  [copper plasticity model comparison](https://www.imechanica.org/sites/default/files/CuPlasticCompare.pdf)
- Explosive products and burn: [JWL with programmed burn](https://docs.itascacg.com/itasca950/common/models/jwl/doc/modeljwl.html),
  [JWL with a finite burn front](https://osupdocs.forestry.oregonstate.edu/index.php/JWLPlusPlus_Material)
- GPU and AMR: [AMReX](https://cs.lbl.gov/news-media/news/2023/amrex-a-performance-portable-framework-for-block-structured-adaptive-mesh-refinement-applications),
  [AMR CFD on GPUs at scale](https://sc22.supercomputing.org/presentation/index-567.htm),
  [GPU Eulerian code for exascale (HERACLES++)](https://arxiv.org/pdf/2503.04428),
  [GPU compressible multiphase hydrocode](https://e-space.mmu.ac.uk/579027)
