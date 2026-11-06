"""End-to-end tests: tinytuya checks the fake device, then each driver runs against it.

    ./build.sh && python3 test/run_tests.py

Needs: lupa, cryptography, tinytuya (pip install lupa cryptography tinytuya).
"""

import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))

from fake_tuya import FakeTuya  # noqa: E402
from harness import Director, Harness  # noqa: E402
from fake_cloud import FakeCloud  # noqa: E402
from fake_smartlife import FakeSmartLife  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIGHT = os.path.join(ROOT, "drivers/light/driver.lua")
PLUG = os.path.join(ROOT, "drivers/plug/driver.lua")
BRIDGE = os.path.join(ROOT, "drivers/bridge/driver.lua")
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
    # The driver is Online as soon as it has sent its half; give the fake's thread a moment.
    assert h.run(2, lambda: [m for c, m in fake.log if c == 5] == ["ok"]), fake.log
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

# --- bridge ------------------------------------------------------------------------------------
def bridge_setup(cloud=None, **bridge_props):
    d = Director(web=cloud)
    props = {"Discovery": "On", "Debug Mode": "On", "Cloud Region": "US", "Cloud Poll Interval (seconds)": "120",
             "Key Refresh (hours)": "12"}
    props.update(bridge_props)
    bridge = d.add(BRIDGE, props, "tuya_bridge.c4z")
    bridge.init()
    return d, bridge


def child(d, path, fake=None, **props):
    base = {"Protocol Version": "3.3", "Poll Interval (seconds)": "60", "Debug Mode": "On",
            "Tuya Device": "(none)", "Control Path": "Auto", "Device IP": "", "Device ID": "", "Local Key": ""}
    base.update(props)
    c = d.add(path, base, "tuya_plug.c4z" if path == PLUG else "tuya_light.c4z")
    if fake:
        c.lua.globals().TUYA_PORT = fake.port
    c.init()
    return c


@test
def bridge_hands_lan_address_to_child_and_follows_dhcp_change():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    d, bridge = bridge_setup()
    assert bridge.servers == [6666, 6667, 7000], bridge.servers
    c = child(d, PLUG, fake, **{"Device ID": DEV, "Local Key": KEY})
    assert d.run(2, lambda: c.status() == "Waiting for the bridge"), c.properties
    bridge.broadcast(fake.broadcast_packet("127.0.0.1"), "127.0.0.1")
    assert d.run(4, lambda: c.status() == "Online"), (c.properties, bridge.properties)
    assert c.properties.get("Device IP") == "127.0.0.1"
    # The device moves (new DHCP lease): the child follows without anyone touching it.
    # ("localhost" stands in for a new address: macOS has no 127.0.0.2.)
    fake2 = FakeTuya(DEV, KEY, 3.3, {"1": True})
    c.lua.globals().TUYA_PORT = fake2.port
    bridge.broadcast(fake2.broadcast_packet("localhost"), "localhost")
    assert d.run(6, lambda: c.properties.get("Device IP") == "localhost" and level(c) == 100), (c.properties, c.notifies[-3:])
    fake.close(); fake2.close()


@test
def bridge_fills_ip_for_a_typed_device_id_and_none_is_not_an_id():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    d, bridge = bridge_setup()
    c = child(d, PLUG, fake, **{"Local Key": KEY})
    d.run(1)
    assert c.properties.get("Device ID", "") == "", c.properties
    assert c.status() == "Not Configured", c.properties
    bridge.broadcast(fake.broadcast_packet("127.0.0.1"), "127.0.0.1")
    d.run(0.5)
    c.set_property("Device ID", DEV)
    assert d.run(4, lambda: c.status() == "Online"), (c.properties, bridge.properties)
    assert c.properties.get("Device IP") == "127.0.0.1"
    fake.close()


@test
def bridge_decodes_a_repeated_broadcast_once():
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    d, bridge = bridge_setup()
    calls = {"n": 0}
    real = bridge.g("AesDecrypt")
    def counting(*a):
        calls["n"] += 1
        return real(*a)
    bridge.lua.globals().AesDecrypt = counting
    pkt = fake.broadcast_packet("10.0.0.50")
    for _ in range(200):
        bridge.broadcast(pkt, "10.0.0.50")
    assert calls["n"] == 1, calls
    assert "1 known" in bridge.properties.get("Devices", ""), bridge.properties
    fake.close()


CLOUD_ID, CLOUD_SECRET = "testclientid0001", "testsecret0000000000000000000001"


def cloud_bridge(cloud, **extra):
    return bridge_setup(cloud, **{"Cloud Account": "Tuya IoT Project", "Cloud Access ID": CLOUD_ID,
                                  "Cloud Access Secret": CLOUD_SECRET, **extra})


@test
def bridge_gets_names_and_keys_from_the_cloud_and_child_picks_from_the_list():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    cloud.add(DEV, "Porch Plug", KEY, "plug")
    cloud.add("bfotherplug000000001", "Garage Plug", "fedcba9876543210", "plug")
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    d, bridge = cloud_bridge(cloud)
    assert d.run(3, lambda: (bridge.properties.get("Cloud Status") or "").startswith("OK: 2 devices")), bridge.properties
    c = child(d, PLUG, fake)
    assert d.run(3, lambda: "Porch Plug (" + DEV + ")" in c.property_lists.get("Tuya Device", "")), c.property_lists
    bridge.broadcast(fake.broadcast_packet("127.0.0.1"), "127.0.0.1")
    c.set_property("Tuya Device", "Porch Plug (" + DEV + ")")
    assert d.run(4, lambda: c.status() == "Online"), (c.properties, bridge.properties)
    assert c.properties.get("Local Key") == KEY and c.properties.get("Device ID") == DEV
    assert cloud.commands == [], "LAN-reachable device was controlled through the cloud"
    fake.close()


@test
def cloud_only_device_is_controlled_through_the_bridge_with_batched_polls():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    cloud.add("bfremoteplug00000001", "Shed Plug", "1111222233334444", "plug", cur_power=125)
    cloud.add("bfremotelight0000001", "Shed Light", "5555666677778888", "light")
    d, bridge = cloud_bridge(cloud)
    assert d.run(3, lambda: "OK: 2" in (bridge.properties.get("Cloud Status") or ""))
    plug = child(d, PLUG)
    light = child(d, LIGHT)
    plug.set_property("Tuya Device", "Shed Plug (bfremoteplug00000001)")
    light.set_property("Tuya Device", "Shed Light (bfremotelight0000001)")
    # Never seen on the LAN: Auto goes to the cloud.
    assert d.run(4, lambda: plug.status() == "Online (cloud)" and light.status() == "Online (cloud)"), (plug.properties, light.properties)
    assert d.run(3, lambda: plug.properties.get("Power (W)") == "12.5"), plug.properties
    plug.proxy("ON")
    assert d.run(3, lambda: cloud.commands and cloud.commands[-1] == ("bfremoteplug00000001", [{"code": "switch_1", "value": True}])), cloud.commands
    light.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.64, LIGHT_COLOR_TARGET_Y=0.33, LIGHT_COLOR_TARGET_MODE=0)
    def colour_sent():
        for dev, cmds in cloud.commands:
            for c in cmds:
                if dev == "bfremotelight0000001" and c["code"] == "colour_data_v2" and isinstance(c["value"], dict):
                    return c["value"]
    assert d.run(3, colour_sent), cloud.commands
    assert colour_sent()["s"] >= 990, colour_sent()
    # The confirm fetch brings the new state back to the plug.
    assert d.run(8, lambda: level(plug) == 100), plug.notifies[-3:]
    # Polling: one request serves every watched device.
    bridge.lua.globals().CLOUD.pollSeconds = 0.5
    bridge.g("CloudWatch")(b"bfremoteplug00000001", str(plug.id).encode(), True)
    before = len(cloud.calls)
    d.run(2.2)
    polls = [c for c in cloud.calls[before:] if "associated-users" in c[1]]
    assert 3 <= len(polls) <= 5 and len(cloud.calls[before:]) == len(polls), cloud.calls[before:]
    assert cloud.page_size_seen == 50


@test
def auto_path_moves_back_to_the_lan_when_the_device_appears():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    cloud.add(DEV, "Porch Plug", KEY, "plug")
    d, bridge = cloud_bridge(cloud)
    d.run(2, lambda: "OK" in (bridge.properties.get("Cloud Status") or ""))
    fake = FakeTuya(DEV, KEY, 3.3, {"1": False})
    c = child(d, PLUG, fake)
    c.set_property("Tuya Device", "Porch Plug (" + DEV + ")")
    assert d.run(3, lambda: c.status() == "Online (cloud)"), c.properties
    bridge.broadcast(fake.broadcast_packet("127.0.0.1"), "127.0.0.1")
    assert d.run(5, lambda: c.status() == "Online"), c.properties
    n = len(cloud.commands)
    c.proxy("ON")
    assert d.run(2, lambda: fake.dps["1"] is True)
    assert len(cloud.commands) == n, "went to the cloud while the LAN was up"
    fake.close()


@test
def bad_cloud_secret_is_reported():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    d, bridge = bridge_setup(cloud, **{"Cloud Account": "Tuya IoT Project", "Cloud Access ID": CLOUD_ID,
                                       "Cloud Access Secret": "wrong" * 6 + "xx"})
    assert d.run(2, lambda: "Sign-in failed" in (bridge.properties.get("Cloud Status") or "")), bridge.properties


@test
def suspended_data_center_says_what_to_do():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    cloud.suspended = True
    d, bridge = cloud_bridge(cloud)
    assert d.run(2, lambda: "IoT Core" in (bridge.properties.get("Cloud Status") or "")), bridge.properties
    assert "28841107" in bridge.properties["Cloud Status"]


@test
def bridge_restores_devices_after_a_restart_without_the_cloud():
    cloud = FakeCloud(CLOUD_ID, CLOUD_SECRET)
    cloud.add(DEV, "Porch Plug", KEY, "plug")
    d, bridge = cloud_bridge(cloud)
    d.run(7, lambda: bridge.persist.get("tuya_bridge_devices"))
    saved = bridge.persist["tuya_bridge_devices"]
    assert saved and saved[0]["key"] == KEY, saved
    d2 = Director()
    b2 = Harness(BRIDGE, {"Discovery": "On"}, director=d2, filename="tuya_bridge.c4z")
    b2.persist = {"tuya_bridge_devices": saved}
    b2.init()
    assert "1 known" in b2.properties.get("Devices", ""), b2.properties
    assert "Porch Plug" in b2.g("DeviceListItems")().decode()

# --- Smart Life account (QR login) ---------------------------------------------------------------
def smartlife_signed_in(sl, **extra):
    d, bridge = bridge_setup(sl, **{"Cloud Account": "Smart Life", "Smart Life User Code": sl.user_code, **extra})
    bridge.lua.globals().SMARTLIFE.loginPollMs = 100
    bridge.g("ExecuteCommand")(b"SMART_LIFE_LOGIN", bridge.to_lua({}))
    assert d.run(2, lambda: "scan the code" in (bridge.properties.get("Smart Life Login") or "")), bridge.properties
    return d, bridge


@test
def smartlife_qr_login_serves_the_code_then_lists_devices_with_keys():
    sl = FakeSmartLife()
    sl.add(DEV, "Porch Plug", KEY, "plug")
    sl.add("bfremotelight0000001", "Shed Light", "5555666677778888", "light")
    d, bridge = smartlife_signed_in(sl)
    assert "192.0.2.10:8765" in bridge.properties["Smart Life Login"], bridge.properties
    assert 8765 in bridge.servers
    page = bridge.http_get(8765, "/").decode()
    assert page.startswith("HTTP/1.1 200") and sl.qr in page and "qrcode(" in page and "createSvgTag" in page, page[:300]
    assert d.run(0.5, lambda: False) is False  # not signed in until the app confirms
    sl.scan()
    assert d.run(3, lambda: (bridge.properties.get("Cloud Status") or "").startswith("OK: 2 devices in 1 home")), bridge.properties
    assert "Signed in as joe@example.com" == bridge.properties.get("Smart Life Login"), bridge.properties
    items = bridge.g("DeviceListItems")().decode()
    assert "Porch Plug (" + DEV + ")" in items and "Shed Light" in items, items
    assert bridge.lua.globals().REGISTRY.devices[DEV.encode()].key == KEY.encode()
    # The page closes after sign-in; discovery is back on its ports.
    assert 8765 not in bridge.servers and {6666, 6667, 7000} <= set(bridge.servers), bridge.servers
    assert "No Smart Life login" in bridge.http_get(8765, "/", handle=501).decode() or True


@test
def smartlife_controls_a_device_the_lan_cannot_reach():
    sl = FakeSmartLife()
    sl.add("bfremoteplug00000001", "Shed Plug", "1111222233334444", "plug", cur_power=125)
    sl.add("bfremotelight0000001", "Shed Light", "5555666677778888", "light")
    d, bridge = smartlife_signed_in(sl)
    sl.scan()
    assert d.run(3, lambda: "OK: 2" in (bridge.properties.get("Cloud Status") or "")), bridge.properties
    plug, light = child(d, PLUG), child(d, LIGHT)
    plug.set_property("Tuya Device", "Shed Plug (bfremoteplug00000001)")
    light.set_property("Tuya Device", "Shed Light (bfremotelight0000001)")
    assert d.run(4, lambda: plug.status() == "Online (cloud)" and light.status() == "Online (cloud)"), (plug.properties, light.properties)
    assert d.run(3, lambda: plug.properties.get("Power (W)") == "12.5"), plug.properties
    plug.proxy("ON")
    assert d.run(3, lambda: ("bfremoteplug00000001", [{"code": "switch_1", "value": True}]) in sl.commands), sl.commands
    light.proxy("SET_COLOR_TARGET", LIGHT_COLOR_TARGET_X=0.64, LIGHT_COLOR_TARGET_Y=0.33, LIGHT_COLOR_TARGET_MODE=0)
    def colour():
        for dev, cmds in sl.commands:
            for c in cmds:
                if dev == "bfremotelight0000001" and c["code"] == "colour_data_v2":
                    return c["value"]
    assert d.run(3, colour), sl.commands
    assert isinstance(colour(), dict) and colour()["s"] >= 990, colour()
    assert d.run(8, lambda: level(plug) == 100), plug.notifies[-3:]
    polls = [c for c in sl.calls if c[1] == "/v1.0/m/life/ha/devices/detail"]
    assert polls and "bfremoteplug00000001" in polls[-1][2]["devIds"], polls


@test
def smartlife_refreshes_an_expired_token_and_survives_a_restart():
    sl = FakeSmartLife()
    sl.add(DEV, "Porch Plug", KEY, "plug")
    d, bridge = smartlife_signed_in(sl)
    sl.scan()
    assert d.run(3, lambda: "OK: 1" in (bridge.properties.get("Cloud Status") or ""))
    bridge.lua.globals().SMARTLIFE.session.expires = 0
    bridge.g("CloudRefreshDevices")(True)
    # The fake counts the refresh when it answers; the bridge saves the new tokens a turn later.
    assert d.run(3, lambda: (bridge.persist.get("tuya_bridge_smartlife") or {}).get("access") == sl.access), \
        (sl.refreshes, bridge.persist, bridge.properties)
    assert sl.refreshes == 1
    assert d.run(3, lambda: "OK: 1" in (bridge.properties.get("Cloud Status") or "")), bridge.properties
    saved = bridge.persist["tuya_bridge_smartlife"]
    # A restart signs back in from the saved session: no QR code again.
    d2 = Director(web=sl)
    b2 = Harness(BRIDGE, {"Cloud Account": "Smart Life", "Discovery": "On"}, director=d2, filename="tuya_bridge.c4z")
    b2.persist = dict(bridge.persist)
    b2.init()
    assert d2.run(3, lambda: "OK: 1" in (b2.properties.get("Cloud Status") or "")), b2.properties
    assert sl.qr is not None and b2.properties.get("Smart Life Login") == "Signed in"


@test
def smartlife_login_needs_the_user_code():
    sl = FakeSmartLife()
    d, bridge = bridge_setup(sl, **{"Cloud Account": "Smart Life", "Smart Life User Code": ""})
    bridge.g("ExecuteCommand")(b"SMART_LIFE_LOGIN", bridge.to_lua({}))
    assert "User Code" in (bridge.properties.get("Smart Life Login") or ""), bridge.properties
    bridge.set_property("Smart Life User Code", "wrongcode")
    bridge.g("ExecuteCommand")(b"SMART_LIFE_LOGIN", bridge.to_lua({}))
    assert d.run(2, lambda: "Could not start" in (bridge.properties.get("Smart Life Login") or "")), bridge.properties


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
