"""A fake Tuya Smart Life (device-sharing) cloud for the bridge's Smart Life account.

Login: POST/GET /v1.0/m/life/home-assistant/qrcode/tokens on the login host; `scan()` stands in
for confirming the QR code in the app. API: every request is checked the way Tuya does it
(X-sign over the headers and encrypted data, keyed from the request id and refresh token), query
and body `encdata` are AES-GCM-decrypted, and every result is AES-GCM-encrypted back, using
Python's own AES-GCM so the bridge's Lua implementation is checked against a reference.
"""

import base64
import hashlib
import hmac
import json
import os
import random
import re
import time
from urllib.parse import parse_qsl, unquote, urlsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

CLIENT_ID = "HA_3y9q4ak7g4ephrvke"
LOGIN_HOST = "apigw.iotbing.com"
API_HOST = "apigw.fake-tuyaus.example"
NONCE_CHARS = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678"

PLUG = [(1, "switch_1"), (18, "cur_current"), (19, "cur_power"), (20, "cur_voltage")]
LIGHT = [(20, "switch_led"), (21, "work_mode"), (22, "bright_value_v2"), (23, "temp_value_v2"), (24, "colour_data_v2")]


def seal(plain: bytes, secret: bytes) -> str:
    nonce = "".join(random.choice(NONCE_CHARS) for _ in range(12)).encode()
    return (base64.b64encode(nonce) + base64.b64encode(AESGCM(secret).encrypt(nonce, plain, None))).decode()


def open_(sealed: str, secret: bytes) -> bytes:
    raw = base64.b64decode(sealed)
    return AESGCM(secret).decrypt(raw[:12], raw[12:], None)  # raises if the tag is wrong


class FakeSmartLife:
    def __init__(self, user_code="usercode123"):
        self.user_code = user_code
        self.qr = None
        self.scanned = False
        self.access, self.refresh = "acc-" + os.urandom(4).hex(), "ref-" + os.urandom(4).hex()
        self.expire = 7200
        self.homes = [{"ownerId": 1001, "name": "Home"}]
        self.devices = {}  # id -> {name, local_key, category, product_name, online, kind, status{code: value}}
        self.calls = []  # (method, path, decoded params, decoded body)
        self.commands = []  # (id, [commands])
        self.refreshes = 0

    def add(self, dev_id, name, key, kind="plug", online=True, **status):
        base = {"switch_1": False, "cur_current": 0, "cur_power": 0, "cur_voltage": 1200} if kind == "plug" else \
            {"switch_led": False, "work_mode": "white", "bright_value_v2": 1000, "temp_value_v2": 500,
             "colour_data_v2": json.dumps({"h": 0, "s": 1000, "v": 1000})}
        base.update(status)
        self.devices[dev_id] = {"name": name, "local_key": key, "category": "cz" if kind == "plug" else "dj",
                                "product_name": "Smart " + kind, "online": online, "kind": kind, "status": base}

    def scan(self):
        self.scanned = True

    def _device(self, dev_id):
        d = self.devices[dev_id]
        return {"id": dev_id, "name": d["name"], "local_key": d["local_key"], "category": d["category"],
                "product_name": d["product_name"], "online": d["online"], "ip": "203.0.113.9", "uuid": dev_id,
                "status": [{"code": c, "value": v} for c, v in d["status"].items()]}

    def _ok(self, result, secret):
        body = {"success": True, "t": int(time.time() * 1000)}
        if result is not None:
            body["result"] = seal(json.dumps(result).encode(), secret)
        return 200, json.dumps(body)

    def _err(self, code, msg):
        return 200, json.dumps({"success": False, "code": code, "msg": msg, "t": int(time.time() * 1000)})

    def __call__(self, method, url, headers, body):
        u = urlsplit(url)
        q = dict(parse_qsl(u.query))
        if u.netloc == LOGIN_HOST:
            return self._login(method, u.path, q)
        if u.netloc != API_HOST:
            return 404, "{}"
        # --- signed, encrypted API -------------------------------------------------------
        if headers.get("X-appKey") != CLIENT_ID:
            return self._err(1004, "bad appKey")
        rid = headers.get("X-requestId", "")
        hash_key = hashlib.md5((rid + self.refresh).encode()).hexdigest()
        secret = hmac.new(rid.encode(), hash_key.encode(), hashlib.sha256).hexdigest()[:16].encode()
        query_enc = q.get("encdata", "")
        body_enc = json.loads(body)["encdata"] if body else ""
        sign_str = "||".join(f"{k}={headers[k]}" for k in ("X-appKey", "X-requestId", "X-sid", "X-time", "X-token")
                             if headers.get(k)) + query_enc + body_enc
        want = hmac.new(hash_key.encode(), sign_str.encode(), hashlib.sha256).hexdigest()
        if headers.get("X-sign") != want:
            return self._err(1004, "sign invalid")
        try:
            params = json.loads(open_(query_enc, secret)) if query_enc else {}
            payload = json.loads(open_(body_enc, secret)) if body_enc else {}
        except Exception as e:  # noqa: BLE001 - any decrypt failure is a bad request
            return self._err(1005, f"cannot decrypt: {e}")
        self.calls.append((method, u.path, params, payload))

        m = re.fullmatch(r"/v1\.0/m/token/(.+)", u.path)
        if m:
            if m.group(1) != self.refresh:
                return self._err(1010, "token invalid")
            self.refreshes += 1
            self.access, self.refresh = "acc-" + os.urandom(4).hex(), "ref-" + os.urandom(4).hex()
            return self._ok({"accessToken": self.access, "refreshToken": self.refresh, "expireTime": self.expire, "uid": "u1"}, secret)
        if headers.get("X-token") != self.access:
            return self._err(1010, "token invalid")
        if u.path == "/v1.0/m/life/users/homes":
            return self._ok(self.homes, secret)
        if u.path == "/v1.0/m/life/ha/home/devices":
            if str(params.get("homeId")) != "1001":
                return self._ok([], secret)
            return self._ok([self._device(i) for i in sorted(self.devices)], secret)
        if u.path == "/v1.0/m/life/ha/devices/detail":
            ids = [i for i in params.get("devIds", "").split(",") if i in self.devices]
            return self._ok([self._device(i) for i in ids], secret)
        m = re.fullmatch(r"/v1\.0/m/life/devices/([^/]+)/status", u.path)
        if m and m.group(1) in self.devices:
            rel = PLUG if self.devices[m.group(1)]["kind"] == "plug" else LIGHT
            return self._ok({"productKey": "pk1", "dpStatusRelationDTOS": [
                {"dpId": dp, "statusCode": code, "supportLocal": True, "valueType": "x"} for dp, code in rel]}, secret)
        m = re.fullmatch(r"/v1\.1/m/thing/([^/]+)/commands", u.path)
        if m and method == "POST" and m.group(1) in self.devices:
            cmds = payload["commands"]
            self.commands.append((m.group(1), cmds))
            st = self.devices[m.group(1)]["status"]
            for c in cmds:
                st[c["code"]] = json.dumps(c["value"]) if isinstance(c["value"], dict) else c["value"]
            return self._ok(True, secret)
        return self._err(1106, "permission deny")

    def _login(self, method, path, q):
        if q.get("clientid") != CLIENT_ID or q.get("usercode") != self.user_code:
            return 200, json.dumps({"success": False, "code": 1106, "msg": "user code not found"})
        if method == "POST" and path == "/v1.0/m/life/home-assistant/qrcode/tokens":
            self.qr = "qr" + os.urandom(6).hex()
            return 200, json.dumps({"success": True, "result": {"qrcode": self.qr}})
        m = re.fullmatch(r"/v1\.0/m/life/home-assistant/qrcode/tokens/(.+)", path)
        if method == "GET" and m and unquote(m.group(1)) == self.qr:
            if not self.scanned:
                return 200, json.dumps({"success": False, "code": 1001, "msg": "not confirmed yet"})
            return 200, json.dumps({"success": True, "t": int(time.time() * 1000), "result": {
                "access_token": self.access, "refresh_token": self.refresh, "expire_time": self.expire, "uid": "u1",
                "endpoint": "https://" + API_HOST, "terminal_id": "term1", "username": "joe@example.com"}})
        return 200, json.dumps({"success": False, "code": 1106, "msg": "bad login request"})
