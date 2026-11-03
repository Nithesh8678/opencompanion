#!/usr/bin/env python3
"""Bounded Chrome native-messaging <-> local OpenCompanion Unix socket bridge.

Protocol traffic is stdout-only. Diagnostics go to stderr. No provider credentials
or browser content are persisted by this process.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import stat
import struct
import sys
import threading
from pathlib import Path
from typing import BinaryIO

MAX_MESSAGE_BYTES = 1024 * 1024 - 1  # Chrome's host-to-browser limit is 1 MiB.
DEFAULT_SOCKET = Path.home() / 'Library/Application Support/OpenCompanion/browser.sock'


class ProtocolError(ValueError):
    pass


def read_exact(stream: BinaryIO, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        # A daemon blocked inside BufferedReader.read can hold its lock while
        # Python finalizes. Native stdin uses an unbuffered descriptor read.
        data = os.read(stream.fileno(), count - len(chunks)) if stream is sys.stdin.buffer else stream.read(count - len(chunks))
        if not data:
            if not chunks:
                raise EOFError
            raise ProtocolError('Truncated native frame.')
        chunks.extend(data)
    return bytes(chunks)


def validate(raw: bytes) -> dict:
    if not raw or len(raw) > MAX_MESSAGE_BYTES:
        raise ProtocolError('Message exceeds transport budget.')
    try:
        message = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as error:
        raise ProtocolError('Invalid JSON message.') from error
    if not isinstance(message, dict) or message.get('protocolVersion') != 1:
        raise ProtocolError('Unsupported message envelope.')
    if message.get('type') not in {'browser.hello', 'browser.request', 'browser.result', 'browser.error'}:
        raise ProtocolError('Unsupported message type.')
    return message


def read_frame(stream: BinaryIO) -> bytes:
    length = struct.unpack('=I', read_exact(stream, 4))[0]
    if not 0 < length <= MAX_MESSAGE_BYTES:
        raise ProtocolError('Invalid native frame length.')
    raw = read_exact(stream, length)
    validate(raw)
    return raw


def write_frame(stream: BinaryIO, raw: bytes) -> None:
    validate(raw)
    stream.write(struct.pack('=I', len(raw)))
    stream.write(raw)
    stream.flush()


def check_socket(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ProtocolError('App socket must be owned by this user with mode 0600.')
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise ProtocolError('App socket directory must be user-owned and not group/world writable.')


def bridge(path: Path, input_stream: BinaryIO, output_stream: BinaryIO) -> None:
    check_socket(path)
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(3)
    connection.connect(str(path))
    connection.settimeout(None)
    stopped = threading.Event()

    def from_browser() -> None:
        try:
            while not stopped.is_set():
                raw = read_frame(input_stream)
                message = validate(raw)
                if message['type'] == 'browser.request':
                    raise ProtocolError('Browser cannot originate native action requests.')
                # JSON may contain whitespace/newlines; compact before line framing.
                encoded = json.dumps(message, separators=(',', ':'), ensure_ascii=False).encode()
                if len(encoded) > MAX_MESSAGE_BYTES:
                    raise ProtocolError('Message exceeds transport budget.')
                connection.sendall(encoded + b'\n')
        except (EOFError, OSError, ProtocolError) as error:
            if not isinstance(error, EOFError):
                print(f'Browser transport stopped: {error}', file=sys.stderr)
        finally:
            stopped.set()
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    reader = threading.Thread(target=from_browser, name='browser-input', daemon=True)
    reader.start()
    try:
        with connection.makefile('rb') as stream:
            while not stopped.is_set():
                line = stream.readline(MAX_MESSAGE_BYTES + 2)
                if not line:
                    break
                if len(line) > MAX_MESSAGE_BYTES + 1 or not line.endswith(b'\n'):
                    raise ProtocolError('App message exceeds transport budget or lacks framing.')
                raw = line[:-1]
                if validate(raw)['type'] != 'browser.request':
                    raise ProtocolError('App may only send browser.request messages.')
                write_frame(output_stream, raw)
    finally:
        stopped.set()
        connection.close()
        reader.join(timeout=1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin', nargs='?', help='Chrome supplies the extension origin.')
    parser.add_argument('--socket', type=Path, default=DEFAULT_SOCKET)
    args = parser.parse_args()
    try:
        bridge(args.socket, sys.stdin.buffer, sys.stdout.buffer)
        return 0
    except (OSError, ProtocolError) as error:
        print(f'OpenCompanion browser bridge: {error}', file=sys.stderr)
        try:
            raw = json.dumps({'protocolVersion': 1, 'type': 'browser.error', 'error': 'Open the OpenCompanion app and enable its browser bridge, then reconnect.'}).encode()
            write_frame(sys.stdout.buffer, raw)
        except (OSError, ProtocolError):
            pass
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
