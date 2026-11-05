"""Run one fake Tuya device on the LAN, for testing a driver on a real controller.

    python3 test/serve.py light|plug [--version 3.3|3.4] [--host 0.0.0.0]

Listens on port 6668 (Tuya's), prints every command the controller sends and the device's
state after it, and pushes a "physical button press" every --press seconds if asked. Device ID
and Local Key are fixed test values (below); enter them in the driver's properties.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))

from fake_tuya import FakeTuya  # noqa: E402

DEV_ID = "bf0123456789abcdefgh"
KEY = "0123456789abcdef"
DEVICES = {
    "light": {"20": False, "21": "white", "22": 1000, "23": 500, "24": "000003e803e8"},
    "plug": {"1": False, "18": 120, "19": 255, "20": 1203},
}
NAMES = {
    0x07: "CONTROL", 0x08: "STATUS", 0x09: "HEART_BEAT", 0x0A: "DP_QUERY", 0x0D: "CONTROL_NEW",
    0x10: "DP_QUERY_NEW", 0x12: "UPDATEDPS", 0x03: "SESS_START", 0x05: "SESS_FINISH",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=DEVICES)
    ap.add_argument("--version", type=float, default=3.3)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--press", type=float, default=0, help="toggle the switch every N seconds (0 = never)")
    ap.add_argument("--broadcast", metavar="IP", help="announce on UDP 6667 every 5 s as this IP, like a real device")
    a = ap.parse_args()

    fake = FakeTuya(DEV_ID, KEY, a.version, DEVICES[a.kind], port=6668, host=a.host)
    switch = "20" if a.kind == "light" else "1"
    print(f"fake {a.kind} (protocol {a.version}) on {a.host}:6668  id={DEV_ID}  key={KEY}", flush=True)
    seen, last_press, last_bc = 0, time.time(), 0
    if a.broadcast:
        import socket
        bc = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        bc.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        time.sleep(0.2)
        while seen < len(fake.log):
            cmd, msg = fake.log[seen]
            seen += 1
            if cmd != 0x09:  # heartbeats are noise
                print(f"{time.strftime('%H:%M:%S')} <- {NAMES.get(cmd, cmd)} {json.dumps(msg)}", flush=True)
                print(f"           state {json.dumps(fake.dps, sort_keys=True)}", flush=True)
        if a.broadcast and time.time() - last_bc >= 5:
            last_bc = time.time()
            # The subnet's broadcast address: a Mac on several networks may not send 255.255.255.255
            # out of the interface this IP is on.
            bc.sendto(fake.broadcast_packet(a.broadcast), (a.broadcast.rsplit(".", 1)[0] + ".255", 6667))
        if a.press and time.time() - last_press >= a.press:
            last_press = time.time()
            fake.push_status({switch: not fake.dps[switch]})
            print(f"{time.strftime('%H:%M:%S')} -> button press: {switch}={fake.dps[switch]}", flush=True)


if __name__ == "__main__":
    main()
