#!/usr/bin/env python3
"""Real society RPCs through an 80ms RTT relay that drops UDP payloads >1300B."""
import argparse
import heapq
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import time

CAP = 1300
ONE_WAY_DELAY = .040


def unused_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def attempt(args, folder, mode):
    server_port = unused_port()
    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(('127.0.0.1', 0))
    back.bind(('127.0.0.1', 0))
    selector = selectors.DefaultSelector()
    selector.register(front, selectors.EVENT_READ, 'front')
    selector.register(back, selectors.EVENT_READ, 'back')
    client_address = None
    queue = []
    serial = 0
    stats = dict(mode=mode, cap=CAP, relay_rtt_ms=80, dropped=0,
                 forwarded=0, max_datagram=0, max_forwarded=0)
    children, handles = [], []
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TROOP_', 'GODOT_', 'DYLD_'))}
    try:
        for role, port in [('server', server_port), ('client', front.getsockname()[1])]:
            handle = (folder / f'{mode}-{role}.log').open('w')
            handles.append(handle)
            command = [args.godot, '--headless', '--path', str(args.project),
                       '--max-fps', '120', '--script', 'res://tests/frontiermtutest.gd',
                       '--', role, str(port), str(mode)]
            children.append(subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT,
                                             stdin=subprocess.DEVNULL, cwd=args.project,
                                             env=environment))
            if role == 'server':
                # The fixture advances 450 simulated society seconds before
                # opening ENet. Pedestrian collision now makes that deliberate
                # model warmup CPU-bound; it is outside the timed WAN phase.
                ready_deadline = time.monotonic() + 20
                while 'FRONTIERMTU_READY' not in (folder / f'{mode}-server.log').read_text():
                    if children[0].poll() is not None or time.monotonic() > ready_deadline:
                        raise RuntimeError('Server fixture did not become ready')
                    time.sleep(.02)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and children[1].poll() is None:
            for key, _ in selector.select(.002):
                data, address = key.fileobj.recvfrom(65535)
                stats['max_datagram'] = max(stats['max_datagram'], len(data))
                if key.data == 'front':
                    client_address = address
                if len(data) > CAP:
                    stats['dropped'] += 1
                    continue
                serial += 1
                heapq.heappush(queue, (time.monotonic() + ONE_WAY_DELAY, serial, key.data, data))
            now = time.monotonic()
            while queue and queue[0][0] <= now:
                _, _, side, data = heapq.heappop(queue)
                if side == 'front':
                    back.sendto(data, ('127.0.0.1', server_port))
                elif client_address:
                    front.sendto(data, client_address)
                stats['forwarded'] += 1
                stats['max_forwarded'] = max(stats['max_forwarded'], len(data))
        stats['client_exit'] = children[1].poll()
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
        for handle in handles:
            handle.close()
        selector.close()
        front.close()
        back.close()
    for role in ['server', 'client']:
        text = (folder / f'{mode}-{role}.log').read_text(errors='replace')
        if 'ERROR:' in text or 'SCRIPT ERROR:' in text:
            raise RuntimeError(f'{mode}-{role} engine error:\n{text[-4000:]}')
        if role == 'client':
            summaries = [line.removeprefix('FRONTIERMTU_RESULT ') for line in text.splitlines()
                         if line.startswith('FRONTIERMTU_RESULT ')]
            if len(summaries) != 1:
                raise RuntimeError(f'{mode}-client missing completion sentinel:\n{text[-4000:]}')
            stats.update(json.loads(summaries[0]))
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    args.project = args.project.resolve()
    folder = Path(tempfile.mkdtemp(prefix='troop-frontier-mtu-'))
    print(f'FRONTIER_MTU_LOGS {folder}', flush=True)
    results = []
    for mode in [0, 1]:
        results.append(attempt(args, folder, mode))
        (folder / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(results[-1]), flush=True)
    original, corrected = results
    # Baseline is diagnostic so an engine with a future smaller default MTU
    # remains valid. The deployed helper must always deliver the whole state.
    assert original['movements'] > 0 and original['voices'] > 0, 'baseline relay carried no small streams'
    assert corrected['client_exit'] == 0 and corrected['ok'], 'corrected RPC fixture did not pass'
    assert corrected['snapshots'] == 12 and corrected['mismatches'] == 0, 'snapshot integrity failed'
    assert corrected['minimum_view_bytes'] > 65536, 'fixture no longer exercises large town state'
    assert corrected['max_forwarded'] <= CAP and corrected['dropped'] == 0, 'corrected UDP exceeds WAN budget'
    assert corrected['last_rtt_ms'] >= 65, 'fixture bypassed the configured network delay'
    print('FRONTIER_MTU PASS 12 atomic town views, movement, silent voice and five-car traffic through 1300-byte / 80ms RTT WAN relay')


if __name__ == '__main__':
    main()
