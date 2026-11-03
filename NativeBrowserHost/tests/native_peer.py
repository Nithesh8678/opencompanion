"""Simulate Chrome framing while using the real native host process."""
import json
from pathlib import Path
import struct
import subprocess
import sys

host = Path(__file__).resolve().parents[1] / 'host.py'
process = subprocess.Popen([sys.executable, str(host), '--socket', sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    def send(value):
        raw = json.dumps(value).encode()
        process.stdin.write(struct.pack('=I', len(raw)) + raw)
        process.stdin.flush()
    send({'protocolVersion': 1, 'type': 'browser.hello', 'connectionID': 'smoke', 'extensionID': 'fixture', 'capabilities': ['snapshot'], 'tabs': [{'tabID': 42, 'title': 'Smoke fixture', 'url': 'https://example.com/', 'origin': 'https://example.com', 'allowActions': False}]})
    length = struct.unpack('=I', process.stdout.read(4))[0]
    request = json.loads(process.stdout.read(length))
    assert request['operation'] == 'snapshot'
    send({'protocolVersion': 1, 'type': 'browser.result', 'requestID': request['requestID'], 'ok': True, 'result': {'documentID': 'native-smoke-document', 'revision': 1, 'elements': [], 'text': 'Real IPC fixture'}})
    # Let the app close the socket after accepting the response.
    process.wait(timeout=5)
finally:
    if process.poll() is None:
        process.kill()
    process.wait(timeout=3)
    process.stdin.close()
    process.stdout.close()
