-- Constants and runtime state shared by every Tuya driver variant.

DRIVER_VERSION = '1'
LOG_PREFIX = '[Tuya] '
DEBUGPRINT = false

-- Binding the light_v2 proxy is attached to (driver.xml <proxies>).
PROXY_BINDING = 5001
-- Button links a keypad can bind to (driver.xml <connections>), as light_v2 numbers them.
BUTTON_BINDINGS = { [300] = 0, [301] = 2, [302] = 1 } -- binding -> BUTTON_ID
BUTTON_TOP, BUTTON_BOTTOM, BUTTON_TOGGLE = 0, 1, 2
BUTTON_ACTION_RELEASE_CLICK = 2

TUYA_PORT = 6668
HEARTBEAT_MS = 10000
CONNECT_TIMEOUT_MS = 10000
-- A device with the wrong key ignores what it cannot decrypt, so silence means a bad key.
QUERY_TIMEOUT_MS = 5000
-- A device that misses this many heartbeats in a row is treated as gone and reconnected.
MAX_MISSED_HEARTBEATS = 2
RECONNECT_MIN_MS = 2000
RECONNECT_MAX_MS = 60000

-- Tuya LAN command numbers.
CMD = {
	SESS_KEY_NEG_START = 3,
	SESS_KEY_NEG_RESP = 4,
	SESS_KEY_NEG_FINISH = 5,
	CONTROL = 7,
	STATUS = 8,
	HEART_BEAT = 9,
	DP_QUERY = 10,
	CONTROL_NEW = 13,
	DP_QUERY_NEW = 16,
	UPDATEDPS = 18,
}

-- Commands sent without the "3.x" + 12-byte version header.
NO_VERSION_HEADER = {
	[CMD.SESS_KEY_NEG_START] = true,
	[CMD.SESS_KEY_NEG_RESP] = true,
	[CMD.SESS_KEY_NEG_FINISH] = true,
	[CMD.HEART_BEAT] = true,
	[CMD.DP_QUERY] = true,
	[CMD.DP_QUERY_NEW] = true,
	[CMD.UPDATEDPS] = true,
}

-- Connection state, reset by OnDriverInit.
DEVICE = {
	ip = '',
	id = '',
	key = '',
	version = 3.3,
}
CONN = nil -- see 06_session.lua
DPS = {} -- last known datapoint values, keyed by DP number as a string

-- Bridge and children find each other by driver file name (C4:GetDevicesByC4iName) and talk
-- with C4:SendToDevice, so there is nothing to bind in Composer.
BRIDGE_FILENAME = 'tuya_bridge.c4z'
CHILD_FILENAMES = { 'tuya_light.c4z', 'tuya_plug.c4z' }
