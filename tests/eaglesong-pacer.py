#!/usr/bin/env python3
"""Template pacing regressions; no CKB, sockets, or wall-clock waits."""
import importlib.util
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pacer', Path(__file__).resolve().parents[1] / 'eaglesong-pacer.py')
pacer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pacer)
REQUEST = dict(jsonrpc='2.0', id=19, method='get_block_template', params=[None, None, None])


class Tests(unittest.TestCase):
    def fixture(self, interval=8000):
        self.now = 100.0
        self.tip = dict(timestamp=hex(100000), hash='a')
        self.calls = []
        p = pacer.Pacer('http://127.0.0.1:1/', interval)
        def rpc(req):
            self.calls.append(req)
            if req['method'] == 'get_tip_header':
                return dict(result=dict(self.tip))
            return dict(id=req['id'], result=dict(parent_hash=self.tip['hash'],
                        current_time=hex(round(self.now * 1000)), work_id='unchanged'))
        p.rpc = rpc
        return p

    def sleep(self, seconds):
        self.now += seconds

    def get(self, p, sleep=None):
        with patch.object(pacer.time, 'monotonic', lambda: self.now), \
                patch.object(pacer.time, 'sleep', sleep or self.sleep):
            return p.template(REQUEST)

    def test_waits_eight_seconds_and_preserves_request_and_template(self):
        p = self.fixture()
        result = self.get(p)
        self.assertEqual(self.now, 108)
        self.assertEqual(self.calls[-1], REQUEST)
        self.assertEqual(result['id'], 19)
        self.assertEqual(result['result']['current_time'], hex(108000))
        self.assertEqual(result['result']['work_id'], 'unchanged')

    def test_subsecond_interval(self):
        p = self.fixture(250)
        self.get(p)
        self.assertEqual(self.now, 100.25)

    def test_first_observation_waits_even_for_an_old_parent(self):
        p = self.fixture()
        self.now = 200
        self.get(p)
        self.assertEqual(self.now, 208)

    def test_new_peer_tip_resets_deadline(self):
        p = self.fixture()
        def sleep(seconds):
            self.sleep(seconds)
            if self.now == 104:
                self.tip = dict(timestamp=hex(104000), hash='b')
        self.assertEqual(self.get(p, sleep)['result']['parent_hash'], 'b')
        self.assertEqual(self.now, 112)

    def test_stale_template_is_refetched_not_rewritten(self):
        p = self.fixture()
        rpc = p.rpc
        stale = dict(id=19, result=dict(parent_hash='old', current_time=hex(100000)))
        count = 0
        def replace(req):
            nonlocal count
            if req['method'] == 'get_block_template':
                count += 1
                if count == 1:
                    return stale
            return rpc(req)
        p.rpc = replace
        self.get(p)
        self.assertEqual(count, 2)
        self.assertEqual(stale['result']['current_time'], hex(100000))

    def test_cached_timestamp_is_forwarded_without_rewrite_or_deadlock(self):
        p = self.fixture()
        rpc = p.rpc
        count = 0
        def replace(req):
            nonlocal count
            result = rpc(req)
            if req['method'] == 'get_block_template':
                count += 1
                if count == 1:
                    result['result']['current_time'] = hex(107999)
            return result
        p.rpc = replace
        result = self.get(p)
        self.assertEqual(count, 1)
        self.assertEqual(result['result']['current_time'], hex(107999))

    def test_same_parent_does_not_restart_wait(self):
        p = self.fixture()
        self.get(p)
        self.get(p, lambda _: self.fail('same parent restarted the timer'))

    def test_wall_clock_does_not_control_pacing(self):
        p = self.fixture()
        with patch.object(pacer.time, 'time', side_effect=RuntimeError('wall clock used')):
            self.get(p)
        self.assertEqual(self.now, 108)

    def test_upstream_failure_has_no_unpaced_fallback(self):
        p = self.fixture()
        p.rpc = lambda _: (_ for _ in ()).throw(OSError('offline'))
        with self.assertRaises(OSError):
            self.get(p)

    def test_template_error_is_forwarded(self):
        p = self.fixture()
        rpc = p.rpc
        error = dict(id=19, error=dict(code=-1, message='test'))
        p.rpc = lambda req: error if req['method'] == 'get_block_template' else rpc(req)
        self.assertEqual(self.get(p), error)

    def test_submit_does_not_take_template_lock(self):
        p = self.fixture()
        request = dict(id=20, method='submit_block', params=['work', {}])
        done = threading.Event()
        with p.templates:
            t = threading.Thread(target=lambda: (p.dispatch(request), done.set()), daemon=True)
            t.start()
            self.assertTrue(done.wait(1), 'submit blocked behind template wait')
        t.join(1)
        self.assertEqual(self.calls, [request])

    def test_rejects_non_mining_methods(self):
        p = self.fixture()
        self.assertEqual(p.dispatch(dict(id=21, method='local_node_info'))['error']['code'], -32601)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
