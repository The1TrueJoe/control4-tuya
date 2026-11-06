# control4-tuya

Control4 drivers for Tuya / Smart Life devices, controlled **locally** over the Tuya LAN
protocol. The cloud is optional: through the bridge, it supplies names and keys, and controls
only devices the LAN can't reach.

| Driver | Proxy | Devices |
|---|---|---|
| `tuya_light.c4z` | `light_v2` (dimmer, colour, white temperature) | bulbs, LED strips, dimmers |
| `tuya_plug.c4z` | `light_v2` (on/off) | plugs, outlets, wall switches; power metering |
| `tuya_bridge.c4z` | none (utility) | optional: finds devices, fills in addresses and keys, cloud fallback |

Both work with keypads (button links), scenes, Navigator and programming like any other
Control4 light. A device pushes its state to the driver on every change, so the app, a voice
assistant or a button press on the device shows up in Control4 at once.

## Supported

- Protocols **3.3** and **3.4** on the LAN (3.4's session-key handshake included). **3.5**
  devices work through the bridge's cloud connection; 3.1 is not supported.
- Lights: the standard datapoint layout (20 switch, 21 mode, 22 brightness, 23 temperature,
  24 colour) and the legacy one (1-5), picked automatically. Light type (colour / tunable
  white / dimmable / on-off) is detected from the datapoints, or set by hand.
- Plugs: any switch datapoint (multi-gang), power / voltage / current on DPs 18-20 or 4-6,
  as properties and as `POWER_W`, `VOLTAGE_V`, `CURRENT_MA` variables.
- "device22" firmware, which only answers queries sent as CONTROL_NEW.
- Reconnect with backoff. A command given while the device is briefly offline is sent when
  it comes back (within 30 s).

## The bridge (optional)

One **Tuya Bridge** per controller. Lights and plugs find it on their own (by driver file
name) and talk to it with `C4:SendToDevice`, so nothing is bound in Composer.

- **LAN discovery.** Tuya devices broadcast on UDP 6666/6667/7000 every few seconds; the bridge
  listens with `C4:CreateServer` and keeps each device's address and protocol version
  current. A repeated broadcast costs one string compare: a packet is only decrypted when its
  bytes change. Broadcasts don't cross routers.
- **Your Tuya account** (optional), as **Cloud Account**:
  - *Smart Life* (default): enter the app's **User Code** (Me > Settings > Account and
    Security), run **Smart Life Login**, and scan the QR code the bridge shows at
    `http://<controller>:8765/` with the Smart Life app. Done once; the bridge keeps and refreshes
    its tokens. No developer account.
  - *Tuya IoT Project*: a developer project's Access ID and Secret, covering every Smart Life
    account linked to it. One paged request (`associated-users/devices`, 50 devices a call)
    serves both key refreshes and status polls.
  - Either way the bridge fetches device names and local keys (every 12 h), and controls
    through the cloud only the devices the LAN can't reach.
- **Children** pick a device from **Tuya Device** (a list the bridge fills in), or take a typed
  **Device ID**; the bridge then supplies IP, Local Key and version, and follows DHCP changes.
- **Control Path**: *Local* (LAN only), *Cloud* (through the bridge), or *Auto* — the LAN when
  the device answers there, the cloud while it doesn't (another subnet, protocol 3.5, or
  down). The LAN connection keeps retrying, so Auto returns to it on its own.
- **Resource Use** (bridge and children): the driver's own Lua memory and CPU time, every 5
  minutes. On an EA-1, each driver idles at about 280 KB and a few ms of CPU per 5 minutes.

Local control never goes through the cloud. Tuya's free IoT plan caps API calls per month, so
cloud-controlled devices are polled once per **Cloud Poll Interval** (default 120 s) in one
batched request, plus one confirming read a few seconds after a cloud command.

## Setup

1. Give the device a DHCP reservation.
2. With a Tuya Bridge signed in to your Smart Life account: pick the device from
   **Tuya Device** and stop here. Otherwise, get its **Device ID** and **Local Key**: `pip install tinytuya`, then
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
src/common/   protocol, crypto, bytes, utilities (all three drivers)
src/child/    session, proxy, properties, callbacks, bridge client (light and plug)
src/light/    colour maths and the light variant
src/plug/     the plug variant
src/bridge/   registry, LAN discovery, Tuya cloud, bridge callbacks
drivers/<v>/  driver.xml, docs; build.sh writes driver.lua here
test/         fake Tuya device, IoT cloud and Smart Life cloud, tests; serve.py runs a fake device
              on the LAN for a real controller
vendor/       qrcode-generator (MIT), embedded in the bridge for the login page
```

`build.sh` concatenates each driver's source folders in filename order into
`drivers/<variant>/driver.lua`, and zips it with a version-stamped copy of `driver.xml` into
`dist/`.

## Building and testing

Two small libraries live in their own repos; clone them next to this one (or point
`C4_AES_GCM` / `C4_TEST_HARNESS` at them):

- [control4-aes-gcm](../control4-aes-gcm): AES-GCM on Director's AES-ECB (the bridge's Smart Life
  login uses it).
- [control4-test-harness](../control4-test-harness): a mock Director for running drivers in tests.

```sh
pip install lupa cryptography tinytuya
./build.sh && python3 test/run_tests.py
```

The tests run each built `driver.lua` in Lua 5.1 against a fake device. The fake is first
checked against tinytuya (the reference client), so passing tests mean the driver speaks
the same protocol tinytuya does. Not covered by the harness: Director itself (its crypto
and TCP APIs are mocked here), and Tuya firmware quirks beyond the ones listed above.
