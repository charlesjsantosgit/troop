#!/usr/bin/env python3
"""Exercise shared societies over actual loopback ENet with durable restart."""
import argparse
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    folder = Path(tempfile.mkdtemp(prefix='troop-frontier-network-'))
    project = args.project.resolve()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    children = []
    handles = []

    def start(role, label=None):
        path = folder / f'{label or role}.log'
        handle = path.open('wb')
        handles.append(handle)
        env = os.environ.copy()
        for key in ['TROOP_ADMIN_KEY', 'TROOP_ADMIN_TOKEN', 'TROOP_STATE_DIR']:
            env.pop(key, None)
        process = subprocess.Popen([args.godot, '--headless', '--path', str(project),
            '--max-fps', '60', '--script', 'res://tests/frontiernetworktest.gd', '--',
            role, str(port), str(folder)], stdout=handle, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True, cwd=project, env=env)
        children.append((process, path, role))
        return process, path, role

    def wait_marker(child, marker, timeout=25):
        process, path, _ = child
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = path.read_text(errors='replace')
            if 'SCRIPT ERROR:' in text or 'FRONTIERNET FAIL' in text:
                raise RuntimeError(f'{path.name}:\n{text[-7000:]}')
            if marker in text:
                return
            if process.poll() is not None:
                raise RuntimeError(f'{path.name} exited {process.returncode}:\n{text[-7000:]}')
            time.sleep(.1)
        raise RuntimeError(f'timeout {path.name}:\n{path.read_text(errors="replace")[-7000:]}')

    def done(child, timeout=70):
        process, path, role = child
        wait_marker(child, f'FRONTIERNET_{role.upper()} ', timeout)
        status = process.wait(timeout=5)
        text = path.read_text(errors='replace')
        if status or 'ERROR:' in text or 'FAIL' in text:
            raise RuntimeError(f'{path.name} failed:\n{text[-7000:]}')

    try:
        server = start('server')
        wait_marker(server, 'FRONTIERNET_SERVER_READY')
        owner = start('owner')
        visitor = start('visitor')
        done(owner)
        done(visitor)
        (folder / 'stop').touch()
        done(server)
        (folder / 'stop').unlink()
        server = start('server', 'server-resumed')
        wait_marker(server, 'FRONTIERNET_SERVER_READY')
        resumed = start('resume')
        done(resumed)
        (folder / 'stop').touch()
        done(server)
        print(f'FRONTIER_NETWORK PASS authenticated shared towns, private inventories, proximity, replay, Moon claims, traffic and persistent restart\nLogs: {folder}')
    finally:
        for process, _, _ in children:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        for process, _, _ in children:
            if process.poll() is None:
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
        for handle in handles:
            handle.close()
        # Clean only each exact per-run installation's generated identity files.
        for _, log, _ in children:
            for line in log.read_text(errors='replace').splitlines():
                if not line.startswith('FRONTIERNET_USERDIR '): continue
                directory = Path(line.removeprefix('FRONTIERNET_USERDIR '))
                if not directory.is_absolute() or directory.is_symlink() or directory.name not in [folder.name+'-'+r for r in ['owner','visitor','server']]:
                    raise RuntimeError('unexpected fixture identity directory')
                for name in ['admin_identity.key', 'admin_identity_secret.txt']:
                    for suffix in ['', '.tmp', '.bak']:
                        (directory / (name + suffix)).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
