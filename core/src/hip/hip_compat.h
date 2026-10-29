// Lets hip_solver.hip build either with HIP (AMD ROCm / HIP SDK, or NVIDIA via HIP) or as plain CUDA.
#pragma once

#if defined(__HIPCC__) || defined(SCL_USE_HIP_RUNTIME)
  #include <hip/hip_runtime.h>
#else
  #include <cuda_runtime.h>
  #define hipError_t cudaError_t
  #define hipSuccess cudaSuccess
  #define hipMalloc cudaMalloc
  #define hipFree cudaFree
  #define hipMemcpy cudaMemcpy
  #define hipMemset cudaMemset
  #define hipMemcpyHostToDevice cudaMemcpyHostToDevice
  #define hipMemcpyDeviceToHost cudaMemcpyDeviceToHost
  #define hipMemcpyDeviceToDevice cudaMemcpyDeviceToDevice
  #define hipDeviceSynchronize cudaDeviceSynchronize
  #define hipGetDeviceCount cudaGetDeviceCount
  #define hipGetDeviceProperties cudaGetDeviceProperties
  #define hipDeviceProp_t cudaDeviceProp
  #define hipSetDevice cudaSetDevice
  #define hipGetErrorString cudaGetErrorString
  #define hipGetLastError cudaGetLastError
  #define hipEvent_t cudaEvent_t
  #define hipEventCreate cudaEventCreate
  #define hipEventDestroy cudaEventDestroy
  #define hipEventRecord cudaEventRecord
  #define hipEventSynchronize cudaEventSynchronize
  #define hipEventElapsedTime cudaEventElapsedTime
#endif
