"""Exercise the release binary against a local WebSocket fixture, without Codex or model calls."""
import base64
import hashlib
import json
import os
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BINARY = ROOT / ".build/release/agentchirp"


def exact(connection, length):
    result = b""
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


def receive(connection):
    first, second = exact(connection, 2)
    assert first == 0x81 and second & 0x80, "client frames must be masked text"
    length = second & 127
    if length == 126:
        length = struct.unpack(">H", exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", exact(connection, 8))[0]
    mask = exact(connection, 4)
    payload = exact(connection, length)
    return json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)))


def send(connection, obj, fragmented=False):
    data = json.dumps(obj).encode()
    def frame(payload, first):
        length = len(payload)
        header = bytes([first, length]) if length < 126 else bytes([first, 126]) + struct.pack(">H", length)
        connection.sendall(header + payload)
    if fragmented:
        frame(data[:5], 1)
        frame(data[5:], 0x80)
    else:
        frame(data, 0x81)


class RuntimeTests(unittest.TestCase):
    def run_server(self, flags=None, mode="normal"):
        with tempfile.TemporaryDirectory(prefix="ccb-", dir="/private/tmp") as directory:
            home = pathlib.Path(directory)
            path = home / "app-server-control/app-server-control.sock"
            path.parent.mkdir()
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(path))
            server.listen()
            methods, errors = [], []
            def serve():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(3)
                        header = b""
                        while not header.endswith(b"\r\n\r\n"):
                            header += exact(connection, 1)
                        key = next(line.split(b":", 1)[1].strip() for line in header.split(b"\r\n")
                                   if line.lower().startswith(b"sec-websocket-key:"))
                        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                        if mode == "bad-handshake":
                            accept = b"invalid"
                        connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                        if mode == "bad-handshake":
                            return
                        while True:
                            request = receive(connection)
                            method = request["method"]
                            methods.append(method)
                            if method == "initialized":
                                continue
                            if mode == "timeout":
                                time.sleep(1.2)
                                return
                            if method == "initialize":
                                result = {"userAgent": "fixture"}
                            elif method == "thread/loaded/list":
                                if mode == "disconnect":
                                    return
                                if mode == "approval-request":
                                    send(connection, {"id": 900, "method": "item/commandExecution/requestApproval", "params": {}})
                                    # Observer must close without replying to the request.
                                    self.assertEqual(connection.recv(4096), b"")
                                    return
                                result = {"data": ["root"], "nextCursor": None}
                            elif method == "thread/read":
                                self.assertFalse(request["params"]["includeTurns"])
                                result = {"thread": {"id": "root", "cwd": "/tmp/project", "source": "cli",
                                                       "status": {"type": "active", "activeFlags": flags or []}}}
                            else:
                                raise AssertionError("Unexpected mutating request: " + method)
                            send(connection, {"id": request["id"], "result": result}, fragmented=True)
                except EOFError:
                    pass
                except Exception as error:
                    errors.append(error)
            worker = threading.Thread(target=serve)
            worker.start()
            result = subprocess.run([str(BINARY), "--codex-status"], env=dict(os.environ, CODEX_HOME=directory),
                                    text=True, capture_output=True, timeout=5)
            worker.join(timeout=4)
            server.close()
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(set(methods) <= {"initialize", "initialized", "thread/loaded/list", "thread/read"})
            return result

    def test_pending_and_answered_status(self):
        for flags, state in [(["waitingOnApproval"], "waiting"), (["waitingOnUserInput"], "waiting"), ([], "working")]:
            result = self.run_server(flags)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)[0]["state"], state)

    def test_disconnect_does_not_reuse_status(self):
        self.assertNotEqual(self.run_server(mode="disconnect").returncode, 0)

    def test_unexpected_approval_is_never_answered(self):
        self.assertNotEqual(self.run_server(mode="approval-request").returncode, 0)

    def test_unresponsive_server_is_bounded(self):
        self.assertNotEqual(self.run_server(mode="timeout").returncode, 0)

    def test_invalid_handshake_is_rejected(self):
        self.assertNotEqual(self.run_server(mode="bad-handshake").returncode, 0)


if __name__ == "__main__":
    unittest.main()
