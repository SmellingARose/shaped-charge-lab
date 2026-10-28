import SwiftUI
import Charts
import MetalKit

enum Palette {
    static let ink = Color(red: 0.055, green: 0.06, blue: 0.072)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.105)
    static let rule = Color.white.opacity(0.07)
    static let text = Color(red: 0.88, green: 0.89, blue: 0.91)
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.62)
    static let amber = Color(red: 0.95, green: 0.64, blue: 0.24)
    static let copper = Color(red: 0.93, green: 0.55, blue: 0.38)
    static let steel = Color(red: 0.55, green: 0.66, blue: 0.80)
}

struct ContentView: View {
    @StateObject private var c = SimController()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(c: c)
                .frame(width: 318)
                .background(Palette.panel)
            Rectangle().fill(Palette.rule).frame(width: 1)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    MetalView(c: c)
                    HUD(c: c).padding(14)
                }
                Rectangle().fill(Palette.rule).frame(height: 1)
                ChartsPanel(c: c)
                    .frame(height: 250)
                    .background(Palette.panel)
            }
        }
        .background(Palette.ink)
        .foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 760)
    }
}

// MARK: - Metal

struct MetalView: NSViewRepresentable {
    let c: SimController

    final class Coordinator { var renderer: Renderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let v = InteractiveMTKView()
        if let r = Renderer(view: v, feed: c.feed, feed3D: c.feed3D, settings: c.view) {
            context.coordinator.renderer = r
            v.delegate = r
            v.renderer = r
        }
        return v
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {}
}

// MARK: - HUD

struct HUD: View {
    @ObservedObject var c: SimController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(phase.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(phaseColor.opacity(0.22)))
                    .overlay(Capsule().stroke(phaseColor.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(phaseColor)
                Text(String(format: "t = %.2f µs", c.mode3D ? (c.frameStats?.time ?? 0) : c.stats.time))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            Text(explanation)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text.opacity(0.9))
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                if c.mode3D {
                    readout("Jet tip", String(format: "%.2f km/s", c.frameStats?.tipV ?? 0))
                    readout("Tip travel", String(format: "%.0f mm", max(c.frameStats?.tipTravel ?? 0, 0)))
                    readout("3D crater", String(format: "%.1f mm", c.frameStats?.penetration ?? 0))
                    readout("Frame", c.frameCount > 0 ? "\(Int(c.frameIndex) + 1)/\(c.frameCount)" : "—")
                } else {
                    readout("Jet tip", String(format: "%.2f km/s", c.stats.tipV))
                    readout("Tip travel", String(format: "%.0f mm", max(c.stats.tipTravel, 0)))
                    readout("Fragments", "\(c.stats.fragments)")
                    readout("SPH crater", String(format: "%.1f mm", c.stats.penetration))
                }
                if let p = c.predictedHere {
                    readout("1D model", String(format: "%.2f CD", p))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.rule, lineWidth: 1))
        .allowsHitTesting(false)
    }

    private var phase: String {
        if c.mode3D {
            if c.recording { return c.frameStats?.phase ?? "Recording" }
            return c.frameStats?.phase ?? "Ready"
        }
        return c.stats.phase
    }

    private var phaseColor: Color {
        switch phase {
        case "Detonation": return Palette.amber
        case "Liner collapse", "Jet stretching", "Jet particulating": return Palette.copper
        case "Penetrating": return Palette.steel
        default: return Palette.dim
        }
    }

    private var explanation: String {
        switch phase {
        case "Ready" where c.mode3D:
            return "Full 3D mode: every particle is simulated, nothing is revolved. Press Record 3D run. It simulates offline on the GPU, then plays back. Try the imperfection sliders to see a real jet bend and drift."
        case "Ready":
            return "A conical copper liner sits in the front of an explosive cylinder. Press Run to detonate it from the rear centre. Drag to orbit, scroll or pinch to zoom, right-drag to pan."
        case "Detonation":
            return "The detonation wave sweeps forward at \(String(format: "%.1f", c.config.detonationVelocity)) km/s. Behind it the explosive becomes gas at roughly \(Int(c.cjPressure)) GPa, about \(Int(c.cjPressure * 9.869))k atmospheres."
        case "Liner collapse":
            return "The gas slams the liner inward. Opposite walls collide on the axis: a thin inner skin squirts forward as the jet, while the thick outer part becomes a slow slug."
        case "Jet stretching":
            return "The front of the jet moves much faster than its tail. That velocity gradient stretches the copper like taffy, so the jet gets longer and thinner the farther it flies."
        case "Jet particulating":
            return "Stretched past its ductility, the jet necks and breaks into a train of beads. Each bead still drills, but gaps, tumbling and sideways drift waste penetration."
        case "Penetrating":
            return "At the target the jet pressure (hundreds of GPa) dwarfs the steel's strength, so both flow like liquids. Depth ≈ jet length × √(ρjet/ρtarget)."
        case "Complete":
            return "Done. Compare this standoff with the curve below: too close and the jet hasn't stretched; too far and it has broken up and drifted."
        default:
            return ""
        }
    }

    private func readout(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.dim)
            Text(v).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }
}

// MARK: - Sidebar

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Palette.dim)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .bottom)
    }
}

struct LabeledSlider: View {
    let label: String
    let value: String
    @Binding var x: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.amber)
            }
            if let step {
                Slider(value: $x, in: range, step: step).controlSize(.small)
            } else {
                Slider(value: $x, in: range).controlSize(.small)
            }
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var c: SimController

    private func bind(_ kp: WritableKeyPath<SimConfig, Float>) -> Binding<Double> {
        Binding(get: { Double(c.config[keyPath: kp]) }, set: { c.config[keyPath: kp] = Float($0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                modeSection
                if c.mode3D { recordSection; playbackSection; asymmetrySection } else { runSection; computeSection }
                chargeSection
                targetSection
                modelSection
                viewSection
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shaped Charge Lab")
                .font(.system(size: 19, weight: .bold, design: .serif))
            Text("Axisymmetric SPH hydrocode · Munroe effect")
                .font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .bottom)
    }

    private var modeSection: some View {
        Section(title: "Simulation") {
            Picker("", selection: $c.mode3D) {
                Text("Live 2D").tag(false)
                Text("Recorded 3D").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(c.mode3D
                 ? "Full 3D on the GPU, no symmetry assumed. Records a run, then plays it back."
                 : "Axisymmetric slice on the CPU, fast enough to watch live. The 3D view revolves the slice.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordSection: some View {
        Section(title: "Record") {
            Button(action: c.toggleRecord) {
                Label(c.recording ? "Stop recording" : (c.frameCount > 0 ? "Record again" : "Record 3D run"),
                      systemImage: c.recording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(c.recording ? .red.opacity(0.8) : Palette.amber)
            .controlSize(.large)
            if c.recording {
                ProgressView(value: Double(min(c.progress.time / max(c.progress.estimatedEnd, 1), 1)))
                    .tint(Palette.amber)
                HStack {
                    stat("sim time", String(format: "%.1f µs", c.progress.time))
                    stat("ms / step", String(format: "%.1f", c.progress.msPerStep))
                    stat("frames", "\(c.progress.frames) · \(c.progress.megabytes) MB")
                }
            }
            LabeledSlider(label: "3D resolution", value: "\(Int(c.layers3D)) across liner",
                          x: $c.layers3D, range: 2...4, step: 1,
                          hint: String(format: "≈%dk particles, roughly %.0f–%.0f min on this GPU.",
                                       c.estimated3DParticles / 1000, max(1, c.estimated3DMinutes * 0.6), max(2, c.estimated3DMinutes * 1.4)))
            Text("Charge and target settings below apply to the next recording. Target thickness is capped at 5 CD in 3D.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playbackSection: some View {
        Section(title: "Playback") {
            HStack(spacing: 8) {
                Button(action: c.togglePlay) {
                    Label(c.playing ? "Pause" : "Play", systemImage: c.playing ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(c.frameCount == 0)
                .keyboardShortcut(.space, modifiers: [])
                Toggle("Loop", isOn: $c.loop).toggleStyle(.checkbox).font(.system(size: 12))
            }
            LabeledSlider(label: "Timeline", value: c.frameStats.map { String(format: "%.1f µs", $0.time) } ?? "—",
                          x: $c.frameIndex, range: 0...Double(max(c.frameCount - 1, 1)), step: 1)
                .disabled(c.frameCount < 2)
            LabeledSlider(label: "Playback speed", value: String(format: "%.0f frames/s", c.playbackFPS),
                          x: Binding(get: { c.playbackFPS }, set: { c.setPlaybackFPS($0) }), range: 5...60, step: 5,
                          hint: c.recording ? "Recorded frames can be played or scrubbed while the run continues. Stopping keeps every frame so far."
                                            : "Frames are about 0.5 µs of simulated time apart.")
        }
    }

    private var asymmetrySection: some View {
        Section(title: "Imperfections (3D only)") {
            LabeledSlider(label: "Detonator offset", value: String(format: "%.1f mm", c.asym.initiationOffset),
                          x: Binding(get: { Double(c.asym.initiationOffset) }, set: { c.asym.initiationOffset = Float($0) }),
                          range: 0...4,
                          hint: "Initiating off the axis makes the wave hit one side of the liner first. The jet bends and drifts.")
            LabeledSlider(label: "Liner wall variation", value: String(format: "±%.0f%%", c.asym.wallVariation * 100),
                          x: Binding(get: { Double(c.asym.wallVariation) }, set: { c.asym.wallVariation = Float($0) }),
                          range: 0...0.1,
                          hint: "One side of the cone thicker than the other, as in an imperfectly machined liner.")
        }
    }

    private var runSection: some View {
        Section(title: "Run") {
            HStack(spacing: 8) {
                Button(action: c.toggleRun) {
                    Label(c.running ? "Pause" : (c.stats.done ? "Run again" : "Run"), systemImage: c.running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Palette.amber)
                .keyboardShortcut(.space, modifiers: [])
                Button(action: c.stepOnce) { Image(systemName: "forward.frame.fill") }
                    .help("Advance 20 steps")
                Button(action: c.reset) { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset to t = 0")
            }
            .controlSize(.large)
            LabeledSlider(label: "Playback pace", value: SimController.paceLabels[Int(c.paceIndex)],
                          x: $c.paceIndex, range: 0...4, step: 1,
                          hint: "Simulated microseconds per real second. Slow it down to watch the liner collapse.")
            Button(action: c.sweeping ? c.reset : c.startSweep) {
                Label(c.sweeping ? "Stop sweep (\(c.sweepQueue.count) left)" : "Sweep standoff 1–8 CD", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .help("Runs the full simulation at several standoffs and plots each result")
        }
    }

    private var computeSection: some View {
        Section(title: "Compute") {
            LabeledSlider(label: "CPU cores", value: "\(Int(c.threads)) of \(c.cores)",
                          x: $c.threads, range: 1...Double(c.cores), step: 1,
                          hint: c.perfCores > 0 ? "\(c.perfCores) performance + \(c.effCores) efficiency cores. Above \(c.perfCores), efficiency cores join in." : nil)
            HStack {
                stat("ms / step", String(format: "%.2f", c.stats.msPerStep))
                stat("steps / s", String(format: "%.0f", c.stats.stepsPerSec))
                stat("active", "\(c.stats.active / 1000)k / \(c.stats.particles / 1000)k")
            }
            LabeledSlider(label: "Resolution", value: "\(c.config.layers) across liner",
                          x: Binding(get: { Double(c.config.layers) }, set: { c.config.layers = Int($0) }),
                          range: 3...7, step: 1,
                          hint: "Particles across the liner wall. ≈\(c.estimatedParticles / 1000)k particles. Cost grows roughly with the cube.")
            LabeledSlider(label: "Jet refinement", value: c.config.jetRefinement == 0 ? "off" : "\(c.config.jetRefinement) levels",
                          x: Binding(get: { Double(c.config.jetRefinement) }, set: { c.config.jetRefinement = Int($0) }),
                          range: 0...5, step: 1,
                          hint: "Each liner particle tracks how far its piece of metal has been stretched. At 2× it splits into its two halves along the stretch, conserving mass and momentum. This sets how many times a piece may split (compute budget).")
        }
    }

    private var chargeSection: some View {
        Section(title: "Charge") {
            Picker("", selection: $c.config.geometry) {
                ForEach(ChargeGeometry.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            LabeledSlider(label: "Explosive strength", value: String(format: "%.1f km/s", c.config.detonationVelocity),
                          x: bind(\.detonationVelocity), range: 5.5...9.5,
                          hint: String(format: "Detonation velocity. Pressure ≈ %.0f GPa, energy ≈ %.1f MJ/kg.", c.cjPressure, c.config.detonationVelocity * c.config.detonationVelocity / 16))
            LabeledSlider(label: "Approach speed", value: String(format: "%.0f m/s", c.config.approachSpeed),
                          x: bind(\.approachSpeed), range: 0...1000,
                          hint: "How fast the charge is flying toward the target when it fires (a warhead on a missile or shell).")
            LabeledSlider(label: "Cone apex angle", value: String(format: "%.0f°", c.config.coneAngleDeg),
                          x: bind(\.coneAngleDeg), range: 30...120,
                          hint: "Narrow cones make faster, thinner jets. Wide cones push slower, heavier jets.")
            LabeledSlider(label: "Liner thickness", value: String(format: "%.1f%% CD", c.config.linerThicknessFrac * 100),
                          x: bind(\.linerThicknessFrac), range: 0.015...0.05)
            Picker("Liner", selection: $c.config.liner) {
                ForEach(LinerMaterial.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var targetSection: some View {
        Section(title: "Target") {
            LabeledSlider(label: "Standoff", value: String(format: "%.2f CD  (%.0f mm)", c.config.standoffCD, c.config.standoffCD * c.config.chargeDiameter),
                          x: bind(\.standoffCD), range: 0.25...10,
                          hint: "Distance from the charge face to the target, in charge diameters (CD = 40 mm).")
            LabeledSlider(label: "Target thickness", value: String(format: "%.0f CD", c.config.targetThicknessCD),
                          x: bind(\.targetThicknessCD), range: 2...10, step: 1)
            Picker("Material", selection: $c.config.target) {
                ForEach(TargetMaterial.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var modelSection: some View {
        Section(title: "Jet breakup") {
            LabeledSlider(label: "Ductility (stretch to break)", value: String(format: "%.1f×", c.config.breakupStretch),
                          x: bind(\.breakupStretch), range: 2...12,
                          hint: "How far the jet can elongate before it particulates. Sets SPH failure strain and the 1D model's breakup time.")
            LabeledSlider(label: "Fragment drift", value: String(format: "%.0f m/s", c.driftSpeed),
                          x: $c.driftSpeed, range: 0...60,
                          hint: "Sideways velocity of broken jet beads. Asymmetry in real charges; it is why very long standoffs lose.")
        }
    }

    private var viewSection: some View {
        Section(title: "View") {
            Picker("Colour", selection: $c.colorMode) {
                Text("Material").tag(0); Text("Speed").tag(1); Text("Pressure").tag(2)
                Text("Temperature").tag(3); Text("Plastic strain").tag(4)
            }
            if !c.mode3D {
                Picker("2D display", selection: $c.sliceOnly) {
                    Text("Revolved 3D").tag(false)
                    Text("Slice only").tag(true)
                }
                .pickerStyle(.segmented)
                Text(c.sliceOnly ? "Only the plane that is actually computed."
                     : "The slice spun around the axis. Exact for symmetric parts. Expanding off-axis debris shows as perfect rings, which real metal would tear apart.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
            LabeledSlider(label: "Cutaway", value: String(format: "%.0f°", c.cutaway), x: $c.cutaway, range: 0...180)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Toggle("Explosive gas", isOn: $c.showGas); Toggle("Explosive", isOn: $c.showExplosive) }
                GridRow { Toggle("Target", isOn: $c.showTarget); Toggle("Grid", isOn: $c.showGround) }
                GridRow { Toggle("Bloom", isOn: $c.bloom); Toggle("Follow jet", isOn: $c.follow) }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(Palette.dim)
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Charts

struct ChartsPanel: View {
    @ObservedObject var c: SimController

    var body: some View {
        HStack(spacing: 0) {
            jetChart.padding(14)
            Rectangle().fill(Palette.rule).frame(width: 1)
            standoffChart.padding(14)
        }
    }

    private var jetChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartTitle("Liner velocity along the axis", "Each dot is a liner particle. The sloped line is the velocity gradient that stretches the jet.")
            Chart(c.jetPoints) { p in
                PointMark(x: .value("Position (mm from charge face)", p.z), y: .value("Axial speed (km/s)", p.v))
                    .symbolSize(9)
                    .foregroundStyle(p.isJet ? Palette.copper : Palette.dim.opacity(0.7))
            }
            .chartXAxisLabel("mm past the charge face", alignment: .trailing)
            .chartYAxisLabel("km/s")
            .chartYScale(domain: 0...max(9, Double(c.jetPoints.map(\.v).max() ?? 0) + 0.5))
        }
    }

    private var standoffChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartTitle("Penetration vs standoff",
                       c.profile == nil ? "Run once to measure the jet; the curve is computed from it."
                       : optimumText)
            Chart {
                ForEach(c.curve) { p in
                    AreaMark(x: .value("Standoff", p.standoff), y: .value("Penetration", p.penetration))
                        .foregroundStyle(LinearGradient(colors: [Palette.amber.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Standoff", p.standoff), y: .value("Penetration", p.penetration))
                        .foregroundStyle(Palette.amber)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let o = c.optimum {
                    PointMark(x: .value("Standoff", o.standoff), y: .value("Penetration", o.penetration))
                        .foregroundStyle(Palette.amber).symbolSize(70)
                        .annotation(position: .top) {
                            Text(String(format: "best %.1f CD", o.standoff)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.amber)
                        }
                }
                ForEach(c.sweepResults) { p in
                    PointMark(x: .value("Standoff", p.standoff), y: .value("Penetration", p.penetration))
                        .foregroundStyle(Palette.steel).symbol(.square).symbolSize(40)
                }
                ForEach(c.results3D) { p in
                    PointMark(x: .value("Standoff", p.standoff), y: .value("Penetration", p.penetration))
                        .foregroundStyle(Color(red: 0.70, green: 0.55, blue: 0.95)).symbol(.diamond).symbolSize(70)
                }
                RuleMark(x: .value("Current", Double(c.config.standoffCD)))
                    .foregroundStyle(Palette.text.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXScale(domain: 0...10)
            .chartXAxisLabel("standoff (charge diameters)", alignment: .trailing)
            .chartYAxisLabel("depth (CD)")
            HStack(spacing: 14) {
                legend(Palette.amber, "1D jet model from measured jet")
                legend(Palette.steel, "2D SPH crater")
                legend(Color(red: 0.70, green: 0.55, blue: 0.95), "3D SPH crater")
                legend(Palette.text.opacity(0.4), "current standoff")
            }
        }
    }

    private var optimumText: String {
        guard let p = c.profile, let o = c.optimum else { return "" }
        return String(format: "Measured jet: tip %.1f km/s, tail %.1f km/s, %.0f%% of liner mass. Peak at %.1f CD.",
                      p.vTip, p.vTail, p.jetMassFraction * 100, o.standoff)
    }

    private func chartTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .semibold))
            Text(sub).font(.system(size: 10.5)).foregroundStyle(Palette.dim).lineLimit(2)
        }
    }

    private func legend(_ col: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(col).frame(width: 7, height: 7)
            Text(t).font(.system(size: 10)).foregroundStyle(Palette.dim)
        }
    }
}
