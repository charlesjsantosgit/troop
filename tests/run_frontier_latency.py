#!/usr/bin/env python3
"""Measure real action/vehicle replies through a constrained lossy UDP link."""
import argparse
import heapq
import json
import os
from pathlib import Path
import random
import selectors
import signal
import socket
import subprocess
import tempfile
import time

ONE_WAY_DELAY = .050
DOWN_BYTES_PER_SECOND = 55_000
UP_BYTES_PER_SECOND = 28_000
DROP_EVERY = 31


def unused_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--project', type=Path,
                        default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    project = args.project.resolve()
    folder = Path(tempfile.mkdtemp(prefix='troop-frontier-latency-'))
    print(f'FRONTIER_LATENCY_LOGS {folder}', flush=True)
    server_port = unused_port()
    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(('127.0.0.1', 0))
    back.bind(('127.0.0.1', 0))
    selector = selectors.DefaultSelector()
    selector.register(front, selectors.EVENT_READ, 'up')
    selector.register(back, selectors.EVENT_READ, 'down')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TROOP_', 'GODOT_', 'DYLD_'))}
    children, handles = [], []

    def start(role, port):
        handle = (folder / f'{role}.log').open('w')
        handles.append(handle)
        command = [args.godot, '--headless', '--path', str(project),
                   '--max-fps', '120', '--script',
                   'res://tests/frontierlatencytest.gd', '--', role,
                   str(port), str(folder)]
        child = subprocess.Popen(command, stdout=handle,
                                 stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, cwd=project,
                                 env=environment, start_new_session=True)
        children.append(child)
        return child

    client_address = None
    queue = []
    sequence = 0
    constrained = False
    next_due = {'up': 0.0, 'down': 0.0}
    stressed_packets = {'up': 0, 'down': 0}
    stats = {'relay_rtt_ms': int(ONE_WAY_DELAY * 2000),
             'down_bytes_per_second': DOWN_BYTES_PER_SECOND,
             'up_bytes_per_second': UP_BYTES_PER_SECOND,
             'drop_every': DROP_EVERY, 'dropped': 0, 'forwarded': 0,
             'stress_down_bytes': 0, 'stress_up_bytes': 0}
    try:
        server = start('server', server_port)
        ready_deadline = time.monotonic() + 12
        while 'FRONTIERLATENCY_SERVER_READY' not in (folder / 'server.log').read_text(errors='replace'):
            if server.poll() is not None or time.monotonic() > ready_deadline:
                raise RuntimeError('server did not become ready:\n' +
                                   (folder / 'server.log').read_text(errors='replace')[-5000:])
            time.sleep(.02)
        client = start('client', front.getsockname()[1])
        deadline = time.monotonic() + 55
        while time.monotonic() < deadline and client.poll() is None:
            if not constrained and (folder / 'stress-ready').exists():
                constrained = True
                next_due = {'up': time.monotonic(), 'down': time.monotonic()}
            for key, _ in selector.select(.002):
                data, address = key.fileobj.recvfrom(65535)
                side = key.data
                if side == 'up':
                    client_address = address
                if constrained:
                    stressed_packets[side] += 1
                    # Drop deterministic downlink packets only. ENet retransmits
                    # reliable data; independent channels can still make progress.
                    if side == 'down' and stressed_packets[side] % DROP_EVERY == 0:
                        stats['dropped'] += 1
                        continue
                    rate = UP_BYTES_PER_SECOND if side == 'up' else DOWN_BYTES_PER_SECOND
                    next_due[side] = max(time.monotonic(), next_due[side]) + len(data) / rate
                    due = next_due[side] + ONE_WAY_DELAY
                    stats['stress_' + side + '_bytes'] += len(data)
                else:
                    due = time.monotonic() + ONE_WAY_DELAY
                sequence += 1
                heapq.heappush(queue, (due, sequence, side, data))
            now = time.monotonic()
            while queue and queue[0][0] <= now:
                _, _, side, data = heapq.heappop(queue)
                if side == 'up':
                    back.sendto(data, ('127.0.0.1', server_port))
                elif client_address:
                    front.sendto(data, client_address)
                stats['forwarded'] += 1
        if client.poll() is None:
            raise RuntimeError('client timed out')
        (folder / 'stop').write_text('stop\n')
        server.wait(timeout=8)
        client_text = (folder / 'client.log').read_text(errors='replace')
        server_text = (folder / 'server.log').read_text(errors='replace')
        if client.returncode or server.returncode or 'SCRIPT ERROR:' in client_text + server_text:
            raise RuntimeError('fixture failed:\n' + client_text[-5000:] + '\n' + server_text[-5000:])
        rows = [line.removeprefix('FRONTIERLATENCY_RESULT ')
                for line in client_text.splitlines()
                if line.startswith('FRONTIERLATENCY_RESULT ')]
        if len(rows) != 1:
            raise RuntimeError('missing result:\n' + client_text[-5000:])
        result = json.loads(rows[0])
        result.update(stats)
        (folder / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, sort_keys=True), flush=True)
        assert result['ok'] and len(result['action_ms']) == 6
        assert result['action_median_ms'] < 1500, 'action reply stalled behind bulk state'
        assert result['trade_result_ms'] < 1500, 'durable trade reply stalled behind bulk state'
        assert result['trade_view_ms'] < 3000, 'authoritative post-trade inventory stayed stale'
        assert result['trade_view_ms'] <= result['trade_result_ms'] + 50, 'trade result omitted its scoped authoritative patch'
        assert not result['inventory_regressed'], 'older bulk state overwrote a newer action patch'
        assert result['watch_retry'], 'a rejected town watch was cached without authority confirmation'
        assert result['vehicle_ms'] < 1500, 'vehicle seat grant stalled behind bulk state'
        assert result['denial_ms'] < 1500 and result['denial_reason'], 'vehicle denial was absent or late'
        assert result['state_views_during'] <= 16, 'full-state backpressure did not bound refresh delivery'
        print('FRONTIER_LATENCY PASS real actions, durable seat claim and correlated denial over constrained lossy ENet')
    finally:
        for child in children:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
        for child in children:
            if child.poll() is None:
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)
        for handle in handles:
            handle.close()
        selector.close()
        front.close()
        back.close()


if __name__ == '__main__':
    main()
