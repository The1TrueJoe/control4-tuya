-- Cloud Account "Tuya IoT Project": the IoT platform's OpenAPI with a developer project's
-- Access ID and Secret, covering every Smart Life account linked to that project.
--
-- One endpoint does both jobs: /v1.0/iot-01/associated-users/devices returns each device's
-- name, local key, online flag and current status, 50 per call, so a key refresh and a status
-- poll are the same paged request.

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

local IOT = { token = nil, tokenExpires = 0 }

local function Settings()
	IOT.host = HOSTS[Properties['Cloud Region'] or 'US'] or HOSTS['US']
	IOT.id = Trim(Properties['Cloud Access ID'])
	IOT.secret = Trim(Properties['Cloud Access Secret'])
end

-- Tuya's request signature: HMAC-SHA256 over client_id [+ token] + t + nonce + the request
-- (method, SHA-256 of the body, signed headers (none), path with sorted query).
local function SignedHeaders(method, path, body, withToken)
	local t = string.format('%.0f', os.time() * 1000)
	local bodyHash = (body and body ~= '') and Sha256Hex(body) or EMPTY_SHA256
	local toSign = method .. '\n' .. bodyHash .. '\n\n' .. path
	local str = IOT.id .. (withToken and IOT.token or '') .. t .. toSign
	local headers = {
		client_id = IOT.id,
		sign = string.upper(ToHex(HmacSha256(IOT.secret, str))),
		t = t,
		sign_method = 'HMAC-SHA256',
		['Content-Type'] = 'application/json',
	}
	if (withToken) then headers.access_token = IOT.token end
	return headers
end

local function GetToken(callback)
	local path = '/v1.0/token?grant_type=1'
	HttpJson('GET', IOT.host .. path, nil, SignedHeaders('GET', path, nil, false), function(json, err)
		if (json and json.success and json.result) then
			IOT.token = json.result.access_token
			IOT.tokenExpires = os.time() + (tonumber(json.result.expire_time) or 3600) - 60
			callback(true)
		else
			CLOUD.ready = false
			local why = err or ExplainCloudError(json)
			CloudStatus('Sign-in failed: ' .. why)
			callback(false, why)
		end
	end)
end

-- A signed API call with the token, refreshing it once if Tuya says it expired.
local function Api(method, path, body, callback, retried)
	if (CloudBackingOff()) then callback(nil, 'backing off after a rate-limit answer') return end
	if (not IOT.token or os.time() >= IOT.tokenExpires) then
		GetToken(function(ok, why)
			if (ok) then Api(method, path, body, callback, retried) else callback(nil, why) end
		end)
		return
	end
	HttpJson(method, IOT.host .. path, body, SignedHeaders(method, path, body, true), function(json, err)
		if (json and json.success) then
			callback(json.result)
		elseif (json and (tostring(json.code) == '1010' or tostring(json.code) == '1011') and not retried) then
			IOT.token = nil
			Api(method, path, body, callback, true)
		else
			CloudThrottled(json)
			callback(nil, err or ExplainCloudError(json))
		end
	end)
end

local fetching = false
local function FetchAll(why)
	if (fetching) then return end
	fetching = true
	local count = 0
	local function page(lastRowKey)
		local path = '/v1.0/iot-01/associated-users/devices?' ..
			(lastRowKey and ('last_row_key=' .. lastRowKey .. '&') or '') .. 'size=' .. PAGE
		Api('GET', path, nil, function(result, err)
			if (not result) then
				fetching = false
				-- A failed sign-in already said so; don't bury it under a generic error.
				if (CLOUD.ready) then CloudStatus('Error: ' .. tostring(err)) end
				return
			end
			for _, dev in ipairs(result.devices or {}) do
				count = count + 1
				IngestDevice({ id = dev.id, name = dev.name, key = dev.local_key, category = dev.category,
					product = dev.product_name, online = dev.online, status = dev.status })
			end
			if (result.has_more and result.last_row_key) then
				page(result.last_row_key)
			else
				fetching = false
				CloudStatus(string.format('OK: %d devices (%s %s)', count, why, os.date('%H:%M')))
			end
		end)
	end
	page(nil)
end

BACKENDS['Tuya IoT Project'] = {
	configured = function()
		Settings()
		return IOT.id ~= '' and IOT.secret ~= ''
	end,
	start = function()
		IOT.token, IOT.tokenExpires = nil, 0
		CloudStatus('Signing in')
		GetToken(function(ok)
			if (ok) then CloudReady() end
		end)
	end,
	fetch = FetchAll,
	-- The device list carries status too: one paged request polls every watched device.
	poll = function(ids, why) FetchAll(why) end,
	spec = function(deviceId, callback)
		Api('GET', '/v1.1/devices/' .. deviceId .. '/specifications', nil, function(result, err)
			if (not result) then callback(nil, err) return end
			local spec = NewSpec()
			for _, list in ipairs({ result.functions or {}, result.status or {} }) do
				for _, f in ipairs(list) do SpecAdd(spec, f.dp_id, f.code) end
			end
			callback(spec)
		end)
	end,
	command = function(deviceId, body, callback)
		Api('POST', '/v1.0/iot-03/devices/' .. deviceId .. '/commands', body, function(result, why)
			callback(result ~= nil, why)
		end)
	end,
	stop = function() end,
}
