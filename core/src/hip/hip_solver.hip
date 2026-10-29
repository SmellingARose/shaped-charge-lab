// GPU backend for NVIDIA and AMD, built as the scl_gpu shared library (see gpu/gpu_plugin.h).
// Kernels: physics/sph.h compiled as HIP (or CUDA, see hip_compat.h).
#include "hip_compat.h"
#include "../physics/sph.h"
#include "../gpu/gpu_plugin.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace scl {

namespace {

#define HIP_OK(x) do { hipError_t e_ = (x); if (e_ != hipSuccess) { std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(e_), __FILE__, __LINE__); return false; } } while (0)

constexpr int TPB = 256;
inline unsigned blocksFor(size_t n) { return unsigned((n + TPB - 1) / TPB); }

// ---- physics wrappers (one thread per particle)
__global__ void kEOS(Particles b, const MatP* mats, SimParams P) {
    eosBody(blockIdx.x * blockDim.x + threadIdx.x, b, mats, P);
}
__global__ void kRates(Particles b, Grid g, const MatP* mats, SimParams P) {
    ratesBody(blockIdx.x * blockDim.x + threadIdx.x, b, g, mats, P);
}
__global__ void kForces(Particles b, Grid g, u32* state, SimParams P) {
    forcesBody(blockIdx.x * blockDim.x + threadIdx.x, b, g, state, P);
}
__global__ void kIntegrate(Particles b, u32* state, const MatP* mats, SimParams P) {
    integrateBody(blockIdx.x * blockDim.x + threadIdx.x, b, state, mats, P);
}
__global__ void kSplit(Particles b, u32* state, SimParams P) {
    splitBody(blockIdx.x * blockDim.x + threadIdx.x, b, state, P);
}
__global__ void kPack(Particles b, FrameP* out, const MatP* mats, SimParams P) {
    packBody(blockIdx.x * blockDim.x + threadIdx.x, b, out, mats, P);
}
__global__ void kFinalizeDt(u32* state) { if (blockIdx.x == 0 && threadIdx.x == 0) finalizeDtBody(state); }
__global__ void kAdvance(u32* state, SimParams P) { if (blockIdx.x == 0 && threadIdx.x == 0) advanceBody(state, P); }

// ---- grid: counting sort into cell order
__global__ void gClear(u32* cnt, SimParams P) {
    u32 i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i <= P.gdim.w) cnt[i] = 0;
}
__global__ void gAssign(Particles b, u32* cellOf, u32* rank, u32* cnt, SimParams P) {
    u32 i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= P.cnt.x) return;
    u32 c = particleCell(i, b, P);
    cellOf[i] = c;
    rank[i] = atomicAdd(&cnt[c], 1u);
}
// Exclusive scan of up to 1024 elements per block (shared-memory Hillis–Steele; warp-size agnostic).
__global__ void gScan(const u32* in, u32* out, u32* sums, u32 len) {
    __shared__ u32 t[1024];
    u32 tid = threadIdx.x, gid = blockIdx.x * 1024 + tid;
    u32 v = gid < len ? in[gid] : 0u;
    t[tid] = v;
    __syncthreads();
    for (u32 off = 1; off < 1024; off <<= 1) {
        u32 add = tid >= off ? t[tid - off] : 0u;
        __syncthreads();
        t[tid] += add;
        __syncthreads();
    }
    if (gid < len) out[gid] = t[tid] - v;
    if (tid == 1023) sums[blockIdx.x] = t[tid];
}
__global__ void gAddSums(u32* out, const u32* sums, u32 len) {
    u32 gid = blockIdx.x * 1024 + threadIdx.x;
    if (gid < len) out[gid] += sums[blockIdx.x];
}
__global__ void gScatter(const u32* cellOf, const u32* rank, const u32* start, u32* sorted, SimParams P) {
    u32 i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= P.cnt.x) return;
    sorted[start[cellOf[i]] + rank[i]] = i;
}
struct Persist { v4 *pos, *vel, *st, *S0, *S1, *aux, *G0, *G1, *G2; u32* flags; };
__global__ void gPermute(Persist a, Persist b, const u32* sorted, SimParams P) {
    u32 k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= P.cnt.x) return;
    u32 j = sorted[k];
    b.pos[k] = a.pos[j]; b.vel[k] = a.vel[j]; b.st[k] = a.st[j]; b.S0[k] = a.S0[j]; b.S1[k] = a.S1[j];
    b.aux[k] = a.aux[j]; b.G0[k] = a.G0[j]; b.G1[k] = a.G1[j]; b.G2[k] = a.G2[j]; b.flags[k] = a.flags[j];
}

class HipSolver {
public:
    static HipSolver* create(const SclGpuInit& g, int device) {
        auto* s = new HipSolver();
        if (!s->init(g, device)) { delete s; return nullptr; }
        return s;
    }
    ~HipSolver() {
        for (void* p : allocations_) hipFree(p);
        for (hipEvent_t e : {ev0_, ev1_}) if (e) hipEventDestroy(e);
        for (hipEvent_t e : prof_) if (e) hipEventDestroy(e);
    }

    double step(int steps) {
        hipEventRecord(ev0_);
        for (int k = 0; k < steps; k++) {
            stepOnce();
            if (P_.cnt.y > 0 && ++stepCounter_ % 10 == 0)
                kSplit<<<blocksFor(n_), TPB>>>(particles(), state_, P_);
        }
        hipEventRecord(ev1_);
        hipEventSynchronize(ev1_);
        float ms = 0;
        hipEventElapsedTime(&ms, ev0_, ev1_);
        hipError_t e = hipGetLastError();
        if (e != hipSuccess) std::fprintf(stderr, "HIP solver error: %s\n", hipGetErrorString(e));
        return double(ms) / std::max(steps, 1);
    }

    void state(SclGpuState& o) {
        u32 s[S_COUNT];
        hipMemcpy(s, state_, sizeof(s), hipMemcpyDeviceToHost);
        o.time = scl_host_float(s[S_TIME]);
        o.dt = scl_host_float(s[S_DT]);
        o.linerZ = s[S_LINERZ] ? scl_host_float(s[S_LINERZ]) - ZOFF : 0;
        o.penZ = s[S_PENZ] ? scl_host_float(s[S_PENZ]) - ZOFF : P_.box.w;
        o.coreTipZ = s[S_CORETIPZ] ? scl_host_float(s[S_CORETIPZ]) - ZOFF : o.linerZ;
        o.tipV = scl_host_float(s[S_TIPV]);
        o.footprintMaxVz = scl_host_float(s[S_FOOTVZ]);
        o.awake = s[S_AWAKE] != 0;
        o.used = std::min<size_t>(s[S_USED], n_);
    }

    void pack(void* out) {
        kPack<<<blocksFor(n_), TPB>>>(particles(), frame_, mats_, P_);
        hipMemcpy(out, frame_, n_ * sizeof(FrameP), hipMemcpyDeviceToHost);
    }

    size_t liner(float* out) {
        std::vector<v4> p(n_), v(n_);
        std::vector<u32> f(n_);
        hipMemcpy(p.data(), cur_.pos, n_ * sizeof(v4), hipMemcpyDeviceToHost);
        hipMemcpy(v.data(), cur_.vel, n_ * sizeof(v4), hipMemcpyDeviceToHost);
        hipMemcpy(f.data(), cur_.flags, n_ * sizeof(u32), hipMemcpyDeviceToHost);
        size_t m = 0;
        for (size_t i = 0; i < n_; i++) {
            if ((f[i] & 255u) != 1u || !(f[i] & F_ACTIVE)) continue;
            float* o = out + 5 * m++;
            o[0] = p[i].x; o[1] = p[i].y; o[2] = p[i].z; o[3] = v[i].z; o[4] = v[i].w;
        }
        return m;
    }

private:
    static float scl_host_float(u32 u) { float f; std::memcpy(&f, &u, 4); return f; }

    template <class T> bool alloc(T*& p, size_t count) {
        HIP_OK(hipMalloc(reinterpret_cast<void**>(&p), std::max<size_t>(count, 1) * sizeof(T)));
        allocations_.push_back(p);
        return true;
    }

    bool init(const SclGpuInit& g, int device) {
        HIP_OK(hipSetDevice(device));
        std::memcpy(&P_, g.params, sizeof(SimParams));
        n_ = g.capacity;
        const MatP* mats = static_cast<const MatP*>(g.materials);
        Persist* sets[2] = {&cur_, &alt_};
        for (Persist* s : sets) {
            if (!alloc(s->pos, n_) || !alloc(s->vel, n_) || !alloc(s->st, n_) || !alloc(s->S0, n_) || !alloc(s->S1, n_) ||
                !alloc(s->aux, n_) || !alloc(s->G0, n_) || !alloc(s->G1, n_) || !alloc(s->G2, n_) || !alloc(s->flags, n_))
                return false;
        }
        if (!alloc(L0_, n_) || !alloc(L1_, n_) || !alloc(L2_, n_) || !alloc(acc_, n_) || !alloc(r0_, n_) || !alloc(dS0_, n_) ||
            !alloc(dS1_, n_) || !alloc(cellOf_, n_) || !alloc(rank_, n_) || !alloc(sorted_, n_) || !alloc(frame_, n_))
            return false;
        ncells1_ = size_t(P_.gdim.w) + 1;
        if (!alloc(cnt_, ncells1_) || !alloc(start_, ncells1_ + 1) || !alloc(sums_, 2048) || !alloc(sumsScanned_, 2048) ||
            !alloc(scratch_, 2048) || !alloc(state_, S_COUNT) || !alloc(mats_, 3))
            return false;

        std::vector<v4> pos(n_), vel(n_), st(n_), aux(n_), zero(n_, mk4(0, 0, 0, 0));
        std::vector<v4> G0(n_, mk4(1, 0, 0, 0)), G1(n_, mk4(0, 1, 0, 0)), G2(n_, mk4(0, 0, 1, 0));
        for (size_t i = 0; i < n_; i++) {
            pos[i] = mk4(g.pos[4 * i], g.pos[4 * i + 1], g.pos[4 * i + 2], g.pos[4 * i + 3]);
            vel[i] = mk4(g.vel[4 * i], g.vel[4 * i + 1], g.vel[4 * i + 2], g.vel[4 * i + 3]);
            st[i] = mk4(mats[g.flags[i] & 255u].rho0, 0, 0, 1);
            aux[i] = mk4(0, g.detonationTime[i], 0, 0);
        }
        const size_t f4 = n_ * sizeof(v4);
        HIP_OK(hipMemcpy(cur_.pos, pos.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.vel, vel.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.st, st.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.aux, aux.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.S0, zero.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.S1, zero.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.G0, G0.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.G1, G1.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.G2, G2.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(cur_.flags, g.flags, n_ * sizeof(u32), hipMemcpyHostToDevice));
        for (v4* p : {L0_, L1_, L2_, acc_, r0_, dS0_, dS1_}) HIP_OK(hipMemcpy(p, zero.data(), f4, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(mats_, mats, sizeof(MatP) * 3, hipMemcpyHostToDevice));
        HIP_OK(hipMemcpy(state_, g.state, sizeof(u32) * S_COUNT, hipMemcpyHostToDevice));
        HIP_OK(hipEventCreate(&ev0_));
        HIP_OK(hipEventCreate(&ev1_));
        if (profile_) for (hipEvent_t& e : prof_) HIP_OK(hipEventCreate(&e));
        return true;
    }

    Particles particles() const {
        Particles b;
        b.pos = cur_.pos; b.vel = cur_.vel; b.st = cur_.st; b.S0 = cur_.S0; b.S1 = cur_.S1; b.aux = cur_.aux;
        b.flags = cur_.flags; b.G0 = cur_.G0; b.G1 = cur_.G1; b.G2 = cur_.G2;
        b.L0 = L0_; b.L1 = L1_; b.L2 = L2_; b.acc = acc_; b.r0 = r0_; b.dS0 = dS0_; b.dS1 = dS1_;
        return b;
    }

    void stepOnce() {
        mark(0);
        const u32 len = u32(ncells1_);
        const unsigned scanBlocks = (len + 1023) / 1024;
        gClear<<<blocksFor(ncells1_), TPB>>>(cnt_, P_);
        gAssign<<<blocksFor(n_), TPB>>>(particles(), cellOf_, rank_, cnt_, P_);
        gScan<<<scanBlocks, 1024>>>(cnt_, start_, sums_, len);
        gScan<<<1, 1024>>>(sums_, sumsScanned_, scratch_, scanBlocks);
        gAddSums<<<scanBlocks, 1024>>>(start_, sumsScanned_, len);
        gScatter<<<blocksFor(n_), TPB>>>(cellOf_, rank_, start_, sorted_, P_);
        gPermute<<<blocksFor(n_), TPB>>>(cur_, alt_, sorted_, P_);
        std::swap(cur_, alt_);
        mark(1);
        Particles b = particles();
        Grid g{start_};
        kEOS<<<blocksFor(n_), TPB>>>(b, mats_, P_);
        mark(2);
        kRates<<<blocksFor(n_), TPB>>>(b, g, mats_, P_);
        mark(3);
        kForces<<<blocksFor(n_), TPB>>>(b, g, state_, P_);
        mark(4);
        kFinalizeDt<<<1, 1>>>(state_);
        kIntegrate<<<blocksFor(n_), TPB>>>(b, state_, mats_, P_);
        kAdvance<<<1, 1>>>(state_, P_);
        mark(5);
        if (profile_) report();
    }

    // SCL_PROFILE=1: per-phase GPU times, averaged over 50 steps (synchronises every step, so only for measuring)
    void mark(int k) { if (profile_) hipEventRecord(prof_[k]); }
    void report() {
        hipEventSynchronize(prof_[5]);
        for (int k = 0; k < 5; k++) {
            float ms = 0;
            hipEventElapsedTime(&ms, prof_[k], prof_[k + 1]);
            profMs_[k] += ms;
        }
        if (++profSteps_ < 50) return;
        u32 used = 0;
        hipMemcpy(&used, state_ + S_USED, sizeof(u32), hipMemcpyDeviceToHost);
        std::fprintf(stderr, "gpu profile ms/step: grid %.2f eos %.2f rates %.2f forces %.2f integrate %.2f (used %u of %zu)\n",
                     profMs_[0] / 50, profMs_[1] / 50, profMs_[2] / 50, profMs_[3] / 50, profMs_[4] / 50, used, n_);
        profSteps_ = 0;
        for (double& v : profMs_) v = 0;
    }

    SimParams P_{};
    size_t n_ = 0, ncells1_ = 0;
    Persist cur_{}, alt_{};
    v4 *L0_ = nullptr, *L1_ = nullptr, *L2_ = nullptr, *acc_ = nullptr, *r0_ = nullptr, *dS0_ = nullptr, *dS1_ = nullptr;
    u32 *cellOf_ = nullptr, *rank_ = nullptr, *sorted_ = nullptr, *cnt_ = nullptr, *start_ = nullptr;
    u32 *sums_ = nullptr, *sumsScanned_ = nullptr, *scratch_ = nullptr, *state_ = nullptr;
    MatP* mats_ = nullptr;
    FrameP* frame_ = nullptr;
    std::vector<void*> allocations_;
    hipEvent_t ev0_ = nullptr, ev1_ = nullptr;
    int stepCounter_ = 0;
    bool profile_ = std::getenv("SCL_PROFILE") != nullptr;
    hipEvent_t prof_[6] = {};
    double profMs_[5] = {};
    int profSteps_ = 0;
};

int deviceCount() {
    int count = 0;
    return hipGetDeviceCount(&count) == hipSuccess ? count : 0;
}

int deviceInfo(int index, SclGpuDevice* out) {
    hipDeviceProp_t prop;
    if (hipGetDeviceProperties(&prop, index) != hipSuccess) return 1;
    std::snprintf(out->name, sizeof(out->name), "%s", prop.name);
    out->computeUnits = prop.multiProcessorCount;
    out->memoryBytes = prop.totalGlobalMem;
    return 0;
}

HipSolver* as(void* s) { return static_cast<HipSolver*>(s); }

const SclGpuPlugin kPlugin = {
    SCL_GPU_PLUGIN_ABI,
    sizeof(SimParams), sizeof(MatP), sizeof(FrameP), S_COUNT,
#if defined(__HIPCC__) || defined(SCL_USE_HIP_RUNTIME)
    "HIP",
#else
    "CUDA",
#endif
    deviceCount,
    deviceInfo,
    [](const SclGpuInit* g, int device) -> void* { return HipSolver::create(*g, device); },
    [](void* s) { delete as(s); },
    [](void* s, int steps) { return as(s)->step(steps); },
    [](void* s, SclGpuState* o) { as(s)->state(*o); },
    [](void* s, void* out) { as(s)->pack(out); },
    [](void* s, float* out) { return as(s)->liner(out); },
};

}  // namespace

}  // namespace scl

SCL_GPU_EXPORT const SclGpuPlugin* scl_gpu_plugin(void) { return &scl::kPlugin; }
