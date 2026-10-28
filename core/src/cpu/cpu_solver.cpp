// CPU backend: the shared physics in physics/sph.h run over a persistent thread pool.
// Particle data is reordered into grid-cell order every step so neighbour loops stream through memory.
#include <chrono>
#include <cstring>
#include <thread>
#include "../solver.hpp"
#include "thread_pool.hpp"

namespace scl {

namespace {

class CpuSolver final : public Solver {
public:
    CpuSolver(const Geometry3D& g, int threads)
        : P_(makeSimParams(g)), n_(g.capacity), pool_(threads), threads_(threads) {
        for (int k = 0; k < 3; k++) {
            const MaterialParams& m = g.materials[k];
            static_assert(sizeof(MaterialParams) == sizeof(MatP), "material layout mismatch");
            std::memcpy(&mats_[k], &m, sizeof(MatP));
        }
        auto alloc = [&](std::vector<v4>& v) { v.assign(n_, mk4(0, 0, 0, 0)); };
        for (auto* v : {&pos_, &vel_, &st_, &S0_, &S1_, &aux_, &G0_, &G1_, &G2_, &L0_, &L1_, &L2_, &acc_, &r0_, &dS0_, &dS1_})
            alloc(*v);
        for (auto* v : {&pos2_, &vel2_, &st2_, &S02_, &S12_, &aux2_, &G02_, &G12_, &G22_}) alloc(*v);
        flags_.assign(n_, 0); flags2_.assign(n_, 0);
        cellOf_.assign(n_, 0); rank_.assign(n_, 0); sorted_.assign(n_, 0);
        cnt_.assign(size_t(P_.gdim.w) + 1, 0); start_.assign(size_t(P_.gdim.w) + 2, 0);
        for (size_t i = 0; i < n_; i++) {
            pos_[i] = mk4(g.pos[i][0], g.pos[i][1], g.pos[i][2], g.pos[i][3]);
            vel_[i] = mk4(g.vel[i][0], g.vel[i][1], g.vel[i][2], g.vel[i][3]);
            const u32 mat = g.flags[i] & 255u;
            st_[i] = mk4(g.materials[mat].rho0, 0, 0, 1);
            aux_[i] = mk4(0, g.detonationTime[i], 0, 0);
            G0_[i] = mk4(1, 0, 0, 0); G1_[i] = mk4(0, 1, 0, 0); G2_[i] = mk4(0, 0, 1, 0);
            flags_[i] = g.flags[i];
        }
        initState(state_, g.used);
        dev_.backend = Backend::CPU;
        dev_.computeUnits = threads;
        dev_.name = "CPU (" + std::to_string(threads) + " threads)";
    }

    double step(int steps) override {
        auto t0 = std::chrono::steady_clock::now();
        for (int k = 0; k < steps; k++) {
            stepOnce();
            if (P_.cnt.y > 0 && ++stepCounter_ % 10 == 0) {
                // splitting appends to free slots through an atomic counter; run serially for determinism
                Particles b = bufs();
                const u32 used = state_[S_USED];
                for (u32 i = 0; i < used; i++) splitBody(i, b, state_, P_);
            }
        }
        auto t1 = std::chrono::steady_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count() / std::max(steps, 1);
    }

    SolverState state() override {
        SolverState s;
        s.time = scl_as_float(state_[S_TIME]);
        s.dt = scl_as_float(state_[S_DT]);
        s.linerZ = state_[S_LINERZ] ? scl_as_float(state_[S_LINERZ]) - ZOFF : 0;
        s.penZ = state_[S_PENZ] ? scl_as_float(state_[S_PENZ]) - ZOFF : P_.box.w;
        s.coreTipZ = state_[S_CORETIPZ] ? scl_as_float(state_[S_CORETIPZ]) - ZOFF : s.linerZ;
        s.tipV = scl_as_float(state_[S_TIPV]);
        s.footprintMaxVz = scl_as_float(state_[S_FOOTVZ]);
        s.awake = state_[S_AWAKE] != 0;
        s.used = std::min<size_t>(state_[S_USED], n_);
        return s;
    }

    void pack(std::vector<Particle3D>& out) override {
        static_assert(sizeof(FrameP) == sizeof(Particle3D), "frame layout mismatch");
        out.resize(n_);
        Particles b = bufs();
        auto* o = reinterpret_cast<FrameP*>(out.data());
        pool_.parallelFor(n_, [&](size_t a, size_t e) { for (size_t i = a; i < e; i++) packBody(u32(i), b, o, mats_, P_); });
    }

    void liner(std::vector<LinerPoint>& out) override {
        out.clear();
        for (size_t i = 0; i < n_; i++) {
            const u32 f = flags_[i];
            if ((f & 255u) == 1u && (f & F_ACTIVE))
                out.push_back({pos_[i].x, pos_[i].y, pos_[i].z, vel_[i].z, vel_[i].w});
        }
    }

    void setThreads(int t) override { threads_ = std::max(1, t); pool_.resize(threads_); dev_.computeUnits = threads_;
                                      dev_.name = "CPU (" + std::to_string(threads_) + " threads)"; }
    Device device() const override { return dev_; }

private:
    Particles bufs() {
        Particles b;
        b.pos = pos_.data(); b.vel = vel_.data(); b.st = st_.data(); b.S0 = S0_.data(); b.S1 = S1_.data(); b.aux = aux_.data();
        b.flags = flags_.data();
        b.G0 = G0_.data(); b.G1 = G1_.data(); b.G2 = G2_.data();
        b.L0 = L0_.data(); b.L1 = L1_.data(); b.L2 = L2_.data();
        b.acc = acc_.data(); b.r0 = r0_.data(); b.dS0 = dS0_.data(); b.dS1 = dS1_.data();
        return b;
    }

    template <class F> void each(size_t count, F&& f) {
        pool_.parallelFor(count, [&](size_t a, size_t e) { for (size_t i = a; i < e; i++) f(u32(i)); }, 512);
    }

    void buildGrid() {
        const size_t ncells = P_.gdim.w;
        Particles b = bufs();
        each(n_, [&](u32 i) { cellOf_[i] = particleCell(i, b, P_); });
        std::fill(cnt_.begin(), cnt_.end(), 0u);
        for (size_t i = 0; i < n_; i++) rank_[i] = cnt_[cellOf_[i]]++;   // sentinel bucket = ncells
        u32 acc = 0;
        for (size_t c = 0; c <= ncells; c++) { start_[c] = acc; acc += cnt_[c]; }
        start_[ncells + 1] = acc;
        for (size_t i = 0; i < n_; i++) sorted_[start_[cellOf_[i]] + rank_[i]] = u32(i);
        // permute persistent arrays into cell order
        each(n_, [&](u32 k) {
            const u32 j = sorted_[k];
            pos2_[k] = pos_[j]; vel2_[k] = vel_[j]; st2_[k] = st_[j]; S02_[k] = S0_[j]; S12_[k] = S1_[j];
            aux2_[k] = aux_[j]; flags2_[k] = flags_[j]; G02_[k] = G0_[j]; G12_[k] = G1_[j]; G22_[k] = G2_[j];
        });
        pos_.swap(pos2_); vel_.swap(vel2_); st_.swap(st2_); S0_.swap(S02_); S1_.swap(S12_);
        aux_.swap(aux2_); flags_.swap(flags2_); G0_.swap(G02_); G1_.swap(G12_); G2_.swap(G22_);
    }

    void stepOnce() {
        buildGrid();
        Particles b = bufs();
        Grid g{start_.data()};
        const size_t live = start_[P_.gdim.w];
        each(n_, [&](u32 i) { eosBody(i, b, mats_, P_); });
        each(live, [&](u32 i) { ratesBody(i, b, g, mats_, P_); });
        each(live, [&](u32 i) { forcesBody(i, b, g, state_, P_); });
        finalizeDtBody(state_);
        each(n_, [&](u32 i) { integrateBody(i, b, state_, mats_, P_); });
        advanceBody(state_, P_);
    }

    SimParams P_;
    size_t n_;
    MatP mats_[3];
    u32 state_[S_COUNT];
    std::vector<v4> pos_, vel_, st_, S0_, S1_, aux_, G0_, G1_, G2_, L0_, L1_, L2_, acc_, r0_, dS0_, dS1_;
    std::vector<v4> pos2_, vel2_, st2_, S02_, S12_, aux2_, G02_, G12_, G22_;
    std::vector<u32> flags_, flags2_, cellOf_, rank_, sorted_, cnt_, start_;
    ThreadPool pool_;
    int threads_;
    int stepCounter_ = 0;
    Device dev_;
};

}  // namespace

std::unique_ptr<Solver> makeCpuSolver(const Geometry3D& g, int threads) {
    return std::make_unique<CpuSolver>(g, threads);
}

}  // namespace scl
