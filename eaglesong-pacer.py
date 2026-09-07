#!/usr/bin/env python3
"""Loopback-only template gate for the cluster's local Eaglesong miners."""
import argparse
import json
import signal
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Pacer:
    def __init__(self, upstream, interval_ms):
        self.upstream = upstream
        self.interval_ms = interval_ms
        self.templates = threading.Lock()
        self.parent = None
        self.ready_at = 0.0
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def rpc(self, request):
        req = urllib.request.Request(self.upstream, json.dumps(request).encode(),
                                     {'Content-Type': 'application/json'})
        with self.http.open(req, timeout=3) as response:
            return json.load(response)

    def template(self, request):
        # Serialize template waits, but never block submit_block behind them.
        with self.templates:
            while True:
                response = self.rpc(dict(jsonrpc='2.0', id=1,
                                         method='get_tip_header', params=[]))
                tip = response['result']
                if tip['hash'] != self.parent:
                    self.parent = tip['hash']
                    self.ready_at = time.monotonic() + self.interval_ms / 1000
                remaining = self.ready_at - time.monotonic()
                if remaining > 0:
                    time.sleep(min(remaining, 0.5))
                    continue  # A peer may have advanced/reorganized the chain.
                result = self.rpc(request)
                if 'error' in result:
                    return result
                template = result['result']
                if template['parent_hash'] == tip['hash']:
                    return result
                # The tip moved during fetch; re-check it. CKB may cache template
                # timestamps, so pacing must not wait for current_time to update.
                time.sleep(0.1)

    def dispatch(self, request):
        if request.get('method') == 'get_block_template':
            return self.template(request)
        if request.get('method') == 'submit_block':
            return self.rpc(request)
        return dict(jsonrpc='2.0', id=request.get('id'),
                    error=dict(code=-32601, message='Mining methods only'))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # Bound concurrent long polls. The standard miner uses two callers.
    slots = threading.BoundedSemaphore(8)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = {}
        try:
            self.connection.settimeout(5)
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 16 * 1024 * 1024:
                raise ValueError('Invalid request size')
            request = json.loads(self.rfile.read(size))
            if not isinstance(request, dict):
                request = {}
                raise ValueError('Expected a JSON-RPC object')
            result = self.server.pacer.dispatch(request)
        except Exception as exc:
            # Upstream failure never falls back to unpaced mining.
            result = dict(jsonrpc='2.0', id=request.get('id'),
                          error=dict(code=-32000, message=str(exc)))
        data = json.dumps(result).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--interval-ms', required=True, type=int)
    parser.add_argument('--ready-file', required=True, type=Path)
    args = parser.parse_args()
    if args.interval_ms <= 0 or not args.upstream.startswith('http://127.0.0.1:'):
        parser.error('Positive interval and loopback upstream required')
    signal.signal(signal.SIGTERM, lambda *_: exit(143))
    with Server(('127.0.0.1', 0), Handler) as server:
        server.pacer = Pacer(args.upstream, args.interval_ms)
        args.ready_file.write_text('http://127.0.0.1:%d/\n' % server.server_port)
        try:
            server.serve_forever(poll_interval=0.2)
        finally:
            args.ready_file.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
