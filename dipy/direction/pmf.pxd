cimport numpy as np

cdef class PmfGen:
    cdef:
        double[:] pmf
        double[:, :, :, :] data
        double[:, :] vertices

    cpdef double[:] get_pmf(self, double[::1] point)
    cdef double* get_pmf_c(self, double* point) noexcept nogil
    cdef int find_closest(self, double* xyz) noexcept nogil
    cpdef double get_pmf_value(self, double[::1] point, double[::1] xyz)
    cdef double get_pmf_value_c(self, double* point, double* xyz) noexcept nogil
    cdef void __clear_pmf(self) noexcept nogil
    pass


cdef class SimplePmfGen(PmfGen):
    pass


cdef class SHCoeffPmfGen(PmfGen):
    cdef:
        double[:, :] B
        double[:] coeff
    pass
