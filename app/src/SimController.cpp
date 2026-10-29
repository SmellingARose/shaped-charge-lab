#include "SimController.h"

#include <QMetaObject>
#include <QPointer>
#include <QThread>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

struct ParamMeta {
    const char* key;
    const char* label;
    const char* group;
    const char* unit;
    double scale;       // shown value = stored value × scale
    int decimals;
    double step;        // in stored units; 0 = continuous
};

// Display metadata for every entry of scl::parameterRanges(), in panel order.
const ParamMeta kMeta[] = {
    {"coneAngleDeg", "Cone apex angle", "Charge", "°", 1, 0, 1},
    {"linerThicknessFrac", "Liner wall", "Charge", "% CD", 100, 1, 0.001},
    {"headHeightCD", "Explosive behind apex", "Charge", "CD", 1, 2, 0.05},
    {"approachSpeed", "Approach speed", "Charge", "m/s", 1, 0, 10},
    {"detonationVelocity", "Detonation velocity", "Explosive", "km/s", 1, 1, 0.1},
    {"standoffCD", "Standoff", "Target", "CD", 1, 2, 0.05},
    {"targetThicknessCD", "Target thickness", "Target", "CD", 1, 0, 1},
    {"initiationOffsetMM", "Detonator offset", "Imperfections", "mm", 1, 1, 0.1},
    {"wallVariation", "Wall thickness variation", "Imperfections", "%", 100, 1, 0.001},
    {"layers", "Particles across liner", "Resolution", "", 1, 0, 1},
    {"jetRefinement", "Refinement levels", "Resolution", "", 1, 0, 1},
    {"breakupStretch", "Breakup stretch", "Jet model", "×", 1, 1, 0.5},
    {"driftSpeed", "Fragment drift", "Jet model", "m/s", 1, 0, 1},
};

const scl::ParameterRange* findRange(const QString& key) {
    for (const auto& r : scl::parameterRanges())
        if (key == QLatin1String(r.key)) return &r;
    return nullptr;
}

}  // namespace

SimController::SimController(QObject* parent) : QObject(parent) {
    m_devices = scl::listDevices();
    for (const auto& d : m_devices)
        if (d.backend == scl::Backend::CPU) m_cpuThreads = std::max(1, d.computeUnits);
    m_poll.setInterval(100);
    connect(&m_poll, &QTimer::timeout, this, &SimController::poll);
    connect(&m_playTimer, &QTimer::timeout, this, [this] {
        if (m_frameCount == 0) return;
        int next = m_frameIndex + 1;
        if (next >= m_frameCount) {
            if (m_loop && !running()) next = 0;
            else { setPlaying(false); return; }
        }
        showFrame(next);
    });
    refreshPreview();
}

SimController::~SimController() {
    if (m_run) m_run->cancel();
}

// ---------------------------------------------------------------- parameters

double SimController::paramValue(const QString& k) const {
    const scl::Config& c = m_cfg;
    if (k == "coneAngleDeg") return c.coneAngleDeg;
    if (k == "linerThicknessFrac") return c.linerThicknessFrac;
    if (k == "headHeightCD") return c.headHeightCD;
    if (k == "approachSpeed") return c.approachSpeed;
    if (k == "detonationVelocity") return c.detonationVelocity;
    if (k == "standoffCD") return c.standoffCD;
    if (k == "targetThicknessCD") return c.targetThicknessCD;
    if (k == "initiationOffsetMM") return c.asymmetry.initiationOffsetMM;
    if (k == "wallVariation") return c.asymmetry.wallVariation;
    if (k == "layers") return c.layers;
    if (k == "jetRefinement") return c.jetRefinement;
    if (k == "breakupStretch") return c.breakupStretch;
    if (k == "driftSpeed") return m_driftSpeed;
    return 0;
}

QVariantList SimController::params() const {
    QVariantList out;
    for (const ParamMeta& m : kMeta) {
        const scl::ParameterRange* r = findRange(m.key);
        if (!r) continue;
        QVariantMap p;
        p["key"] = m.key;
        p["label"] = m.label;
        p["group"] = m.group;
        p["unit"] = m.unit;
        p["scale"] = m.scale;
        p["decimals"] = m.decimals;
        p["step"] = m.step;
        p["min"] = r->min;
        p["max"] = r->max;
        p["realLow"] = r->realisticLow;
        p["realHigh"] = r->realisticHigh;
        p["realistic"] = r->realistic;
        p["note"] = QString::fromUtf8(r->note);
        p["value"] = paramValue(m.key);
        out.push_back(p);
    }
    return out;
}

void SimController::setParam(const QString& k, double v) {
    if (std::fabs(paramValue(k) - v) < 1e-9) return;
    scl::Config& c = m_cfg;
    bool chargeChanged = true;
    if (k == "coneAngleDeg") c.coneAngleDeg = float(v);
    else if (k == "linerThicknessFrac") c.linerThicknessFrac = float(v);
    else if (k == "headHeightCD") c.headHeightCD = float(v);
    else if (k == "approachSpeed") {   // the same jet, shifted (exact without air drag); only 3D results are stale
        c.approachSpeed = float(v);
        chargeChanged = false;
        m_results.clear();
    }
    else if (k == "detonationVelocity") c.detonationVelocity = float(v);
    else if (k == "standoffCD") { c.standoffCD = float(v); chargeChanged = false; }
    else if (k == "targetThicknessCD") { c.targetThicknessCD = float(v); chargeChanged = false; }
    else if (k == "initiationOffsetMM") c.asymmetry.initiationOffsetMM = float(v);
    else if (k == "wallVariation") c.asymmetry.wallVariation = float(v);
    else if (k == "layers") c.layers = int(std::lround(v));
    else if (k == "jetRefinement") c.jetRefinement = int(std::lround(v));
    else if (k == "breakupStretch") c.breakupStretch = float(v);
    else if (k == "driftSpeed") { m_driftSpeed = float(v); chargeChanged = false; }
    else return;
    if (chargeChanged) {             // a different charge makes a different jet
        m_haveJet = false;
        m_results.clear();
    }
    emit paramsChanged();
    emit configChanged();
    updateCurve();
    if (!running()) refreshPreview();
}

void SimController::resetParams() {
    const scl::LinerMaterial l = m_cfg.liner;
    const scl::TargetMaterial t = m_cfg.target;
    m_cfg = scl::Config{};
    m_cfg.liner = l;
    m_cfg.target = t;
    m_driftSpeed = 20;
    m_haveJet = false;
    m_results.clear();
    emit paramsChanged();
    emit configChanged();
    updateCurve();
    if (!running()) refreshPreview();
}

void SimController::setLiner(int v) {
    if (v == int(m_cfg.liner)) return;
    m_cfg.liner = scl::LinerMaterial(v);
    m_haveJet = false;
    m_results.clear();
    emit configChanged();
    updateCurve();
    if (!running()) refreshPreview();
}

void SimController::setTarget(int v) {
    if (v == int(m_cfg.target)) return;
    m_cfg.target = scl::TargetMaterial(v);
    m_results.clear();
    emit configChanged();
    updateCurve();
    if (!running()) refreshPreview();
}

// ---------------------------------------------------------------- devices

QStringList SimController::devices() const {
    QStringList out;
    for (const auto& d : m_devices) {
        if (d.backend == scl::Backend::CPU) out << QStringLiteral("CPU · %1 threads").arg(d.computeUnits);
        else out << QString::fromStdString(d.name);
    }
    return out;
}

void SimController::setDeviceIndex(int i) {
    if (i < 0 || i >= int(m_devices.size()) || i == m_deviceIndex) return;
    m_deviceIndex = i;
    emit deviceChanged();
    emit configChanged();
}

bool SimController::deviceIsCpu() const {
    return m_devices.empty() || m_devices[size_t(m_deviceIndex)].backend == scl::Backend::CPU;
}

int SimController::maxCpuThreads() const {
    for (const auto& d : m_devices)
        if (d.backend == scl::Backend::CPU) return std::max(1, d.computeUnits);
    return 1;
}

void SimController::setCpuThreads(int t) {
    t = std::clamp(t, 1, maxCpuThreads());
    if (t == m_cpuThreads) return;
    m_cpuThreads = t;
    if (m_run) m_run->setCpuThreads(t);
    emit deviceChanged();
    emit configChanged();
}

QString SimController::estimate() const {
    if (m_devices.empty()) return {};
    scl::Device d = m_devices[size_t(m_deviceIndex)];
    if (d.backend == scl::Backend::CPU) d.computeUnits = m_cpuThreads;
    const scl::RunEstimate e = scl::estimateRun(m_cfg, d);
    const QString n = e.particles >= 1000000 ? QStringLiteral("%1M").arg(e.particles / 1e6, 0, 'f', 1)
                                             : QStringLiteral("%1k").arg(qRound(e.particles / 1000.0));
    const QString t = e.minutes < 1 ? QStringLiteral("under a minute")
                                    : QStringLiteral("about %1 min").arg(qRound(e.minutes));
    return QStringLiteral("%1 particles · %2").arg(n, t);
}

QString SimController::runDevice() const {
    return m_run ? QString::fromStdString(m_run->device().name) : QString();
}

int SimController::memoryMB() const {
    if (m_frameCount == 0) return 0;
    std::lock_guard<std::mutex> l(m_frameMutex);
    const size_t per = m_viewFrame ? m_viewFrame->particles.size() * sizeof(scl::Particle3D) : 0;
    return int(per * size_t(m_frameCount) / 1000000);
}

// ---------------------------------------------------------------- runs

void SimController::start() {
    if (running()) return;
    setPlaying(false);
    m_run.reset();
    m_runCfg = m_cfg;
    scl::RunOptions opt;
    scl::Device dev;
    if (!m_devices.empty()) {
        dev = m_devices[size_t(m_deviceIndex)];
        if (dev.backend == scl::Backend::CPU) dev.computeUnits = m_cpuThreads;
        opt.device = &dev;
    }
    m_frameCount = 0;
    m_frameIndex = 0;
    m_live = true;
    m_stats = {};
    m_frameStats = {};
    m_progress = 0;
    QPointer<SimController> self(this);
    m_run = scl::startRun(
        m_runCfg, opt,
        [self](size_t index) {
            QMetaObject::invokeMethod(self, [self, index] {
                if (!self) return;
                self->m_frameCount = int(index) + 1;
                emit self->framesChanged();
                if (self->m_live && !self->m_playing) self->showFrame(int(index));
            }, Qt::QueuedConnection);
        },
        [self](float pen, bool completed) {
            QMetaObject::invokeMethod(self, [self, pen, completed] {
                if (!self) return;
                self->poll();
                if (completed) {
                    self->m_results.push_back(QPointF(self->m_runCfg.standoffCD, pen / self->m_runCfg.chargeDiameter));
                    emit self->chartsChanged();
                }
                self->m_poll.stop();
                emit self->runStateChanged();
            }, Qt::QueuedConnection);
        });
    m_poll.start();
    emit runStateChanged();
    emit framesChanged();
}

void SimController::stop() {
    if (m_run) m_run->cancel();
}

void SimController::poll() {
    if (!m_run) return;
    m_stats = m_run->progress();
    // progress estimate: runs end around the time the slow jet tail has finished arriving
    const double expected = 40 + 25 * m_runCfg.standoffCD + 10 * m_runCfg.targetThicknessCD;
    m_progress = m_stats.done ? 1.0 : std::min(0.98, m_stats.time / expected);
    if (!m_haveJet && m_run->jetProfile(m_jet)) {
        m_haveJet = true;
        m_jetApproach = m_runCfg.approachSpeed;
        updateCurve();
    }
    QVariantList samples;
    for (const auto& s : m_run->linerSamples(1200)) samples.push_back(QVariant::fromValue(QPointF(s.zFromFace, s.vz)));
    m_jetSamples = samples;
    emit statsChanged();
    emit chartsChanged();
}

void SimController::updateCurve() {
    m_curve.clear();
    m_optimumVsSpeed.clear();
    m_optimum = m_bestNow = QPointF(-1, -1);
    m_bestSummary.clear();
    if (m_haveJet) {
        const float drift = m_driftSpeed / 1000.0f;
        const auto jet = scl::atApproachSpeed(m_jet, m_jetApproach, m_cfg.approachSpeed);
        const auto pts = scl::penetrationCurve(jet, m_cfg, drift, 10, 0.1f);
        for (const auto& p : pts) m_curve.push_back(QVariant::fromValue(QPointF(p.standoffCD, p.penetrationCD)));
        const scl::CurvePoint peak = scl::bestStandoff(pts);
        const float best = peak.penetrationCD;
        float here = 0;
        if (best > 0) m_optimum = QPointF(peak.standoffCD, best);
        for (size_t k = 1; k < pts.size(); k++) {   // depth at the standoff set now (linear between curve points)
            if (pts[k].standoffCD < m_cfg.standoffCD) continue;
            const auto& a = pts[k - 1]; const auto& b = pts[k];
            const float w = std::clamp((m_cfg.standoffCD - a.standoffCD) / (b.standoffCD - a.standoffCD), 0.0f, 1.0f);
            here = a.penetrationCD + w * (b.penetrationCD - a.penetrationCD);
            break;
        }
        for (const auto& o : scl::optimumVsApproach(m_jet, m_cfg, drift, m_jetApproach))
            m_optimumVsSpeed.push_back(QVariant::fromValue(QPointF(o.approachSpeed, o.standoffCD)));
        if (best > 0) {
            m_bestNow = QPointF(m_cfg.approachSpeed, m_optimum.x());
            const double mm = m_optimum.x() * m_cfg.chargeDiameter;
            const int gain = here > 0 ? qRound((best / here - 1) * 100) : 0;
            const QString head = QStringLiteral("Best %1 CD (%2 mm) at %3 m/s")
                                     .arg(m_optimum.x(), 0, 'f', 1).arg(qRound(mm)).arg(qRound(m_cfg.approachSpeed));
            m_bestSummary = gain >= 1
                ? head + QStringLiteral(": %1% deeper than the %2 CD set now.").arg(gain).arg(m_cfg.standoffCD, 0, 'f', 1)
                : head + QStringLiteral(": the %1 CD set now is within 1% of it.").arg(m_cfg.standoffCD, 0, 'f', 1);
        }
    }
    emit chartsChanged();
}

QString SimController::jetSummary() const {
    if (!m_haveJet) return {};
    return QStringLiteral("Tip %1 km/s · tail %2 km/s · %3% of liner")
        .arg(m_jet.vTip, 0, 'f', 1).arg(m_jet.vTail, 0, 'f', 1).arg(qRound(m_jet.jetMassFraction * 100));
}

// ---------------------------------------------------------------- frames and playback

void SimController::refreshPreview() {
    auto f = std::make_shared<ViewFrame>();
    f->scene = scl::preview(m_cfg, f->particles);
    {
        std::lock_guard<std::mutex> l(m_frameMutex);
        m_viewFrame = f;
    }
    if (m_run && !running()) {     // a finished run stays in the timeline, but a changed config shows its own preview
        m_live = true;
    }
    m_frameStats = {};
    emit frameChanged();
    emit viewFrameChanged();
}

void SimController::showFrame(int index) {
    if (!m_run) return;
    scl::Frame fr;
    if (!m_run->frame(size_t(index), fr)) return;
    auto f = std::make_shared<ViewFrame>();
    f->particles = std::move(fr.particles);
    f->scene = m_run->scene();
    f->tipTravel = fr.stats.tipTravel;
    {
        std::lock_guard<std::mutex> l(m_frameMutex);
        m_viewFrame = f;
    }
    m_frameIndex = index;
    m_frameStats = fr.stats;
    m_live = index >= m_frameCount - 1;
    emit frameChanged();
    emit viewFrameChanged();
}

void SimController::setFrameIndex(int i) {
    if (m_frameCount == 0) return;
    i = std::clamp(i, 0, m_frameCount - 1);
    if (i == m_frameIndex && !m_live) return;
    showFrame(i);
}

void SimController::stepFrame(int delta) {
    setPlaying(false);
    setFrameIndex(m_frameIndex + delta);
}

void SimController::setPlaying(bool p) {
    if (p == m_playing) return;
    if (p && m_frameCount == 0) return;
    m_playing = p;
    if (p) {
        if (m_frameIndex >= m_frameCount - 1) showFrame(0);
        m_playTimer.start(int(1000.0 / m_fps));
    } else {
        m_playTimer.stop();
    }
    emit playingChanged();
}

void SimController::setPlaybackFps(double f) {
    f = std::clamp(f, 5.0, 60.0);
    m_fps = f;
    if (m_playing) m_playTimer.start(int(1000.0 / m_fps));
    emit playingChanged();
}

std::shared_ptr<const ViewFrame> SimController::viewFrame() const {
    std::lock_guard<std::mutex> l(m_frameMutex);
    return m_viewFrame;
}

// ---------------------------------------------------------------- explainer

QString SimController::phase() const {
    if (!m_run || m_frameCount == 0) return QStringLiteral("Ready");
    switch (m_frameStats.phase) {
    case scl::Phase::Ready: return QStringLiteral("Ready");
    case scl::Phase::Detonation: return QStringLiteral("Detonation");
    case scl::Phase::LinerCollapse: return QStringLiteral("Liner collapse");
    case scl::Phase::JetStretching: return QStringLiteral("Jet stretching");
    case scl::Phase::JetParticulating: return QStringLiteral("Jet breakup");
    case scl::Phase::Penetrating: return QStringLiteral("Penetration");
    case scl::Phase::Complete: return QStringLiteral("Complete");
    }
    return {};
}

QString SimController::phaseText() const {
    const QString p = phase();
    if (p == "Ready")
        return QStringLiteral("A copper cone sits in the front of an explosive cylinder. Press Run to detonate it "
                              "from the rear and watch the cone turn into a jet.");
    if (p == "Detonation")
        return QStringLiteral("The detonation wave sweeps forward at %1 km/s. Behind it the explosive turns into gas "
                              "at around %2 GPa.")
            .arg(m_runCfg.detonationVelocity, 0, 'f', 1)
            .arg(qRound(1.7 * m_runCfg.detonationVelocity * m_runCfg.detonationVelocity / 4));
    if (p == "Liner collapse")
        return QStringLiteral("The gas drives the cone inward. Its walls meet on the axis: a thin inner layer squirts "
                              "forward as the jet, the thick outer part becomes a slow slug.");
    if (p == "Jet stretching")
        return QStringLiteral("The jet's tip moves far faster than its tail, so the copper stretches like taffy: "
                              "longer and thinner the farther it flies.");
    if (p == "Jet breakup")
        return QStringLiteral("Stretched past its limit, the jet breaks into a train of beads. Each still drills, "
                              "but gaps and sideways drift waste penetration.");
    if (p == "Penetration")
        return QStringLiteral("At the target the jet pressure dwarfs the steel's strength and both flow like liquids. "
                              "Depth ≈ jet length × √(ρ jet / ρ target).");
    return QStringLiteral("Done. Compare this standoff with the curve: too close and the jet has not stretched yet, "
                          "too far and it has broken up and drifted.");
}
