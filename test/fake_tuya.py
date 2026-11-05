"""A fake Tuya LAN device (protocol 3.3 or 3.4) for testing the driver without hardware.

It speaks the device side of the 0x55AA protocol: DP queries, control, heartbeats,
UPDATEDPS, and 3.4 session-key negotiation, and pushes STATUS frames on every change,
as real devices do. Checked against tinytuya (the reference client) in run_tests.py
before the driver is tested against it.
"""

import hashlib
import hmac
import json
import os
import socket
import struct
import threading
import time
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PREFIX, SUFFIX = 0x000055AA, 0x0000AA55
NO_HEADER = {3, 4, 5, 9, 10, 16, 18}


def aes(key, data, encrypt=True):
    c = Cipher(algorithms.AES(key), modes.ECB())
    op = c.encryptor() if encrypt else c.decryptor()
    return op.update(data) + op.finalize()


def pad(b):
    n = 16 - len(b) % 16
    return b + bytes([n]) * n


def unpad(b):
    n = b[-1] if b else 0
    if not 1 <= n <= 16 or b[-n:] != bytes([n]) * n:
        raise ValueError("bad padding")
    return b[:-n]


class FakeTuya:
    def __init__(self, dev_id, key, version=3.3, dps=None, port=0, device22=False, host="127.0.0.1"):
        self.id = dev_id
        self.real_key = key.encode()
        self.version = version
        self.dps = dict(dps or {})
        self.device22 = device22
        self.log = []  # (cmd, decoded payload) received
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]
        self.conn = None
        self.lock = threading.Lock()
        self.seq = 100
        self.running = True
        self.connections = 0
        threading.Thread(target=self._accept, daemon=True).start()

    # --- framing -------------------------------------------------------------------------
    def _frame(self, cmd, payload, key, retcode=True):
        if retcode:
            payload = struct.pack(">I", 0) + payload
        use_hmac = self.version >= 3.4
        end = 36 if use_hmac else 8
        self.seq += 1
        body = struct.pack(">4I", PREFIX, self.seq, cmd, len(payload) + end) + payload
        check = hmac.new(key, body, hashlib.sha256).digest() if use_hmac else struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        return body + check + struct.pack(">I", SUFFIX)

    def _encrypt_payload(self, cmd, text, key):
        raw = text.encode() if isinstance(text, str) else text
        vh = ("%.1f" % self.version).encode() + b"\0" * 12
        if self.version >= 3.4:
            if cmd not in NO_HEADER:
                raw = vh + raw
            return aes(key, pad(raw))
        enc = aes(key, pad(raw))
        return enc if cmd in NO_HEADER else vh + enc

    def send(self, cmd, text, key=None):
        key = key or self.key
        # Acks (control, heartbeat) are a bare return code, as on real devices.
        payload = self._encrypt_payload(cmd, text, key) if text else b""
        frame = self._frame(cmd, payload, key)
        with self.lock:
            if self.conn:
                try:
                    self.conn.sendall(frame)
                except OSError:
                    pass

    def push_status(self, changed):
        """What a device sends when its state changes (from a command or a button press)."""
        self.dps.update(changed)
        if self.version >= 3.4:
            body = {"protocol": 4, "t": int(time.time()), "data": {"dps": changed}}
        else:
            body = {"devId": self.id, "dps": changed, "t": int(time.time())}
        self.send(8, json.dumps(body, separators=(",", ":")))

    def drop(self):
        with self.lock:
            if self.conn:
                try:
                    self.conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.conn.close()
                self.conn = None

    def close(self):
        self.running = False
        self.drop()
        self.sock.close()

    # --- device side ---------------------------------------------------------------------
    def _accept(self):
        while self.running:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            with self.lock:
                if self.conn:
                    self.conn.close()
                self.conn = c
            self.connections += 1
            self.key = self.real_key
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        buf = b""
        while self.running:
            try:
                data = c.recv(4096)
            except OSError:
                return
            if not data:
                return
            buf += data
            while len(buf) >= 16:
                start = buf.find(b"\x00\x00\x55\xaa")
                if start < 0:
                    buf = b""
                    break
                buf = buf[start:]
                _, seq, cmd, length = struct.unpack(">4I", buf[:16])
                if len(buf) < 16 + length:
                    break
                frame, buf = buf[: 16 + length], buf[16 + length:]
                self._handle(cmd, frame)

    def _handle(self, cmd, frame):
        use_hmac = self.version >= 3.4
        end = 36 if use_hmac else 8
        body, check = frame[:-end], frame[-end:-4]
        key = self.key
        if use_hmac:
            if hmac.new(key, body, hashlib.sha256).digest() != check:
                self.log.append((cmd, "BAD HMAC"))
                return
        elif struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF) != check:
            self.log.append((cmd, "BAD CRC"))
            return
        payload = body[16:]
        if self.version < 3.4 and payload[:3] == b"3.3":
            payload = payload[15:]
        try:
            plain = unpad(aes(key, payload, encrypt=False))
        except Exception:
            self.log.append((cmd, "UNDECRYPTABLE"))
            return
        if self.version >= 3.4 and plain[:3] == b"3.4":
            plain = plain[15:]

        if cmd == 3:  # session start: prove we hold the key, send our nonce
            self.local_nonce = plain
            self.remote_nonce = os.urandom(16)
            resp = self.remote_nonce + hmac.new(self.real_key, self.local_nonce, hashlib.sha256).digest()
            self.log.append((cmd, "nonce"))
            self.send(4, resp, key=self.real_key)
            return
        if cmd == 5:
            expect = hmac.new(self.real_key, self.remote_nonce, hashlib.sha256).digest()
            self.log.append((cmd, "ok" if plain == expect else "BAD FINISH"))
            xor = bytes(a ^ b for a, b in zip(self.local_nonce, self.remote_nonce))
            self.key = aes(self.real_key, xor)
            return

        text = plain.decode(errors="replace")
        try:
            msg = json.loads(text) if text else {}
        except ValueError:
            msg = {"raw": text}
        self.log.append((cmd, msg))

        if cmd == 9:
            self.send(9, b"")
        elif cmd == 10:
            if self.device22:
                frame = self._frame(10, b"json obj data unvalid", self.key)
                with self.lock:
                    self.conn and self.conn.sendall(frame)
            else:
                self.send(10, json.dumps({"devId": self.id, "dps": self.dps}, separators=(",", ":")))
        elif cmd == 16:
            self.send(16, json.dumps({"dps": self.dps}, separators=(",", ":")))
        elif cmd in (7, 13):
            dps = msg.get("dps") or (msg.get("data") or {}).get("dps") or {}
            if cmd == 13 and all(v is None for v in dps.values()):
                # device22 query: report the asked-for DPs.
                self.send(8, json.dumps({"devId": self.id, "dps": {k: self.dps[k] for k in dps if k in self.dps}}, separators=(",", ":")))
                return
            self.send(cmd, b"")
            self.push_status(dps)
        elif cmd == 18:
            asked = {str(d): self.dps[str(d)] for d in msg.get("dpId", []) if str(d) in self.dps}
            if asked:
                self.push_status(asked)
