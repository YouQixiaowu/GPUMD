/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


#include "sw.cuh"
#include "mic.cuh"
#include "measure.cuh"
#include "atom.cuh"
#include "error.cuh"

#define BLOCK_SIZE_SW 64 // 128 is also good


/*----------------------------------------------------------------------------80
This file implements the Stillinger-Weber (SW) potential.
[1] Frank H. Stillinger and Thomas A. Weber,
    Computer simulation of local order in condensed phases of silicon,
    Phys. Rev. B 31, 5262 (1985).
    The implementation supports up to three atom types.
------------------------------------------------------------------------------*/


SW2::SW2(FILE *fid, Atom* atom, int num_of_types)
{
    if (num_of_types == 1) { initialize_sw_1985_1(fid); }
    if (num_of_types == 2) { initialize_sw_1985_2(fid); }
    if (num_of_types == 3) { initialize_sw_1985_3(fid); }

    // memory for the partial forces dU_i/dr_ij
    int num_of_neighbors = (atom->neighbor.MN < 50) ? atom->neighbor.MN : 50;
    int memory = sizeof(double) * atom->N * num_of_neighbors;
    CHECK(cudaMalloc((void**)&sw2_data.f12x, memory));
    CHECK(cudaMalloc((void**)&sw2_data.f12y, memory));
    CHECK(cudaMalloc((void**)&sw2_data.f12z, memory));
}


void SW2::initialize_sw_1985_1(FILE *fid)
{
    printf("Use single-element Stillinger-Weber potential.\n");
    int count;
    double epsilon, lambda, A, B, a, gamma, sigma, cos0;
    count = fscanf
    (
        fid, "%lf%lf%lf%lf%lf%lf%lf%lf",
        &epsilon, &lambda, &A, &B, &a, &gamma, &sigma, &cos0
    );
    PRINT_SCANF_ERROR(count, 8, "Reading error for SW potential.");

    sw2_para.A[0][0] = epsilon * A;
    sw2_para.B[0][0] = B;
    sw2_para.a[0][0] = a;
    sw2_para.sigma[0][0] = sigma;
    sw2_para.gamma[0][0] = gamma;
    sw2_para.rc[0][0] = sigma * a;
    rc = sw2_para.rc[0][0];
    sw2_para.lambda[0][0][0] = epsilon * lambda;
    sw2_para.cos0[0][0][0] = cos0;
}


void SW2::initialize_sw_1985_2(FILE *fid)
{
    printf("Use two-element Stillinger-Weber potential.\n");
    int count;

    // 2-body parameters and the force cutoff
    double A[3], B[3], a[3], sigma[3], gamma[3];
    rc = 0.0;
    for (int n = 0; n < 3; n++)
    {
        count = fscanf
        (fid, "%lf%lf%lf%lf%lf", &A[n], &B[n], &a[n], &sigma[n], &gamma[n]);
        PRINT_SCANF_ERROR(count, 5, "Reading error for SW potential.");
    }
    for (int n1 = 0; n1 < 2; n1++)
    for (int n2 = 0; n2 < 2; n2++)
    {
        sw2_para.A[n1][n2] = A[n1+n2];
        sw2_para.B[n1][n2] = B[n1+n2];
        sw2_para.a[n1][n2] = a[n1+n2];
        sw2_para.sigma[n1][n2] = sigma[n1+n2];
        sw2_para.gamma[n1][n2] = gamma[n1+n2];
        sw2_para.rc[n1][n2] = sigma[n1+n2] * a[n1+n2];
        if (rc < sw2_para.rc[n1][n2]) rc = sw2_para.rc[n1][n2];
    }

    // 3-body parameters
    double lambda, cos0;
    for (int n1 = 0; n1 < 2; n1++)
    for (int n2 = 0; n2 < 2; n2++)
    for (int n3 = 0; n3 < 2; n3++)
    {
        count = fscanf(fid, "%lf%lf", &lambda, &cos0);
        PRINT_SCANF_ERROR(count, 2, "Reading error for SW potential.");
        sw2_para.lambda[n1][n2][n3] = lambda;
        sw2_para.cos0[n1][n2][n3] = cos0;
    }
}


void SW2::initialize_sw_1985_3(FILE *fid)
{
    printf("Use three-element Stillinger-Weber potential.\n");
    int count;

    // 2-body parameters and the force cutoff
    double A, B, a, sigma, gamma;
    rc = 0.0;
    for (int n1 = 0; n1 < 3; n1++)
    for (int n2 = 0; n2 < 3; n2++)
    {
        count = fscanf(fid, "%lf%lf%lf%lf%lf", &A, &B, &a, &sigma, &gamma);
        PRINT_SCANF_ERROR(count, 5, "Reading error for SW potential.");
        sw2_para.A[n1][n2] = A;
        sw2_para.B[n1][n2] = B;
        sw2_para.a[n1][n2] = a;
        sw2_para.sigma[n1][n2] = sigma;
        sw2_para.gamma[n1][n2] = gamma;
        sw2_para.rc[n1][n2] = sigma * a;
        if (rc < sw2_para.rc[n1][n2]) rc = sw2_para.rc[n1][n2];
    }

    // 3-body parameters
    double lambda, cos0;
    for (int n1 = 0; n1 < 3; n1++)
    for (int n2 = 0; n2 < 3; n2++)
    for (int n3 = 0; n3 < 3; n3++)
    {
        count = fscanf(fid, "%lf%lf", &lambda, &cos0);
        PRINT_SCANF_ERROR(count, 2, "Reading error for SW potential.");
        sw2_para.lambda[n1][n2][n3] = lambda;
        sw2_para.cos0[n1][n2][n3] = cos0;
    }
}


SW2::~SW2(void)
{
    CHECK(cudaFree(sw2_data.f12x));
    CHECK(cudaFree(sw2_data.f12y));
    CHECK(cudaFree(sw2_data.f12z));
}


// two-body part of the SW potential
static __device__ void find_p2_and_f2
(double sigma, double a, double B, double epsilon_times_A, double d12, double &p2, double &f2)
{ 
    double r12 = d12 / sigma;
    double B_over_r12power4 = B / (r12*r12*r12*r12);
    double exp_factor = epsilon_times_A * exp(ONE/(r12 - a));
    p2 = exp_factor * (B_over_r12power4 - ONE);
    f2 = -p2/((r12-a)*(r12-a))-exp_factor*FOUR*B_over_r12power4/r12;
    f2 /= (sigma * d12);
}


// find the partial forces dU_i/dr_ij
static __global__ void gpu_find_force_sw3_partial
(
    int number_of_particles, int N1, int N2,
    Box box, SW2_Para sw3,
    int *g_neighbor_number, int *g_neighbor_list, int *g_type, int shift,
    const double* __restrict__ g_x,
    const double* __restrict__ g_y,
    const double* __restrict__ g_z,
    double *g_potential, double *g_f12x, double *g_f12y, double *g_f12z
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_neighbor_number[n1];
        int type1 = g_type[n1] - shift;
        double x1 = LDG(g_x, n1); double y1 = LDG(g_y, n1); double z1 = LDG(g_z, n1);
        double potential_energy = ZERO;

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {
            int index = i1 * number_of_particles + n1;
            int n2 = g_neighbor_list[index];
            int type2 = g_type[n2] - shift;
            double x12  = LDG(g_x, n2) - x1;
            double y12  = LDG(g_y, n2) - y1;
            double z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(box, x12, y12, z12);
            double d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
            double d12inv = ONE / d12;
            if (d12 >= sw3.rc[type1][type2]) {continue;} 

            double gamma12 = sw3.gamma[type1][type2];
            double sigma12 = sw3.sigma[type1][type2];
            double a12     = sw3.a[type1][type2];
            double tmp = gamma12 / (sigma12*(d12/sigma12-a12)*(d12/sigma12-a12));
            double p2, f2;
            find_p2_and_f2
            (
                sigma12, a12, sw3.B[type1][type2], sw3.A[type1][type2],
                d12, p2, f2
            );

            // treat the two-body part in the same way as the many-body part
            double f12x = f2 * x12 * HALF;
            double f12y = f2 * y12 * HALF;
            double f12z = f2 * z12 * HALF;
            // accumulate potential energy
            potential_energy += p2 * HALF;

            // three-body part
            for (int i2 = 0; i2 < neighbor_number; ++i2)
            {
                int n3 = g_neighbor_list[n1 + number_of_particles * i2];
                if (n3 == n2) { continue; }
                int type3 = g_type[n3] - shift;
                double x13 = LDG(g_x, n3) - x1;
                double y13 = LDG(g_y, n3) - y1;
                double z13 = LDG(g_z, n3) - z1;
                dev_apply_mic(box, x13, y13, z13);
                double d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
                if (d13 >= sw3.rc[type1][type3]) {continue;}

                double cos0   = sw3.cos0[type1][type2][type3];
                double lambda = sw3.lambda[type1][type2][type3];
                double exp123 = d13/sw3.sigma[type1][type3] - sw3.a[type1][type3];
                exp123 = sw3.gamma[type1][type3] / exp123;
                exp123 = exp(gamma12 / (d12 / sigma12 - a12) + exp123);
                double one_over_d12d13 = ONE / (d12 * d13);
                double cos123 = (x12*x13 + y12*y13 + z12*z13) * one_over_d12d13;
                double cos123_over_d12d12 = cos123*d12inv*d12inv;

                double tmp1 = exp123 * (cos123 - cos0) * lambda;
                double tmp2 = tmp * (cos123 - cos0) * d12inv;

                // accumulate potential energy
                potential_energy += (cos123 - cos0) * tmp1 * HALF;

                double cos_d = x13 * one_over_d12d13 - x12 * cos123_over_d12d12; 
                f12x += tmp1 * (TWO * cos_d - tmp2 * x12);

                cos_d = y13 * one_over_d12d13 - y12 * cos123_over_d12d12;
                f12y += tmp1 * (TWO * cos_d - tmp2 * y12);

                cos_d = z13 * one_over_d12d13 - z12 * cos123_over_d12d12;
                f12z += tmp1 * (TWO * cos_d - tmp2 * z12);
            }
            g_f12x[index] = f12x; g_f12y[index] = f12y; g_f12z[index] = f12z;
        }
        // save potential
        g_potential[n1] = potential_energy;
    }
}


static __global__ void gpu_set_f12_to_zero
(int N, int N1, int N2, int *g_NN, double* g_f12x, double* g_f12y, double* g_f12z)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_NN[n1];
        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {
            int index = i1 * N + n1;
            g_f12x[index] = ZERO;
            g_f12y[index] = ZERO;
            g_f12z[index] = ZERO;
        }
    }
}


// Find force and related quantities for the SW potential (A wrapper)
void SW2::compute(Atom *atom, Measure *measure, int potential_number)
{
    int N = atom->N;
    int shift = atom->shift[potential_number];
    int grid_size = (N2 - N1 - 1) / BLOCK_SIZE_SW + 1;
    int *NN = atom->NN_local;
    int *NL = atom->NL_local;
    int *type = atom->type;
    double *x = atom->x;
    double *y = atom->y;
    double *z = atom->z;
    double *pe = atom->potential_per_atom;

    // special data for SW potential
    double *f12x = sw2_data.f12x;
    double *f12y = sw2_data.f12y;
    double *f12z = sw2_data.f12z;
    gpu_set_f12_to_zero<<<grid_size, BLOCK_SIZE_SW>>>
    (N, N1, N2, NN, f12x, f12y, f12z);
    CUDA_CHECK_KERNEL

    // step 1: calculate the partial forces
    gpu_find_force_sw3_partial<<<grid_size, BLOCK_SIZE_SW>>>
    (
        N, N1, N2, atom->box, sw2_para, NN, NL,
        type, shift, x, y, z, pe, f12x, f12y, f12z
    );
    CUDA_CHECK_KERNEL

    // step 2: calculate force and related quantities
    find_properties_many_body(atom, NN, NL, f12x, f12y, f12z);
}


