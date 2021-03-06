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
Initialize the velocities of the system:
    total linear momentum is zero
    total angular momentum is zero
If DEBUG is on in the makefile, the velocities are the same from run to run.
If DEBUG is off, the velocities are different in different runs.
------------------------------------------------------------------------------*/


#include "atom.cuh"
#include "error.cuh"


void Atom::scale_velocity(void)
{
    double temperature = 0.0;
    for (int n = 0; n < N; ++n) 
    {
        double v2 = cpu_vx[n]*cpu_vx[n]+cpu_vy[n]*cpu_vy[n]+cpu_vz[n]*cpu_vz[n];
        temperature += cpu_mass[n] * v2;
    }
    temperature /= 3.0 * K_B * N;
    double factor = sqrt(initial_temperature / temperature);
    for (int n = 0; n < N; ++n)
    {
        cpu_vx[n] *= factor; cpu_vy[n] *= factor; cpu_vz[n] *= factor;
    }
}


static void get_random_velocities(int N, double* vx, double* vy, double* vz)
{
    for (int n = 0; n < N; ++n)
    {
        vx[n] = -1.0 + (rand() * 2.0) / RAND_MAX; 
        vy[n] = -1.0 + (rand() * 2.0) / RAND_MAX; 
        vz[n] = -1.0 + (rand() * 2.0) / RAND_MAX;    
    }
}


static void zero_linear_momentum(int N, double* m, double* vx, double* vy, double* vz)
{
    double p[3] = {0.0, 0.0, 0.0}; // linear momentum
    for (int n = 0; n < N; ++n)
    {       
        p[0] += m[n]*vx[n]/N; p[1] += m[n]*vy[n]/N; p[2] += m[n]*vz[n]/N;
    }
    for (int n = 0; n < N; ++n) 
    { 
        vx[n] -= p[0] / m[n]; vy[n] -= p[1] / m[n]; vz[n] -= p[2] / m[n]; 
    }
}


static void get_center(int N, double r0[3], double* m, double* x, double* y, double* z)
{
    double mass_total = 0;
    for (int i = 0; i < N; i++)
    {
        double mass = m[i];
        mass_total += mass;
        r0[0] += x[i] * mass; r0[1] += y[i] * mass; r0[2] += z[i] * mass;
    }
    r0[0] /= mass_total; r0[1] /= mass_total; r0[2] /= mass_total;
}


static void get_angular_momentum
(
    int N, double L[3], double r0[3], double* m, double* x, double* y, double* z,
    double* vx, double* vy, double* vz
)
{
    for (int i = 0; i < N; i++)
    {
        double dx = x[i] - r0[0]; double dy = y[i] - r0[1]; double dz = z[i] - r0[2];
        L[0] += m[i] * (dy * vz[i] - dz * vy[i]);
        L[1] += m[i] * (dz * vx[i] - dx * vz[i]);
        L[2] += m[i] * (dx * vy[i] - dy * vx[i]);
    }
}


static void get_inertia
(int N, double I[3][3], double r0[3], double* m, double* x, double* y, double* z)
{
    for (int i = 0; i < N; i++)
    {
        double dx = x[i] - r0[0]; double dy = y[i] - r0[1]; double dz = z[i] - r0[2];
        I[0][0] += m[i] * (dy*dy + dz*dz);
        I[1][1] += m[i] * (dx*dx + dz*dz);
        I[2][2] += m[i] * (dx*dx + dy*dy);
        I[0][1] -= m[i]*dx*dy; I[1][2] -= m[i]*dy*dz; I[0][2] -= m[i]*dx*dz;
    }
    I[1][0] = I[0][1]; I[2][1] = I[1][2]; I[2][0] = I[0][2];
}


static void get_angular_velocity(double I[3][3], double L[3], double w[3])
{
    double inverse[3][3]; // inverse of I
    inverse[0][0] =   I[1][1]*I[2][2] - I[1][2]*I[2][1];
    inverse[0][1] = -(I[0][1]*I[2][2] - I[0][2]*I[2][1]);
    inverse[0][2] =   I[0][1]*I[1][2] - I[0][2]*I[1][1];
    inverse[1][0] = -(I[1][0]*I[2][2] - I[1][2]*I[2][0]);
    inverse[1][1] =   I[0][0]*I[2][2] - I[0][2]*I[2][0];
    inverse[1][2] = -(I[0][0]*I[1][2] - I[0][2]*I[1][0]);
    inverse[2][0] =   I[1][0]*I[2][1] - I[1][1]*I[2][0];
    inverse[2][1] = -(I[0][0]*I[2][1] - I[0][1]*I[2][0]);
    inverse[2][2] =   I[0][0]*I[1][1] - I[0][1]*I[1][0];
    double determinant = I[0][0]*I[1][1]*I[2][2] + I[0][1]*I[1][2]*I[2][0] +
                       I[0][2]*I[1][0]*I[2][1] - I[0][0]*I[1][2]*I[2][1] -
                       I[0][1]*I[1][0]*I[2][2] - I[2][0]*I[1][1]*I[0][2];
    for (int i = 0; i < 3; i++)
    {
        for (int j = 0; j < 3; j++) { inverse[i][j] /= determinant; }
    }
    // w = inv(I) * L, because L = I * w
    w[0] = inverse[0][0] * L[0] + inverse[0][1] * L[1] + inverse[0][2] * L[2];
    w[1] = inverse[1][0] * L[0] + inverse[1][1] * L[1] + inverse[1][2] * L[2];
    w[2] = inverse[2][0] * L[0] + inverse[2][1] * L[1] + inverse[2][2] * L[2];
}


// v_i = v_i - w x dr_i
static void zero_angular_momentum
(
    int N, double w[3], double r0[3], double* x, double* y, double* z,
    double* vx, double* vy, double* vz
)
{
    for (int i = 0; i < N; i++)
    {
        double dx = x[i] - r0[0]; double dy = y[i] - r0[1]; double dz = z[i] - r0[2];
        vx[i]-=w[1]*dz-w[2]*dy; vy[i]-=w[2]*dx-w[0]*dz; vz[i]-=w[0]*dy-w[1]*dx;
    }
}


void Atom::initialize_velocity_cpu(void)
{
    get_random_velocities(N, cpu_vx, cpu_vy, cpu_vz);
    zero_linear_momentum(N, cpu_mass, cpu_vx, cpu_vy, cpu_vz);
    double r0[3] = {0, 0, 0}; // center of mass position
    get_center(N, r0, cpu_mass, cpu_x, cpu_y, cpu_z);
    double L[3] = {0, 0, 0}; // angular momentum
    get_angular_momentum(N, L, r0, cpu_mass, cpu_x, cpu_y, cpu_z,
        cpu_vx, cpu_vy, cpu_vz);
    double I[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}; // moment of inertia
    get_inertia(N, I, r0, cpu_mass, cpu_x, cpu_y, cpu_z);
    double w[3]; // angular velocity
    get_angular_velocity(I, L, w);
    zero_angular_momentum(N, w, r0, cpu_x, cpu_y, cpu_z,
        cpu_vx, cpu_vy, cpu_vz);
    scale_velocity();
}


void Atom::initialize_velocity(void)
{
    if (has_velocity_in_xyz == 0) { initialize_velocity_cpu(); }
    int M = sizeof(double) * N;
    CHECK(cudaMemcpy(vx, cpu_vx, M, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(vy, cpu_vy, M, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(vz, cpu_vz, M, cudaMemcpyHostToDevice));
    printf("Initialized velocities with T = %g K.\n", initial_temperature);
}


