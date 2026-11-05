-- Tuya cloud: the IoT platform's OpenAPI, for device names and local keys from every app
-- account linked to the user's project, and for control of devices the LAN can't reach.
--
-- Built to stay inside the free plan's monthly call quota and off the controller's CPU:
--   * one endpoint does both jobs: /v1.0/iot-01/associated-users/devices returns each
--     device's name, local key, online flag and current status, 50 per call. A key refresh
--     (every Key Refresh hours) and a status poll of cloud-controlled devices (every Cloud
--     Poll Interval, only while any child is watching) are the same paged request.
--   * the token is reused until it expires; a device's DP<->code spec is fetched once, the
--     first time it is controlled through the cloud, and kept with PersistSetValue.
--   * HTTP is Director's own C4:url; signing is C4:HMAC / C4:Hash.
-- Not here: Tuya's message queue (Pulsar). Cloud-controlled devices are polled, not pushed.

local HOSTS = {
	['US'] = 'https://openapi.tuyaus.com',
	['US East'] = 'https://openapi-ueaz.tuyaus.com',
	['EU'] = 'https://openapi.tuyaeu.com',
	['EU West'] = 'https://openapi-weaz.tuyaeu.com',
	['China'] = 'https://openapi.tuyacn.com',
	['India'] = 'https://openapi.tuyain.com',
}
local EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
local PAGE = 50
local SPEC_KEY = 'tuya_bridge_specs'
local BACKOFF_S = 600

CLOUD = {
	ready = false, -- credentials set and a token was issued
	token = nil, tokenExpires = 0,
	specs = {}, -- device id -> { dp = { [dp] = { code, type } }, code = { [code] = dp } }
	watch = {}, -- device id -> { [childId] = true }
	backoffUntil = 0,
}

local function Status(text)
	UpdateDriverProperty('Cloud Status', text)
end

local function Configured()
	return CLOUD.host and CLOUD.id ~= '' and CLOUD.secret ~= ''
end

-- Tuya's request signature: HMAC-SHA256 over client_id [+ token] + t + nonce + the request
-- (method, SHA-256 of the body, signed headers (none), path with sorted query).
local function SignedHeaders(method, path, body, withToken)
	local t = string.format('%.0f', os.time() * 1000)
	local bodyHash = (body and body ~= '') and Sha256Hex(body) or EMPTY_SHA256
	local toSign = method .. '\n' .. bodyHash .. '\n\n' .. path
	local str = CLOUD.id .. (withToken and CLOUD.token or '') .. t .. toSign
	local headers = {
		client_id = CLOUD.id,
		sign = string.upper(ToHex(HmacSha256(CLOUD.secret, str))),
		t = t,
		sign_method = 'HMAC-SHA256',
		['Content-Type'] = 'application/json',
	}
	if (withToken) then headers.access_token = CLOUD.token end
	return headers
end

local function Http(method, path, body, headers, callback)
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
		transfer:Get(CLOUD.host .. path, headers)
	else
		transfer:Post(CLOUD.host .. path, body or '', headers)
	end
end

local function GetToken(callback)
	local path = '/v1.0/token?grant_type=1'
	Http('GET', path, nil, SignedHeaders('GET', path, nil, false), function(json, err)
		if (json and json.success and json.result) then
			CLOUD.token = json.result.access_token
			CLOUD.tokenExpires = os.time() + (tonumber(json.result.expire_time) or 3600) - 60
			CLOUD.ready = true
			callback(true)
		else
			CLOUD.ready = false
			local why = err or Explain(json)
			Status('Sign-in failed: ' .. why)
			callback(false, why)
		end
	end)
end

-- Tuya answers that say "fix this in the Tuya console", reworded as what to do there.
local HINTS = {
	['28841107'] = 'Tuya says the project can\'t use its data center. In the Tuya IoT console: start or extend '
		.. 'the IoT Core trial (Cloud Services), authorize IoT Core for this project (Service API tab), and check '
		.. 'the data center is enabled (Overview)',
	['1106'] = 'Tuya says permission denied: link your Smart Life account to the project (Devices > Link App Account)',
	['1004'] = 'Tuya rejected the signature: check Cloud Access ID and Secret',
}

local function Explain(json, fallback)
	if (json and HINTS[tostring(json.code)]) then
		return HINTS[tostring(json.code)] .. ' (' .. tostring(json.code) .. ')'
	end
	return fallback or (json and (tostring(json.msg) .. ' (' .. tostring(json.code) .. ')')) or 'no answer'
end

-- Rate-limit and quota answers (Tuya codes 40000309 / "frequency" messages) back off for ten
-- minutes rather than retrying into a bigger bill.
local function Throttled(json)
	local msg = string.lower(tostring(json and json.msg or ''))
	return (json and tostring(json.code) == '40000309') or string.find(msg, 'frequen', 1, true) or string.find(msg, 'limit', 1, true)
end

-- A signed API call with the token, refreshing it once if Tuya says it expired.
local function Api(method, path, body, callback, retried)
	if (not Configured()) then callback(nil, 'cloud not configured') return end
	if (os.time() < CLOUD.backoffUntil) then callback(nil, 'backing off after a rate-limit answer') return end
	if (not CLOUD.token or os.time() >= CLOUD.tokenExpires) then
		GetToken(function(ok, why)
			if (ok) then Api(method, path, body, callback, retried) else callback(nil, why) end
		end)
		return
	end
	Http(method, path, body, SignedHeaders(method, path, body, true), function(json, err)
		if (json and json.success) then
			callback(json.result)
		elseif (json and (tostring(json.code) == '1010' or tostring(json.code) == '1011') and not retried) then
			CLOUD.token = nil
			Api(method, path, body, callback, true)
		else
			if (Throttled(json)) then CLOUD.backoffUntil = os.time() + BACKOFF_S end
			callback(nil, err or Explain(json))
		end
	end)
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

-- A device's datapoint <-> code map, fetched once and persisted.
local function WithSpec(deviceId, callback)
	if (CLOUD.specs[deviceId]) then callback(CLOUD.specs[deviceId]) return end
	Api('GET', '/v1.1/devices/' .. deviceId .. '/specifications', nil, function(result, err)
		if (not result) then callback(nil, err) return end
		local spec = { dp = {}, code = {} }
		for _, list in ipairs({ result.functions or {}, result.status or {} }) do
			for _, f in ipairs(list) do
				if (f.dp_id and f.code) then
					spec.dp[tostring(f.dp_id)] = { code = f.code, type = f.type }
					spec.code[f.code] = tostring(f.dp_id)
				end
			end
		end
		CLOUD.specs[deviceId] = spec
		pcall(function() C4:PersistSetValue(SPEC_KEY, CLOUD.specs) end)
		callback(spec)
	end)
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

-- One paged pass over every linked account's devices: names and keys into the registry,
-- current status to any child controlling that device through the cloud.
local fetching = false
local function FetchDevices(why)
	if (fetching or not Configured()) then return end
	fetching = true
	local count = 0
	local function page(lastRowKey)
		local path = '/v1.0/iot-01/associated-users/devices?' ..
			(lastRowKey and ('last_row_key=' .. lastRowKey .. '&') or '') .. 'size=' .. PAGE
		Api('GET', path, nil, function(result, err)
			if (not result) then
				fetching = false
				-- A failed sign-in already said so; don't bury it under a generic error.
				if (CLOUD.ready) then Status('Error: ' .. tostring(err)) end
				return
			end
			for _, dev in ipairs(result.devices or {}) do
				count = count + 1
				UpdateDevice(dev.id, {
					name = dev.name, key = dev.local_key, category = dev.category,
					product = dev.product_name, cloud = true,
				})
				local d = REGISTRY.devices[dev.id]
				if (d) then d.online = dev.online end
				TellWatchers({ id = dev.id, online = dev.online, status = dev.status })
			end
			if (result.has_more and result.last_row_key) then
				page(result.last_row_key)
			else
				fetching = false
				Status(string.format('OK: %d devices (%s %s)', count, why, os.date('%H:%M')))
			end
		end)
	end
	page(nil)
end

function CloudRefreshDevices(force)
	if (force) then CLOUD.backoffUntil = 0 end
	FetchDevices('refreshed')
end

-- Called by a child (through the bridge) to set datapoints on a device it can't reach locally.
function CloudCommand(deviceId, dps)
	if (not (CLOUD.ready or Configured()) or not deviceId) then return false end
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
		local body = '{"commands":[' .. table.concat(commands, ',') .. ']}'
		Api('POST', '/v1.0/iot-03/devices/' .. deviceId .. '/commands', body, function(result, why)
			if (result == nil) then
				UpdateDriverProperty('Last Error', 'cloud command for ' .. deviceId .. ': ' .. tostring(why))
				for childId, _ in pairs(CLOUD.watch[deviceId] or {}) do
					SendToChild(childId, 'TUYA_CLOUD_FAILED', { DEVICE_ID = deviceId, WHY = tostring(why) })
				end
				return
			end
			-- Confirm the result once, a few seconds later, instead of waiting for the next poll.
			CLOUD.confirm = CLOUD.confirm or SetTimer(4000, function()
				CLOUD.confirm = nil
				FetchDevices('confirmed')
			end)
		end)
	end)
	return true
end

local function Watching()
	for _, children in pairs(CLOUD.watch) do
		if (next(children)) then return true end
	end
	return false
end

local function SchedulePoll()
	CLOUD.pollTimer = CancelTimer(CLOUD.pollTimer)
	if (Watching()) then
		CLOUD.pollTimer = SetTimer(CLOUD.pollSeconds * 1000, function() FetchDevices('polled') end, true)
	end
end

function CloudWatch(deviceId, childId, on)
	if (not deviceId) then return end
	CLOUD.watch[deviceId] = CLOUD.watch[deviceId] or {}
	local was = CLOUD.watch[deviceId][tostring(childId)]
	CLOUD.watch[deviceId][tostring(childId)] = on or nil
	if (on and not was) then FetchDevices('watching') end
	SchedulePoll()
end

function StartCloud()
	StopCloud()
	CLOUD.host = HOSTS[Properties['Cloud Region'] or 'US'] or HOSTS['US']
	CLOUD.id = Trim(Properties['Cloud Access ID'])
	CLOUD.secret = Trim(Properties['Cloud Access Secret'])
	CLOUD.pollSeconds = math.max(60, tonumber(Properties['Cloud Poll Interval (seconds)']) or 120)
	CLOUD.token, CLOUD.ready, CLOUD.backoffUntil = nil, false, 0
	if (not Configured()) then
		Status('Not configured (LAN only)')
		return
	end
	local ok, specs = pcall(function() return C4:PersistGetValue(SPEC_KEY) end)
	if (ok and type(specs) == 'table') then CLOUD.specs = specs end
	Status('Signing in')
	FetchDevices('signed in')
	local hours = math.max(1, tonumber(Properties['Key Refresh (hours)']) or 12)
	CLOUD.refreshTimer = SetTimer(hours * 3600 * 1000, function() FetchDevices('refreshed') end, true)
	SchedulePoll()
end

function StopCloud()
	CLOUD.refreshTimer = CancelTimer(CLOUD.refreshTimer)
	CLOUD.pollTimer = CancelTimer(CLOUD.pollTimer)
	CLOUD.confirm = CancelTimer(CLOUD.confirm)
end
