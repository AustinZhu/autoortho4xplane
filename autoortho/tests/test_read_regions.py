"""Behaviour of one X-Plane read that spans several DDS regions.

The NFS client reads 32 KB blocks aligned to 16 KB pages while the 128-byte
DDS header keeps every mipmap boundary unaligned.  The offsets below are the
ones X-Plane produces for a 4096x4096 BC1 tile: the header block and the block
that straddles the mipmap 3/4 boundary.
"""

import threading
import time

import pytest

from autoortho import getortho


HEADER_BLOCK = (0, 32768)
STRADDLE_BLOCK = (11124736, 32768)


@pytest.fixture
def tile(tmp_path):
    return getortho.Tile(0, 0, "BI", 16, cache_dir=str(tmp_path), max_zoom=16)


def _record_region_calls(monkeypatch, tile, barrier=None, fail_on=None):
    calls = []
    lock = threading.Lock()

    def _meet():
        if barrier is not None:
            barrier.wait()

    def fake_get_bytes(offset, length, time_budget=None):
        with lock:
            calls.append(("bytes", offset, length))
        if fail_on == ("bytes", offset):
            raise RuntimeError("region build failed")
        _meet()
        return True

    def fake_get_mipmap(mipmap=0, time_budget=None):
        with lock:
            calls.append(("mipmap", mipmap))
        if fail_on == ("mipmap", mipmap):
            raise RuntimeError("region build failed")
        _meet()
        return True

    monkeypatch.setattr(tile, "get_bytes", fake_get_bytes)
    monkeypatch.setattr(tile, "get_mipmap", fake_get_mipmap)
    return calls


def test_tile_layout_matches_xplane_offsets(tile):
    mm3, mm4 = tile.dds.mipmap_list[3], tile.dds.mipmap_list[4]
    assert tile.dds.total_size == 11184952
    assert mm3.endpos == mm4.startpos == 11141248
    start, length = STRADDLE_BLOCK
    assert mm3.startpos <= start < mm3.endpos
    assert mm4.startpos < start + length < mm4.endpos


def test_straddle_read_builds_both_regions_concurrently(monkeypatch, tile):
    # A serialized implementation cannot have both builds inside the barrier
    # at once, so the second one raises BrokenBarrierError instead of hanging.
    barrier = threading.Barrier(2, timeout=5)
    calls = _record_region_calls(monkeypatch, tile, barrier=barrier)
    start, length = STRADDLE_BLOCK
    mm4_start = tile.dds.mipmap_list[4].startpos

    data = tile.read_dds_bytes(start, length)

    assert len(data) == length
    assert sorted(calls) == sorted([
        ("bytes", start, mm4_start - start),
        ("bytes", mm4_start, start + length - mm4_start),
    ])


def test_header_block_still_requests_a_real_mipmap_zero_build(monkeypatch, tile):
    # The bytes after the header may be consumed from the kernel page cache in
    # the same open, so they must be built for real rather than served as a
    # placeholder.
    calls = _record_region_calls(monkeypatch, tile)
    start, length = HEADER_BLOCK

    data = tile.read_dds_bytes(start, length)

    assert len(data) == length
    assert calls == [("bytes", 128, length - 128)]


def test_single_region_read_runs_inline_with_exact_range(monkeypatch, tile):
    calls = _record_region_calls(monkeypatch, tile)
    mm0 = tile.dds.mipmap_list[0]
    offset = mm0.startpos + 3 * 524288 + 4096

    tile.read_dds_bytes(offset, 32768)

    assert calls == [("bytes", offset, 32768)]


def test_full_mipmap_region_uses_get_mipmap(monkeypatch, tile):
    calls = _record_region_calls(monkeypatch, tile)
    mm4 = tile.dds.mipmap_list[4]

    tile.read_dds_bytes(mm4.startpos, mm4.length + 4096)

    assert sorted(calls) == [("bytes", mm4.endpos, 4096), ("mipmap", 4)]


def test_region_build_failure_propagates_after_all_regions_ran(monkeypatch, tile):
    start, length = STRADDLE_BLOCK
    mm4_start = tile.dds.mipmap_list[4].startpos
    calls = _record_region_calls(
        monkeypatch, tile, fail_on=("bytes", mm4_start)
    )

    with pytest.raises(RuntimeError):
        tile.read_dds_bytes(start, length)

    assert len(calls) == 2


def test_returned_bytes_reflect_data_written_by_region_builds(monkeypatch, tile):
    mm3, mm4 = tile.dds.mipmap_list[3], tile.dds.mipmap_list[4]
    marker3 = bytes([0x33]) * 16
    marker4 = bytes([0x44]) * 16

    def fake_get_bytes(offset, length, time_budget=None):
        if offset < mm4.startpos:
            tile.dds.write_mipmap_at(3, mm3.length - 16, marker3)
        else:
            tile.dds.write_mipmap_at(4, 0, marker4)
        return True

    monkeypatch.setattr(tile, "get_bytes", fake_get_bytes)
    start, length = STRADDLE_BLOCK

    data = tile.read_dds_bytes(start, length)

    boundary = mm4.startpos - start
    assert data[boundary - 16:boundary] == marker3
    assert data[boundary:boundary + 16] == marker4


def test_slow_region_worker_is_abandoned_after_the_join_margin(monkeypatch, tile):
    class _ExhaustedBudget:
        remaining = 0.0
        exhausted = True

        def begin_read(self):
            pass

        def end_read(self):
            pass

    bumped = []
    monkeypatch.setattr(getortho, "bump", lambda key, n=1: bumped.append(key))
    monkeypatch.setattr(getortho, "_READ_REGION_JOIN_MARGIN", 0.2)
    monkeypatch.setattr(tile, "get_maxwait", lambda: 0.0)
    monkeypatch.setattr(
        tile, "_get_or_create_tile_time_budget", lambda: _ExhaustedBudget()
    )
    mm4_start = tile.dds.mipmap_list[4].startpos
    finished = threading.Event()

    def fake_get_bytes(offset, length, time_budget=None):
        if offset >= mm4_start:
            time.sleep(1.0)
            finished.set()
        return True

    monkeypatch.setattr(tile, "get_bytes", fake_get_bytes)
    start, length = STRADDLE_BLOCK

    began = time.monotonic()
    data = tile.read_dds_bytes(start, length)
    elapsed = time.monotonic() - began

    assert len(data) == length
    assert elapsed < 0.9
    assert "read_region_join_timeout" in bumped
    assert finished.wait(timeout=3)


def test_saturated_pool_falls_back_to_inline_builds(monkeypatch, tile):
    permits = []
    while getortho._read_region_capacity.acquire(blocking=False):
        permits.append(True)
    try:
        calls = _record_region_calls(monkeypatch, tile)
        start, length = STRADDLE_BLOCK
        tile.read_dds_bytes(start, length)
        assert len(calls) == 2
    finally:
        for _ in permits:
            getortho._read_region_capacity.release()


def test_has_resolved_bytes_requires_every_overlapped_mipmap(tile):
    start, length = STRADDLE_BLOCK
    mm3, mm4 = tile.dds.mipmap_list[3], tile.dds.mipmap_list[4]

    assert not tile.has_resolved_bytes(start, length)
    mm4.retrieved = True
    assert not tile.has_resolved_bytes(start, length)
    mm3.retrieved = True
    assert tile.has_resolved_bytes(start, length)
    assert tile.has_resolved_bytes(mm4.startpos, 16)
    assert not tile.has_resolved_bytes(0, 32768)
    assert not tile.has_resolved_bytes(start, 0)


def test_has_resolved_bytes_ignores_partially_written_rows(tile):
    mm4 = tile.dds.mipmap_list[4]
    tile.dds.write_mipmap_at(4, 0, bytes(64))

    assert mm4.retrieved is False
    assert not tile.has_resolved_bytes(mm4.startpos, 64)


def test_has_resolved_bytes_is_false_without_dds(tile):
    tile.dds.mipmap_list[4].retrieved = True
    offset = tile.dds.mipmap_list[4].startpos
    tile.dds = None

    assert not tile.has_resolved_bytes(offset, 16)


def test_peek_tile_does_not_create_or_touch(tmp_path):
    tc = getortho.TileCacher(str(tmp_path))
    try:
        assert tc.peek_tile(0, 0, "BI", 16) is None
        assert tc.tiles == {}
        opened = tc._open_tile(0, 0, "BI", 16)
        assert tc.peek_tile(0, 0, "BI", 16) is opened
    finally:
        tc._close_tile(0, 0, "BI", 16)
