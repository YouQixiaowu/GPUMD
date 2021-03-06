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
Calculate:
    Velocity AutoCorrelation (VAC) function
    Self Diffusion Coefficient (SDC)
    Mass-weighted VAC (MVAC)
    Phonon Density Of States (PDOS or simply DOS)

Reference for PDOS:
    J. M. Dickey and A. Paskin, 
    Computer Simulation of the Lattice Dynamics of Solids, 
    Phys. Rev. 188, 1407 (1969).
------------------------------------------------------------------------------*/


#include "vac.cuh"
#include "atom.cuh"
#include "error.cuh"

const int BLOCK_SIZE = 128;


static __global__ void gpu_initialize_vac
(int Nc, double *g_vac_x, double *g_vac_y, double *g_vac_z)
{
    int n = threadIdx.x + blockIdx.x * blockDim.x;
    if (n < Nc)
    {
        g_vac_x[n] = ZERO;
        g_vac_y[n] = ZERO;
        g_vac_z[n] = ZERO;
    }
}


static __global__ void gpu_copy_mass
(
    int N, int offset, int *g_group_contents,
    double *g_mass_o, double *g_mass_i
)
{
    int n = threadIdx.x + blockIdx.x * blockDim.x;

    if (n < N)
    {
        int m = g_group_contents[offset + n];
        g_mass_o[n] = g_mass_i[m];
    }
}


void VAC::preprocess(Atom *atom)
{
    if (!compute_dos && !compute_sdc) return;

    if (compute_dos == compute_sdc)
    {
        PRINT_INPUT_ERROR("Cannot calculate DOS and SDC simultaneously.");
    }

    dt = atom->time_step * sample_interval;
    dt_in_ps = dt * TIME_UNIT_CONVERSION / 1000.0; // natural to ps

    // initialize the number of time origins
    num_time_origins = 0;

    // determine the number of atoms in the selected group
    if (-1 == grouping_method)
    {
        N = atom->N;
    }
    else
    {
        N = atom->group[grouping_method].cpu_size[group];
    }

    // only need to record Nc frames of velocity data (saving a lot of memory)
    CHECK(cudaMalloc((void**)&vx, sizeof(double) * N * Nc));
    CHECK(cudaMalloc((void**)&vy, sizeof(double) * N * Nc));
    CHECK(cudaMalloc((void**)&vz, sizeof(double) * N * Nc));

    // using unified memory for VAC
    CHECK(cudaMallocManaged((void**)&vac_x, sizeof(double) * Nc));
    CHECK(cudaMallocManaged((void**)&vac_y, sizeof(double) * Nc));
    CHECK(cudaMallocManaged((void**)&vac_z, sizeof(double) * Nc));

    // initialize the VAC to zero
    gpu_initialize_vac<<<(Nc - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
    (Nc, vac_x, vac_y, vac_z);
    CUDA_CHECK_KERNEL

    if (compute_dos)
    {
        // set default number of DOS points
        if (num_dos_points == -1) {num_dos_points = Nc;}

        // check if the sampling frequency is large enough
        double nu_max = 1000.0/(atom->time_step * sample_interval); // THz
        if (nu_max < omega_max/PI)
        {
            PRINT_INPUT_ERROR("VAC sampling rate < Nyquist frequency.");
        }

        // need mass for DOS calculations
        CHECK(cudaMalloc((void**)&mass, sizeof(double) * N));

        if (grouping_method >= 0)
        {
            gpu_copy_mass<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
            (
                N, atom->group[grouping_method].cpu_size_sum[group],
                atom->group[grouping_method].contents, mass, atom->mass
            );
            CUDA_CHECK_KERNEL
        }
        else
        {
            const int mem = sizeof(double) * N;
            CHECK(cudaMemcpy(mass, atom->mass, mem, cudaMemcpyDeviceToDevice));
        }
    }
}


static __global__ void gpu_copy_velocity
(
    int N, int offset, int *g_group_contents,
    double *g_vx_o, double *g_vy_o, double *g_vz_o,
    double *g_vx_i, double *g_vy_i, double *g_vz_i
)
{
    int n = threadIdx.x + blockIdx.x * blockDim.x;

    if (n < N)
    {
        int m = g_group_contents[offset + n];
        g_vx_o[n] = g_vx_i[m];
        g_vy_o[n] = g_vy_i[m];
        g_vz_o[n] = g_vz_i[m];
    }
}


static __global__ void gpu_copy_velocity
(
    int N, 
    double *g_vx_o, double *g_vy_o, double *g_vz_o,
    double *g_vx_i, double *g_vy_i, double *g_vz_i
)
{
    int n = threadIdx.x + blockIdx.x * blockDim.x;

    if (n < N)
    {
        g_vx_o[n] = g_vx_i[n];
        g_vy_o[n] = g_vy_i[n];
        g_vz_o[n] = g_vz_i[n];
    }
}


static __global__ void gpu_find_vac
(
    int N, int correlation_step, int compute_dos, double *g_mass,
    double *g_vx, double *g_vy, double *g_vz,
    double *g_vx_all, double *g_vy_all, double *g_vz_all,
    double *g_vac_x, double *g_vac_y, double *g_vac_z
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int size_sum = bid * N;
    int number_of_rounds = (N - 1) / BLOCK_SIZE + 1;
    __shared__ double s_vac_x[BLOCK_SIZE];
    __shared__ double s_vac_y[BLOCK_SIZE];
    __shared__ double s_vac_z[BLOCK_SIZE];
    double vac_x = ZERO;
    double vac_y = ZERO;
    double vac_z = ZERO;

    for (int round = 0; round < number_of_rounds; ++round)
    {
        int n = tid + round * BLOCK_SIZE;
        if (n < N)
        {
            double mass = compute_dos ? g_mass[n] : ONE;
            vac_x += mass * g_vx[n] * g_vx_all[size_sum + n];
            vac_y += mass * g_vy[n] * g_vy_all[size_sum + n];
            vac_z += mass * g_vz[n] * g_vz_all[size_sum + n];
        }
    }
    s_vac_x[tid] = vac_x;
    s_vac_y[tid] = vac_y;
    s_vac_z[tid] = vac_z;
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_vac_x[tid] += s_vac_x[tid + offset];
            s_vac_y[tid] += s_vac_y[tid + offset];
            s_vac_z[tid] += s_vac_z[tid + offset];
        }
        __syncthreads();
    }

    if (tid == 0)
    {
        if (bid <= correlation_step)
        {
            g_vac_x[correlation_step - bid] += s_vac_x[0];
            g_vac_y[correlation_step - bid] += s_vac_y[0];
            g_vac_z[correlation_step - bid] += s_vac_z[0];
        }
        else
        {
            g_vac_x[correlation_step + gridDim.x - bid] += s_vac_x[0];
            g_vac_y[correlation_step + gridDim.x - bid] += s_vac_y[0];
            g_vac_z[correlation_step + gridDim.x - bid] += s_vac_z[0];
        }
    }
}


void VAC::process(int step, Atom *atom)
{
    if (!(compute_dos || compute_sdc)) return;
    if ((step + 1) % sample_interval != 0) { return; }
    int sample_step = step / sample_interval; // 0, 1, ..., Nc-1, Nc, Nc+1, ...
    int correlation_step = sample_step % Nc;  // 0, 1, ..., Nc-1, 0, 1, ...
    int offset = correlation_step * N;

    // copy the velocity data at the current step to appropriate place
    if (grouping_method >= 0)
    {
        gpu_copy_velocity<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
        (
            N, atom->group[grouping_method].cpu_size_sum[group],
            atom->group[grouping_method].contents,
            vx + offset, vy + offset, vz + offset,
            atom->vx, atom->vy, atom->vz
        );
    }
    else
    {
        gpu_copy_velocity<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
        (
            N, vx + offset, vy + offset, vz + offset,
            atom->vx, atom->vy, atom->vz
        );
    }
    CUDA_CHECK_KERNEL 

    // start to calculate the VAC (or MVAC) when we have enough frames
    if (sample_step >= Nc - 1)
    {
        ++num_time_origins;
        
        gpu_find_vac<<<Nc, BLOCK_SIZE>>>
        (
            N, correlation_step, compute_dos, mass, 
            vx + offset, vy + offset, vz + offset, 
            vx, vy, vz, vac_x, vac_y, vac_z
        );
        CUDA_CHECK_KERNEL 
    }
}


static void perform_dft
(
    int N, int Nc, int num_dos_points,
    double delta_t, double omega_0, double d_omega,
    double *vac_x, double *vac_y, double *vac_z,
    double *dos_x, double *dos_y, double *dos_z
)
{
    // Apply Hann window and normalize by the correct factor
    for (int nc = 0; nc < Nc; nc++)
    {
        double hann_window = (cos((PI * nc) / Nc) + 1.0) * 0.5;

        double multiply_factor = 2.0 * hann_window;
        if (nc == 0)
        {
            multiply_factor = 1.0 * hann_window;
        }

        vac_x[nc] *= multiply_factor;
        vac_y[nc] *= multiply_factor;
        vac_z[nc] *= multiply_factor;
    }

    // Calculate DOS by discrete Fourier transform
    for (int nw = 0; nw < num_dos_points; nw++)
    {
        double omega = omega_0 + nw * d_omega;
        for (int nc = 0; nc < Nc; nc++)
        {
            double cos_factor = cos(omega * nc * delta_t);
            dos_x[nw] += vac_x[nc] * cos_factor;
            dos_y[nw] += vac_y[nc] * cos_factor;
            dos_z[nw] += vac_z[nc] * cos_factor;
        }
        dos_x[nw] *= delta_t * 2.0 * N;
        dos_y[nw] *= delta_t * 2.0 * N;
        dos_z[nw] *= delta_t * 2.0 * N;
    }
}


void VAC::find_dos(char *input_dir, Atom *atom)
{
    double d_omega = omega_max / num_dos_points;
    double omega_0 = d_omega;

    // initialize DOS data
    double *dos_x, *dos_y, *dos_z;
    MY_MALLOC(dos_x, double, num_dos_points);
    MY_MALLOC(dos_y, double, num_dos_points);
    MY_MALLOC(dos_z, double, num_dos_points);
    for (int nw = 0; nw < num_dos_points; nw++)
    {
        dos_x[nw] = dos_y[nw] = dos_z[nw] = 0.0;
    }

    // perform DFT to get DOS from normalized MVAC
    perform_dft
    (
        N, Nc, num_dos_points, dt_in_ps, omega_0, d_omega,
        vac_x, vac_y, vac_z, dos_x, dos_y, dos_z
    );

    // output DOS
    char file_dos[FILE_NAME_LENGTH];
    strcpy(file_dos, input_dir);
    strcat(file_dos, "/dos.out");
    FILE *fid = fopen(file_dos, "a");
    for (int nw = 0; nw < num_dos_points; nw++)
    {
        double omega = omega_0 + d_omega * nw;
        fprintf(fid, "%g %g %g %g\n", omega, dos_x[nw], dos_y[nw], dos_z[nw]);
    }
    fflush(fid);
    fclose(fid);

    // free memory
    MY_FREE(dos_x);
    MY_FREE(dos_y);
    MY_FREE(dos_z);
}


static void integrate_vac
(
    int Nc, double dt, double *vac_x, double *vac_y, double *vac_z,
    double *sdc_x, double *sdc_y, double *sdc_z
)
{
    double dt2 = dt * 0.5;
    for (int nc = 1; nc < Nc; nc++)
    {
        sdc_x[nc] = sdc_x[nc - 1] + (vac_x[nc - 1] + vac_x[nc]) * dt2;
        sdc_y[nc] = sdc_y[nc - 1] + (vac_y[nc - 1] + vac_y[nc]) * dt2;
        sdc_z[nc] = sdc_z[nc - 1] + (vac_z[nc - 1] + vac_z[nc]) * dt2;
    }
}


void VAC::find_sdc(char *input_dir, Atom *atom)
{
    // initialize the SDC data
    double *sdc_x, *sdc_y, *sdc_z;
    MY_MALLOC(sdc_x, double, Nc);
    MY_MALLOC(sdc_y, double, Nc);
    MY_MALLOC(sdc_z, double, Nc);
    for (int nc = 0; nc < Nc; nc++)
    {
        sdc_x[nc] = sdc_y[nc] = sdc_z[nc] = 0.0;
    }

    // get the SDC from the VAC according to the Green-Kubo relation
    integrate_vac(Nc, dt, vac_x, vac_y, vac_z, sdc_x, sdc_y, sdc_z);

    // output the VAC and SDC
    char file_sdc[FILE_NAME_LENGTH];
    strcpy(file_sdc, input_dir);
    strcat(file_sdc, "/sdc.out");
    FILE *fid = fopen(file_sdc, "a");
    for (int nc = 0; nc < Nc; nc++)
    {
        double t = nc * dt_in_ps;

        // change to A^2/ps^2
        vac_x[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION;
        vac_y[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION;
        vac_z[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION;

        sdc_x[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps
        sdc_y[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps
        sdc_z[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps

        fprintf(fid, "%g %g %g %g ", t, vac_x[nc], vac_y[nc], vac_z[nc]);
        fprintf(fid, "%g %g %g\n", sdc_x[nc], sdc_y[nc], sdc_z[nc]);
    }
    fflush(fid);
    fclose(fid);

    // free memory
    MY_FREE(sdc_x); 
    MY_FREE(sdc_y); 
    MY_FREE(sdc_z);
}


void VAC::postprocess(char *input_dir, Atom *atom)
{
    if (!(compute_dos || compute_sdc)) return;

    CHECK(cudaDeviceSynchronize()); // needed for pre-Pascal GPU

    // calculate DOS or SDC
    if (compute_dos)
    {
        // normalize to vac_x[0] = vac_y[0] = vac_z[0] = 1
        double vac_x_0 = vac_x[0];
        double vac_y_0 = vac_y[0];
        double vac_z_0 = vac_z[0];
        for (int nc = 0; nc < Nc; nc++)
        {
            vac_x[nc] /= vac_x_0;
            vac_y[nc] /= vac_y_0;
            vac_z[nc] /= vac_z_0;
        }

        // output normalized MVAC
        char file_vac[FILE_NAME_LENGTH];
        strcpy(file_vac, input_dir);
        strcat(file_vac, "/mvac.out");
        FILE *fid = fopen(file_vac, "a");
        for (int nc = 0; nc < Nc; nc++)
        {
            double t = nc * dt_in_ps;
            fprintf(fid, "%g %g %g %g\n", t, vac_x[nc], vac_y[nc], vac_z[nc]);
        }
        fflush(fid);
        fclose(fid);

        // calculate and output DOS
        find_dos(input_dir, atom);
    }
    else
    {
        // normalize by the number of atoms and number of time origins
        for (int nc = 0; nc < Nc; nc++)
        {
            vac_x[nc] /= double(N) * num_time_origins;
            vac_y[nc] /= double(N) * num_time_origins;
            vac_z[nc] /= double(N) * num_time_origins;
        }
        find_sdc(input_dir, atom);
    }

    // free memory
    CHECK(cudaFree(vac_x));
    CHECK(cudaFree(vac_y));
    CHECK(cudaFree(vac_z));
    CHECK(cudaFree(vx));
    CHECK(cudaFree(vy));
    CHECK(cudaFree(vz));
    if (compute_dos)
    {
        CHECK(cudaFree(mass));
    }
}


