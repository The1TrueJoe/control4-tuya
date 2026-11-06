-- Cloud Account "Smart Life": sign in with the Smart Life (or Tuya Smart) app by scanning a QR
-- code, through Tuya's device-sharing login. No developer project, nothing to renew.
--
-- Login: the User Code from the app (Me > Settings > Account and Security) asks Tuya for a QR
-- token; the bridge shows it as a QR code on a small page it serves (09_login.lua); the app
-- scans it and confirms; polling the token then returns the account's tokens and API
-- endpoint. Tokens are kept with PersistSetValue and refreshed before they expire, so this
-- happens once.
--
-- Requests: every response's result (and any query or body) is AES-128-GCM encrypted with a
-- per-request key, and requests are signed with HMAC-SHA256 over the headers. GCM comes from
-- control4-aes-gcm (built on Director's AES-ECB).

local CLIENT_ID = 'HA_3y9q4ak7g4ephrvke'
local SCHEMA = 'haauthorize'
local LOGIN_HOST = 'https://apigw.iotbing.com'
local PERSIST_KEY = 'tuya_bridge_smartlife'
local LOGIN_TRIES = 100 -- five minutes
local NONCE_CHARS = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678'

-- session: { userCode, endpoint, access, refresh, uid, expires, terminal }
SMARTLIFE = { login = nil, loginPollMs = 3000 }

-- The login status, shown in the Smart Life Login property and the SMART_LIFE_STATUS variable
-- (which the Smart Life Login web tab reads).
function SetLoginStatus(text)
	UpdateDriverProperty('Smart Life Login', text)
	pcall(function() C4:SetVariable('SMART_LIFE_STATUS', text) end)
end

local function SetQr(payload)
	pcall(function() C4:SetVariable('SMART_LIFE_QR', payload or '') end)
end

function SmartLifeVariables()
	pcall(function()
		C4:AddVariable('SMART_LIFE_STATUS', 'Not signed in', 'STRING', true, false)
		C4:AddVariable('SMART_LIFE_QR', '', 'STRING', true, true)
	end)
end

local function Save()
	pcall(function() C4:PersistSetValue(PERSIST_KEY, SMARTLIFE.session or {}) end)
end

local function Load()
	local ok, s = pcall(function() return C4:PersistGetValue(PERSIST_KEY) end)
	if (ok and type(s) == 'table' and s.access and s.access ~= '') then
		SMARTLIFE.session = s
	else
		SMARTLIFE.session = nil
	end
end

local function UrlEncode(s)
	return (string.gsub(tostring(s), '([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end))
end

local function RandomChars(n)
	local out = {}
	for i = 1, n do
		local k = math.random(1, #NONCE_CHARS)
		out[i] = string.sub(NONCE_CHARS, k, k)
	end
	return table.concat(out)
end

-- A random (version 4) UUID, as the API's X-requestId.
local function Uuid()
	local h = ToHex(RandomBytes(16))
	local variant = math.random(1, 4)
	return string.sub(h, 1, 8) .. '-' .. string.sub(h, 9, 12) .. '-4' .. string.sub(h, 14, 16) .. '-' ..
		string.sub('89ab', variant, variant) .. string.sub(h, 18, 20) .. '-' .. string.sub(h, 21, 32)
end

-- base64(nonce) .. base64(ciphertext .. tag), as the API expects.
local function Seal(plain, secret)
	local nonce = RandomChars(12)
	return Base64Encode(nonce) .. Base64Encode(AesGcm.encrypt(secret, nonce, plain))
end

local function Open(sealed, secret)
	local raw = Base64Decode(sealed)
	if (not raw or #raw < 28) then return nil end
	-- Over Director's verified HTTPS: skip GHASH (see control4-aes-gcm's cost note).
	return AesGcm.decrypt(secret, string.sub(raw, 1, 12), string.sub(raw, 13), { verify = false })
end

local Request

local function NeedsRefresh(s)
	return s and s.expires and os.time() >= (s.expires - 60)
end

-- One signed, encrypted request. params/body are JSON strings or nil. callback(result, why).
local function RawRequest(method, path, params, body, callback)
	local s = SMARTLIFE.session
	if (not s) then callback(nil, 'not signed in') return end
	local rid = Uuid()
	local hashKey = Md5Hex(rid .. (s.refresh or ''))
	local secret = string.sub(ToHex(HmacSha256(rid, hashKey)), 1, 16)

	local queryEnc, bodyEnc = '', ''
	local url = s.endpoint .. path
	if (params) then
		queryEnc = Seal(params, secret)
		url = url .. (string.find(url, '?', 1, true) and '&' or '?') .. 'encdata=' .. UrlEncode(queryEnc)
	end
	local payload = nil
	if (body) then
		bodyEnc = Seal(body, secret)
		payload = '{"encdata":"' .. bodyEnc .. '"}'
	end
	local t = string.format('%.0f', os.time() * 1000)
	local headers = { ['X-appKey'] = CLIENT_ID, ['X-requestId'] = rid, ['X-time'] = t, ['X-token'] = s.access or '',
		['Content-Type'] = 'application/json' }
	-- Signed header order is fixed; X-sid is empty and so left out.
	local signStr = 'X-appKey=' .. CLIENT_ID .. '||X-requestId=' .. rid .. '||X-time=' .. t
	if (s.access and s.access ~= '') then signStr = signStr .. '||X-token=' .. s.access end
	headers['X-sign'] = ToHex(HmacSha256(hashKey, signStr .. queryEnc .. bodyEnc))

	HttpJson(method, url, payload, headers, function(json, err)
		if (not json) then callback(nil, err) return end
		if (not json.success) then
			CloudThrottled(json)
			callback(nil, ExplainCloudError(json), json)
			return
		end
		local result = json.result
		if (type(result) == 'string' and result ~= '') then
			local plain = Open(result, secret)
			result = plain and (JsonDecode(plain) or plain)
		end
		callback(result, nil, json)
	end)
end

local function Refresh(callback)
	local s = SMARTLIFE.session
	RawRequest('GET', '/v1.0/m/token/' .. s.refresh, nil, nil, function(result, why, json)
		if (type(result) == 'table' and result.accessToken) then
			s.access = result.accessToken
			s.refresh = result.refreshToken or s.refresh
			s.expires = math.floor((tonumber(json and json.t) or os.time() * 1000) / 1000) + (tonumber(result.expireTime) or 7200)
			Save()
			callback(true)
		else
			callback(false, why)
		end
	end)
end

-- Refreshes the access token first when it is about to expire.
Request = function(method, path, params, body, callback)
	if (CloudBackingOff()) then callback(nil, 'backing off after a rate-limit answer') return end
	if (NeedsRefresh(SMARTLIFE.session)) then
		Refresh(function(ok, why)
			if (ok) then
				RawRequest(method, path, params, body, callback)
			else
				CLOUD.ready = false
				CloudStatus('Signed out: ' .. tostring(why) .. ' - run Smart Life Login again')
				callback(nil, why)
			end
		end)
		return
	end
	RawRequest(method, path, params, body, callback)
end

local function ToDevice(dev)
	return { id = dev.id, name = dev.name, key = dev.local_key, category = dev.category,
		product = dev.product_name, online = dev.online, status = dev.status }
end

local fetching = false
local function FetchAll(why)
	if (fetching or not SMARTLIFE.session) then return end
	fetching = true
	Request('GET', '/v1.0/m/life/users/homes', nil, nil, function(homes, err)
		if (type(homes) ~= 'table') then
			fetching = false
			CloudStatus('Error: ' .. tostring(err))
			return
		end
		local pending, count = #homes, 0
		if (pending == 0) then
			fetching = false
			CloudStatus('OK: no homes in this account')
			return
		end
		for _, home in ipairs(homes) do
			Request('GET', '/v1.0/m/life/ha/home/devices', JsonObject({ homeId = tostring(home.ownerId) }), nil, function(devices, why2)
				for _, dev in ipairs(type(devices) == 'table' and devices or {}) do
					count = count + 1
					IngestDevice(ToDevice(dev))
				end
				if (why2) then UpdateDriverProperty('Last Error', 'home ' .. tostring(home.name) .. ': ' .. tostring(why2)) end
				pending = pending - 1
				if (pending == 0) then
					fetching = false
					CloudStatus(string.format('OK: %d devices in %d home%s (%s %s)', count, #homes, #homes == 1 and '' or 's', why, os.date('%H:%M')))
				end
			end)
		end
	end)
end

-- The QR login. Called by the Smart Life Login action.
function SmartLifeStartLogin(userCode)
	userCode = Trim(userCode or Properties['Smart Life User Code'])
	if (userCode == '') then
		SetLoginStatus('Enter your User Code first (Smart Life: Me > Settings > Account and Security)')
		return
	end
	SmartLifeStopLogin()
	local url = LOGIN_HOST .. '/v1.0/m/life/home-assistant/qrcode/tokens?clientid=' .. CLIENT_ID ..
		'&usercode=' .. UrlEncode(userCode) .. '&schema=' .. SCHEMA
	HttpJson('POST', url, '', {}, function(json, err)
		local qr = json and json.success and json.result and json.result.qrcode
		if (not qr) then
			SetLoginStatus('Could not start: ' .. tostring(err or ExplainCloudError(json)))
			return
		end
		SMARTLIFE.login = { token = qr, userCode = userCode, tries = 0 }
		local payload = 'tuyaSmart--qrLogin?token=' .. qr
		SetQr(payload)
		local where = ShowLoginQr(payload)
		SetLoginStatus('Scan the code in the Smart Life Login tab (or at ' .. where .. ') with the Smart Life app (5 minutes)')
		SMARTLIFE.loginTimer = SetTimer(SMARTLIFE.loginPollMs, function()
			local login = SMARTLIFE.login
			if (not login) then return end
			login.tries = login.tries + 1
			if (login.tries > LOGIN_TRIES) then
				SmartLifeStopLogin()
				SetLoginStatus('The code expired. Run Smart Life Login again.')
				return
			end
			local pollUrl = LOGIN_HOST .. '/v1.0/m/life/home-assistant/qrcode/tokens/' .. login.token ..
				'?clientid=' .. CLIENT_ID .. '&usercode=' .. UrlEncode(login.userCode)
			HttpJson('GET', pollUrl, nil, {}, function(r)
				if (not (SMARTLIFE.login == login and r and r.success and r.result and r.result.access_token)) then return end
				local res = r.result
				SMARTLIFE.session = {
					userCode = login.userCode, endpoint = res.endpoint, access = res.access_token, refresh = res.refresh_token,
					uid = res.uid, terminal = res.terminal_id,
					expires = math.floor((tonumber(r.t) or os.time() * 1000) / 1000) + (tonumber(res.expire_time) or 7200),
				}
				Save()
				SmartLifeStopLogin()
				SetLoginStatus('Signed in' .. (res.username and (' as ' .. tostring(res.username)) or ''))
				CloudReady()
			end)
		end, true)
	end)
end

function SmartLifeStopLogin()
	SMARTLIFE.loginTimer = CancelTimer(SMARTLIFE.loginTimer)
	SMARTLIFE.login = nil
	SetQr(nil)
	HideLoginQr()
end

function SmartLifeLogout()
	SmartLifeStopLogin()
	SMARTLIFE.session = nil
	Save()
	CLOUD.ready = false
	SetLoginStatus('Signed out')
	CloudStatus('Not signed in (LAN only)')
end

BACKENDS['Smart Life'] = {
	configured = function() return true end,
	start = function()
		Load()
		if (SMARTLIFE.session) then
			SetLoginStatus('Signed in')
			CloudReady()
		else
			CloudStatus('Not signed in: enter your User Code and run Smart Life Login')
		end
	end,
	fetch = FetchAll,
	poll = function(ids, why)
		-- One request for every watched device (status and online).
		Request('GET', '/v1.0/m/life/ha/devices/detail', JsonObject({ devIds = table.concat(ids, ',') }), nil, function(devices)
			for _, dev in ipairs(type(devices) == 'table' and devices or {}) do
				IngestDevice(ToDevice(dev))
			end
		end)
	end,
	spec = function(deviceId, callback)
		-- The DP <-> code relation comes with the device's status strategy.
		Request('GET', '/v1.0/m/life/devices/' .. deviceId .. '/status', nil, nil, function(result, err)
			if (type(result) ~= 'table') then callback(nil, err) return end
			local spec = NewSpec()
			for _, rel in ipairs(result.dpStatusRelationDTOS or {}) do
				SpecAdd(spec, rel.dpId, rel.statusCode)
			end
			callback(spec)
		end)
	end,
	command = function(deviceId, body, callback)
		Request('POST', '/v1.1/m/thing/' .. deviceId .. '/commands', nil, body, function(result, why)
			callback(why == nil, why)
		end)
	end,
	stop = function()
		SmartLifeStopLogin()
	end,
}
