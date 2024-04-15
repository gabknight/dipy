from dipy.direction.pmf cimport PmfGen
from dipy.tracking.fast_tracking cimport TrackingParameters

cdef int probabilistic_tracker(double* point,
                               double* direction,
                               TrackingParameters params,
                               PmfGen pmf_gen) noexcept nogil