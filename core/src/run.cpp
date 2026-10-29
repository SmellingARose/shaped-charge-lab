// Backend-agnostic run driver: steps a Solver on its own thread, stores frames, measures the jet,
// and stops when nothing over the target can still penetrate.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <deque>
#include <mutex>
#include <thread>
#include "backends.hpp"
#include "solver.hpp"
#if !defined(__APPLE__)
#include "gpu/gpu_host.hpp"
#endif

namespace scl {

std::vector<Device> gpuDevices() {
    std::vector<Device> out;
#if !defined(__APPLE__)
    for (auto& d : gpuPluginDevices()) out.push_back(d);
#endif
#if defined(SCL_WITH_METAL)
    for (auto& d : metalDevices()) out.push_back(d);
#endif
    return out;
}

namespace {

std::unique_ptr<Solver> makeSolver(const Geometry3D& g, const RunOptions& o) {
    Backend want = o.device ? o.device->backend : o.backend;
    if (want == Backend::Auto) {
        auto gpus = gpuDevices();
        want = gpus.empty() ? Backend::CPU : gpus.front().backend;
    }
#if defined(SCL_WITH_METAL)
    if (want == Backend::Metal) if (auto s = makeMetalSolver(g)) return s;
#endif
#if !defined(__APPLE__)
    if (want == Backend::HIP) {
        int index = 0;
        if (o.device) {
            auto list = gpuPluginDevices();
            for (size_t k = 0; k < list.size(); k++) if (list[k].name == o.device->name) index = int(k);
        }
        if (auto s = makeGpuPluginSolver(g, index)) return s;
    }
#endif
    int threads = int(std::max(1u, std::thread::hardware_concurrency()));
    if (o.device && o.device->backend == Backend::CPU && o.device->computeUnits > 0) threads = o.device->computeUnits;
    return makeCpuSolver(g, threads);
}

class RunImpl final : public Run {
public:
    RunImpl(const Config& c, const RunOptions& o, std::function<void(size_t)> onFrame, std::function<void(float, bool)> onDone)
        : cfg_(c), opt_(o), geo_(buildGeometry(c)), onFrame_(std::move(onFrame)), onDone_(std::move(onDone)) {
        solver_ = makeSolver(geo_, o);
        device_ = solver_->device();
        scene_ = geo_.scene();
        worker_ = std::thread([this] { loop(); });
    }
    ~RunImpl() override { cancel(); if (worker_.joinable()) worker_.join(); }

    void cancel() override { cancel_ = true; }
    void setPaused(bool p) override { paused_ = p; }
    void setCpuThreads(int t) override { pendingThreads_ = t; }
    bool running() const override { return running_; }
    size_t frameCount() const override { std::lock_guard<std::mutex> l(m_); return frames_.size(); }
    bool frame(size_t i, Frame& out) const override {
        std::lock_guard<std::mutex> l(m_);
        if (i >= frames_.size()) return false;
        out = frames_[i];
        return true;
    }
    SceneInfo scene() const override { return scene_; }
    Stats progress() const override { std::lock_guard<std::mutex> l(m_); return progress_; }
    Device device() const override { return device_; }
    std::vector<JetSample> linerSamples(size_t maxCount) const override {
        std::lock_guard<std::mutex> l(m_);
        std::vector<JetSample> out;
        const size_t stride = std::max<size_t>(1, liner_.size() / std::max<size_t>(maxCount, 1));
        for (size_t k = 0; k < liner_.size(); k += stride)
            out.push_back({liner_[k].z - geo_.L, liner_[k].vz, liner_[k].vz > 2.0f});
        return out;
    }
    bool jetProfile(JetProfile& out) const override {
        std::lock_guard<std::mutex> l(m_);
        if (!haveJet_) return false;
        out = jet_;
        return true;
    }

private:
    Phase phaseOf(const SolverState& s, float pen) const {
        const float apexTime = geo_.zApex / cfg_.detonationVelocity;
        if (s.time < apexTime) return Phase::Detonation;
        if (s.coreTipZ < geo_.L + 0.1f * geo_.CD) return Phase::LinerCollapse;
        if (!s.awake || pen < 0.05f) return Phase::JetStretching;
        return Phase::Penetrating;
    }

    /// Fit z = z_vo + v (t − t_vo) to the jet (material clearly faster than the slug).
    void measureJet(float time) {
        if (liner_.empty()) return;
        std::vector<float> vs;
        float total = 0;
        for (auto& p : liner_) { vs.push_back(p.vz); total += p.mass; }
        std::sort(vs.begin(), vs.end());
        const float vTip = vs[size_t(float(vs.size() - 1) * 0.995f)];
        if (vTip < 1) return;
        const float cut = std::max(0.3f * vTip, 1.5f);
        double sw = 0, sv = 0, sz = 0, svv = 0, svz = 0;
        float vTail = vTip;
        for (auto& p : liner_) {
            if (p.vz <= cut || p.vz > vTip * 1.02f) continue;
            sw += p.mass; sv += p.mass * p.vz; sz += p.mass * p.z;
            svv += p.mass * p.vz * p.vz; svz += p.mass * p.vz * p.z;
            vTail = std::min(vTail, p.vz);
        }
        const double den = sw * svv - sv * sv;
        if (sw <= 0 || std::fabs(den) < 1e-12) return;
        const double B = (sw * svz - sv * sz) / den, A = (sz - B * sv) / sw;
        jet_ = {vTip, std::max(vTail, cut), float(A), time - float(std::max(B, 0.5)), time, float(sw / std::max(total, 1e-9f)),
                geo_.L, geo_.CD, geo_.materials[1].rho0};
        haveJet_ = true;
    }

    void loop() {
        const float vCut = std::sqrt(2 * geo_.materials[2].bernoulliR / geo_.materials[1].rho0);
        float interval = opt_.frameIntervalUs, nextFrame = 0, best = 0, wakeTime = -1;
        const size_t frameBytes = geo_.capacity * sizeof(Particle3D);
        const size_t maxFrames = std::max<size_t>(40, opt_.memoryBudgetBytes / std::max<size_t>(frameBytes, 1));
        int batch = 10;
        std::deque<std::chrono::steady_clock::time_point> stepTimes;
        bool done = false;
        while (!cancel_ && !done) {
            if (paused_) { std::this_thread::sleep_for(std::chrono::milliseconds(20)); continue; }
            if (int t = pendingThreads_.exchange(0)) solver_->setThreads(t);
            const double ms = solver_->step(batch);
            batch = ms < 5 ? 20 : 10;
            const SolverState s = solver_->state();
            if (!std::isfinite(s.time)) break;
            const float pen = std::max(s.penZ - geo_.zFace, 0.0f);
            if (s.awake && wakeTime < 0) wakeTime = s.time;
            best = std::max(best, pen);
            done = (wakeTime >= 0 && s.time - wakeTime > 5 && s.footprintMaxVz < vCut)
                || best >= cfg_.targetThicknessCD * geo_.CD - 2 * geo_.dpCoarse || s.time > 500;

            auto now = std::chrono::steady_clock::now();
            for (int k = 0; k < batch; k++) stepTimes.push_back(now);
            while (!stepTimes.empty() && now - stepTimes.front() > std::chrono::seconds(1)) stepTimes.pop_front();

            Stats st;
            st.time = s.time;
            st.phase = done ? Phase::Complete : phaseOf(s, best);
            st.tipSpeed = s.tipV;
            st.tipTravel = s.coreTipZ - geo_.L;
            st.penetration = best;
            st.msPerStep = ms;
            st.stepsPerSecond = double(stepTimes.size());
            st.particles = int(s.used);
            st.activeParticles = int(s.used);
            st.done = done;
            st.refinementExhausted = s.used >= geo_.capacity && cfg_.jetRefinement > 0;

            const bool wantJet = !haveJetLocked() && s.time > geo_.zApex / cfg_.detonationVelocity + 2
                && (s.coreTipZ > geo_.L + 0.6f * geo_.CD || s.awake);
            if (s.time >= nextFrame || done || wantJet) {
                Frame f;
                f.time = s.time;
                f.stats = st;
                solver_->pack(f.particles);
                std::vector<LinerPoint> lp;
                solver_->liner(lp);
                size_t index;
                {
                    std::lock_guard<std::mutex> l(m_);
                    liner_ = std::move(lp);
                    if (wantJet) measureJet(s.time);
                    frames_.push_back(std::move(f));
                    if (frames_.size() > maxFrames) {
                        std::vector<Frame> kept;
                        for (size_t k = 0; k < frames_.size(); k += 2) kept.push_back(std::move(frames_[k]));
                        frames_ = std::move(kept);
                        interval *= 2;
                    }
                    index = frames_.size() - 1;
                    progress_ = st;
                }
                nextFrame = s.time + interval;
                if (onFrame_) onFrame_(index);
            } else {
                std::lock_guard<std::mutex> l(m_);
                progress_ = st;
            }
        }
        running_ = false;
        if (onDone_) onDone_(best, done && !cancel_);
    }

    bool haveJetLocked() const { std::lock_guard<std::mutex> l(m_); return haveJet_; }

    Config cfg_;
    RunOptions opt_;
    Geometry3D geo_;
    std::unique_ptr<Solver> solver_;
    Device device_;
    SceneInfo scene_;
    std::function<void(size_t)> onFrame_;
    std::function<void(float, bool)> onDone_;
    mutable std::mutex m_;
    std::vector<Frame> frames_;
    std::vector<LinerPoint> liner_;
    Stats progress_;
    JetProfile jet_{};
    bool haveJet_ = false;
    std::atomic<bool> cancel_{false}, paused_{false}, running_{true};
    std::atomic<int> pendingThreads_{0};
    std::thread worker_;
};

}  // namespace

SceneInfo preview(const Config& c, std::vector<Particle3D>& out) {
    const Geometry3D g = buildGeometry(c);
    auto q = [](float v, float lo, float span) {
        return uint16_t(std::lround(std::fmin(std::fmax((v - lo) / span, 0.0f), 1.0f) * 65535.0f));
    };
    out.assign(g.used, Particle3D{});
    for (size_t i = 0; i < g.used; i++) {
        Particle3D& p = out[i];
        p.x = q(g.pos[i][0], -g.boxRadius, 2 * g.boxRadius);
        p.y = q(g.pos[i][1], -g.boxRadius, 2 * g.boxRadius);
        p.z = q(g.pos[i][2], g.zMin, g.zMax - g.zMin);
        const uint32_t f = g.flags[i];
        p.material = uint8_t(f & 255u);
        p.flags = uint8_t(1u | ((f & F_COARSE) ? 8u : 0u));
    }
    return g.scene();
}

RunEstimate estimateRun(const Config& c, const Device& d) {
    const size_t n = estimateParticles(c);
    const double dpF = c.linerThicknessFrac * c.chargeDiameter / c.layers;
    const double steps = 110 / (0.03 * dpF);
    // measured: M4 GPU ≈ 13 ns per particle-step; CPU ≈ 40 ns per particle-step per 10 threads
    double nsPerParticleStep = 13;
    if (d.backend == Backend::CPU) nsPerParticleStep = 40.0 * 10 / std::max(d.computeUnits, 1);
    return {n, double(n) * nsPerParticleStep * 1e-9 * steps / 60};
}

std::unique_ptr<Run> startRun(const Config& c, const RunOptions& o, std::function<void(size_t)> onFrame,
                              std::function<void(float, bool)> onDone) {
    return std::make_unique<RunImpl>(c, o, std::move(onFrame), std::move(onDone));
}

}  // namespace scl
