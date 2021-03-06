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

/*----------------------------------------------------------------------------80
Green-Kubo Modal Analysis (GKMA) and
Homogenous Nonequilibrium Modal Analysis (HNEMA) implementations.

Original GMKA method is detailed in:
H.R. Seyf, K. Gordiz, F. DeAngelis, and A. Henry, "Using Green-Kubo modal
analysis (GKMA) and interface conductance modal analysis (ICMA) to study
phonon transport with molecular dynamics," J. Appl. Phys., 125, 081101 (2019).

The code here is inspired by the LAMMPS implementation provided by the Henry
group at MIT. This code can be found:
https://drive.google.com/open?id=1IHJ7x-bLZISX3I090dW_Y_y-Mqkn07zg

GPUMD Contributing author: Alexander Gabourie (Stanford University)
------------------------------------------------------------------------------*/

#include "modal_analysis.cuh"
#include "error.cuh"
#include <fstream>
#include <string>
#include <iostream>
#include <sstream>


#define NUM_OF_HEAT_COMPONENTS 5
#define BLOCK_SIZE 128
#define ACCUM_BLOCK 1024
#define BIN_BLOCK 128
#define BLOCK_SIZE_FORCE 64
#define BLOCK_SIZE_GK 16


static __global__ void gpu_reset_data
(
        int num_elements, float* data
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n < num_elements)
    {
        data[n] = 0.0f;
    }
}

static __global__ void gpu_scale_jm
(
        int num_elements, float factor, float* jm
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n < num_elements)
    {
        jm[n]*=factor;
    }
}


static __global__ void gpu_reduce_xdotn
(
        int num_participating, int num_modes,
        const float* __restrict__ data_n,
        float* data
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (num_participating - 1) / ACCUM_BLOCK + 1;

    __shared__ float s_data_x[ACCUM_BLOCK];
    __shared__ float s_data_y[ACCUM_BLOCK];
    __shared__ float s_data_z[ACCUM_BLOCK];
    s_data_x[tid] = 0.0f;
    s_data_y[tid] = 0.0f;
    s_data_z[tid] = 0.0f;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * ACCUM_BLOCK;
        if (n < num_participating)
        {
            s_data_x[tid] += data_n[n + bid*num_participating ];
            s_data_y[tid] += data_n[n + (bid + num_modes)*num_participating];
            s_data_z[tid] += data_n[n + (bid + 2*num_modes)*num_participating];
        }
    }

    __syncthreads();
    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_data_x[tid] += s_data_x[tid + offset];
            s_data_y[tid] += s_data_y[tid + offset];
            s_data_z[tid] += s_data_z[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0)
    {
        data[bid] = s_data_x[0];
        data[bid + num_modes] = s_data_y[0];
        data[bid + 2*num_modes] = s_data_z[0];
    }

}

static __global__ void gpu_calc_xdotn
(
        int num_participating, int N1, int N2, int num_modes,
        const double* __restrict__ g_vx,
        const double* __restrict__ g_vy,
        const double* __restrict__ g_vz,
        const double* __restrict__ g_mass,
        const float* __restrict__ g_eig,
        float* g_xdotn
)
{
    int neig = blockIdx.x * blockDim.x + threadIdx.x;
    int nglobal = neig + N1;
    int nm = blockIdx.y * blockDim.y + threadIdx.y;

    if (nglobal >= N1 && nglobal < N2 && nm < num_modes)
    {

        float vx1, vy1, vz1;
        vx1 = __double2float_rn(LDG(g_vx, nglobal));
        vy1 = __double2float_rn(LDG(g_vy, nglobal));
        vz1 = __double2float_rn(LDG(g_vz, nglobal));

        float sqrtmass = sqrt(__double2float_rn(LDG(g_mass, nglobal)));
        g_xdotn[neig + nm*num_participating] =
                sqrtmass*g_eig[neig + nm*3*num_participating]*vx1;
        g_xdotn[neig + (nm + num_modes)*num_participating] =
                sqrtmass*g_eig[neig + (1 + nm*3)*num_participating]*vy1;
        g_xdotn[neig + (nm + 2*num_modes)*num_participating] =
                sqrtmass*g_eig[neig + (2 + nm*3)*num_participating]*vz1;
    }
}


static __device__ void gpu_bin_reduce
(
       int num_modes, int bin_size, int shift, int num_bins,
       int tid, int bid, int number_of_patches,
       const float* __restrict__ g_jm,
       float* bin_out
)
{
    __shared__ float s_data_xin[BIN_BLOCK];
    __shared__ float s_data_xout[BIN_BLOCK];
    __shared__ float s_data_yin[BIN_BLOCK];
    __shared__ float s_data_yout[BIN_BLOCK];
    __shared__ float s_data_z[BIN_BLOCK];
    s_data_xin[tid] = 0.0f;
    s_data_xout[tid] = 0.0f;
    s_data_yin[tid] = 0.0f;
    s_data_yout[tid] = 0.0f;
    s_data_z[tid] = 0.0f;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * BIN_BLOCK;
        if (n < bin_size)
        {
            s_data_xin[tid] += g_jm[n + shift];
            s_data_xout[tid] += g_jm[n + shift + num_modes];
            s_data_yin[tid] += g_jm[n + shift + 2*num_modes];
            s_data_yout[tid] += g_jm[n + shift + 3*num_modes];
            s_data_z[tid] += g_jm[n + shift + 4*num_modes];
        }
    }

    __syncthreads();
    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_data_xin[tid] += s_data_xin[tid + offset];
            s_data_xout[tid] += s_data_xout[tid + offset];
            s_data_yin[tid] += s_data_yin[tid + offset];
            s_data_yout[tid] += s_data_yout[tid + offset];
            s_data_z[tid] += s_data_z[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0)
    {
        bin_out[bid] = s_data_xin[0];
        bin_out[bid + num_bins] = s_data_xout[0];
        bin_out[bid + 2*num_bins] = s_data_yin[0];
        bin_out[bid + 3*num_bins] = s_data_yout[0];
        bin_out[bid + 4*num_bins] = s_data_z[0];
    }
}


static __global__ void gpu_bin_modes
(
       int num_modes, int bin_size, int num_bins,
       const float* __restrict__ g_jm,
       float* bin_out
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (bin_size - 1) / BIN_BLOCK + 1;
    int shift = bid*bin_size;

    gpu_bin_reduce
    (
           num_modes, bin_size, shift, num_bins,
           tid, bid, number_of_patches, g_jm, bin_out
    );

}

static __global__ void gpu_bin_frequencies
(
       int num_modes,
       const int* __restrict__ bin_count,
       const int* __restrict__ bin_sum,
       int num_bins,
       const float* __restrict__ g_jm,
       float* bin_out
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int bin_size = bin_count[bid];
    int shift = bin_sum[bid];
    int number_of_patches = (bin_size - 1) / BIN_BLOCK + 1;

    gpu_bin_reduce
    (
           num_modes, bin_size, shift, num_bins,
           tid, bid, number_of_patches, g_jm, bin_out
    );

}


static __global__ void gpu_set_jmn
(
    int num_participating, int N1, int N2,
    const double* __restrict__ sxx,
    const double* __restrict__ sxy,
    const double* __restrict__ sxz,
    const double* __restrict__ syx,
    const double* __restrict__ syy,
    const double* __restrict__ syz,
    const double* __restrict__ szx,
    const double* __restrict__ szy,
    const double* __restrict__ szz,
    const double* __restrict__ g_mass,
    const float* __restrict__ g_eig,
    const float* __restrict__ g_xdot,
    float* g_jmn,
    int num_modes
)
{
    int neig = blockIdx.x * blockDim.x + threadIdx.x;
    int nglobal = neig + N1;
    int nm = blockIdx.y * blockDim.y + threadIdx.y;

    if (nglobal >= N1 && nglobal < N2 && nm < num_modes)
    {
        float vx_ma, vy_ma, vz_ma;
        float rsqrtmass = rsqrt(__double2float_rn(LDG(g_mass, nglobal)));

        vx_ma=rsqrtmass*g_eig[neig + nm*3*num_participating]
                              *__double2float_rn(g_xdot[nm]);
        vy_ma=rsqrtmass*g_eig[neig + (1 + nm*3)*num_participating]
                              *__double2float_rn(g_xdot[nm + num_modes]);
        vz_ma=rsqrtmass*g_eig[neig + (2 + nm*3)*num_participating]
                              *__double2float_rn(g_xdot[nm + 2*num_modes]);

        g_jmn[neig + nm*num_participating] =
                __double2float_rn(sxx[nglobal]) * vx_ma +
                __double2float_rn(sxy[nglobal]) * vy_ma; // x-in
        g_jmn[neig + (nm+num_modes)*num_participating] =
                __double2float_rn(sxz[nglobal]) * vz_ma; // x-out

        g_jmn[neig + (nm+2*num_modes)*num_participating] =
                __double2float_rn(syx[nglobal]) * vx_ma +
                __double2float_rn(syy[nglobal]) * vy_ma; // y-in
        g_jmn[neig + (nm+3*num_modes)*num_participating] =
                __double2float_rn(syz[nglobal]) * vz_ma; // y-out

        g_jmn[neig + (nm+4*num_modes)*num_participating] =
                __double2float_rn(szx[nglobal]) * vx_ma +
                __double2float_rn(szy[nglobal]) * vy_ma +
                __double2float_rn(szz[nglobal]) * vz_ma; // z-all

    }
}


static __global__ void gpu_accumulate_jmn
(
    int num_participating, int N1, int N2,
    const double* __restrict__ sxx,
    const double* __restrict__ sxy,
    const double* __restrict__ sxz,
    const double* __restrict__ syx,
    const double* __restrict__ syy,
    const double* __restrict__ syz,
    const double* __restrict__ szx,
    const double* __restrict__ szy,
    const double* __restrict__ szz,
    const double* __restrict__ g_mass,
    const float* __restrict__ g_eig,
    const float* __restrict__ g_xdot,
    float* g_jmn,
    int num_modes
)
{
    int neig = blockIdx.x * blockDim.x + threadIdx.x;
    int nglobal = neig + N1;
    int nm = blockIdx.y * blockDim.y + threadIdx.y;

    if (nglobal >= N1 && nglobal < N2 && nm < num_modes)
    {
        float vx_ma, vy_ma, vz_ma;
        float rsqrtmass = rsqrt(__double2float_rn(LDG(g_mass, nglobal)));

        vx_ma=rsqrtmass*g_eig[neig + nm*3*num_participating]
                              *__double2float_rn(g_xdot[nm]);
        vy_ma=rsqrtmass*g_eig[neig + (1 + nm*3)*num_participating]
                              *__double2float_rn(g_xdot[nm + num_modes]);
        vz_ma=rsqrtmass*g_eig[neig + (2 + nm*3)*num_participating]
                              *__double2float_rn(g_xdot[nm + 2*num_modes]);

        g_jmn[neig + nm*num_participating] +=
                __double2float_rn(sxx[nglobal]) * vx_ma +
                __double2float_rn(sxy[nglobal]) * vy_ma; // x-in
        g_jmn[neig + (nm+num_modes)*num_participating] +=
                __double2float_rn(sxz[nglobal]) * vz_ma; // x-out

        g_jmn[neig + (nm+2*num_modes)*num_participating] +=
                __double2float_rn(syx[nglobal]) * vx_ma +
                __double2float_rn(syy[nglobal]) * vy_ma; // y-in
        g_jmn[neig + (nm+3*num_modes)*num_participating] +=
                __double2float_rn(syz[nglobal]) * vz_ma; // y-out

        g_jmn[neig + (nm+4*num_modes)*num_participating] +=
                __double2float_rn(szx[nglobal]) * vx_ma +
                __double2float_rn(szy[nglobal]) * vy_ma +
                __double2float_rn(szz[nglobal]) * vz_ma; // z-all

    }
}

static __global__ void gpu_reduce_jmn
(
        int num_participating, int num_modes,
        const float* __restrict__ data_n,
        float* data
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (num_participating - 1) / ACCUM_BLOCK + 1;

    __shared__ float s_data_xin[ACCUM_BLOCK];
    __shared__ float s_data_xout[ACCUM_BLOCK];
    __shared__ float s_data_yin[ACCUM_BLOCK];
    __shared__ float s_data_yout[ACCUM_BLOCK];
    __shared__ float s_data_z[ACCUM_BLOCK];
    s_data_xin[tid] = 0.0f;
    s_data_xout[tid] = 0.0f;
    s_data_yin[tid] = 0.0f;
    s_data_yout[tid] = 0.0f;
    s_data_z[tid] = 0.0f;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * ACCUM_BLOCK;
        if (n < num_participating)
        {
            s_data_xin[tid] +=
                    data_n[n + bid*num_participating ];
            s_data_xout[tid] +=
                    data_n[n + (bid + num_modes)*num_participating];
            s_data_yin[tid] +=
                    data_n[n + (bid + 2*num_modes)*num_participating];
            s_data_yout[tid] +=
                    data_n[n + (bid + 3*num_modes)*num_participating];
            s_data_z[tid] +=
                    data_n[n + (bid + 4*num_modes)*num_participating];
        }
    }

    __syncthreads();
    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_data_xin[tid] += s_data_xin[tid + offset];
            s_data_xout[tid] += s_data_xout[tid + offset];
            s_data_yin[tid] += s_data_yin[tid + offset];
            s_data_yout[tid] += s_data_yout[tid + offset];
            s_data_z[tid] += s_data_z[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0)
    {
        data[bid] = s_data_xin[0];
        data[bid + num_modes] = s_data_xout[0];
        data[bid + 2*num_modes] = s_data_yin[0];
        data[bid + 3*num_modes] = s_data_yout[0];
        data[bid + 4*num_modes] = s_data_z[0];
    }

}


void MODAL_ANALYSIS::compute_heat(Atom *atom)
{
    dim3 grid, block;
    int gk_grid_size = (num_modes - 1)/BLOCK_SIZE_GK + 1;
    int grid_size = (N2 - N1 - 1) / BLOCK_SIZE_FORCE + 1;
    block.x = BLOCK_SIZE_FORCE; grid.x = grid_size;
    block.y = BLOCK_SIZE_GK;    grid.y = gk_grid_size;
    block.z = 1;                grid.z = 1;
    gpu_calc_xdotn<<<grid, block>>>
    (
        num_participating, N1, N2, num_modes,
        atom->vx, atom->vy, atom->vz,
        atom->mass, eig, xdotn
    );
    CUDA_CHECK_KERNEL

    gpu_reduce_xdotn<<<num_modes, ACCUM_BLOCK>>>
    (
        num_participating, num_modes, xdotn, xdot
    );
    CUDA_CHECK_KERNEL

    if (method == GKMA_METHOD)
    {
        gpu_set_jmn<<<grid, block>>>
        (
            num_participating, N1, N2,
            atom->virial_per_atom,
            atom->virial_per_atom + atom->N * 3,
            atom->virial_per_atom + atom->N * 4,
            atom->virial_per_atom + atom->N * 6,
            atom->virial_per_atom + atom->N * 1,
            atom->virial_per_atom + atom->N * 5,
            atom->virial_per_atom + atom->N * 7,
            atom->virial_per_atom + atom->N * 8,
            atom->virial_per_atom + atom->N * 2,
            atom->mass, eig, xdot, jmn, num_modes
        );
    }
    else if (method == HNEMA_METHOD)
    {
        gpu_accumulate_jmn<<<grid, block>>>
        (
            num_participating, N1, N2,
            atom->virial_per_atom,
            atom->virial_per_atom + atom->N * 3,
            atom->virial_per_atom + atom->N * 4,
            atom->virial_per_atom + atom->N * 6,
            atom->virial_per_atom + atom->N * 1,
            atom->virial_per_atom + atom->N * 5,
            atom->virial_per_atom + atom->N * 7,
            atom->virial_per_atom + atom->N * 8,
            atom->virial_per_atom + atom->N * 2,
            atom->mass, eig, xdot, jmn, num_modes
        );
    }
    CUDA_CHECK_KERNEL
}


void MODAL_ANALYSIS::setN(Atom *atom)
{
    N1 = 0;
    N2 = 0;
    for (int n = 0; n < atom_begin; ++n)
    {
        N1 += atom->cpu_type_size[n];
    }
    for (int n = atom_begin; n <= atom_end; ++n)
    {
        N2 += atom->cpu_type_size[n];
    }

    num_participating = N2 - N1;
}

void MODAL_ANALYSIS::preprocess(char *input_dir, Atom *atom)
{
    if (!compute) return;
        num_modes = last_mode-first_mode+1;
        samples_per_output = output_interval/sample_interval;
        setN(atom);

        strcpy(output_file_position, input_dir);
        if (method == GKMA_METHOD)
        {
            strcat(output_file_position, "/heatmode.out");
        }
        else if (method == HNEMA_METHOD)
        {
            strcat(output_file_position, "/kappamode.out");
        }

        CHECK(cudaMallocManaged((void **)&eig,
                sizeof(float) * num_participating * num_modes * 3));

        // initialize eigenvector data structures
        strcpy(eig_file_position, input_dir);
        strcat(eig_file_position, "/eigenvector.out");
        std::ifstream eigfile;
        eigfile.open(eig_file_position);
        if (!eigfile)
        {
            PRINT_INPUT_ERROR("Cannot open eigenvector.out file.");
        }

        // GPU phonon code output format
        std::string val;
        float floatval;

        // Setup binning
        if (f_flag)
        {
            double *f;
            CHECK(cudaMallocManaged((void **)&f, sizeof(double)*num_modes));
            getline(eigfile, val);
            std::stringstream ss(val);
            for (int i=0; i<first_mode-1; i++) { ss >> f[0]; }
            double temp;
            for (int i=0; i<num_modes; i++)
            {
                ss >> temp;
                f[i] = copysign(sqrt(abs(temp))/(2.0*PI), temp);
            }
            double fmax, fmin; // freq are in ascending order in file
            int shift;
            fmax = (floor(abs(f[num_modes-1])/f_bin_size)+1)*f_bin_size;
            fmin = floor(abs(f[0])/f_bin_size)*f_bin_size;
            shift = floor(abs(fmin)/f_bin_size);
            num_bins = floor((fmax-fmin)/f_bin_size);

            CHECK(cudaMallocManaged((void **)&bin_count, sizeof(int)*num_bins));
            for(int i_=0; i_<num_bins;i_++){bin_count[i_]=(int)0;}

            for (int i = 0; i< num_modes; i++)
            {
                bin_count[int(abs(f[i]/f_bin_size))-shift]++;
            }

            CHECK(cudaMallocManaged((void **)&bin_sum, sizeof(int)*num_bins));
            for(int i_=0; i_<num_bins;i_++){bin_sum[i_]=(int)0;}

            for (int i = 1; i < num_bins; i++)
            {
                bin_sum[i] = bin_sum[i-1] + bin_count[i-1];
            }

            CHECK(cudaFree(f));
        }
        else
        {
            num_bins = num_modes/bin_size;
            getline(eigfile,val);
        }

        // skips modes up to first_mode
        for (int i=1; i<first_mode; i++) { getline(eigfile,val); }
        for (int j=0; j<num_modes; j++) //modes
        {
            for (int i=0; i<3*num_participating; i++) // xyz of eigvec
            {
                eigfile >> floatval;
                eig[i + 3*num_participating*j] = floatval;
            }
        }
        eigfile.close();

        // Allocate modal velocities
        CHECK(cudaMallocManaged
        (
            (void **)&xdot,
            sizeof(float) * num_modes * 3
        ));

        CHECK(cudaMallocManaged
        (
            (void **)&xdotn,
            sizeof(float) * num_modes * 3 * num_participating
        ));

        // Allocate modal measured quantities
        CHECK(cudaMallocManaged
        (
            (void **)&jm,
            sizeof(float) * num_modes * NUM_OF_HEAT_COMPONENTS
        ));
        CHECK(cudaMallocManaged
        (
            (void **)&jmn,
            sizeof(float) * num_modes * NUM_OF_HEAT_COMPONENTS * num_participating
        ));
        CHECK(cudaMallocManaged
        (
            (void **)&bin_out,
            sizeof(float) * num_bins * NUM_OF_HEAT_COMPONENTS
        ));


        num_heat_stored = num_modes*NUM_OF_HEAT_COMPONENTS;
        if (method == HNEMA_METHOD)
        {
            // Initialize modal measured quantities
            gpu_reset_data
            <<<(num_heat_stored*num_participating-1)/BLOCK_SIZE+1,BLOCK_SIZE>>>
            (
                    num_heat_stored*num_participating, jmn
            );
            CUDA_CHECK_KERNEL
        }
}

void MODAL_ANALYSIS::process(int step, Atom *atom, Integrate *integrate, double fe)
{
    if (!compute) return;
    if (!((step+1) % sample_interval == 0)) return;

    compute_heat(atom);

    if (method == HNEMA_METHOD &&
            !((step+1) % output_interval == 0)) return;

    gpu_reduce_jmn<<<num_modes, ACCUM_BLOCK>>>
    (
        num_participating, num_modes, jmn, jm
    );
    CUDA_CHECK_KERNEL

    if (method == HNEMA_METHOD)
    {
        float volume = atom->box.get_volume();
        float factor = KAPPA_UNIT_CONVERSION/
            (volume * integrate->ensemble->temperature
                    * fe * (float)samples_per_output);
        gpu_scale_jm<<<(num_heat_stored-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
        (
                num_heat_stored, factor, jm
        );
        CUDA_CHECK_KERNEL
    }

    if (f_flag)
    {
        gpu_bin_frequencies<<<num_bins, BIN_BLOCK>>>
        (
               num_modes, bin_count, bin_sum, num_bins,
               jm, bin_out
        );
        CUDA_CHECK_KERNEL
    }
    else
    {
        gpu_bin_modes<<<num_bins, BIN_BLOCK>>>
        (
               num_modes, bin_size, num_bins,
               jm, bin_out
        );
        CUDA_CHECK_KERNEL
    }

    // Compute thermal conductivity and output
    cudaDeviceSynchronize(); // ensure GPU ready to move data to CPU
    FILE *fid = fopen(output_file_position, "a");
    for (int i = 0; i < num_bins; i++)
    {
        fprintf(fid, "%g %g %g %g %g\n",
                bin_out[i], bin_out[i+num_bins], bin_out[i+2*num_bins],
                         bin_out[i+3*num_bins], bin_out[i+4*num_bins]);
    }
    fflush(fid);
    fclose(fid);

    if (method == HNEMA_METHOD)
    {
        gpu_reset_data
        <<<(num_heat_stored*num_participating-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
        (
                num_heat_stored*num_participating, jmn
        );
        CUDA_CHECK_KERNEL
    }

}


void MODAL_ANALYSIS::postprocess()
{
    if (!compute) return;
    CHECK(cudaFree(eig));
    CHECK(cudaFree(xdot));
    CHECK(cudaFree(xdotn));
    CHECK(cudaFree(jm));
    CHECK(cudaFree(jmn));
    CHECK(cudaFree(bin_out));
    if (f_flag)
    {
        CHECK(cudaFree(bin_count));
        CHECK(cudaFree(bin_sum));
    }
}
