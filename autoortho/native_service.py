"""JSON-lines control bridge for the macOS SwiftUI app.

Reading state never imports the engine or rewrites configuration. Engine work
runs in the existing frozen helper, preserving FUSE/process-supervisor behavior.
The only transport is the parent app's inherited stdin/stdout pipes.
"""
from __future__ import annotations

import concurrent.futures
import ast
import configparser
import contextlib
import hashlib
try:
    import fcntl
except ImportError:  # The module can be imported by cross-platform test runners.
    fcntl = None
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


def read_config(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    text = Path(path).read_text()
    parser.read_string(text)
    return parser, text


def settings_schema(text):
    """Expose existing settings and their authored help, including future keys."""
    section, comments, result = '', [], []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            section, comments = stripped[1:-1], []
        elif stripped.startswith(('#', ';')):
            comments.append(stripped[1:].strip())
        elif '=' in line and section:
            key, value = map(str.strip, line.split('=', 1))
            kind = 'bool' if value.lower() in {'true', 'false'} else 'text'
            if re.fullmatch(r'[+-]?\d+', value):
                kind = 'integer'
            elif re.fullmatch(r'[+-]?\d+\.\d+', value):
                kind = 'number'
            result.append(dict(id=f'{section}.{key}', section=section, key=key,
                               value=value, help=' '.join(comments), kind=kind))
            comments = []
        elif not stripped:
            comments = []
    return result


def update_config(path, changes, revision):
    """Update only requested keys, preserve comments, and reject stale edits."""
    path = Path(path)
    parser, text = read_config(path)
    if hashlib.sha256(text.encode()).hexdigest() != revision:
        raise ValueError('Settings changed in another app. Reload them before saving.')
    schema = {item['id']: item for item in settings_schema(text)}
    for name, value in changes.items():
        if name not in schema or not isinstance(value, str):
            raise ValueError(f'Unknown setting: {name}')
        if any(ch in value for ch in ('\n', '\r', '\0')):
            raise ValueError('A setting must be a single line.')
        if schema[name]['kind'] == 'bool' and value.lower() not in {'true', 'false'}:
            raise ValueError(f'{name} must be true or false.')
        if schema[name]['kind'] in {'integer', 'number'}:
            try:
                number = int(value) if schema[name]['kind'] == 'integer' else float(value)
                if not math.isfinite(number):
                    raise ValueError()
            except ValueError:
                raise ValueError(f'{name} must be a finite number.') from None
        if schema[name]['value'].startswith(('[', '{')):
            try:
                old_literal = ast.literal_eval(schema[name]['value'])
                new_literal = ast.literal_eval(value)
                if type(old_literal) is not type(new_literal):
                    raise ValueError()
            except (SyntaxError, ValueError):
                raise ValueError(f'{name} must contain a valid {type(old_literal).__name__ if "old_literal" in locals() else "value"}.') from None
        if name in {'flightdata.webui_port', 'flightdata.xplane_udp_port'}:
            if not value.isdecimal() or not 1024 <= int(value) <= 65535:
                raise ValueError('Ports must be between 1024 and 65535.')
        ranges = {'autoortho.min_zoom': (1, 20), 'autoortho.max_zoom': (12, 20),
                  'autoortho.max_zoom_near_airports': (12, 20),
                  'cache.file_cache_size': (10, 10000), 'cache.cache_mem_limit': (2, 1024),
                  'pydds.water_alpha': (0, 255)}
        if name in ranges:
            low, high = ranges[name]
            if not value.isdecimal() or not low <= int(value) <= high:
                raise ValueError(f'{name} must be between {low} and {high}.')
    section, lines = '', []
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            section = stripped[1:-1]
        elif '=' in line and not stripped.startswith(('#', ';')):
            key = line.split('=', 1)[0].strip()
            name = f'{section}.{key}'
            if name in changes:
                line = f'{key} = {changes[name]}\n'
        lines.append(line)
    updated = ''.join(lines)
    check = configparser.ConfigParser(interpolation=None, strict=False)
    check.read_string(updated)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.autoortho-', delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(updated)
            file.flush()
            os.fsync(file.fileno())
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


class NativeService:
    def __init__(self, config=None, executable=None):
        self.config_path = Path(config or Path.home() / '.autoortho')
        self.executable = executable or sys.executable
        self.process = None
        self.started = 0
        self.engine_lock = None
        self.lock = threading.RLock()
        self.tasks = {}
        self.catalog = []
        self.plan = None
        self.imagery_path = Path.home() / '.autoortho-data/custom_map.json'
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)

    def config(self):
        return read_config(self.config_path)[0]

    def path(self, key):
        return Path(self.config().get('paths', key)).expanduser()

    def installed(self):
        result = []
        for path in sorted((self.path('scenery_path') / 'z_autoortho').glob('*_info.json')):
            try:
                item = json.loads(path.read_text())
                result.append(dict(id=item.get('id', path.stem.removesuffix('_info')),
                                   name=item.get('name', path.stem), version=item.get('ver', ''),
                                   bytes=item.get('totalsize', 0), installed=True))
            except (ValueError, OSError):
                continue
        return result

    def mounts(self):
        custom = self.path('xplane_path') / 'Custom Scenery'
        root = self.path('scenery_path') / 'z_autoortho/scenery'
        return [dict(name=p.name, path=str(custom / p.name), mounted=os.path.ismount(custom / p.name))
                for p in sorted(root.iterdir()) if p.is_dir()] if root.is_dir() else []

    def snapshot(self):
        cfg, text = read_config(self.config_path)
        mounts = self.mounts()
        with self.lock:
            owned = self.process is not None and self.process.poll() is None
            code = self.process.poll() if self.process else None
            tasks = [dict(value) for value in self.tasks.values()]
        mounted = bool(mounts) and all(item['mounted'] for item in mounts)
        status = 'streaming' if mounted else ('starting' if owned else 'stopped')
        if code not in (None, 0) and not owned:
            status = 'failed'
        cache = self.path('cache_dir')
        ancestor = cache
        while not ancestor.exists() and ancestor != ancestor.parent:
            ancestor = ancestor.parent
        free = shutil.disk_usage(ancestor).free
        xplane = self.path('xplane_path')
        checks = [dict(id='xplane', title='X-Plane installation', ok=(xplane / 'Resources').is_dir(),
                       detail=str(xplane)),
                  dict(id='scenery', title='Scenery installed', ok=bool(mounts),
                       detail=f'{len(mounts)} region mount' + ('s' if len(mounts) != 1 else '')),
                  dict(id='storage', title='Available storage', ok=free >= 2 * 1024**3,
                       detail=f'{free / 1024**3:.1f} GB available')]
        log_dir = Path.home() / '.autoortho-data/logs'
        report_dir = Path(cfg.get('diagnostics', 'report_dir', fallback=str(Path.home() / '.autoortho-data/reports')))
        reports = [dict(id=str(p), name=p.parent.name, path=str(p), modified=p.stat().st_mtime)
                   for p in report_dir.glob('performance-*/report.md')]
        reports.sort(key=lambda item: item['modified'], reverse=True)
        return dict(status=status, owned=owned, ready=all(c['ok'] for c in checks), checks=checks,
                    mounts=mounts, settings=settings_schema(text),
                    revision=hashlib.sha256(text.encode()).hexdigest(), regions=self.installed(),
                    catalog=self.catalog, tasks=tasks, freeBytes=free, reports=reports[:20],
                    logPath=str(log_dir / 'autoortho.log'), reportsPath=str(report_dir),
                    port=cfg.getint('flightdata', 'webui_port', fallback=5847), plan=self.plan,
                    engineExit=code)

    def start(self):
        with self.lock:
            if self.process and self.process.poll() is None:
                raise ValueError('Streaming is already starting or running.')
            if self.engine_lock is not None:
                self.engine_lock.close()
                self.engine_lock = None
            if any(item['mounted'] for item in self.mounts()):
                raise ValueError('Another AutoOrtho instance owns these mounts. Stop it first.')
            if not self.snapshot()['ready']:
                raise ValueError('Complete the setup checks before starting streaming.')
            if any(task['state'] == 'running' for task in self.tasks.values()):
                raise ValueError('Wait for scenery operations to finish before streaming.')
            env = dict(os.environ, PYINSTALLER_RESET_ENVIRONMENT='1', AO_NATIVE_ENGINE='1')
            env.pop('AO_RUN_MODE', None)
            log = Path.home() / '.autoortho-data/logs/native-engine.log'
            log.parent.mkdir(parents=True, exist_ok=True)
            lock = (log.parent / 'native-engine.lock').open('a')
            try:
                if fcntl is None:
                    raise ValueError('The native engine launcher requires macOS.')
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with log.open('ab') as output:
                    self.process = subprocess.Popen([self.executable, '--native-engine'], env=env,
                                                    stdout=output, stderr=subprocess.STDOUT)
                self.engine_lock = lock
            except BlockingIOError:
                lock.close()
                raise ValueError('Another native AutoOrtho instance is starting its engine.') from None
            except Exception:
                lock.close()
                raise
            self.started = time.monotonic()
        return {'started': True}

    def stop(self):
        with self.lock:
            process = self.process
        if process is None:
            # Observing a legacy app's mounts does not transfer their ownership.
            return {'stopped': True}
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                raise ValueError('The engine is still unmounting. It has not been force-quit.') from None
        if any(item['mounted'] for item in self.mounts()):
            raise ValueError('Scenery remains mounted. See Diagnostics before quitting.')
        if self.engine_lock is not None:
            self.engine_lock.close()
            self.engine_lock = None
        return {'stopped': True}

    def save(self, params):
        with self.lock:
            if (self.process and self.process.poll() is None) or any(m['mounted'] for m in self.mounts()):
                raise ValueError('Stop streaming before changing engine settings.')
            update_config(self.config_path, params['changes'], params['revision'])
        return self.snapshot()

    def logs(self):
        path = Path.home() / '.autoortho-data/logs/autoortho.log'
        if not path.exists():
            return {'text': 'No log yet. Start streaming to record activity.'}
        with path.open('rb') as file:
            file.seek(max(0, path.stat().st_size - 96000))
            return {'text': file.read().decode('utf-8', errors='replace')}

    @contextlib.contextmanager
    def engine_imports(self):
        # Config reads during catalog inspection must not rewrite defaults.
        previous = os.environ.get('AO_RUN_MODE')
        os.environ['AO_RUN_MODE'] = 'mount_worker'
        try:
            yield
        finally:
            if previous is None:
                os.environ.pop('AO_RUN_MODE', None)
            else:
                os.environ['AO_RUN_MODE'] = previous

    def manager(self):
        with self.engine_imports():
            import downloader
            import aoconfig
            aoconfig.CFG.load()
            manager = downloader.OrthoManager(extract_dir=str(self.path('scenery_path')),
                                              download_dir=str(self.path('download_dir')))
            manager.find_regions()
        return manager

    def refresh_catalog(self):
        manager = self.manager()
        items = []
        for key, region in manager.regions.items():
            latest = region.get_latest_release()
            items.append(dict(id=key, name=getattr(latest, 'name', key), version=latest.ver,
                              installed=region.local_rel is not None,
                              bytes=getattr(latest, 'totalsize', 0) or 0))
        with self.lock:
            self.catalog = items
        return {'regions': items}

    def scenery_task(self, action, region_id):
        if action not in {'install', 'uninstall', 'seasons', 'restore', 'roughness', 'restore_roughness'}:
            raise ValueError('Unknown scenery action.')
        with self.lock:
            if any(m['mounted'] for m in self.mounts()) or (self.process and self.process.poll() is None):
                raise ValueError('Stop streaming before modifying scenery.')
            if any(task['state'] == 'running' for task in self.tasks.values()):
                raise ValueError('A scenery operation is already running.')
            task_id = str(time.time_ns())
            self.tasks[task_id] = dict(id=task_id, title=f'{action.capitalize()} {region_id}',
                                       state='running', message='Preparing…', progress=None)

        def run():
            def progress(payload):
                with self.lock:
                    task = self.tasks[task_id]
                    task['message'] = str(payload.get('status', payload.get('message', payload.get('stage', 'Working…'))))
                    percent = payload.get('overall_pcnt', payload.get('pcnt_done', payload.get('percent')))
                    if isinstance(percent, (int, float)):
                        task['progress'] = max(0, min(1, percent / 100))
            try:
                manager = self.manager()
                region = manager.regions.get(region_id)
                if region is None:
                    raise ValueError('This region is unavailable in the current catalog.')
                if action == 'install':
                    success = region.install_release(progress_callback=progress)
                    # install_release returns None for an already-installed version.
                    if success is False:
                        raise ValueError('Scenery installation failed. See Diagnostics.')
                elif action == 'uninstall':
                    if region.local_rel is None or not region.local_rel.uninstall():
                        raise ValueError('Scenery could not be removed.')
                elif action in {'roughness', 'restore_roughness'}:
                    with self.engine_imports():
                        from utils.ter_utils import ter_utils
                    if action == 'roughness':
                        amount = self.config().getfloat('terrain', 'default_roughness', fallback=1.0)
                        success = ter_utils.patch_terrain_to_package('z_ao_' + region_id, amount, progress_callback=progress)
                    else:
                        success = ter_utils.restore_ter_files('z_ao_' + region_id, progress_callback=progress)
                    if success is False:
                        raise ValueError('Terrain reflectivity operation failed. See Diagnostics.')
                else:
                    with self.engine_imports():
                        from utils.dsf_utils import dsf_utils
                    operation = dsf_utils.add_seasons_to_package if action == 'seasons' else dsf_utils.restore_default_dsfs
                    if operation('z_ao_' + region_id, progress_callback=progress) is False:
                        raise ValueError('Scenery operation failed. See Diagnostics.')
                with self.lock:
                    self.tasks[task_id].update(state='complete', message='Complete', progress=1)
            except Exception as error:
                with self.lock:
                    self.tasks[task_id].update(state='failed', message=str(error))
        self.pool.submit(run)
        return {'task': task_id}

    def flight(self, params):
        user = str(params.get('user', '')).strip()
        if not user or not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', user):
            raise ValueError('Enter a SimBrief pilot ID or username.')
        import ssl
        import certifi
        from urllib.parse import urlencode
        query = urlencode({'userid' if user.isdecimal() else 'username': user, 'json': '1'})
        request = urllib.request.Request('https://www.simbrief.com/api/xml.fetcher.php?' + query,
                                         headers={'User-Agent': 'AutoOrtho-Native'})
        with urllib.request.urlopen(request, timeout=20, context=ssl.create_default_context(cafile=certifi.where())) as response:
            data = json.load(response)
        if str(data.get('fetch', {}).get('status', '')).lower().startswith('error'):
            raise ValueError(str(data['fetch']['status']))
        self.plan = data
        self.publish_plan()
        return {'plan': data}

    def publish_plan(self):
        if self.process and self.process.poll() is None and self.plan:
            port = self.config().getint('flightdata', 'webui_port', fallback=5847)
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/native/flight-plan',
                                             data=json.dumps(self.plan).encode(),
                                             headers={'Content-Type': 'application/json'}, method='POST')
            with urllib.request.urlopen(request, timeout=5):
                pass

    def imagery(self, params):
        from utils.custom_map import CustomMapConfig
        config = CustomMapConfig(path=str(self.imagery_path))
        if 'latitude' not in params:
            return {'cells': config.get_all_cells()}
        lat, lon = int(params['latitude']), int(params['longitude'])
        if not (-90 <= lat < 90 and -180 <= lon < 180):
            raise ValueError('Choose a valid one-degree scenery tile.')
        provider = params.get('provider')
        if provider not in {None, 'BI', 'NAIP', 'EOX', 'USGS', 'Firefly', 'GO2', 'ARC', 'YNDX', 'APPLE'}:
            raise ValueError('Unknown imagery provider.')
        key = f'{lat},{lon}'
        if any(item['mounted'] for item in self.mounts()):
            if not self.process or self.process.poll() is not None:
                raise ValueError('Change imagery in the AutoOrtho instance managing your mounts.')
            port = self.config().getint('flightdata', 'webui_port', fallback=5847)
            body = {'cells': {key: provider}} if provider else {'keys': [key]}
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/custommap/cells',
                                             data=json.dumps(body).encode(), method='POST' if provider else 'DELETE',
                                             headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=5):
                pass
        elif provider:
            config.set_cells({key: provider})
        else:
            config.remove_cells([key])
        return {'cells': CustomMapConfig(path=str(self.imagery_path)).get_all_cells()}

    def dispatch(self, method, params):
        if method == 'snapshot':
            return self.snapshot()
        if method == 'settings.save':
            return self.save(params)
        if method == 'streaming.start':
            return self.start()
        if method == 'streaming.stop':
            return self.stop()
        if method == 'logs':
            return self.logs()
        if method == 'catalog':
            return self.refresh_catalog()
        if method == 'scenery':
            return self.scenery_task(params['action'], params['region'])
        if method == 'flight':
            return self.flight(params)
        if method == 'flight.publish':
            self.publish_plan()
            return {'published': True}
        if method == 'imagery':
            return self.imagery(params)
        if method == 'shutdown':
            return self.stop()
        raise ValueError('Unknown operation.')


def install_flight_routes():
    """Register a loopback-only route on the engine's existing flight server."""
    import flighttrack
    from flask import request, jsonify
    import aostats
    from utils.simbrief_flight import simbrief_flight_manager

    @flighttrack.app.post('/api/native/flight-plan')
    def native_flight_plan():
        if request.remote_addr not in {'127.0.0.1', '::1'}:
            return jsonify(error='Local access only'), 403
        data = request.get_json()
        if not isinstance(data, dict) or not isinstance(data.get('navlog'), dict):
            return jsonify(error='Invalid flight plan'), 400
        simbrief_flight_manager.load_flight_data(data)
        snapshot = {'origin': data.get('origin', {}), 'destination': data.get('destination', {}),
                    'general': {'initial_altitude': data.get('general', {}).get('initial_altitude', 0)},
                    'navlog': {'fix': list(data.get('navlog', {}).get('fix', []))[:512]}}
        aostats.set_stat('simbrief_route_snapshot', snapshot)
        aostats.set_stat('simbrief_route_generation', int(time.time() * 1000))
        aostats.set_stat('simbrief_route_enabled', True)
        return jsonify(ok=True)


def main():
    service = NativeService()
    output_lock = threading.Lock()
    output = sys.stdout
    # Third-party libraries sometimes print; stdout belongs exclusively to JSON RPC.
    sys.stdout = sys.stderr

    def respond(request):
        response = {'id': request.get('id')}
        try:
            response['result'] = service.dispatch(request['method'], request.get('params', {}))
        except Exception as error:
            response['error'] = str(error)
        with output_lock:
            output.write(json.dumps(response, default=str) + '\n')
            output.flush()

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as requests:
        try:
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise ValueError('Request must be an object.')
                    requests.submit(respond, request)
                except ValueError as error:
                    with output_lock:
                        output.write(json.dumps({'id': None, 'error': str(error)}) + '\n')
                        output.flush()
        finally:
            try:
                service.stop()
            except Exception as error:
                print(f'Engine shutdown: {error}', file=sys.stderr)
    service.pool.shutdown(wait=True)


if __name__ == '__main__':
    main()
