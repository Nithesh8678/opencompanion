#!/usr/bin/env python3
"""Single-user local/self-host OpenAI-compatible relay; Python standard library only."""
from __future__ import annotations

from dataclasses import dataclass, field
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import secrets
import socket
import threading
import time
from urllib.parse import urlsplit

MAX_BODY = 1024 * 1024
MAX_RESPONSE = 16 * 1024 * 1024
MAX_SSE_LINE = 256 * 1024
MAX_ACTIVE = 4
REQUEST_TIMEOUT = 120


@dataclass(frozen=True)
class Configuration:
    relay_token: str
    provider_key: str
    provider_base_url: str = 'https://api.openai.com/v1'
    host: str = '127.0.0.1'
    port: int = 8736

    def __post_init__(self):
        if len(self.relay_token) < 32:
            raise ValueError('OPENCOMPANION_RELAY_TOKEN must contain at least 32 characters.')
        if not self.provider_key:
            raise ValueError('OPENCOMPANION_PROVIDER_KEY is required; no model is simulated.')
        parsed = urlsplit(self.provider_base_url)
        if parsed.scheme not in {'https', 'http'} or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('Provider base URL must be an absolute URL without credentials, query or fragment.')
        if parsed.scheme == 'http' and parsed.hostname not in {'localhost', '127.0.0.1', '::1'}:
            raise ValueError('Non-local providers require HTTPS.')
        if self.host not in {'localhost', '127.0.0.1', '::1'}:
            raise ValueError('This single-user relay binds to loopback. Use an authenticated TLS reverse proxy for remote access.')


@dataclass
class ActiveRequest:
    cancelled: threading.Event = field(default_factory=threading.Event)
    connection: http.client.HTTPConnection | None = None

    def cancel(self):
        self.cancelled.set()
        connection = self.connection
        if connection:
            # shutdown interrupts a pending upstream read; close alone can wait.
            if connection.sock:
                try:
                    connection.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            connection.close()


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    request_queue_size = 8

    def __init__(self, address, configuration):
        self.configuration = configuration
        self.active: dict[str, ActiveRequest] = {}
        self.active_lock = threading.Lock()
        self.connection_slots = threading.BoundedSemaphore(16)
        super().__init__(address, RelayHandler)

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()

    def server_close(self):
        with self.active_lock:
            requests = list(self.active.values())
        for request in requests:
            request.cancel()
        super().server_close()


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'OpenCompanionRelay/1'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, format, *args):
        # Never log request bodies, keys, authorization, prompts or page content.
        pass

    def json_response(self, status, value):
        body = json.dumps(value, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        self.wfile.write(body)

    def error(self, status, message):
        self.json_response(status, {'error': {'message': message, 'type': 'relay_error'}})

    def authorized(self):
        supplied = self.headers.get('Authorization', '')
        expected = 'Bearer ' + self.server.configuration.relay_token
        if not hmac.compare_digest(supplied.encode(), expected.encode()):
            self.error(401, 'A valid relay bearer token is required.')
            return False
        if self.headers.get('Origin'):
            self.error(403, 'Browser-origin requests are not supported by this native-client relay.')
            return False
        return True

    def read_json(self):
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('Chunked request bodies are not supported.')
        if self.headers.get_content_type() != 'application/json':
            raise ValueError('Content-Type must be application/json.')
        try:
            length = int(self.headers.get('Content-Length', '-1'))
        except ValueError as error:
            raise ValueError('Content-Length is required.') from error
        if not 0 < length <= MAX_BODY:
            raise ValueError('Request body must be between 1 byte and 1 MiB.')
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise ValueError('Truncated request body.')
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError('Request body must be an object.')
        return value

    def do_GET(self):
        if self.path == '/health':
            self.json_response(200, {'status': 'ok', 'protocolVersion': 1, 'profile': 'single-user-relay', 'providerConnectivity': 'not-tested'})
        else:
            self.error(404, 'Unknown endpoint.')

    def do_POST(self):
        if not self.authorized():
            return
        try:
            value = self.read_json()
        except (ValueError, UnicodeDecodeError, socket.timeout):
            self.error(400, 'Invalid or oversized JSON request.')
            return
        if self.path == '/v1/cancel':
            request_id = value.get('requestID')
            if not isinstance(request_id, str):
                self.error(400, 'requestID is required.')
                return
            with self.server.active_lock:
                active = self.server.active.get(request_id)
            if active:
                active.cancel()
            self.json_response(200, {'requestID': request_id, 'cancelled': bool(active)})
            return
        if self.path != '/v1/chat/completions':
            self.error(404, 'Unknown endpoint.')
            return
        if not isinstance(value.get('messages'), list) or not value['messages'] or not isinstance(value.get('model'), str) or not value['model'].strip() or not isinstance(value.get('stream', False), bool):
            self.error(400, 'A configured model, nonempty messages array and optional boolean stream are required.')
            return
        request_id = self.headers.get('X-Request-ID') or secrets.token_hex(16)
        if not re.fullmatch('[A-Za-z0-9_-]{1,128}', request_id):
            self.error(400, 'Invalid X-Request-ID.')
            return
        active = ActiveRequest()
        with self.server.active_lock:
            if request_id in self.server.active:
                self.error(409, 'This requestID is already active.')
                return
            if len(self.server.active) >= MAX_ACTIVE:
                self.error(429, 'Relay is at its bounded concurrency limit.')
                return
            self.server.active[request_id] = active
        headers_sent = False
        started = time.monotonic()
        try:
            config = self.server.configuration
            base = urlsplit(config.provider_base_url)
            connection_class = http.client.HTTPSConnection if base.scheme == 'https' else http.client.HTTPConnection
            upstream = connection_class(base.hostname, base.port, timeout=15)
            active.connection = upstream
            if active.cancelled.is_set():
                raise InterruptedError
            body = json.dumps(value, separators=(',', ':')).encode()
            path = base.path.rstrip('/') + '/chat/completions'
            upstream.request('POST', path, body=body, headers={'Authorization': 'Bearer ' + config.provider_key, 'Content-Type': 'application/json', 'Accept': 'text/event-stream' if value.get('stream') else 'application/json'})
            if active.cancelled.is_set():
                active.cancel()
                raise InterruptedError
            response = upstream.getresponse()
            if active.cancelled.is_set():
                raise InterruptedError
            streaming = value.get('stream') and 200 <= response.status < 300
            if streaming and 'text/event-stream' not in response.getheader('Content-Type', ''):
                raise ValueError('Provider did not return an SSE stream.')
            if not streaming:
                data = response.read(MAX_RESPONSE + 1)
                if active.cancelled.is_set():
                    raise InterruptedError
                if len(data) > MAX_RESPONSE:
                    raise ValueError('Provider response exceeds budget.')
                # Reparse JSON; never forward HTML error pages or upstream headers.
                result = json.loads(data)
                self.json_response(response.status, result)
                return
            self.send_response(response.status)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Accel-Buffering', 'no')
            self.send_header('X-Request-ID', request_id)
            self.send_header('Connection', 'close')
            self.end_headers()
            headers_sent = True
            self.close_connection = True
            total = 0
            while True:
                if active.cancelled.is_set():
                    raise InterruptedError
                if time.monotonic() - started > REQUEST_TIMEOUT:
                    raise TimeoutError
                line = response.readline(MAX_SSE_LINE + 1)
                if not line:
                    break
                total += len(line)
                if len(line) > MAX_SSE_LINE or total > MAX_RESPONSE:
                    raise ValueError('Provider stream exceeds budget.')
                self.wfile.write(line)
                self.wfile.flush()  # backpressure reaches the next upstream read
        except (OSError, ValueError, http.client.HTTPException, InterruptedError, TimeoutError) as error:
            if not headers_sent:
                try:
                    self.error(499 if active.cancelled.is_set() else 502, 'Request cancelled.' if active.cancelled.is_set() else 'Provider request failed. Check the server provider configuration and model access.')
                except OSError:
                    pass
            else:
                try:
                    message = {'error': {'type': 'cancelled' if active.cancelled.is_set() else 'relay_error', 'message': 'Stream cancelled.' if active.cancelled.is_set() else 'Provider stream interrupted.'}}
                    self.wfile.write(b'data: ' + json.dumps(message).encode() + b'\n\ndata: [DONE]\n\n')
                    self.wfile.flush()
                except OSError:
                    pass
        finally:
            active.cancel()
            with self.server.active_lock:
                self.server.active.pop(request_id, None)


def main():
    try:
        config = Configuration(relay_token=os.environ.get('OPENCOMPANION_RELAY_TOKEN', ''), provider_key=os.environ.get('OPENCOMPANION_PROVIDER_KEY', ''), provider_base_url=os.environ.get('OPENCOMPANION_PROVIDER_BASE_URL', 'https://api.openai.com/v1'), host=os.environ.get('OPENCOMPANION_BIND', '127.0.0.1'), port=int(os.environ.get('OPENCOMPANION_PORT', '8736')))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    with RelayServer((config.host, config.port), config) as server:
        print(f'OpenCompanion single-user relay listening at http://{config.host}:{server.server_port}; provider access is not yet verified.', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
