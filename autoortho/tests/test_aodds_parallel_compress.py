"""Tests for the banded parallel BC compression and bounded OpenMP teams in aodds.

The oracle for byte identity is the ISPC texture compressor itself: one
``CompressBlocksBC1``/``CompressBlocksBC3`` call over the whole surface, made
directly through ``libispc_texcomp``. That is the exact call the native
pipeline made before compression was split into row bands.
"""

import ctypes
import os
import subprocess
import sys
import threading

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from aopipeline import AoDDS  # noqa: E402
import pydds  # noqa: E402

pytestmark = pytest.mark.skipif(
    not AoDDS.is_available(), reason="native aopipeline library not available"
)

TESTFILES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "testfiles")
CHUNK_JPEG = os.path.join(TESTFILES, "test_tile_small.jpg")


class _Image(ctypes.Structure):
    """Mirror of ``aodecode_image_t``."""

    _fields_ = [
        ("data", ctypes.POINTER(ctypes.c_uint8)),
        ("width", ctypes.c_int32),
        ("height", ctypes.c_int32),
        ("stride", ctypes.c_int32),
        ("channels", ctypes.c_int32),
        ("from_pool", ctypes.c_int32),
    ]


def _lib():
    lib = AoDDS._load_library()
    lib.aodds_compress.argtypes = [
        ctypes.POINTER(_Image), ctypes.c_int32, ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32,
    ]
    lib.aodds_compress.restype = ctypes.c_uint32
    return lib


def _random_rgba(width, height, seed):
    rng = np.random.default_rng(seed)
    return np.ascontiguousarray(rng.integers(0, 256, size=(height, width, 4), dtype=np.uint8))


def _native_compress(lib, pixels, fmt, max_threads):
    height, width = pixels.shape[:2]
    block_size = 8 if fmt == "BC1" else 16
    out = np.zeros((width // 4) * (height // 4) * block_size, dtype=np.uint8)
    image = _Image(
        pixels.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        width, height, width * 4, 4, 0,
    )
    written = lib.aodds_compress(
        ctypes.byref(image),
        ctypes.c_int32(0 if fmt == "BC1" else 1),
        out.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_int32(max_threads),
    )
    assert written == out.nbytes
    return out.tobytes()


def _ispc_reference(pixels, fmt):
    height, width = pixels.shape[:2]
    block_size = 8 if fmt == "BC1" else 16
    out = ctypes.create_string_buffer((width // 4) * (height // 4) * block_size)
    surface = pydds.rgba_surface(pixels.ctypes.data_as(ctypes.c_char_p), width, height, width * 4)
    fn = pydds._ispc.CompressBlocksBC1 if fmt == "BC1" else pydds._ispc.CompressBlocksBC3
    fn(ctypes.byref(surface), out)
    return out.raw


@pytest.mark.parametrize("fmt", ["BC1", "BC3"])
@pytest.mark.parametrize(
    "width,height",
    [
        (256, 256),     # below the parallel threshold: single call
        (1024, 256),    # at the threshold
        (4096, 256),    # one mipmap-0 chunk row, the live hot path
        (4096, 4096),   # full mipmap 0
        (4096, 260),    # block rows do not divide evenly across bands
    ],
)
def test_banded_compress_matches_whole_surface_ispc(fmt, width, height):
    lib = _lib()
    pixels = _random_rgba(width, height, seed=width * 31 + height)
    reference = _ispc_reference(pixels, fmt)
    for max_threads in (1, 3, 8, 0):
        assert _native_compress(lib, pixels, fmt, max_threads) == reference, (
            f"{fmt} {width}x{height} differs with max_threads={max_threads}"
        )


def _row_of_chunks(count):
    with open(CHUNK_JPEG, "rb") as f:
        jpeg = f.read()
    return [jpeg] * count


def test_partial_mipmap_identical_for_any_thread_bound():
    jpegs = _row_of_chunks(16)
    jpegs[5] = None  # one missing chunk takes the fill color path
    single = AoDDS.build_partial_mipmap(jpegs, 16, 1, format="BC1", max_threads=1)
    assert single.success and single.bytes_written == 4096 * 256 // 2
    for max_threads in (4, 16, 0):
        result = AoDDS.build_partial_mipmap(jpegs, 16, 1, format="BC1", max_threads=max_threads)
        assert result.success
        assert result.data == single.data, f"max_threads={max_threads}"
    v2 = AoDDS.build_partial_mipmap_v2(jpegs, 16, 1, format="BC1", max_threads=4)
    assert v2.success and v2.data == single.data


_THREAD_DELTA_SCRIPT = """
import sys, threading, psutil
sys.path.insert(0, sys.argv[1])
from aopipeline import AoDDS
jpegs = [open(sys.argv[2], "rb").read()] * 16
# A team of one on the main thread registers it as an OpenMP root without
# creating workers, so the runtime stays alive after the worker thread exits.
AoDDS.build_partial_mipmap(jpegs, 16, 1, format="BC1", max_threads=1)
proc = psutil.Process()
before = proc.num_threads()
worker = threading.Thread(
    target=lambda: AoDDS.build_partial_mipmap(jpegs, 16, 1, format="BC1", max_threads=int(sys.argv[3]))
)
worker.start()
worker.join()
print(proc.num_threads() - before)
"""


def _threads_created_by_one_partial_build(max_threads):
    # libomp pools finished workers process-wide and reaps them when the last
    # root exits, so each measurement runs in its own process.
    completed = subprocess.run(
        [sys.executable, "-I", "-c", _THREAD_DELTA_SCRIPT,
         os.path.dirname(TESTFILES), CHUNK_JPEG, str(max_threads)],
        capture_output=True, text=True, timeout=120, check=True,
    )
    return int(completed.stdout.strip())


def test_partial_mipmap_team_respects_thread_bound():
    pytest.importorskip("psutil")
    if (os.cpu_count() or 1) <= 4:
        pytest.skip("needs more than 4 cores to tell a bounded team from the default")
    bounded = _threads_created_by_one_partial_build(4)
    unbounded = _threads_created_by_one_partial_build(0)
    # A root with max_threads=4 creates at most 3 workers; the count can still
    # include the exiting root thread itself. The default team is
    # min(omp_get_max_threads(), 16 chunks) and creates many more.
    assert bounded <= 4 < unbounded, (bounded, unbounded)


def test_openmp_workers_do_not_spin_after_a_region():
    # Pins the behavior of the bundled libomp (KMP_BLOCKTIME=0 by default),
    # which the thread-count fix relies on. A runtime swap would show up here.
    if os.environ.get("KMP_BLOCKTIME") or os.environ.get("OMP_WAIT_POLICY"):
        pytest.skip("wait policy set by the environment")
    lib = _lib()
    if not hasattr(lib, "kmp_get_blocktime"):
        pytest.skip("not a libomp runtime")
    lib.kmp_get_blocktime.restype = ctypes.c_int
    seen = {}

    def read():
        seen["blocktime"] = lib.kmp_get_blocktime()

    worker = threading.Thread(target=read)
    worker.start()
    worker.join()
    assert seen["blocktime"] == 0
