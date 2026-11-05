"""Runs a built driver.lua in Lua 5.1 (lupa) with the parts of Control4's DriverWorks API it
uses: C4:CreateTCPClient (real sockets), C4:SetTimer, C4:Encrypt/Decrypt (AES-128-ECB),
C4:HMAC, C4:JsonDecode, C4:SendToProxy, C4:UpdateProperty and variables.

Not Director: it checks the driver's protocol and logic, not how Director schedules it.
"""

import hashlib
import heapq
import hmac
import itertools
import json
import selectors
import socket
import time

import lupa.lua51 as lua51
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def b(x):
    return x if isinstance(x, bytes) else str(x).encode()


class Timer:
    def __init__(self, h, due, ms, fn, repeat):
        self.h, self.due, self.ms, self.fn, self.repeat, self.cancelled = h, due, ms, fn, repeat, False

    def Cancel(self, *_):
        self.cancelled = True


class TcpClient:
    def __init__(self, h):
        self.h = h
        self.cb = {}
        self.sock = None
        self.connected = False

    def _set(self, name, args):
        self.cb[name] = args[-1]
        return self

    def OnConnect(self, *a): return self._set("connect", a)
    def OnRead(self, *a): return self._set("read", a)
    def OnDisconnect(self, *a): return self._set("disconnect", a)
    def OnError(self, *a): return self._set("error", a)
    def OnWrite(self, *a): return self._set("write", a)
    def OnResolve(self, *a): return self._set("resolve", a)
    def ReadAtLeast(self, *a): return self
    def ReadUpTo(self, *a): return self

    def Connect(self, *a):
        host, port = a[-2], a[-1]
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setblocking(False)
        try:
            self.sock.connect((b(host).decode(), int(port)))
        except BlockingIOError:
            pass
        self.h.sel.register(self.sock, selectors.EVENT_WRITE | selectors.EVENT_READ, self)
        return self

    def Write(self, *a):
        data = b(a[-1])
        if self.sock and self.connected:
            try:
                self.sock.sendall(data)
            except OSError:
                pass
        return self

    def Close(self, *a):
        if self.sock:
            try:
                self.h.sel.unregister(self.sock)
            except Exception:
                pass
            self.sock.close()
            self.sock = None
        self.connected = False
        return self

    def _event(self, mask):
        if not self.connected and mask & selectors.EVENT_WRITE:
            err = self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if err:
                self.Close()
                self.h.call(self.cb.get("error"), self, err, b"connection refused")
                return
            self.connected = True
            self.h.sel.modify(self.sock, selectors.EVENT_READ, self)
            self.h.call(self.cb.get("connect"), self)
            return
        if mask & selectors.EVENT_READ and self.sock:
            try:
                data = self.sock.recv(65536)
            except OSError:
                data = b""
            if not data:
                self.Close()
                self.h.call(self.cb.get("disconnect"), self, 0, b"closed")
                return
            self.h.call(self.cb.get("read"), self, data)


class Harness:
    def __init__(self, driver_lua, properties):
        self.lua = lua51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.sel = selectors.DefaultSelector()
        self.timers = []
        self.counter = itertools.count()
        self.notifies = []  # (command, {params})
        self.prints = []
        self.variables = {}
        self.properties = dict(properties)
        g = self.lua.globals()
        g.Properties = self.lua.table_from({k.encode(): b(v) for k, v in self.properties.items()})
        g.C4 = self._c4()
        g.print = lambda *a: self.prints.append(" ".join(x.decode(errors="replace") if isinstance(x, bytes) else str(x) for x in a))
        self.lua.execute(open(driver_lua, "rb").read())

    # --- Lua <-> Python ------------------------------------------------------------------
    def to_lua(self, v):
        if isinstance(v, dict):
            return self.lua.table_from({b(k): self.to_lua(x) for k, x in v.items() if x is not None})
        if isinstance(v, list):
            return self.lua.table_from([self.to_lua(x) for x in v])
        if isinstance(v, str):
            return v.encode()
        return v

    def from_lua(self, v):
        if lua51.lua_type(v) == "table":
            return {(k.decode() if isinstance(k, bytes) else k): self.from_lua(x) for k, x in v.items()}
        if isinstance(v, bytes):
            return v.decode(errors="replace")
        return v

    def call(self, fn, *args):
        if fn is not None:
            fn(*args)

    def _c4(self):
        h = self
        lua = self.lua

        def aes(cipher, key, iv, data, encrypt):
            assert b(cipher) == b"AES-128-ECB", cipher
            # Director refuses any IV for ECB: "The specified iv was too long".
            if iv is not None and len(b(iv)) > 0:
                return None, b"The specified iv was too long"
            c = Cipher(algorithms.AES(b(key)), modes.ECB())
            op = c.encryptor() if encrypt else c.decryptor()
            data = b(data)
            if len(data) % 16:
                return None, b"data not a multiple of the block size"
            return op.update(data) + op.finalize()

        def set_timer(_, ms, fn, repeat=False):
            t = Timer(h, time.monotonic() + ms / 1000, ms, fn, bool(repeat))
            heapq.heappush(h.timers, (t.due, next(h.counter), t))
            return t

        def json_decode(_, text):
            return h.to_lua(json.loads(b(text).decode()))

        def send_to_proxy(_, binding, command, params, kind=None):
            p = h.from_lua(params) if lua51.lua_type(params) == "table" else params
            h.notifies.append((b(command).decode(), p))

        def update_property(_, name, value):
            h.properties[b(name).decode()] = b(value).decode(errors="replace")

        def add_variable(_, name, value, *a):
            h.variables[b(name).decode()] = b(value).decode()
            return True

        def set_variable(_, name, value):
            h.variables[b(name).decode()] = b(value).decode()

        return lua.table_from({
            b"Encrypt": lambda _, c, k, iv, d, o=None: aes(c, k, iv, d, True),
            b"Decrypt": lambda _, c, k, iv, d, o=None: aes(c, k, iv, d, False),
            b"HMAC": lambda _, alg, k, d, o=None: hmac.new(b(k), b(d), hashlib.sha256).digest(),
            b"JsonDecode": json_decode,
            b"SetTimer": set_timer,
            b"CreateTCPClient": lambda _: TcpClient(h),
            b"SendToProxy": send_to_proxy,
            b"UpdateProperty": update_property,
            b"AddVariable": add_variable,
            b"SetVariable": set_variable,
        })

    # --- driving it ----------------------------------------------------------------------
    def g(self, name):
        return self.lua.globals()[name.encode()]

    def init(self):
        self.g("OnDriverInit")(b"")
        self.g("OnDriverLateInit")(b"")

    def proxy(self, command, **params):
        self.g("ReceivedFromProxy")(5001, command.encode(), self.to_lua(params))

    def set_property(self, name, value):
        self.properties[name] = value
        self.lua.globals().Properties[name.encode()] = b(value)
        self.g("OnPropertyChanged")(name.encode())

    def run(self, seconds=0.2, until=None):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if until and until():
                return True
            now = time.monotonic()
            while self.timers and self.timers[0][0] <= now:
                _, _, t = heapq.heappop(self.timers)
                if t.cancelled:
                    continue
                t.fn(t)
                if t.repeat and not t.cancelled:
                    t.due = now + t.ms / 1000
                    heapq.heappush(self.timers, (t.due, next(self.counter), t))
            timeout = 0.02
            if self.timers:
                timeout = max(0, min(timeout, self.timers[0][0] - time.monotonic()))
            for key, mask in (self.sel.select(timeout) if self.sel.get_map() else []):
                key.data._event(mask)
            if not self.sel.get_map():
                time.sleep(timeout)
        return bool(until and until())

    def status(self):
        return self.properties.get("Connection Status")

    def last(self, command):
        for c, p in reversed(self.notifies):
            if c == command:
                return p
        return None
