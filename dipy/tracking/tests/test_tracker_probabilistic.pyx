import warnings

import numpy as np
import numpy.testing as npt

from dipy.core.sphere import unit_octahedron
from dipy.core.sphere import HemiSphere
from dipy.data import get_fnames, get_sphere
from dipy.direction.pmf import SHCoeffPmfGen, SimplePmfGen
from dipy.reconst.shm import (
    SphHarmFit,
    SphHarmModel,
    descoteaux07_legacy_msg,
)
from dipy.tracking.tracker_probabilistic cimport probabilistic_tracker

from dipy.tracking.tracker_parameters import generate_tracking_parameters

from dipy.tracking.tests.test_fast_tracking import get_fast_tracking_performances


def test_tracker_probabilistic():
    # Test the probabilistic tracker function
    cdef double[:] stream_data = np.zeros(3, dtype=float)
    cdef double[:] point
    cdef double[:] direction

    class SillyModel(SphHarmModel):
        sh_order_max = 4

        def fit(self, data, mask=None):
            coeff = np.zeros(data.shape[:-1] + (15,))
            return SphHarmFit(self, coeff, mask=None)

    model = SillyModel(gtab=None)
    data = np.zeros((3, 3, 3, 7))
    sphere = unit_octahedron

    params = generate_tracking_parameters("prob",
                                          max_len=500,
                                          step_size=0.2,
                                          voxel_size=np.ones(3),
                                          max_angle=20)

    # Test if the tracking works on different dtype of the same data.
    for dtype in [np.float32, np.float64]:
        with warnings.catch_warnings():
            warnings.filterwarnings(
                "ignore",
                message=descoteaux07_legacy_msg,
                category=PendingDeprecationWarning,
            )
            fit = model.fit(data.astype(dtype))
            sh_pmf_gen = SHCoeffPmfGen(fit.shm_coeff, sphere, 'descoteaux07')
            sf_pmf_gen = SimplePmfGen(fit.odf(sphere), sphere)

        point = np.zeros(3)
        direction = unit_octahedron.vertices[0].copy()

        # Test using SH pmf
        state = probabilistic_tracker(&point[0],
                                      &direction[0],
                                      params,
                                      &stream_data[0],
                                      sh_pmf_gen)
        npt.assert_equal(state, 1)

        # Test using SF pmf
        state = probabilistic_tracker(&point[0],
                                      &direction[0],
                                      params,
                                      &stream_data[0],
                                      sf_pmf_gen)
        npt.assert_equal(state, 1)


def test_probabilistic_performances():
    # Test probabilistic tracker on the DiSCo dataset
    params = generate_tracking_parameters("prob",
                                          max_len=500,
                                          step_size=0.2,
                                          voxel_size=np.ones(3),
                                          max_angle=20)
    r = get_fast_tracking_performances(params)
    npt.assert_(r > 0.85, msg="Probabilistic tracker has a low performance "
                              "score: " + str(r))