# cython: boundscheck=False
# cython: initializedcheck=False
# cython: wraparound=False
# cython: Nonecheck=False

from libc.stdio cimport printf

cimport cython
from cython.parallel import prange
import numpy as np
cimport numpy as cnp

from dipy.core.interpolation cimport trilinear_interpolate4d_c
from dipy.direction.pmf cimport PmfGen
from dipy.tracking.stopping_criterion cimport StoppingCriterion
from dipy.utils cimport fast_numpy

from dipy.tracking.stopping_criterion cimport (StreamlineStatus,
                                               StoppingCriterion,
                                               TRACKPOINT,
                                               ENDPOINT,
                                               OUTSIDEIMAGE,
                                               INVALIDPOINT)
from dipy.tracking.tracker_parameters cimport TrackerParameters, func_ptr

from nibabel.streamlines import ArraySequence as Streamlines

from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from libc.math cimport floor, ceil
from libc.stdio cimport printf

from posix.time cimport clock_gettime, timespec, CLOCK_REALTIME

cdef extern from "stdlib.h" nogil:
    void *memset(void *ptr, int value, size_t num)

def generate_tractogram(double[:,::1] seed_positions,
                        double[:,::1] seed_directions,
                        StoppingCriterion sc,
                        TrackerParameters params,
                        PmfGen pmf_gen,
                        int nbr_threads=0,
                        float buffer_frac=1.0):

    cdef:
        cnp.npy_intp _len = seed_positions.shape[0]
        cnp.npy_intp _plen = int(ceil(_len * buffer_frac))
        cnp.npy_intp i
        double** streamlines_arr = <double**> malloc(_len * sizeof(double*))
        int* length_arr = <int*> malloc(_len * sizeof(int))
        int* status_arr = <int*> malloc(_len * sizeof(double))

    if streamlines_arr == NULL or length_arr == NULL or status_arr == NULL:
        raise MemoryError("Memory allocation failed")

    # srand/rand don't play well with multi-threading
    if params.random_seed > 0 and not nbr_threads == 1:
        raise ValueError("random_seed > 0 do not work with nbr_threads != 1.")

    seed_start = 0
    seed_end = seed_start + _plen
    while seed_start < _len:
        generate_tractogram_c(seed_positions[seed_start:seed_end],
                              seed_directions[seed_start:seed_end],
                              nbr_threads, sc, params,
                              pmf_gen,
                              streamlines_arr, length_arr, status_arr)
        seed_start += _plen
        seed_end += _plen
        streamlines = []
        try:
            for i in range(_len):
                if length_arr[i] > 1:
                    s = np.asarray(<cnp.float_t[:length_arr[i]*3]> streamlines_arr[i])
                    streamlines.append(s.copy().reshape((-1,3)))
                    if streamlines_arr[i] == NULL:
                        continue
                    free(streamlines_arr[i])
        finally:
            free(streamlines_arr)
            free(length_arr)
            free(status_arr)

        for s in streamlines:
            yield s


cdef int generate_tractogram_c(double[:,::1] seed_positions,
                               double[:,::1] seed_directions,
                               int nbr_threads,
                               StoppingCriterion sc,
                               TrackerParameters params,
                               PmfGen pmf_gen,
                               double** streamlines,
                               int* lengths,
                               int* status):
    cdef:
        cnp.npy_intp _len=seed_positions.shape[0]
        cnp.npy_intp i, j, k

    if nbr_threads<= 0:
        nbr_threads = 0
    for i in prange(_len, nogil=True, num_threads=nbr_threads):
        stream = <double*> malloc((params.max_len * 3 * 2 + 1) * sizeof(double))
        stream_idx = <int*> malloc(2 * sizeof(int))
        status[i] = generate_local_streamline(&seed_positions[i][0],
                                              &seed_directions[i][0],
                                              stream,
                                              stream_idx,
                                              sc,
                                              params,
                                              pmf_gen)

        # copy the streamlines points from the buffer to a 1d vector of the streamline length
        lengths[i] = stream_idx[1] - stream_idx[0]
        if lengths[i] > 1:
            streamlines[i] = <double*> malloc(lengths[i] * 3 * sizeof(double))
            memcpy(&streamlines[i][0], &stream[stream_idx[0] * 3], lengths[i] * 3 * sizeof(double))
        free(stream)
        free(stream_idx)

    return 0


cdef int generate_local_streamline(double* seed,
                                   double* direction,
                                   double* stream,
                                   int* stream_idx,
                                   StoppingCriterion sc,
                                   TrackerParameters params,
                                   PmfGen pmf_gen) noexcept nogil:
    cdef:
        cnp.npy_intp i, j
        cnp.npy_uint32 s_random_seed
        double[3] point
        double[3] voxdir
        double* stream_data        
        StreamlineStatus stream_status_forward, stream_status_backward
        timespec ts

    # set the random generator
    if params.random_seed > 0:
        s_random_seed = int(
            (seed[0] * 2 + seed[1] * 3 + seed[2] * 5) * params.random_seed
            )
    else:
        clock_gettime(CLOCK_REALTIME, &ts)
        s_random_seed = int(ts.tv_sec + (ts.tv_nsec / 1000000000.))

    fast_numpy.seed(s_random_seed)

    # set the initial position
    fast_numpy.copy_point(seed, point)
    fast_numpy.copy_point(direction, voxdir)
    fast_numpy.copy_point(seed, &stream[params.max_len * 3])

    # forward tracking
    stream_data = <double*> malloc(100 * sizeof(double))
    memset(stream_data, 0, 100 * sizeof(double))
    stream_status_forward = TRACKPOINT
    for i in range(1, params.max_len):
        if <func_ptr>params.tracker(&point[0], &voxdir[0], params, stream_data, pmf_gen):
            break
        # update position
        for j in range(3):
            point[j] += voxdir[j] * params.inv_voxel_size[j] * params.step_size
        fast_numpy.copy_point(point, &stream[(params.max_len + i )* 3])

        stream_status_forward = sc.check_point_c(point)
        if (stream_status_forward == ENDPOINT or
            stream_status_forward == INVALIDPOINT or
            stream_status_forward == OUTSIDEIMAGE):
            break
    stream_idx[1] = params.max_len + i -1
    free(stream_data)

    # backward tracking
    stream_data = <double*> malloc(100 * sizeof(double))
    memset(stream_data, 0, 100 * sizeof(double))

    fast_numpy.copy_point(seed, point)
    fast_numpy.copy_point(direction, voxdir)
    if i > 1:
        # Use the first selected orientation for the backward tracking segment
        for j in range(3):
            voxdir[j] = stream[(params.max_len + 1) * 3 + j] - stream[params.max_len * 3 + j]                     
        fast_numpy.normalize(voxdir)
    
    # flip the initial direction for backward streamline segment
    for j in range(3):
        voxdir[j] = voxdir[j] * -1

    stream_status_backward = TRACKPOINT
    for i in range(1, params.max_len):
        if <func_ptr>params.tracker(&point[0], &voxdir[0], params, stream_data, pmf_gen):
            break
        # update position
        for j in range(3):
            point[j] += voxdir[j] * params.inv_voxel_size[j] * params.step_size
        fast_numpy.copy_point(point, &stream[(params.max_len - i )* 3])

        stream_status_backward = sc.check_point_c(point)
        if (stream_status_backward == ENDPOINT or
            stream_status_backward == INVALIDPOINT or
            stream_status_backward == OUTSIDEIMAGE):
            break
    stream_idx[0] = params.max_len - i + 1
    free(stream_data)
    # # need to handle stream status
    return 0 #stream_status


cdef int get_pmf(double* pmf,
                 double* point,
                 PmfGen pmf_gen,
                 double pmf_threshold,
                 int pmf_len) noexcept nogil:
    cdef:
        cnp.npy_intp i
        double absolute_pmf_threshold
        double max_pmf=0

    pmf = pmf_gen.get_pmf_c(point, pmf)

    for i in range(pmf_len):
        if pmf[i] > max_pmf:
            max_pmf = pmf[i]
    absolute_pmf_threshold = pmf_threshold * max_pmf

    for i in range(pmf_len):
        if pmf[i] < absolute_pmf_threshold:
            pmf[i] = 0.0

    return 0
