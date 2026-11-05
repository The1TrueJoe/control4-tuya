"""A fake Tuya IoT platform (OpenAPI) for the bridge's cloud client.

Implements only what the bridge uses, and checks every request's signature the way Tuya
does, so a signing bug fails a test instead of working by accident:
  GET  /v1.0/token?grant_type=1
  GET  /v1.0/iot-01/associated-users/devices?[last_row_key=..&]size=N
  GET  /v1.1/devices/{id}/specifications
  POST /v1.0/iot-03/devices/{id}/commands
"""

import hashlib
import hmac
import json
import re
from urllib.parse import parse_qsl, urlsplit

PLUG_SPEC = [("switch_1", 1, "Boolean"), ("cur_current", 18, "Integer"), ("cur_power", 19, "Integer"), ("cur_voltage", 20, "Integer")]
LIGHT_SPEC = [("switch_led", 20, "Boolean"), ("work_mode", 21, "Enum"), ("bright_value_v2", 22, "Integer"),
              ("temp_value_v2", 23, "Integer"), ("colour_data_v2", 24, "Json")]


class FakeCloud:
    def __init__(self, client_id="testclientid0001", secret="testsecret0000000000000000000001"):
        self.client_id, self.secret = client_id, secret
        self.token = "tok-" + hashlib.md5(secret.encode()).hexdigest()[:12]
        self.devices = {}  # id -> {name, local_key, category, product_name, online, spec, status{code: value}}
        self.calls = []  # (method, path)
        self.commands = []  # (id, [{"code","value"}])
        self.page_size_seen = None
        self.suspended = False  # answer device calls the way a project without IoT Core does

    def add(self, dev_id, name, key, kind="plug", online=True, **status):
        spec = PLUG_SPEC if kind == "plug" else LIGHT_SPEC
        base = {"switch_1": False, "cur_current": 0, "cur_power": 0, "cur_voltage": 1200} if kind == "plug" else \
            {"switch_led": False, "work_mode": "white", "bright_value_v2": 1000, "temp_value_v2": 500,
             "colour_data_v2": json.dumps({"h": 0, "s": 1000, "v": 1000})}
        base.update(status)
        self.devices[dev_id] = {"name": name, "local_key": key, "category": "cz" if kind == "plug" else "dj",
                                "product_name": "Smart " + kind.title(), "online": online, "spec": spec, "status": base}

    def _check_sign(self, method, path, headers, body, with_token):
        t = headers.get("t", "")
        body_hash = hashlib.sha256(body.encode()).hexdigest()
        to_sign = f"{method}\n{body_hash}\n\n{path}"
        s = self.client_id + (self.token if with_token else "") + t + to_sign
        want = hmac.new(self.secret.encode(), s.encode(), hashlib.sha256).hexdigest().upper()
        return headers.get("sign") == want and headers.get("client_id") == self.client_id

    def __call__(self, method, url, headers, body):
        u = urlsplit(url)
        path = u.path + (("?" + u.query) if u.query else "")
        self.calls.append((method, path))
        # Tuya signs the query sorted by key; the client must send it that way.
        if u.query:
            q = parse_qsl(u.query)
            if [k for k, _ in q] != sorted(k for k, _ in q):
                return 200, json.dumps({"success": False, "code": 1004, "msg": "sign invalid (query order)"})
        if u.path == "/v1.0/token":
            if not self._check_sign(method, path, headers, body, False):
                return 200, json.dumps({"success": False, "code": 1004, "msg": "sign invalid"})
            return 200, json.dumps({"success": True, "result": {"access_token": self.token, "expire_time": 7200, "uid": "u1"}})
        if headers.get("access_token") != self.token or not self._check_sign(method, path, headers, body, True):
            return 200, json.dumps({"success": False, "code": 1004, "msg": "sign invalid"})

        if self.suspended:
            return 200, json.dumps({"success": False, "code": 28841107, "msg": "No permission. The data center is suspended."})
        if u.path == "/v1.0/iot-01/associated-users/devices":
            q = dict(parse_qsl(u.query))
            size = int(q.get("size", 20))
            self.page_size_seen = size
            ids = sorted(self.devices)
            start = ids.index(q["last_row_key"]) + 1 if q.get("last_row_key") else 0
            page = ids[start:start + size]
            devs = [{"id": i, "name": d["name"], "local_key": d["local_key"], "category": d["category"],
                     "product_name": d["product_name"], "online": d["online"], "ip": "203.0.113.9",
                     "status": [{"code": c, "value": v} for c, v in d["status"].items()]} for i, d in
                    ((i, self.devices[i]) for i in page)]
            more = start + size < len(ids)
            return 200, json.dumps({"success": True, "result": {"devices": devs, "has_more": more,
                                                                  "last_row_key": page[-1] if page else None}})
        m = re.fullmatch(r"/v1\.1/devices/([^/]+)/specifications", u.path)
        if m and m.group(1) in self.devices:
            spec = self.devices[m.group(1)]["spec"]
            funcs = [{"code": c, "dp_id": dp, "type": t, "values": "{}"} for c, dp, t in spec]
            return 200, json.dumps({"success": True, "result": {"category": "cz", "functions": funcs, "status": funcs}})
        m = re.fullmatch(r"/v1\.0/iot-03/devices/([^/]+)/commands", u.path)
        if m and method == "POST" and m.group(1) in self.devices:
            cmds = json.loads(body)["commands"]
            self.commands.append((m.group(1), cmds))
            d = self.devices[m.group(1)]
            for c in cmds:
                v = c["value"]
                d["status"][c["code"]] = json.dumps(v) if isinstance(v, dict) else v
            return 200, json.dumps({"success": True, "result": True})
        return 200, json.dumps({"success": False, "code": 1106, "msg": "permission deny"})
