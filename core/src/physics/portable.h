// Portability layer: lets the physics in sph.h compile unchanged as Metal Shading Language,
// HIP (CUDA/ROCm) device code, and plain C++ for the CPU backend.
#pragma once

#if defined(__METAL_VERSION__)
  #include <metal_stdlib>
  #define SCL_FN inline
  #define SCL_HD inline
  #define SCL_DEV device
  #define SCL_CONST constant
  typedef uint u32;
  #define scl_sqrt metal::sqrt
  #define scl_exp metal::exp
  #define scl_pow metal::pow
  #define scl_floor metal::floor
  #define scl_fabs metal::fabs
  #define scl_fmin metal::fmin
  #define scl_fmax metal::fmax
  #define scl_log2 metal::log2
  #define SCL_ATOMIC_U32 metal::atomic_uint
  SCL_FN u32 scl_atomic_add(SCL_DEV SCL_ATOMIC_U32* a, u32 v) { return metal::atomic_fetch_add_explicit(a, v, metal::memory_order_relaxed); }
  SCL_FN void scl_atomic_min(SCL_DEV SCL_ATOMIC_U32* a, u32 v) { metal::atomic_fetch_min_explicit(a, v, metal::memory_order_relaxed); }
  SCL_FN void scl_atomic_max(SCL_DEV SCL_ATOMIC_U32* a, u32 v) { metal::atomic_fetch_max_explicit(a, v, metal::memory_order_relaxed); }
  SCL_FN u32 scl_atomic_load(SCL_DEV SCL_ATOMIC_U32* a) { return metal::atomic_load_explicit(a, metal::memory_order_relaxed); }
  SCL_FN float scl_as_float(u32 u) { return as_type<float>(u); }
  SCL_FN u32 scl_as_uint(float f) { return as_type<u32>(f); }
#elif defined(__HIPCC__) || defined(__CUDACC__)
  #if defined(__HIPCC__)
    #include <hip/hip_runtime.h>
  #endif
  #define SCL_FN __device__ __forceinline__
  #define SCL_HD __host__ __device__ __forceinline__
  #define SCL_DEV
  #define SCL_CONST
  typedef unsigned int u32;
  #define scl_sqrt sqrtf
  #define scl_exp expf
  #define scl_pow powf
  #define scl_floor floorf
  #define scl_fabs fabsf
  #define scl_fmin fminf
  #define scl_fmax fmaxf
  #define scl_log2 log2f
  #define SCL_ATOMIC_U32 unsigned int
  SCL_FN u32 scl_atomic_add(u32* a, u32 v) { return atomicAdd(a, v); }
  SCL_FN void scl_atomic_min(u32* a, u32 v) { atomicMin(a, v); }
  SCL_FN void scl_atomic_max(u32* a, u32 v) { atomicMax(a, v); }
  SCL_FN u32 scl_atomic_load(u32* a) { return *(volatile u32*)a; }
  SCL_FN float scl_as_float(u32 u) { return __uint_as_float(u); }
  SCL_FN u32 scl_as_uint(float f) { return __float_as_uint(f); }
#else
  #include <atomic>
  #include <cmath>
  #include <cstdint>
  #include <cstring>
  #define SCL_FN inline
  #define SCL_HD inline
  #define SCL_DEV
  #define SCL_CONST
  typedef uint32_t u32;
  #define scl_sqrt std::sqrt
  #define scl_exp std::exp
  #define scl_pow std::pow
  #define scl_floor std::floor
  #define scl_fabs std::fabs
  #define scl_fmin std::fmin
  #define scl_fmax std::fmax
  #define scl_log2 std::log2
  #define SCL_ATOMIC_U32 u32
  #if defined(_MSC_VER)
  SCL_FN u32 scl_atomic_add(u32* a, u32 v) { return std::atomic_ref<u32>(*a).fetch_add(v, std::memory_order_relaxed); }
  SCL_FN u32 scl_atomic_load(u32* a) { return std::atomic_ref<u32>(*a).load(std::memory_order_relaxed); }
  SCL_FN bool scl_cas(u32* a, u32& expected, u32 v) { return std::atomic_ref<u32>(*a).compare_exchange_weak(expected, v, std::memory_order_relaxed); }
  #else
  SCL_FN u32 scl_atomic_add(u32* a, u32 v) { return __atomic_fetch_add(a, v, __ATOMIC_RELAXED); }
  SCL_FN u32 scl_atomic_load(u32* a) { return __atomic_load_n(a, __ATOMIC_RELAXED); }
  SCL_FN bool scl_cas(u32* a, u32& expected, u32 v) { return __atomic_compare_exchange_n(a, &expected, v, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED); }
  #endif
  SCL_FN void scl_atomic_min(u32* a, u32 v) { u32 c = scl_atomic_load(a); while (v < c && !scl_cas(a, c, v)) {} }
  SCL_FN void scl_atomic_max(u32* a, u32 v) { u32 c = scl_atomic_load(a); while (v > c && !scl_cas(a, c, v)) {} }
  SCL_FN float scl_as_float(u32 u) { float f; std::memcpy(&f, &u, 4); return f; }
  SCL_FN u32 scl_as_uint(float f) { u32 u; std::memcpy(&u, &f, 4); return u; }
#endif

// ---- small vector types with the same layout everywhere (16-byte v4 in buffers)
struct v3 { float x, y, z; };
struct alignas(16) v4 { float x, y, z, w; };
struct alignas(16) u4 { u32 x, y, z, w; };

SCL_HD v3 mk3(float x, float y, float z) { v3 r; r.x = x; r.y = y; r.z = z; return r; }
SCL_HD v4 mk4(float x, float y, float z, float w) { v4 r; r.x = x; r.y = y; r.z = z; r.w = w; return r; }
SCL_HD v4 mk4(v3 a, float w) { return mk4(a.x, a.y, a.z, w); }
SCL_HD v3 xyz(v4 a) { return mk3(a.x, a.y, a.z); }
SCL_HD v3 operator+(v3 a, v3 b) { return mk3(a.x + b.x, a.y + b.y, a.z + b.z); }
SCL_HD v3 operator-(v3 a, v3 b) { return mk3(a.x - b.x, a.y - b.y, a.z - b.z); }
SCL_HD v3 operator*(v3 a, float s) { return mk3(a.x * s, a.y * s, a.z * s); }
SCL_HD v3 operator*(float s, v3 a) { return mk3(a.x * s, a.y * s, a.z * s); }
SCL_HD float dot3(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
SCL_HD float len3(v3 a) { return scl_sqrt(dot3(a, a)); }
SCL_HD v3 norm3(v3 a) { float l = len3(a); return l > 0 ? a * (1.0f / l) : mk3(0, 0, 1); }

// symmetric / general 3×3 as three rows
struct m3 { v3 r0, r1, r2; };
SCL_HD v3 mulv(m3 m, v3 v) { return mk3(dot3(m.r0, v), dot3(m.r1, v), dot3(m.r2, v)); }
