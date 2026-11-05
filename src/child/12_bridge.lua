-- A light or plug's side of the Tuya Bridge: optional. Without a bridge the driver runs on its
-- own properties (Device IP / ID / Local Key), exactly as before.
--
-- With one, the child finds it by file name (C4:GetDevicesByC4iName) and they talk with
-- C4:SendToDevice, so there is nothing to bind in Composer:
--   * Tuya Device: a dropdown (C4:UpdatePropertyList) of everything the bridge knows; picking
--     one fills Device ID, and the bridge keeps IP, Local Key and version current (a DHCP
--     change on the LAN follows within one broadcast).
--   * Control Path: Local (LAN only), Cloud (through the bridge's Tuya account), or Auto:
--     LAN when the device answers there, the cloud while it doesn't (another subnet, protocol
--     3.5, or simply down). The local session keeps retrying, so Auto goes back to the LAN.

BRIDGE = { id = nil, cloud = false, path = 'Auto', cloudMode = false }

local NONE = '(none)'

local function MyId()
	return tostring(C4:GetDeviceID())
end

local function ToBridge(command, params)
	if (not BRIDGE.id) then return false end
	params = params or {}
	params.CHILD = MyId()
	pcall(function() C4:SendToDevice(BRIDGE.id, command, params) end)
	return true
end

function FindBridge()
	local ok, devices = pcall(function() return C4:GetDevicesByC4iName(BRIDGE_FILENAME) end)
	BRIDGE.id = nil
	if (ok and type(devices) == 'table') then
		BRIDGE.id = next(devices)
	end
	UpdateDriverProperty('Bridge', BRIDGE.id and ('Tuya Bridge (device ' .. tostring(BRIDGE.id) .. ')') or 'None (manual setup)')
	return BRIDGE.id
end

function BridgeHello()
	ToBridge('TUYA_HELLO', { DEVICE_ID = DEVICE.id })
end

local function SetWatch(on)
	if (BRIDGE.watching ~= on) then
		BRIDGE.watching = on
		ToBridge('TUYA_CLOUD_WATCH', { DEVICE_ID = DEVICE.id, ON = on and '1' or '0' })
	end
end

-- Decides, from the Control Path and what's reachable, whether commands go to the cloud.
function EvaluatePath()
	local canCloud = BRIDGE.id ~= nil and BRIDGE.cloud and DEVICE.id ~= ''
	local wantCloud
	if (BRIDGE.path == 'Cloud') then
		wantCloud = canCloud
	elseif (BRIDGE.path == 'Local') then
		wantCloud = false
	else
		wantCloud = canCloud and not SessionReady()
	end
	if (wantCloud ~= BRIDGE.cloudMode) then
		BRIDGE.cloudMode = wantCloud
		DebugLog(wantCloud and 'controlling through the cloud' or 'controlling on the LAN')
	end
	SetWatch(wantCloud)
	if (wantCloud) then
		SetConnectionStatus('Online (cloud)')
	end
	-- Cloud-only paths don't keep a LAN socket open; coming back from one restarts it. (A LAN
	-- connection that merely dropped is left to the session's own reconnect backoff.)
	if (BRIDGE.path == 'Cloud' or DEVICE.localUnsupported) then
		if (not BRIDGE.lanStopped) then
			BRIDGE.lanStopped = true
			StopSession()
		end
	elseif (BRIDGE.lanStopped and LATE_INIT_DONE) then
		BRIDGE.lanStopped = false
		StartSession()
	end
end

-- From the session: the LAN connection came up or went away.
function OnLocalState(ready)
	EvaluatePath()
end

-- From SendDps when the LAN is not available: send through the bridge if that's the path.
function CloudSend(dps)
	if (not BRIDGE.cloudMode) then return false end
	return ToBridge('TUYA_CLOUD_SET', { DEVICE_ID = DEVICE.id, DPS = JsonObject(dps) })
end

local function ApplyInfo(p)
	if (p.DEVICE_ID ~= DEVICE.id) then return end
	local restart = false
	if (p.IP and p.IP ~= '' and p.IP ~= DEVICE.ip) then
		DEVICE.ip = p.IP
		UpdateDriverProperty('Device IP', p.IP)
		restart = true
	end
	if (p.KEY and p.KEY ~= '' and p.KEY ~= DEVICE.key) then
		DEVICE.key = p.KEY
		UpdateDriverProperty('Local Key', p.KEY)
		restart = true
	end
	if (p.VERSION and p.VERSION ~= '') then
		local v = ParseVersion(p.VERSION)
		local unsupported = (v == nil)
		if (unsupported ~= (DEVICE.localUnsupported == true)) then
			DEVICE.localUnsupported = unsupported or nil
			restart = true
		end
		if (v and v ~= DEVICE.version) then
			DEVICE.version = v
			UpdateDriverProperty('Protocol Version', string.format('%.1f', v))
			restart = true
		end
	end
	BRIDGE.cloud = (p.CLOUD == '1')
	if (restart and LATE_INIT_DONE and not (BRIDGE.path == 'Cloud' or DEVICE.localUnsupported)) then
		RestartSession()
	end
	EvaluatePath()
end

local function ApplyCloudStatus(p)
	if (p.DEVICE_ID ~= DEVICE.id or not BRIDGE.cloudMode) then return end
	local dps = JsonDecode(p.DPS or '')
	if (dps) then
		local changed = {}
		for dp, value in pairs(dps) do
			DPS[tostring(dp)] = value
			changed[tostring(dp)] = value
		end
		UpdateDriverProperty('Last Update', os.date('%Y-%m-%d %H:%M:%S') .. ' (cloud)')
		OnDpsChanged(changed)
	end
	local online = (p.ONLINE == '1')
	if (online ~= BRIDGE.cloudOnline) then
		BRIDGE.cloudOnline = online
		Notify('ONLINE_CHANGED', { STATE = online })
		SetConnectionStatus(online and 'Online (cloud)' or 'Offline (cloud says the device is offline)')
	end
end

-- Messages from the bridge, arriving on ExecuteCommand. Returns true when it was one.
function HandleBridgeCommand(command, p)
	if (command == 'TUYA_BRIDGE_UP') then
		BRIDGE.id = tonumber(p.BRIDGE) or FindBridge()
		UpdateDriverProperty('Bridge', 'Tuya Bridge (device ' .. tostring(BRIDGE.id) .. ')')
		BRIDGE.watching = nil
		BridgeHello()
		EvaluatePath()
	elseif (command == 'TUYA_LIST') then
		local current = Properties['Tuya Device'] or NONE
		local items = (p.ITEMS and p.ITEMS ~= '') and (NONE .. ',' .. p.ITEMS) or NONE
		pcall(function() C4:UpdatePropertyList('Tuya Device', items, current) end)
	elseif (command == 'TUYA_INFO') then
		ApplyInfo(p)
	elseif (command == 'TUYA_STATUS') then
		ApplyCloudStatus(p)
	elseif (command == 'TUYA_CLOUD_FAILED') then
		UpdateDriverProperty('Last Error', 'cloud command failed: ' .. tostring(p.WHY or 'see the bridge'))
	else
		return false
	end
	return true
end

-- Child properties that belong to the bridge link. Returns true when handled.
function ApplyBridgeProperty(name, value)
	if (name == 'Tuya Device') then
		local id = string.match(value or '', '%(([^()]+)%)%s*$')
		if (id and id ~= DEVICE.id) then
			DEVICE.id = id
			UpdateDriverProperty('Device ID', id)
			BRIDGE.watching = nil
			if (LATE_INIT_DONE) then BridgeHello() end
		end
		return true
	elseif (name == 'Control Path') then
		BRIDGE.path = value ~= '' and value or 'Auto'
		if (LATE_INIT_DONE) then EvaluatePath() end
		return true
	end
	return false
end
