// Stub run: builds the real initial geometry and emits it as frames, without physics.
// Lets the app run end to end before the solver backends land. Replaced by core/src/run.cpp.
#include <atomic>
#include <cmath>
#include <mutex>
#include <thread>
#include "backends.hpp"
#include "geometry.hpp"

namespace scl {

std::vector<Device> gpuDevices() { return {}; }

namespace {
Particle3D pack(const Geometry3D& g, size_t i) {
    Particle3D p{};
    auto q = [](float v, float lo, float span) { return uint16_t(std::lround(std::fmin(std::fmax((v - lo) / span, 0.0f), 1.0f) * 65535)); };
    p.x = q(g.pos[i][0], -g.boxRadius, 2 * g.boxRadius);
    p.y = q(g.pos[i][1], -g.boxRadius, 2 * g.boxRadius);
    p.z = q(g.pos[i][2], g.zMin, g.zMax - g.zMin);
    const uint32_t f = g.flags[i];
    p.material = uint8_t(f & 255u);
    p.flags = uint8_t(((f & (F_ACTIVE | F_SLEEP)) ? 1 : 0) | ((f & F_COARSE) ? 8 : 0));
    return p;
}

class StubRun final : public Run {
public:
    StubRun(const Config& c, std::function<void(size_t)> onFrame, std::function<void(float, bool)> onDone)
        : geo_(buildGeometry(c)) {
        worker_ = std::thread([this, onFrame, onDone] {
            for (int k = 0; k < 20 && !cancel_; k++) {
                Frame f;
                f.time = k * 0.5f;
                f.stats.time = f.time;
                f.stats.particles = int(geo_.used);
                f.particles.resize(geo_.capacity);
                for (size_t i = 0; i < geo_.capacity; i++) f.particles[i] = pack(geo_, i);
                { std::lock_guard<std::mutex> l(m_); frames_.push_back(std::move(f)); }
                if (onFrame) onFrame(frames_.size() - 1);
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            running_ = false;
            if (onDone) onDone(0, !cancel_);
        });
    }
    ~StubRun() override { cancel_ = true; if (worker_.joinable()) worker_.join(); }
    void cancel() override { cancel_ = true; }
    void setPaused(bool) override {}
    void setCpuThreads(int) override {}
    bool running() const override { return running_; }
    size_t frameCount() const override { std::lock_guard<std::mutex> l(m_); return frames_.size(); }
    bool frame(size_t i, Frame& out) const override {
        std::lock_guard<std::mutex> l(m_);
        if (i >= frames_.size()) return false;
        out = frames_[i];
        return true;
    }
    SceneInfo scene() const override { return geo_.scene(); }
    Stats progress() const override { Stats s; s.particles = int(geo_.used); return s; }
    Device device() const override { return listDevices().back(); }
    std::vector<JetSample> linerSamples(size_t) const override { return {}; }
    bool jetProfile(JetProfile&) const override { return false; }

private:
    Geometry3D geo_;
    mutable std::mutex m_;
    std::vector<Frame> frames_;
    std::atomic<bool> cancel_{false}, running_{true};
    std::thread worker_;
};
}  // namespace

RunEstimate estimateRun(const Config& c, const Device&) {
    const size_t n = estimateParticles(c);
    return {n, double(n) * 13e-9 * 110 / (0.03 * double(c.linerThicknessFrac * c.chargeDiameter / c.layers)) / 60};
}

std::unique_ptr<Run> startRun(const Config& c, const RunOptions&, std::function<void(size_t)> onFrame,
                              std::function<void(float, bool)> onDone) {
    return std::make_unique<StubRun>(c, std::move(onFrame), std::move(onDone));
}

}  // namespace scl
