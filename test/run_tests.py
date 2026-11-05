"""End-to-end tests: tinytuya checks the fake device, then each driver runs against it.

    ./build.sh && python3 test/run_tests.py

Needs: lupa, cryptography, tinytuya (pip install lupa cryptography tinytuya).
"""

import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))

from fake_tuya import FakeTuya  # noqa: E402
from harness import Harness  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIGHT = os.path.join(ROOT, "drivers/light/driver.lua")
PLUG = os.path.join(ROOT, "drivers/plug/driver.lua")
KEY = "0123456789abcdef"
DEV = "bf0123456789abcdefgh"

RESULTS = []


def test(fn):
    RESULTS.append(fn)
    return fn


def driver(path, fake, **props):
    base = {
        "Device IP": "127.0.0.1",
        "Device ID": fake.id,
        "Local Key": KEY,
        "Protocol Version": "%.1f" % fake.version,
        "Poll Interval (seconds)": "60",
        "Debug Mode": "On",
    }
    base.update(props)
    h = Harness(path, base)
    # The fake listens on a random port; point the driver at it.
    h.lua.globals().TUYA_PORT = fake.port
    h.init()
    assert h.run(3, lambda: h.status() == "Online"), f"never came online: {h.status()} {h.properties.get('Last Error')}"
    return h


def sent(fake, cmd):
    return [m for c, m in fake.log if c == cmd]


def level(h):
    p = h.last("LIGHT_BRIGHTNESS_CHANGED")
    return p and p["LIGHT_BRIGHTNESS_CURRENT"]


# --- the fake against the reference client --------------------------------------------------
@test
def tinytuya_agrees_with_fake_33_and_34():
    import tinytuya
    for version in (3.3, 3.4):
        fake = FakeTuya(DEV, KEY, version, {"1": False, "20": True})
        d = tinytuya.OutletDevice(DEV, "127.0.0.1", KEY, version=version, port=fake.port, connection_timeout=3)
        st = d.status()
        assert st.get("dps", {}).get("1") is False, (version, st)
        d.set_value(1, True, nowait=True)
        import time
        time.sleep(0.3)
        assert fake.dps["1"] is True, (version, fake.log)
        d.close()
        fake.close()


# --- plug -------------------------------------------------------------------------------------
@test
def plug_33_on_off_toggle_and_physical_press():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False, "18": 120, "19": 255, "20": 1203})
    h = driver(PLUG, fake)
    assert h.run(2, lambda: level(h) == 0), h.notifies
    assert h.last("ONLINE_CHANGED")["STATE"] is True

    h.proxy("ON")
    assert h.run(2, lambda: fake.dps["1"] is True), fake.log
    assert sent(fake, 7)[-1]["dps"] == {"1": True}
    assert level(h) == 100

    h.proxy("TOGGLE")
    assert h.run(2, lambda: fake.dps["1"] is False)
    assert h.run(1, lambda: level(h) == 0)

    # Someone presses the button on the plug.
    fake.push_status({"1": True})
    assert h.run(2, lambda: level(h) == 100), h.notifies

    h.proxy("SET_LEVEL", LEVEL=0)
    assert h.run(2, lambda: fake.dps["1"] is False)
    fake.close()


@test
def plug_reports_power_after_refresh():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": True, "18": 120, "19": 255, "20": 1203})
    h = driver(PLUG, fake)
    assert h.run(2, lambda: h.properties.get("Power (W)") == "25.5"), h.properties
    fake.dps["19"] = 600
    h.g("ExecuteCommand")(b"Refresh Now", h.to_lua({}))
    assert h.run(2, lambda: h.properties.get("Power (W)") == "60"), (h.properties, fake.log)
    assert sent(fake, 18), "no UPDATEDPS sent"
    assert h.variables.get("VOLTAGE_V") == "120.3", h.variables
    fake.close()


@test
def plug_variables_exist_before_any_reading():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    h = driver(PLUG, fake)
    assert {"POWER_W", "VOLTAGE_V", "CURRENT_MA"} <= set(h.variables), h.variables
    fake.close()


@test
def plug_switch_dp_for_second_gang():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False, "2": False})
    h = driver(PLUG, fake, **{"Switch DP": "2"})
    h.proxy("ON")
    assert h.run(2, lambda: fake.dps["2"] is True)
    assert fake.dps["1"] is False
    fake.close()


# --- light ------------------------------------------------------------------------------------
STANDARD = {"20": False, "21": "white", "22": 1000, "23": 500, "24": "000003e803e8"}


@test
def light_33_standard_level_and_capabilities():
    fake = FakeTuya(DEV, KEY, 3.3, STANDARD)
    h = driver(LIGHT, fake)
    assert h.run(2, lambda: h.properties.get("Detected Profile") == "Standard (DP 20-24)")
    caps = h.last("DYNAMIC_CAPABILITIES_CHANGED")
    assert caps["supports_color"] is True and caps["supports_color_correlated_temperature"] is True, caps

    h.proxy("SET_LEVEL", LEVEL=50)
    assert h.run(2, lambda: fake.dps["22"] == 500 and fake.dps["20"] is True), fake.log
    assert level(h) == 50

    h.proxy("SET_BRIGHTNESS_TARGET", LIGHT_BRIGHTNESS_TARGET=1)
    assert h.run(2, lambda: fake.dps["22"] == 10)
    h.proxy("SET_BRIGHTNESS_TARGET", LIGHT_BRIGHTNESS_TARGET=100)
    assert h.run(2, lambda: fake.dps["22"] == 1000)

    h.proxy("OFF")
    assert h.run(2, lambda: fake.dps["20"] is False)
    assert h.run(1, lambda: level(h) == 0)

    # The app dims it to 30%: the driver follows.
    fake.push_status({"20": True, "22": 297})
    assert h.run(2, lambda: level(h) == 30), h.last("LIGHT_BRIGHTNESS_CHANGED")
    fake.close()


@test
def light_colour_and_white_targets():
    fake = FakeTuya(DEV, KEY, 3.3, dict(STANDARD, **{"20": True}))
    h = driver(LIGHT, fake)
    h.run(1, lambda: h.properties.get("Detected Profile"))

    h.proxy("SET_LEVEL", LEVEL=100)
    h.run(1)
    # Red, full colour mode.
    h.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.64, LIGHT_COLOR_TARGET_Y=0.33, LIGHT_COLOR_TARGET_MODE=0)
    assert h.run(2, lambda: fake.dps["21"] == "colour"), fake.log
    hue, sat, val = int(fake.dps["24"][0:4], 16), int(fake.dps["24"][4:8], 16), int(fake.dps["24"][8:12], 16)
    assert (hue <= 2 or hue >= 358) and sat >= 990 and val == 1000, fake.dps["24"]
    told = h.last("LIGHT_COLOR_CHANGED")
    assert told["LIGHT_COLOR_CURRENT_COLOR_MODE"] == 0, told

    # Blue: hue ~240.
    h.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.15, LIGHT_COLOR_TARGET_Y=0.06, LIGHT_COLOR_TARGET_MODE=0)
    assert h.run(2, lambda: 230 <= int(fake.dps["24"][0:4], 16) <= 250), fake.dps["24"]

    # Dimming in colour mode changes the colour's value, not the white brightness.
    h.proxy("SET_LEVEL", LEVEL=50)
    assert h.run(2, lambda: int(fake.dps["24"][8:12], 16) == 500), fake.dps
    assert fake.dps["22"] == 1000

    # 2700 K white (warmest) and 6500 K (coolest).
    h.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.4599, LIGHT_COLOR_TARGET_Y=0.4106, LIGHT_COLOR_TARGET_MODE=1)
    assert h.run(2, lambda: fake.dps["21"] == "white"), fake.log
    assert fake.dps["23"] <= 15, fake.dps["23"]
    h.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.3127, LIGHT_COLOR_TARGET_Y=0.3290, LIGHT_COLOR_TARGET_MODE=1)
    assert h.run(2, lambda: fake.dps["23"] >= 985), fake.dps["23"]
    assert h.last("LIGHT_COLOR_CHANGED")["LIGHT_COLOR_CURRENT_COLOR_MODE"] == 1

    # A colour set from the app is reported back as xy.
    fake.push_status({"21": "colour", "24": "007803e803e8"})  # hue 120 = green
    def green():
        c = h.last("LIGHT_COLOR_CHANGED")
        return c and c["LIGHT_COLOR_CURRENT_COLOR_MODE"] == 0 and c["LIGHT_COLOR_CURRENT_Y"] > 0.5
    assert h.run(2, green), h.last("LIGHT_COLOR_CHANGED")
    fake.close()


@test
def light_34_session_and_control():
    fake = FakeTuya(DEV, KEY, 3.4, STANDARD)
    h = driver(LIGHT, fake)
    assert [m for c, m in fake.log if c == 5] == ["ok"], fake.log
    assert h.run(2, lambda: sent(fake, 16)), "no DP_QUERY_NEW"
    h.proxy("SET_LEVEL", LEVEL=75)
    assert h.run(2, lambda: fake.dps["22"] == 750 and fake.dps["20"] is True), fake.log
    assert sent(fake, 13)[-1]["protocol"] == 5
    fake.push_status({"20": False})
    assert h.run(2, lambda: level(h) == 0)
    fake.close()


@test
def light_legacy_profile():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": True, "2": "white", "3": 255, "4": 0, "5": "ff00000000ffff"})
    h = driver(LIGHT, fake)
    assert h.run(2, lambda: h.properties.get("Detected Profile") == "Legacy (DP 1-5)")
    h.proxy("SET_LEVEL", LEVEL=1)
    assert h.run(2, lambda: fake.dps["3"] == 25), fake.dps
    h.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.17, LIGHT_COLOR_TARGET_Y=0.7, LIGHT_COLOR_TARGET_MODE=0)
    assert h.run(2, lambda: fake.dps["2"] == "colour")
    assert len(fake.dps["5"]) == 14, fake.dps["5"]
    fake.close()


# --- failure handling -------------------------------------------------------------------------
@test
def wrong_key_34_says_so():
    # A device ignores a handshake signed with another key, as this fake does.
    fake = FakeTuya(DEV, KEY, 3.4, STANDARD)
    h = Harness(LIGHT, {"Device IP": "127.0.0.1", "Device ID": DEV, "Local Key": "fedcba9876543210", "Protocol Version": "3.4"})
    h.lua.globals().TUYA_PORT = fake.port
    h.lua.globals().CONNECT_TIMEOUT_MS = 500
    h.init()
    assert h.run(3, lambda: "handshake" in (h.properties.get("Last Error") or "")), h.properties
    assert fake.log and fake.log[0] == (3, "BAD HMAC"), fake.log
    fake.close()


@test
def wrong_key_33_reports_error():
    fake = FakeTuya(DEV, KEY, 3.3, STANDARD)
    h = Harness(LIGHT, {"Device IP": "127.0.0.1", "Device ID": DEV, "Local Key": "fedcba9876543210", "Protocol Version": "3.3"})
    h.lua.globals().TUYA_PORT = fake.port
    h.lua.globals().QUERY_TIMEOUT_MS = 500
    h.init()
    # 3.3 has no handshake; the device ignores frames it cannot decrypt, so no state arrives.
    assert h.run(3, lambda: h.status() == "No Response"), h.properties
    assert "Local Key" in h.properties.get("Last Error", "")
    assert fake.log and all(m == "UNDECRYPTABLE" for _, m in fake.log), fake.log
    fake.close()


@test
def reconnects_after_device_drops():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    h = driver(PLUG, fake)
    fake.drop()
    assert h.run(2, lambda: h.status() == "Offline"), h.status()
    assert h.last("ONLINE_CHANGED")["STATE"] is False
    # A command given while offline lands once it is back.
    h.proxy("ON")
    assert h.run(6, lambda: h.status() == "Online"), h.status()
    assert h.run(2, lambda: fake.dps["1"] is True), fake.log
    fake.close()


@test
def device22_falls_back_to_control_new_query():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": True}, device22=True)
    h = driver(PLUG, fake)
    assert h.run(2, lambda: level(h) == 100), (fake.log, h.prints[-5:])
    assert sent(fake, 13), "no CONTROL_NEW query"
    fake.close()


@test
def heartbeat_keeps_session_and_detects_silence():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    h = driver(PLUG, fake)
    h.lua.globals().HEARTBEAT_MS = 200
    h.g("RestartSession")()
    assert h.run(3, lambda: h.status() == "Online")
    h.run(1.5)
    assert len(sent(fake, 9)) >= 3, fake.log
    assert h.status() == "Online"
    fake.close()


@test
def unsupported_protocol_is_refused_by_name():
    h = Harness(PLUG, {"Device IP": "127.0.0.1", "Device ID": DEV, "Local Key": KEY, "Protocol Version": "3.5"})
    h.init()
    assert "3.5" in (h.properties.get("Last Error") or ""), h.properties


def main():
    failed = 0
    for fn in RESULTS:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception:
            failed += 1
            print("FAIL", fn.__name__)
            traceback.print_exc()
    print(f"{len(RESULTS) - failed}/{len(RESULTS)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
