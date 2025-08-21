// file: vector_add.cu
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <random>
#include <algorithm>
#include <cmath>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t err__ = (call);                                                 \
    if (err__ != cudaSuccess) {                                                 \
      std::fprintf(stderr, "CUDA error %s at %s:%d\n",                          \
                   cudaGetErrorString(err__), __FILE__, __LINE__);              \
      std::exit(EXIT_FAILURE);                                                  \
    }                                                                           \
  } while (0)

// Grid-stride kernel: y[i] = a[i] + b[i]
__global__ void vecAdd_kernel(const float* __restrict__ a,
                              const float* __restrict__ b,
                              float* __restrict__ y,
                              size_t n) {
  size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  size_t stride = blockDim.x * (size_t)gridDim.x;
  for (size_t i = idx; i < n; i += stride) {
    y[i] = a[i] + b[i];
  }
}

int main(int argc, char** argv) {
  // problem size (default 1<<24)
  size_t N = (argc > 1) ? static_cast<size_t>(atoll(argv[1])) : (1ull << 24);
  std::printf("N = %zu\n", N);

  // host init
  std::vector<float> hA(N), hB(N), hY(N), hRef(N);
  std::mt19937 rng(123);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for (size_t i = 0; i < N; ++i) {
    hA[i] = dist(rng);
    hB[i] = dist(rng);
    hRef[i] = hA[i] + hB[i];
  }

  // device alloc
  float *dA = nullptr, *dB = nullptr, *dY = nullptr;
  CUDA_CHECK(cudaMalloc(&dA, N * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&dB, N * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&dY, N * sizeof(float)));

  // H2D
  CUDA_CHECK(cudaMemcpy(dA, hA.data(), N * sizeof(float), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(dB, hB.data(), N * sizeof(float), cudaMemcpyHostToDevice));

  // launch
  int block = 256;
  int maxBlocks;
  CUDA_CHECK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
      &maxBlocks, vecAdd_kernel, block, 0));
  cudaDeviceProp prop{};
  CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
  int grid = std::min<int>(prop.multiProcessorCount * maxBlocks, (int)((N + block - 1) / block));
  grid = std::max(grid, 1);  // ensure at least 1 block

  vecAdd_kernel<<<grid, block>>>(dA, dB, dY, N);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  // D2H
  CUDA_CHECK(cudaMemcpy(hY.data(), dY, N * sizeof(float), cudaMemcpyDeviceToHost));

  // check
  double max_abs_err = 0.0;
  for (size_t i = 0; i < N; ++i) {
    max_abs_err = std::max(max_abs_err, (double)std::abs(hY[i] - hRef[i]));
  }
  std::printf("Max |error| = %.3e\n", max_abs_err);

  // cleanup
  CUDA_CHECK(cudaFree(dA));
  CUDA_CHECK(cudaFree(dB));
  CUDA_CHECK(cudaFree(dY));

  if (max_abs_err > 1e-6) {
    std::fprintf(stderr, "Validation failed.\n");
    return EXIT_FAILURE;
  }
  std::puts("OK");
  return EXIT_SUCCESS;
}
