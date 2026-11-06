-- Tuya cloud, the part both account types share: handing devices to the registry, converting
-- values, polling cloud-controlled devices and sending them commands. How to sign in and
-- talk to Tuya is a backend's job (08_iot.lua, 08_smartlife.lua), chosen by Cloud Account.
--
-- Kept light on the controller and the account: HTTP is Director's own C4:url; a device's
-- DP<->code map is fetched once and persisted; status is polled only while some child is
-- controlling a device through the cloud, once per Cloud Poll Interval, in one batched
-- request, plus one confirming read a few seconds after a command.
--
-- A backend is a table registered in BACKENDS with:
--   configured()            enough settings to try
--   start()                 sign in / restore tokens; sets CLOUD.ready when usable
--   fetch(why)              every device: IngestDevice() each, then CloudStatus(...)
--   poll(ids, why)          current status of these devices: IngestDevice() each
--   spec(id, cb)            cb(spec) with spec.dp[dp] = { code }, spec.code[code] = dp
--   command(id, body, cb)   body = '{"commands":[...]}'; cb(ok, why)
--   stop()

local SPEC_KEY = 'tuya_bridge_specs'
local BACKOFF_S = 600

BACKENDS = {}

CLOUD = {
	ready = false,
	backend = nil,
	specs = {}, -- device id -> { dp = { [dp] = { code } }, code = { [code] = dp } }
	watch = {}, -- device id -> { [childId] = true }
	backoffUntil = 0,
	pollSeconds = 120,
}

function CloudStatus(text)
	UpdateDriverProperty('Cloud Status', text)
end

-- Tuya answers that mean "fix this in the Tuya app or console", reworded as what to do.
local HINTS = {
	['28841107'] = 'Tuya says the project can\'t use its data center. In the Tuya IoT console: start or extend '
		.. 'the IoT Core trial (Cloud Services), authorize IoT Core for this project (Service API tab), and check '
		.. 'the data center is enabled (Overview)',
	['1106'] = 'Tuya says permission denied: link your Smart Life account to the project (Devices > Link App Account)',
	['1004'] = 'Tuya rejected the signature: check Cloud Access ID and Secret',
}

function ExplainCloudError(json, fallback)
	if (json and HINTS[tostring(json.code)]) then
		return HINTS[tostring(json.code)] .. ' (' .. tostring(json.code) .. ')'
	end
	return fallback or (json and (tostring(json.msg) .. ' (' .. tostring(json.code) .. ')')) or 'no answer'
end

-- Rate-limit and quota answers (40000309, "frequency"/"limit" messages) back off for ten
-- minutes rather than retrying into a bigger bill.
function CloudThrottled(json)
	local msg = string.lower(tostring(json and json.msg or ''))
	if ((json and tostring(json.code) == '40000309') or string.find(msg, 'frequen', 1, true) or string.find(msg, 'limit', 1, true)) then
		CLOUD.backoffUntil = os.time() + BACKOFF_S
		return true
	end
	return false
end

function CloudBackingOff()
	return os.time() < CLOUD.backoffUntil
end

-- One HTTPS request through Director; callback(json) or callback(nil, why).
function HttpJson(method, url, body, headers, callback)
	local transfer = C4:url()
	transfer:SetOptions({ fail_on_error = false, timeout = 20, connect_timeout = 10 })
	transfer:OnDone(Tracked(function(_, responses, errCode, errMsg)
		if (errCode ~= 0) then
			callback(nil, errMsg or ('transfer error ' .. tostring(errCode)))
			return
		end
		local resp = responses[#responses] or {}
		local json = JsonDecode(resp.body or '')
		if (not json) then
			callback(nil, 'HTTP ' .. tostring(resp.code) .. ' with no JSON')
			return
		end
		callback(json)
	end, 'cloud'))
	if (method == 'GET') then
		transfer:Get(url, headers or {})
	else
		transfer:Post(url, body or '', headers or {})
	end
end

-- Value conversions between the cloud's JSON colour objects and the LAN's hex strings.
local function Hex4(n) return string.format('%04x', math.floor(tonumber(n) or 0)) end

local function HsvRgb(h, s, v)
	local c = v * s
	local hp = (h % 360) / 60
	local x = c * (1 - math.abs(hp % 2 - 1))
	local r, g, b = 0, 0, 0
	if (hp < 1) then r, g, b = c, x, 0 elseif (hp < 2) then r, g, b = x, c, 0
	elseif (hp < 3) then r, g, b = 0, c, x elseif (hp < 4) then r, g, b = 0, x, c
	elseif (hp < 5) then r, g, b = x, 0, c else r, g, b = c, 0, x end
	local m = v - c
	return math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5)
end

local function CloudToLocal(code, value)
	if (code == 'colour_data_v2' or code == 'colour_data') then
		local c = type(value) == 'table' and value or JsonDecode(tostring(value))
		if (not c) then return value end
		if (code == 'colour_data_v2') then
			return Hex4(c.h) .. Hex4(c.s) .. Hex4(c.v)
		end
		local r, g, b = HsvRgb(tonumber(c.h) or 0, (tonumber(c.s) or 0) / 255, (tonumber(c.v) or 0) / 255)
		return string.format('%02x%02x%02x%04x%02x%02x', r, g, b, math.floor(tonumber(c.h) or 0),
			math.floor(tonumber(c.s) or 0), math.floor(tonumber(c.v) or 0))
	end
	return value
end

local function LocalToCloud(code, value)
	if (type(value) == 'string' and code == 'colour_data_v2' and #value == 12) then
		return { h = tonumber(value:sub(1, 4), 16), s = tonumber(value:sub(5, 8), 16), v = tonumber(value:sub(9, 12), 16) }
	elseif (type(value) == 'string' and code == 'colour_data' and #value == 14) then
		return { h = tonumber(value:sub(7, 10), 16), s = tonumber(value:sub(11, 12), 16), v = tonumber(value:sub(13, 14), 16) }
	end
	return value
end

-- A device's datapoint <-> code map, fetched once through the backend and persisted.
local function WithSpec(deviceId, callback)
	if (CLOUD.specs[deviceId]) then callback(CLOUD.specs[deviceId]) return end
	if (not CLOUD.backend) then callback(nil, 'no cloud account') return end
	CLOUD.backend.spec(deviceId, function(spec, err)
		if (spec) then
			CLOUD.specs[deviceId] = spec
			pcall(function() C4:PersistSetValue(SPEC_KEY, CLOUD.specs) end)
		end
		callback(spec, err)
	end)
end

-- A spec is plain data (it is persisted): backends fill one from whatever their API returns.
function NewSpec()
	return { dp = {}, code = {} }
end

function SpecAdd(spec, dp, code)
	if (dp and code) then
		spec.dp[tostring(dp)] = { code = code }
		spec.code[code] = tostring(dp)
	end
end

local function TellWatchers(device)
	local watchers = CLOUD.watch[device.id]
	if (not watchers or not next(watchers)) then return end
	WithSpec(device.id, function(spec)
		if (not spec) then return end
		local dps = {}
		for _, s in ipairs(device.status or {}) do
			local dp = spec.code[s.code]
			if (dp) then dps[dp] = CloudToLocal(s.code, s.value) end
		end
		local params = { DEVICE_ID = device.id, DPS = JsonObject(dps), ONLINE = device.online and '1' or '0' }
		for childId, _ in pairs(watchers) do
			SendToChild(childId, 'TUYA_STATUS', params)
		end
	end)
end

-- A device as a backend found it: { id, name, key, category, product, online, status = {{code, value}} }.
function IngestDevice(dev)
	if (not dev or not dev.id) then return end
	if (dev.name or dev.key) then
		UpdateDevice(dev.id, { name = dev.name, key = dev.key, category = dev.category, product = dev.product, cloud = true })
	end
	local d = REGISTRY.devices[dev.id]
	if (d) then d.online = dev.online end
	TellWatchers(dev)
end

function CloudRefreshDevices(force)
	if (force) then CLOUD.backoffUntil = 0 end
	if (CLOUD.backend and CLOUD.backend.configured()) then
		CLOUD.backend.fetch('refreshed')
	end
end

local function Watched()
	local ids = {}
	for id, children in pairs(CLOUD.watch) do
		if (next(children)) then ids[#ids + 1] = id end
	end
	return ids
end

local function Poll(why)
	local ids = Watched()
	if (#ids > 0 and CLOUD.backend) then
		CLOUD.backend.poll(ids, why)
	end
end

-- Called by a child (through the bridge) to set datapoints on a device it can't reach locally.
function CloudCommand(deviceId, dps)
	local b = CLOUD.backend
	if (not (b and b.configured()) or not deviceId) then return false end
	WithSpec(deviceId, function(spec, err)
		local commands = {}
		for dp, value in pairs(spec and dps or {}) do
			local f = spec.dp[tostring(dp)]
			if (f) then
				commands[#commands + 1] = JsonObject({ code = f.code, value = LocalToCloud(f.code, value) })
			end
		end
		if (#commands == 0) then
			UpdateDriverProperty('Last Error', 'cloud command for ' .. deviceId .. ': ' .. tostring(err or 'no matching datapoints'))
			return
		end
		b.command(deviceId, '{"commands":[' .. table.concat(commands, ',') .. ']}', function(ok, why)
			if (not ok) then
				UpdateDriverProperty('Last Error', 'cloud command for ' .. deviceId .. ': ' .. tostring(why))
				for childId, _ in pairs(CLOUD.watch[deviceId] or {}) do
					SendToChild(childId, 'TUYA_CLOUD_FAILED', { DEVICE_ID = deviceId, WHY = tostring(why) })
				end
				return
			end
			-- Confirm the result once, a few seconds later, instead of waiting for the next poll.
			CLOUD.confirm = CLOUD.confirm or SetTimer(4000, function()
				CLOUD.confirm = nil
				Poll('confirmed')
			end)
		end)
	end)
	return true
end

local function SchedulePoll()
	CLOUD.pollTimer = CancelTimer(CLOUD.pollTimer)
	if (#Watched() > 0) then
		CLOUD.pollTimer = SetTimer(CLOUD.pollSeconds * 1000, function() Poll('polled') end, true)
	end
end

function CloudWatch(deviceId, childId, on)
	if (not deviceId) then return end
	CLOUD.watch[deviceId] = CLOUD.watch[deviceId] or {}
	local was = CLOUD.watch[deviceId][tostring(childId)]
	CLOUD.watch[deviceId][tostring(childId)] = on or nil
	if (on and not was) then Poll('watching') end
	SchedulePoll()
end

-- The backend calls this once it can make requests (signed in, tokens restored).
function CloudReady()
	CLOUD.ready = true
	CLOUD.backend.fetch('signed in')
	local hours = math.max(1, tonumber(Properties['Key Refresh (hours)']) or 12)
	CLOUD.refreshTimer = CancelTimer(CLOUD.refreshTimer)
	CLOUD.refreshTimer = SetTimer(hours * 3600 * 1000, function() CLOUD.backend.fetch('refreshed') end, true)
	SchedulePoll()
end

function StartCloud()
	StopCloud()
	CLOUD.pollSeconds = math.max(60, tonumber(Properties['Cloud Poll Interval (seconds)']) or 120)
	CLOUD.ready, CLOUD.backoffUntil = false, 0
	CLOUD.backend = BACKENDS[Properties['Cloud Account'] or '']
	if (not CLOUD.backend) then
		CloudStatus('Off (LAN only)')
		return
	end
	local ok, specs = pcall(function() return C4:PersistGetValue(SPEC_KEY) end)
	if (ok and type(specs) == 'table') then CLOUD.specs = specs end
	if (not CLOUD.backend.configured()) then
		CloudStatus('Not configured (LAN only)')
		return
	end
	CLOUD.backend.start()
end

function StopCloud()
	CLOUD.refreshTimer = CancelTimer(CLOUD.refreshTimer)
	CLOUD.pollTimer = CancelTimer(CLOUD.pollTimer)
	CLOUD.confirm = CancelTimer(CLOUD.confirm)
	if (CLOUD.backend and CLOUD.backend.stop) then CLOUD.backend.stop() end
	CLOUD.ready = false
end
