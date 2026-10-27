"""The X-Plane 12 water variant ``{row}_{col}_{maptype}{zoom}_w.dds``.

The variant serves the tile imagery as DXT5 with a constant alpha, so a
WATER_COLOR_MASK terrain can tint X-Plane water with the photo.
"""

import os
import shutil
import threading
from collections import OrderedDict, defaultdict

import numpy as np
import pytest

from autoortho import autoortho_fuse, getortho, pydds

TESTFILES = os.path.join(os.path.dirname(os.path.dirname(__file__)), "testfiles")
NORMAL = "/textures/0_0_BI16.dds"
WATER = "/textures/0_0_BI16_w.dds"
ALPHA = 40


class _OfflineGetter:
    """Chunk getter whose downloads never complete."""

    def submit(self, *args, **kwargs):
        return None

    def __getattr__(self, name):
        return lambda *args, **kwargs: 0


class _Cacher:
    def __init__(self, tile):
        self.tile = tile

    def peek_tile(self, row, col, map_type, zoom):
        return self.tile

    def _get_tile(self, row, col, map_type, zoom):
        return self.tile


@pytest.fixture
def fs(monkeypatch, tmp_path):
    """A FUSE filesystem over one ZL16 tile whose chunks sit in the cache."""
    monkeypatch.setattr(getortho, "dynamic_dds_cache", None)
    monkeypatch.setattr(getortho, "chunk_getter", _OfflineGetter())
    monkeypatch.setattr(getortho.CFG.autoortho, "suspend_maxwait", False)
    monkeypatch.setattr(getortho.CFG.pydds, "format", "BC1")
    monkeypatch.setattr(getortho.CFG.pydds, "water_alpha", ALPHA)
    monkeypatch.setattr(getortho.Tile, "maxchunk_wait", 0.05)
    jpeg = os.path.join(TESTFILES, "test_tile_small.jpg")
    # Every mipmap down to the 256 px one has its own cached chunks.
    for mipmap in range(5):
        side = 16 >> mipmap
        for col in range(side):
            for row in range(side):
                shutil.copyfile(
                    jpeg, tmp_path / f"{col}_{row}_{16 - mipmap}_BI.jpg"
                )
    tile = getortho.Tile(0, 0, "BI", 16, cache_dir=str(tmp_path), max_zoom=16)

    filesystem = autoortho_fuse.AutoOrtho.__new__(autoortho_fuse.AutoOrtho)
    filesystem.dds_re = autoortho_fuse.DDS_PATH_RE
    filesystem.dsf_re = autoortho_fuse.re.compile(r".*/[-+]\d+[-+]\d+.dsf")
    filesystem._tile_locks = defaultdict(threading.Lock)
    filesystem._calculate_build_timeout = lambda: 5
    filesystem._ft_started = True
    filesystem._size_cache = OrderedDict({(0, 0, "BI", 16): tile.dds.total_size})
    filesystem._size_cache_max = 16
    filesystem.tc = _Cacher(tile)
    return filesystem


def _water_layout():
    """Mipmap layout of a 4096 px DXT5 texture."""
    return pydds.DDS(4096, 4096, dxt_format="BC3").mipmap_list


def _colour_rgb(block):
    """Decode the 16 texels of an 8-byte colour block in four-colour mode."""
    c0 = int.from_bytes(block[0:2], "little")
    c1 = int.from_bytes(block[2:4], "little")

    def rgb(c):
        return np.array(
            [((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31]
        )

    p0, p1 = rgb(c0), rgb(c1)
    palette = [p0, p1, (2 * p0 + p1) // 3, (p0 + 2 * p1) // 3]
    if c0 <= c1:
        palette[2:] = [(p0 + p1) // 2, np.zeros(3, dtype=int)]
    bits = int.from_bytes(block[4:8], "little")
    return [palette[(bits >> (2 * i)) & 3] for i in range(16)]


def _water_reference(normal):
    """Expected water bytes for whole tile DDS blocks after the header."""
    return b"".join(
        bytes((ALPHA, ALPHA)) + bytes(6) + normal[i:i + 8]
        for i in range(0, len(normal), 8)
    )


def test_water_name_matches_the_tile_of_the_normal_name():
    water = autoortho_fuse.DDS_PATH_RE.match("/a/textures/28432_53392_BI16_w.dds")
    normal = autoortho_fuse.DDS_PATH_RE.match("/a/textures/28432_53392_BI16.dds")

    assert water.groups() == ("28432", "53392", "BI", "16")
    assert normal.groups() == ("28432", "53392", "BI", "16")
    # Baked water textures stay real files.
    assert not autoortho_fuse.DDS_PATH_RE.match(
        "/a/textures/28432_53392_BI16_xp12_water.dds"
    )


def test_water_header_is_dxt5_with_every_mipmap(fs):
    header = fs.read(WATER, 128, 0, 0)
    size = fs.getattr(WATER)["st_size"]

    assert header[:4] == b"DDS "
    assert header[84:88] == b"DXT5"
    width = int.from_bytes(header[16:20], "little")
    height = int.from_bytes(header[12:16], "little")
    assert (width, height) == (4096, 4096)
    assert int.from_bytes(header[28:32], "little") == 13
    assert int.from_bytes(header[20:24], "little") == 4096 * 4096
    expected = 128 + sum(
        max(1, (4096 >> m) * (4096 >> m) // 16) * 16 for m in range(13)
    )
    assert size == expected == 22369776


def test_normal_name_is_unchanged(fs):
    header = fs.read(NORMAL, 128, 0, 0)

    assert header[84:88] == b"DXT1"
    assert int.from_bytes(header[20:24], "little") == 4096 * 4096 // 2
    assert fs.getattr(NORMAL)["st_size"] == 11184952


def test_water_alpha_is_constant(fs):
    size = fs.getattr(WATER)["st_size"]
    data = np.frombuffer(fs.read(WATER, size - 128, 128, 0), dtype=np.uint8)
    blocks = data.reshape(-1, 16)

    assert len(blocks) == (size - 128) // 16
    assert (blocks[:, 0] == ALPHA).all() and (blocks[:, 1] == ALPHA).all()
    # Index 0 everywhere selects alpha0 for every texel.
    assert not blocks[:, 2:8].any()


def test_water_colour_matches_the_normal_texture(fs):
    mm0 = _water_layout()[0]
    water = fs.read(WATER, mm0.length, mm0.startpos, 0)
    normal = fs.read(NORMAL, mm0.length // 2, 128, 0)

    worst = 0
    for block in range(0, len(normal) // 8, 97):
        want = _colour_rgb(normal[block * 8:block * 8 + 8])
        got = _colour_rgb(water[block * 16 + 8:block * 16 + 16])
        worst = max(worst, max(int(abs(a - b).max()) for a, b in zip(want, got)))
    assert worst <= 8
    # The imagery is the photo, not the missing colour.
    assert len(set(normal[i:i + 4] for i in range(0, len(normal), 8))) > 1000


def _read_cases():
    layout = _water_layout()
    end = layout[-1].endpos
    return {
        "header": (0, 128),
        "header_and_rows": (0, 65536),
        "unaligned_mm0": (128 + 16 * 1000 + 5, 4099),
        "mid_mm2": (layout[2].startpos + layout[2].length // 2 - 7, 32768),
        "mm3_into_mm4": (layout[3].endpos - 100, 300),
        "tail_after_mm4": (layout[5].startpos, end - layout[5].startpos),
        "past_end": (end - 10, 4096),
    }


@pytest.mark.parametrize("case", list(_read_cases()))
def test_partial_water_read_serves_the_tile_blocks(fs, case):
    offset, length = _read_cases()[case]

    got = fs.read(WATER, length, offset, 0)

    end = _water_layout()[-1].endpos
    # Like the tile DDS, a read past the end returns padding.
    assert len(got) == length
    if offset < 128:
        header = fs.read(NORMAL, 128, 0, 0)
        assert got[:min(length, 128)] == (
            header[:20]
            + (4096 * 4096).to_bytes(4, "little")
            + header[24:84]
            + b"DXT5"
            + header[88:]
        )[:min(length, 128)]
    if offset + length > 128:
        first = (max(offset, 128) - 128) // 16
        last = -(-(min(offset + length, end) - 128) // 16)
        normal = fs.read(NORMAL, (last - first) * 8, 128 + first * 8, 0)
        expected = _water_reference(normal)
        skip = max(offset, 128) - (128 + first * 16)
        body = got[max(0, 128 - offset):end - offset]
        assert len(body) == min(offset + length, end) - max(offset, 128)
        assert body == expected[skip:skip + len(body)]
        missing = pydds.get_fallback_bytes(8, 8)
        assert any(
            normal[i:i + 8] != missing for i in range(0, len(normal), 8)
        )


def test_water_tail_after_partial_last_mipmap_read_is_imagery(fs):
    layout = _water_layout()
    # X-Plane pages a far texture: a block read that ends inside mipmap 4.
    fs.read(WATER, 4096, layout[4].endpos - 4096, 0)

    tail = fs.read(WATER, layout[-1].endpos - layout[5].startpos, layout[5].startpos, 0)

    missing = pydds.get_fallback_bytes(8, 8)
    colour = [tail[i + 8:i + 16] for i in range(0, len(tail), 16)]
    assert all(block != missing for block in colour)
