"""Native control bridge contracts, independent of Qt, networking, and mounts."""
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

spec = importlib.util.spec_from_file_location('native_service', Path(__file__).parents[1] / 'native_service.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


@pytest.fixture
def setup(tmp_path):
    xplane = tmp_path / 'X-Plane 12'
    (xplane / 'Resources').mkdir(parents=True)
    (xplane / 'Custom Scenery').mkdir()
    scenery = tmp_path / 'scenery'
    (scenery / 'z_autoortho/scenery/z_ao_asi').mkdir(parents=True)
    (scenery / 'z_autoortho/asi_info.json').write_text(json.dumps(dict(id='asi', name='Asia', ver='1', totalsize=100)))
    config = tmp_path / 'config.ini'
    config.write_text(f'''[paths]
# Preserve this path comment.
xplane_path = {xplane}
scenery_path = {scenery}
cache_dir = {tmp_path / 'cache'}
download_dir = {tmp_path / 'downloads'}
[autoortho]
# Keep satellite imagery unchanged.
maptype_override = BI
max_zoom = 16
maxwait = 5.0
dynamic_zoom_steps = [{{'altitude_ft': 0, 'zoom_level': 16}}]
[cache]
file_cache_size = 50
[flightdata]
webui_port = 5847
xplane_udp_port = 49000
[general]
showconfig = True
''')
    return config, native.NativeService(config=config, executable='/not/launched')


def revision(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_snapshot_does_not_rewrite_settings(setup):
    config, service = setup
    before = config.read_bytes()
    state = service.snapshot()
    assert state['ready']
    assert state['status'] == 'stopped'
    assert state['regions'][0]['id'] == 'asi'
    assert state['revision'] == revision(config)
    assert config.read_bytes() == before


def test_save_preserves_unrelated_settings_comments_and_imagery(setup):
    config, service = setup
    state = service.save({'changes': {'autoortho.max_zoom': '17'}, 'revision': revision(config)})
    text = config.read_text()
    assert '# Preserve this path comment.' in text
    assert 'maptype_override = BI' in text
    assert 'max_zoom = 17' in text
    assert state['revision'] == revision(config)


@pytest.mark.parametrize('changes', [
    {'autoortho.max_zoom': '35'}, {'autoortho.max_zoom': 'bad'},
    {'cache.file_cache_size': '-2'}, {'general.showconfig': 'perhaps'},
    {'autoortho.maxwait': 'nan'}, {'autoortho.dynamic_zoom_steps': '[broken'},
    {'paths.cache_dir': '/tmp/cache\n[other]\nx = y'},
    {'flightdata.webui_port': '0'}, {'unknown.key': 'x'},
])
def test_invalid_settings_leave_file_unchanged(setup, changes):
    config, service = setup
    before = config.read_bytes()
    with pytest.raises(ValueError):
        service.save({'changes': changes, 'revision': revision(config)})
    assert config.read_bytes() == before


def test_external_edit_rejects_stale_save(setup):
    config, service = setup
    original = revision(config)
    config.write_text(config.read_text() + '\n# Edited elsewhere\n')
    with pytest.raises(ValueError, match='another app'):
        service.save({'changes': {'autoortho.max_zoom': '17'}, 'revision': original})
    assert 'max_zoom = 16' in config.read_text()


def test_external_mounts_are_not_owned_or_stopped(setup, monkeypatch):
    _, service = setup
    monkeypatch.setattr(native.os.path, 'ismount', lambda path: str(path).endswith('z_ao_asi'))
    assert service.snapshot()['status'] == 'streaming'
    assert not service.snapshot()['owned']
    assert service.stop() == {'stopped': True}
    with pytest.raises(ValueError, match='Another AutoOrtho'):
        service.start()


def test_settings_locked_while_engine_is_starting(setup):
    config, service = setup
    service.process = SimpleNamespace(poll=lambda: None)
    with pytest.raises(ValueError, match='Stop streaming'):
        service.save({'changes': {'autoortho.max_zoom': '17'}, 'revision': revision(config)})


def test_failed_engine_is_not_reported_as_streaming(setup):
    _, service = setup
    service.process = SimpleNamespace(poll=lambda: 3)
    assert service.snapshot()['status'] == 'failed'


def test_unmount_timeout_does_not_force_kill_engine(setup):
    _, service = setup
    class Process:
        terminated = False
        def poll(self): return None
        def terminate(self): self.terminated = True
        def wait(self, timeout): raise native.subprocess.TimeoutExpired('engine', timeout)
    service.process = Process()
    with pytest.raises(ValueError, match='not been force-quit'):
        service.stop()
    assert service.process.terminated


def test_no_regions_prevents_launch(setup):
    _, service = setup
    (service.path('scenery_path') / 'z_autoortho/scenery/z_ao_asi').rmdir()
    with pytest.raises(ValueError, match='setup checks'):
        service.start()


def test_unknown_operation_rejected(setup):
    _, service = setup
    with pytest.raises(ValueError, match='Unknown operation'):
        service.dispatch('execute', {'command': 'anything'})


def test_imagery_edit_preserves_other_tiles(setup, tmp_path, monkeypatch):
    _, service = setup
    monkeypatch.syspath_prepend(str(Path(__file__).parents[1]))
    service.imagery_path = tmp_path / 'custom-map.json'
    service.imagery_path.write_text(json.dumps({'version': 1, 'cells': {'34,135': 'BI'}}))
    result = service.imagery({'latitude': 35, 'longitude': 139, 'provider': 'APPLE'})
    assert result['cells'] == {'34,135': 'BI', '35,139': 'APPLE'}
    result = service.imagery({'latitude': 35, 'longitude': 139, 'provider': None})
    assert result['cells'] == {'34,135': 'BI'}


@pytest.mark.parametrize('params', [
    {'latitude': 91, 'longitude': 139, 'provider': 'BI'},
    {'latitude': 35, 'longitude': 139, 'provider': 'unknown'},
])
def test_invalid_imagery_edit_does_not_write(setup, tmp_path, monkeypatch, params):
    _, service = setup
    monkeypatch.syspath_prepend(str(Path(__file__).parents[1]))
    service.imagery_path = tmp_path / 'custom-map.json'
    with pytest.raises(ValueError):
        service.imagery(params)
    assert not service.imagery_path.exists()


def test_release_size_known_before_parsing():
    unparsed = SimpleNamespace(totalsize=0, release_dict={'assets': [{'size': 1500}, {'size': '500'}, {}]})
    assert native.release_size(unparsed) == 2000
    assert native.release_size(SimpleNamespace(totalsize=42)) == 42
    assert native.release_size(SimpleNamespace()) == 0


def test_installed_regions_use_catalog_display_names(setup):
    _, service = setup
    info = service.path('scenery_path') / 'z_autoortho/asi_info.json'
    info.write_text(json.dumps(dict(id='asi', name='Asia Ortho Set', ver='1', totalsize=100)))
    assert [region['name'] for region in service.installed()] == ['Asia']


def test_reports_found_in_home_relative_report_dir(setup, tmp_path, monkeypatch):
    config, service = setup
    monkeypatch.setenv('HOME', str(tmp_path))
    (tmp_path / 'ao-reports/performance-1').mkdir(parents=True)
    (tmp_path / 'ao-reports/performance-1/report.md').write_text('# report')
    config.write_text(config.read_text() + '[diagnostics]\nreport_dir = ~/ao-reports\n')
    assert [report['name'] for report in service.snapshot()['reports']] == ['performance-1']


def test_finished_tasks_are_capped_and_clearable(setup):
    _, service = setup
    service.tasks = {str(i): dict(id=str(i), state='complete') for i in range(5)}
    service.tasks['9'] = dict(id='9', state='running')
    service.prune_tasks(keep=2)
    assert list(service.tasks) == ['3', '4', '9']
    service.dispatch('tasks.clear', {})
    assert list(service.tasks) == ['9']


def test_unchanged_log_is_not_resent(setup, tmp_path, monkeypatch):
    _, service = setup
    monkeypatch.setenv('HOME', str(tmp_path))
    (tmp_path / '.autoortho-data/logs').mkdir(parents=True)
    (tmp_path / '.autoortho-data/logs/autoortho.log').write_text('started\n')
    first = service.logs()
    assert first['text'] == 'started\n'
    assert service.logs({'since': first['stamp']}) == {'stamp': first['stamp'], 'unchanged': True}


def test_region_name_survives_removal(setup):
    _, service = setup
    assert service.region_name('eur') == 'Europe'
    assert service.region_name('custom') == 'custom'


def test_update_installs_the_latest_release(setup, monkeypatch):
    _, service = setup
    calls = []
    region = SimpleNamespace(install_release=lambda progress_callback=None: calls.append('latest') or True)
    monkeypatch.setattr(service, 'manager', lambda: SimpleNamespace(regions={'asi': region}))
    task = service.dispatch('scenery', {'region': 'asi', 'action': 'update'})['task']
    service.pool.shutdown(wait=True)
    assert calls == ['latest']
    assert service.tasks[task]['state'] == 'complete' and service.tasks[task]['name'] == 'Asia'
