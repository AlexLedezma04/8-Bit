#include <cstdio>

// Adds two vectors.
__global__ void add(const float *a, const float *b, float *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i]; /* one each */
}

int main() {
    add<<<1, 256>>>(nullptr, nullptr, nullptr, 0);
    printf("done\n");
}
