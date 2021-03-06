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
GPUMD Contributing author: Alexander Gabourie (Stanford University)
------------------------------------------------------------------------------*/

#pragma once
#include "common.cuh"
#include "mic.cuh"
#include "atom.cuh"
#include "integrate.cuh"
#include "ensemble.cuh"

#define NO_METHOD -1
#define GKMA_METHOD 0
#define HNEMA_METHOD 1

class MODAL_ANALYSIS
{
public:
    int compute = 0;
    int method = NO_METHOD; // Method to compute
    int output_interval;    // number of times steps to output average heat current
    int sample_interval;    // steps per heat current computation
    int first_mode;         // first mode to consider
    int last_mode;          // last mode to consider
    int bin_size;           // number of modes per bin
    double f_bin_size;        // freq. range per bin (THz)
    int f_flag;             // 0 -> modes, 1 -> freq.
    int num_modes;          // total number of modes to consider
    int atom_begin;         // Beginning atom group/type
    int atom_end;           // End atom group/type

    float* eig;              // eigenvectors
    float* xdotn;            // per-atom modal velocity
    float* xdot;             // modal velocities
    float* jmn;              // per-atom modal heat current
    float* jm;               // total modal heat current
    float* bin_out;          // modal binning structure
    int* bin_count;         // Number of modes per bin when f_flag=1
    int* bin_sum;           // Running sum from bin_count

    char eig_file_position[FILE_NAME_LENGTH];
    char output_file_position[FILE_NAME_LENGTH];

    void preprocess(char*, Atom*);
    void process(int, Atom*, Integrate*, double);
    void postprocess();

private:
    int samples_per_output; // samples to be averaged for output
    int num_bins;           // number of bins to output
    int N1;                 // Atom starting index
    int N2;                 // Atom ending index
    int num_participating;  // Number of particles participating
    int num_heat_stored;    // Number of stored heat current elements

    void compute_heat(Atom*);
    void setN(Atom*);


};
