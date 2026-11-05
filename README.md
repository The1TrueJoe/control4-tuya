# control4-tuya

Control4 drivers for Tuya / Smart Life devices, controlled **locally** over the Tuya LAN
protocol. No cloud is in the control path.

| Driver | Proxy | Devices |
|---|---|---|
| `tuya_light.c4z` | `light_v2` (dimmer, colour, white temperature) | bulbs, LED strips, dimmers |
| `tuya_plug.c4z` | `light_v2` (on/off) | plugs, outlets, wall switches; power metering |

Both work with keypads (button links), scenes, Navigator and programming like any other
Control4 light. A device pushes its state to the driver on every change, so the app, a voice
assistant or a button press on the device shows up in Control4 at once.

## Supported

- Protocols **3.3** and **3.4** (3.4's session-key handshake included). 3.1 and 3.5 are
  refused by name.
- Lights: the standard datapoint layout (20 switch, 21 mode, 22 brightness, 23 temperature,
  24 colour) and the legacy one (1-5), picked automatically. Light type (colour / tunable
  white / dimmable / on-off) is detected from the datapoints, or set by hand.
- Plugs: any switch datapoint (multi-gang), power / voltage / current on DPs 18-20 or 4-6,
  as properties and as `POWER_W`, `VOLTAGE_V`, `CURRENT_MA` variables.
- "device22" firmware, which only answers queries sent as CONTROL_NEW.
- Reconnect with backoff. A command given while the device is briefly offline is sent when
  it comes back (within 30 s).

## Setup

1. Give the device a DHCP reservation.
2. Get its **Device ID** and **Local Key**: `pip install tinytuya`, then
   `python -m tinytuya wizard`. The wizard needs a free Tuya IoT developer project linked to
   your Smart Life app account. `python -m tinytuya scan` shows each device's IP and protocol
   version.
3. Add the driver in Composer, then set **Device IP**, **Device ID**, **Local Key** and
   **Protocol Version**. **Connection Status** goes to *Online* once the device answers.
   *No Response* or a handshake error means the Local Key or protocol version is wrong.

Re-pairing a device in the app gives it a new Local Key. Many Tuya devices accept only one
LAN connection, so close other local integrations on the same device.

## Layout

```
src/common/   protocol, crypto, session, proxy and property handling (both drivers)
src/light/    colour maths and the light variant
src/plug/     the plug variant
drivers/<v>/  driver.xml, docs; build.sh writes driver.lua here
test/         fake Tuya device, Lua 5.1 harness with Control4's API mocked, tests
```

`build.sh` concatenates `src/common` and `src/<variant>` in filename order into
`drivers/<variant>/driver.lua` and zips each driver into `dist/`.

## Testing

```sh
pip install lupa cryptography tinytuya
./build.sh && python3 test/run_tests.py
```

The tests run each built `driver.lua` in Lua 5.1 against a fake device. The fake is first
checked against tinytuya (the reference client), so passing tests mean the driver speaks
the same protocol tinytuya does. Not covered by the harness: Director itself (its crypto
and TCP APIs are mocked here), and Tuya firmware quirks beyond the ones listed above.
