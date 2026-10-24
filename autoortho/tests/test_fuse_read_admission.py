"""Live-tile admission on the FUSE read path.

Admission bounds how many tiles are under live build at once.  A read whose
bytes are already built allocates nothing, so it must not queue behind builds.
"""

import re
import threading
from collections import defaultdict

import pytest

from autoortho import autoortho_fuse


class _Tile:
    def __init__(self, resolved):
        self.resolved = resolved
        self.reads = []

    def has_resolved_bytes(self, offset, length):
        return self.resolved

    def read_dds_bytes(self, offset, length):
        self.reads.append((offset, length))
        return bytes([0xAB]) * length


class _Cacher:
    def __init__(self, tile):
        self.tile = tile
        self.peeked = 0

    def peek_tile(self, row, col, map_type, zoom):
        self.peeked += 1
        return self.tile

    def _get_tile(self, row, col, map_type, zoom):
        if self.tile is None:
            self.tile = _Tile(resolved=False)
        return self.tile


@pytest.fixture
def admission(monkeypatch):
    state = {"acquired": 0, "released": 0, "grant": True}

    def acquire(timeout):
        state["acquired"] += 1
        return state["grant"]

    def release():
        state["released"] += 1

    monkeypatch.setattr(autoortho_fuse.getortho, "acquire_live_tile_slot", acquire)
    monkeypatch.setattr(autoortho_fuse.getortho, "release_live_tile_slot", release)
    monkeypatch.setattr(
        autoortho_fuse.getortho, "is_shutdown_requested", lambda: False
    )
    return state


def _filesystem(tile):
    fs = autoortho_fuse.AutoOrtho.__new__(autoortho_fuse.AutoOrtho)
    fs.dds_re = re.compile(r".*/(\d+)[-_](\d+)[-_]((?!ZL)\S*)(\d{2}).dds")
    fs._tile_locks = defaultdict(threading.Lock)
    fs.tc = _Cacher(tile)
    fs._calculate_build_timeout = lambda: 5
    return fs


PATH = "/textures/26160_58160_BI16.dds"


def test_resolved_range_skips_admission(admission):
    tile = _Tile(resolved=True)
    fs = _filesystem(tile)

    data = fs.read(PATH, 32768, 11124736, 0)

    assert data == bytes([0xAB]) * 32768
    assert tile.reads == [(11124736, 32768)]
    assert admission["acquired"] == 0
    assert admission["released"] == 0


def test_unresolved_range_takes_and_releases_admission(admission):
    tile = _Tile(resolved=False)
    fs = _filesystem(tile)

    data = fs.read(PATH, 32768, 0, 0)

    assert len(data) == 32768
    assert admission["acquired"] == 1
    assert admission["released"] == 1


def test_missing_tile_takes_admission_before_creation(admission):
    fs = _filesystem(None)

    fs.read(PATH, 16384, 11157504, 0)

    assert admission["acquired"] == 1
    assert admission["released"] == 1
    assert fs.tc.tile.reads == [(11157504, 16384)]


def test_tile_replaced_between_peek_and_lookup_takes_admission(admission):
    peeked = _Tile(resolved=True)
    fs = _filesystem(peeked)
    replacement = _Tile(resolved=True)
    fs.tc._get_tile = lambda *args: replacement

    fs.read(PATH, 32768, 11124736, 0)

    assert replacement.reads == [(11124736, 32768)]
    assert admission["acquired"] == 1
    assert admission["released"] == 1


def test_admission_timeout_still_returns_fallback_bytes(admission):
    admission["grant"] = False
    tile = _Tile(resolved=False)
    fs = _filesystem(tile)

    data = fs.read(PATH, 32768, 11124736, 0)

    assert len(data) == 32768
    assert tile.reads == []
    assert admission["released"] == 0


def test_tile_lock_is_released_after_resolved_read(admission):
    tile = _Tile(resolved=True)
    fs = _filesystem(tile)

    fs.read(PATH, 32768, 11124736, 0)

    for lock in fs._tile_locks.values():
        assert lock.acquire(blocking=False)
        lock.release()
