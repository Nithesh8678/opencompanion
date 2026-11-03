import io
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import subprocess
import sys
import threading
import unittest
from host import MAX_MESSAGE_BYTES, ProtocolError, check_socket, read_frame, validate, write_frame


class FramingTests(unittest.TestCase):
    def test_round_trip_and_adjacent_frames(self):
        first = json.dumps({'protocolVersion': 1, 'type': 'browser.hello', 'title': 'नमस्ते'}).encode()
        second = b'{"protocolVersion":1,"type":"browser.result","ok":true}'
        stream = io.BytesIO()
        write_frame(stream, first)
        write_frame(stream, second)
        stream.seek(0)
        self.assertEqual(read_frame(stream), first)
        self.assertEqual(read_frame(stream), second)
        with self.assertRaises(EOFError):
            read_frame(stream)

    def test_rejects_partial_oversized_and_malformed_frames(self):
        for raw in [b'\x01', struct.pack('=I', 5) + b'{}', struct.pack('=I', MAX_MESSAGE_BYTES + 1), struct.pack('=I', 2) + b'[]']:
            with self.subTest(raw=raw), self.assertRaises(ProtocolError):
                read_frame(io.BytesIO(raw))

    def test_unsupported_protocol_and_type(self):
        for message in [{'protocolVersion': 2, 'type': 'browser.hello'}, {'protocolVersion': 1, 'type': 'exec'}, []]:
            with self.assertRaises(ProtocolError):
                validate(json.dumps(message).encode())

    def test_real_process_duplex_socket_bridge(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bridge.sock'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                os.chmod(path, 0o600)
                process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('host.py')), '--socket', str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    connection, _ = server.accept()
                    connection.settimeout(3)
                    with connection, connection.makefile('rb') as stream:
                        hello = b'{"protocolVersion":1,"type":"browser.hello","tabs":[]}'
                        write_frame(process.stdin, hello)
                        self.assertEqual(json.loads(stream.readline()), json.loads(hello))
                        request = b'{"protocolVersion":1,"type":"browser.request","requestID":"fixture","operation":"snapshot","tabID":42}'
                        connection.sendall(request + b'\n')
                        self.assertEqual(read_frame(process.stdout), request)
                    process.stdin.close()
                    process.wait(timeout=3)
                    self.assertEqual(process.returncode, 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=3)
                    process.stdout.close()
                    process.stderr.close()

    def test_socket_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bridge.sock'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                os.chmod(path, 0o600)
                check_socket(path)
                os.chmod(path, 0o666)
                with self.assertRaises(ProtocolError):
                    check_socket(path)


if __name__ == '__main__':
    unittest.main()
