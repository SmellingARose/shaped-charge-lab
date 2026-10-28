// Metal backend (macOS). Kernels: physics/sph.h compiled as MSL via metal/kernels.metal.in.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cstring>
#include <map>
#include <string>
#include "../solver.hpp"

namespace scl {

namespace {

static const char* kMetalSource =
#include "metal_source.inc"
    ;

id<MTLDevice> defaultDevice() {
    static id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    return dev;
}

class MetalSolver final : public Solver {
public:
    static std::unique_ptr<Solver> create(const Geometry3D& g) {
        auto s = std::unique_ptr<MetalSolver>(new MetalSolver(g));
        if (!s->ok_) return nullptr;
        return s;
    }

    ~MetalSolver() override = default;

    double step(int steps) override {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue_ commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            for (int k = 0; k < steps; k++) {
                encodeStep(e);
                if (P_.cnt.y > 0 && ++stepCounter_ % 10 == 0) dispatchParticles(e, "kSplit", n_);
            }
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.error) NSLog(@"Metal solver error: %@", cb.error);
            return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / std::max(steps, 1);
        }
    }

    SolverState state() override {
        const u32* s = (const u32*)[state_ contents];
        SolverState o;
        o.time = scl_as_float(s[S_TIME]);
        o.dt = scl_as_float(s[S_DT]);
        o.linerZ = s[S_LINERZ] ? scl_as_float(s[S_LINERZ]) - ZOFF : 0;
        o.penZ = s[S_PENZ] ? scl_as_float(s[S_PENZ]) - ZOFF : P_.box.w;
        o.coreTipZ = s[S_CORETIPZ] ? scl_as_float(s[S_CORETIPZ]) - ZOFF : o.linerZ;
        o.tipV = scl_as_float(s[S_TIPV]);
        o.footprintMaxVz = scl_as_float(s[S_FOOTVZ]);
        o.awake = s[S_AWAKE] != 0;
        o.used = std::min<size_t>(s[S_USED], n_);
        return o;
    }

    void pack(std::vector<Particle3D>& out) override {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue_ commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            bindParticles(e);
            [e setBuffer:frame_ offset:0 atIndex:21];
            run(e, "kPack", n_);
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
        out.resize(n_);
        std::memcpy(out.data(), [frame_ contents], n_ * sizeof(Particle3D));
    }

    void liner(std::vector<LinerPoint>& out) override {
        out.clear();
        const v4* p = (const v4*)[buf_["pos"] contents];
        const v4* v = (const v4*)[buf_["vel"] contents];
        const u32* f = (const u32*)[buf_["flags"] contents];
        for (size_t i = 0; i < n_; i++)
            if ((f[i] & 255u) == 1u && (f[i] & F_ACTIVE)) out.push_back({p[i].x, p[i].y, p[i].z, v[i].z, v[i].w});
    }

    Device device() const override { return dev_; }

private:
    explicit MetalSolver(const Geometry3D& g) : P_(makeSimParams(g)), n_(g.capacity) {
        id<MTLDevice> dev = defaultDevice();
        if (!dev) return;
        queue_ = [dev newCommandQueue];
        NSError* err = nil;
        MTLCompileOptions* opts = [MTLCompileOptions new];
        opts.mathMode = MTLMathModeFast;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kMetalSource] options:opts error:&err];
        if (!lib) { NSLog(@"Metal compile failed: %@", err); return; }
        for (NSString* name in @[@"kEOS", @"kRates", @"kForces", @"kIntegrate", @"kSplit", @"kPack", @"kFinalizeDt", @"kAdvance",
                                 @"gClear", @"gAssign", @"gScan", @"gAddSums", @"gScatter", @"gPermute"]) {
            id<MTLFunction> fn = [lib newFunctionWithName:name];
            id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&err];
            if (!pso) { NSLog(@"Metal pipeline %@ failed: %@", name, err); return; }
            pso_[name.UTF8String] = pso;
        }
        auto make = [&](size_t bytes) { return [dev newBufferWithLength:std::max<size_t>(bytes, 16) options:MTLResourceStorageModeShared]; };
        const size_t f4 = n_ * sizeof(v4);
        for (const char* k : {"pos", "vel", "st", "S0", "S1", "aux", "G0", "G1", "G2", "L0", "L1", "L2", "acc", "r0", "dS0", "dS1",
                              "pos2", "vel2", "st2", "S02", "S12", "aux2", "G02", "G12", "G22"})
            buf_[k] = make(f4);
        buf_["flags"] = make(n_ * 4); buf_["flags2"] = make(n_ * 4);
        cellOf_ = make(n_ * 4); rank_ = make(n_ * 4); sorted_ = make(n_ * 4);
        const size_t nc1 = size_t(P_.gdim.w) + 1;
        cnt_ = make(nc1 * 4); start_ = make((nc1 + 1) * 4);
        sums_ = make(1024 * 4 * 2); sumsScanned_ = make(1024 * 4 * 2); scratch_ = make(1024 * 4 * 2);
        state_ = make(S_COUNT * 4);
        mats_ = make(sizeof(MatP) * 3);
        frame_ = make(n_ * sizeof(Particle3D));

        auto* P = (v4*)[buf_["pos"] contents]; auto* V = (v4*)[buf_["vel"] contents];
        auto* ST = (v4*)[buf_["st"] contents]; auto* AX = (v4*)[buf_["aux"] contents];
        auto* G0 = (v4*)[buf_["G0"] contents]; auto* G1 = (v4*)[buf_["G1"] contents]; auto* G2 = (v4*)[buf_["G2"] contents];
        auto* FL = (u32*)[buf_["flags"] contents];
        for (const char* k : {"S0", "S1", "L0", "L1", "L2", "acc", "r0", "dS0", "dS1"}) std::memset([buf_[k] contents], 0, f4);
        for (size_t i = 0; i < n_; i++) {
            P[i] = mk4(g.pos[i][0], g.pos[i][1], g.pos[i][2], g.pos[i][3]);
            V[i] = mk4(g.vel[i][0], g.vel[i][1], g.vel[i][2], g.vel[i][3]);
            ST[i] = mk4(g.materials[g.flags[i] & 255u].rho0, 0, 0, 1);
            AX[i] = mk4(0, g.detonationTime[i], 0, 0);
            G0[i] = mk4(1, 0, 0, 0); G1[i] = mk4(0, 1, 0, 0); G2[i] = mk4(0, 0, 1, 0);
            FL[i] = g.flags[i];
        }
        std::memcpy([mats_ contents], g.materials.data(), sizeof(MatP) * 3);
        initState((u32*)[state_ contents], g.used);
        dev_.backend = Backend::Metal;
        dev_.name = std::string(dev.name.UTF8String) + " (Metal)";
        dev_.memoryBytes = dev.recommendedMaxWorkingSetSize;
        ok_ = true;
    }

    void run(id<MTLComputeCommandEncoder> e, const char* name, size_t count) {
        id<MTLComputePipelineState> p = pso_[name];
        [e setComputePipelineState:p];
        const NSUInteger w = std::min<NSUInteger>(p.maxTotalThreadsPerThreadgroup, 256);
        [e dispatchThreads:MTLSizeMake(std::max<size_t>(count, 1), 1, 1) threadsPerThreadgroup:MTLSizeMake(w, 1, 1)];
    }

    void bindParticles(id<MTLComputeCommandEncoder> e) {
        static const char* order[] = {"pos", "vel", "st", "S0", "S1", "aux", "flags", "G0", "G1", "G2",
                                      "L0", "L1", "L2", "acc", "r0", "dS0", "dS1"};
        for (int k = 0; k < 17; k++) [e setBuffer:buf_[order[k]] offset:0 atIndex:k];
        [e setBuffer:start_ offset:0 atIndex:17];
        [e setBuffer:state_ offset:0 atIndex:18];
        [e setBuffer:mats_ offset:0 atIndex:19];
        [e setBytes:&P_ length:sizeof(P_) atIndex:20];
    }

    void dispatchParticles(id<MTLComputeCommandEncoder> e, const char* name, size_t count) {
        bindParticles(e);
        run(e, name, count);
    }

    void scan(id<MTLComputeCommandEncoder> e) {
        u32 len = u32(P_.gdim.w) + 1;
        const NSUInteger blocks = (len + 1023) / 1024;
        [e setComputePipelineState:pso_["gScan"]];
        [e setBuffer:cnt_ offset:0 atIndex:0]; [e setBuffer:start_ offset:0 atIndex:1]; [e setBuffer:sums_ offset:0 atIndex:2];
        [e setBytes:&len length:4 atIndex:3];
        [e dispatchThreadgroups:MTLSizeMake(blocks, 1, 1) threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
        u32 blen = u32(blocks);
        [e setBuffer:sums_ offset:0 atIndex:0]; [e setBuffer:sumsScanned_ offset:0 atIndex:1]; [e setBuffer:scratch_ offset:0 atIndex:2];
        [e setBytes:&blen length:4 atIndex:3];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
        [e setComputePipelineState:pso_["gAddSums"]];
        [e setBuffer:start_ offset:0 atIndex:0]; [e setBuffer:sumsScanned_ offset:0 atIndex:1];
        [e setBytes:&len length:4 atIndex:2];
        [e dispatchThreadgroups:MTLSizeMake(blocks, 1, 1) threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
    }

    void encodeStep(id<MTLComputeCommandEncoder> e) {
        // grid
        [e setBuffer:cnt_ offset:0 atIndex:0]; [e setBytes:&P_ length:sizeof(P_) atIndex:1];
        run(e, "gClear", size_t(P_.gdim.w) + 1);
        [e setBuffer:buf_["pos"] offset:0 atIndex:0]; [e setBuffer:buf_["flags"] offset:0 atIndex:1];
        [e setBuffer:cellOf_ offset:0 atIndex:2]; [e setBuffer:rank_ offset:0 atIndex:3]; [e setBuffer:cnt_ offset:0 atIndex:4];
        [e setBytes:&P_ length:sizeof(P_) atIndex:5];
        run(e, "gAssign", n_);
        scan(e);
        [e setBuffer:cellOf_ offset:0 atIndex:0]; [e setBuffer:rank_ offset:0 atIndex:1]; [e setBuffer:start_ offset:0 atIndex:2];
        [e setBuffer:sorted_ offset:0 atIndex:3]; [e setBytes:&P_ length:sizeof(P_) atIndex:4];
        run(e, "gScatter", n_);
        static const char* persist[] = {"pos", "vel", "st", "S0", "S1", "aux", "flags", "G0", "G1", "G2"};
        for (int k = 0; k < 10; k++) {
            [e setBuffer:buf_[persist[k]] offset:0 atIndex:k];
            [e setBuffer:buf_[std::string(persist[k]) + "2"] offset:0 atIndex:10 + k];
        }
        [e setBuffer:sorted_ offset:0 atIndex:20]; [e setBytes:&P_ length:sizeof(P_) atIndex:21];
        run(e, "gPermute", n_);
        for (int k = 0; k < 10; k++) std::swap(buf_[persist[k]], buf_[std::string(persist[k]) + "2"]);
        // physics
        dispatchParticles(e, "kEOS", n_);
        dispatchParticles(e, "kRates", n_);
        dispatchParticles(e, "kForces", n_);
        [e setBuffer:state_ offset:0 atIndex:0];
        run(e, "kFinalizeDt", 1);
        dispatchParticles(e, "kIntegrate", n_);
        [e setBuffer:state_ offset:0 atIndex:0]; [e setBytes:&P_ length:sizeof(P_) atIndex:1];
        run(e, "kAdvance", 1);
    }

    SimParams P_;
    size_t n_;
    bool ok_ = false;
    int stepCounter_ = 0;
    id<MTLCommandQueue> queue_;
    std::map<std::string, id<MTLComputePipelineState>> pso_;
    std::map<std::string, id<MTLBuffer>> buf_;
    id<MTLBuffer> cellOf_, rank_, sorted_, cnt_, start_, sums_, sumsScanned_, scratch_, state_, mats_, frame_;
    Device dev_;
};

}  // namespace

std::unique_ptr<Solver> makeMetalSolver(const Geometry3D& g) { return MetalSolver::create(g); }

std::vector<Device> metalDevices() {
    std::vector<Device> out;
    if (id<MTLDevice> d = defaultDevice()) {
        Device x;
        x.backend = Backend::Metal;
        x.name = std::string(d.name.UTF8String) + " (Metal)";
        x.memoryBytes = d.recommendedMaxWorkingSetSize;
        out.push_back(x);
    }
    return out;
}

}  // namespace scl
