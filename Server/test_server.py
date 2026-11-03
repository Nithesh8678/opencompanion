import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import unittest
from server import Configuration, RelayServer

TOKEN = 'test-relay-token-with-at-least-32-characters'
received = []
slow_started = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        received.append((self.path, self.headers['Authorization'], body))
        if body['model'] == 'slow':
            slow_started.set()
            time.sleep(2)
        if body.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"Verified fixture"}}]}\n\ndata: [DONE]\n\n')
        else:
            data = b'{"choices":[{"message":{"role":"assistant","content":"Verified fixture"}}]}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass


class RelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        cls.provider.daemon_threads = True
        cls.relay = RelayServer(('127.0.0.1', 0), Configuration(TOKEN, 'mock-provider-secret', f'http://127.0.0.1:{cls.provider.server_port}/v1'))
        for server in [cls.provider, cls.relay]:
            threading.Thread(target=server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for server in [cls.relay, cls.provider]:
            server.shutdown()
            server.server_close()

    def request(self, path, body=None, token=TOKEN, **headers):
        connection = http.client.HTTPConnection('127.0.0.1', self.relay.server_port, timeout=5)
        connection.request('POST' if body is not None else 'GET', path, body=json.dumps(body) if body is not None else None, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', **headers})
        response = connection.getresponse()
        result = (response.status, response.read(), dict(response.getheaders()))
        connection.close()
        return result

    def test_health_does_not_claim_provider_connectivity(self):
        status, body, _ = self.request('/health')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['providerConnectivity'], 'not-tested')
        self.assertNotIn(b'secret', body)

    def test_authentication_precedes_upstream(self):
        before = len(received)
        status, _, _ = self.request('/v1/chat/completions', {'model': 'fixture', 'messages': [{}]}, token='wrong')
        self.assertEqual(status, 401)
        self.assertEqual(len(received), before)

    def test_json_and_sse_relay_with_server_only_key(self):
        for streaming in [False, True]:
            status, body, headers = self.request('/v1/chat/completions', {'model': 'fixture', 'messages': [{'role': 'user', 'content': 'test'}], 'stream': streaming})
            self.assertEqual(status, 200)
            self.assertIn(b'Verified fixture', body)
            self.assertNotIn(b'mock-provider-secret', body)
            self.assertEqual(received[-1][0:2], ('/v1/chat/completions', 'Bearer mock-provider-secret'))
            if streaming:
                self.assertIn('[DONE]', body.decode())
                self.assertIn('X-Request-ID', headers)

    def test_explicit_cancel_reaches_upstream(self):
        slow_started.clear()
        result = []
        worker = threading.Thread(target=lambda: result.append(self.request('/v1/chat/completions', {'model': 'slow', 'messages': [{}]}, **{'X-Request-ID': 'cancel-fixture'})))
        worker.start()
        self.assertTrue(slow_started.wait(2))
        started = time.monotonic()
        status, body, _ = self.request('/v1/cancel', {'requestID': 'cancel-fixture'})
        worker.join(2)
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)['cancelled'])
        self.assertFalse(worker.is_alive())
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(result[0][0], 499)

    def test_bad_inputs_and_browser_origin(self):
        for body in [{}, {'model': '', 'messages': [{}]}, {'model': 'test', 'messages': [], 'stream': True}]:
            self.assertEqual(self.request('/v1/chat/completions', body)[0], 400)
        self.assertEqual(self.request('/v1/chat/completions', {'model': 'fixture', 'messages': [{}]}, Origin='https://example.com')[0], 403)

    def test_configuration_requires_credentials_and_local_bind(self):
        for args in [('short', 'key'), (TOKEN, ''), (TOKEN, 'key', 'http://untrusted.example/v1'), (TOKEN, 'key', 'https://example.com/v1', '0.0.0.0')]:
            with self.assertRaises(ValueError):
                Configuration(*args)


if __name__ == '__main__':
    unittest.main()
