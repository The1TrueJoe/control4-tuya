-- LAN discovery: Tuya devices broadcast who they are every few seconds on UDP 6666
-- (protocol 3.1, plain JSON) and 6667 (3.2+, AES-ECB with a fixed, published key). 3.5
-- devices broadcast on 7000 with AES-GCM, which Director cannot decrypt here: the bridge
-- notes the address and leaves those devices to the cloud.
--
-- Cost: a device repeats the same bytes every broadcast, so a packet identical to the last
-- one from that address only refreshes `seen`. Decrypting and decoding happen when a device
-- first appears or changes (new IP, new version). Broadcasts don't cross routers: devices on
-- another subnet are only known through the cloud.

local BROADCAST_KEY = FromHex('6c1ec8e2bb9bb59ab50b0daf649b410a') -- md5("yGAdlopoPVldABfn")
local PORTS = { 6666, 6667, 7000 }
local SEEN_TIMEOUT_S = 600

DISCOVERY = { enabled = true, servers = {}, last = {}, gcmOnly = {} } -- last: ip -> { data, seen, id }

-- Identified by content, not port: Director's strPort is the sender's port, and the handle
-- names a client, not which of our listeners it arrived on.
local function Decode(data)
	if (string.sub(data, 1, 4) == '\0\0\102\153') then
		return 'gcm'
	end
	if (#data < 28 or string.sub(data, 1, 4) ~= '\0\0\85\170') then
		return nil
	end
	-- 16-byte header, 4-byte return code, payload, CRC and suffix (8 bytes).
	local payload = string.sub(data, 21, #data - 8)
	if (string.sub(payload, 1, 1) ~= '{') then
		if (#payload == 0 or #payload % 16 ~= 0) then return nil end
		local plain = AesDecrypt(BROADCAST_KEY, payload)
		payload = plain and Pkcs7Unpad(plain)
		if (not payload) then return nil end
	end
	return JsonDecode(payload)
end

function OnServerDataIn(nHandle, strData, strClientAddress, strPort)
	local ip = tostring(strClientAddress)
	local now = os.time()
	local prev = DISCOVERY.last[ip]
	if (prev and prev.data == strData) then
		prev.seen = now
		local d = prev.id and REGISTRY.devices[prev.id]
		if (d) then d.seen = now end
		return
	end
	DISCOVERY.last[ip] = { data = strData, seen = now }
	local info = Decode(strData)
	if (info == 'gcm') then
		DISCOVERY.gcmOnly[ip] = now
		DebugLog('3.5 broadcast from ' .. ip .. ' (AES-GCM; reachable through the cloud only)')
		return
	end
	if (type(info) ~= 'table' or not info.gwId) then
		DebugLog('unreadable broadcast from ' .. ip)
		return
	end
	DISCOVERY.last[ip].id = info.gwId
	DebugLog(string.format('found %s at %s (protocol %s)', info.gwId, tostring(info.ip or ip), tostring(info.version)))
	UpdateDevice(info.gwId, {
		ip = info.ip or ip,
		version = info.version and tostring(info.version) or nil,
		productKey = info.productKey,
		seen = now,
	})
end

function OnServerStatusChanged(nPort, strStatus)
	DebugLog('UDP ' .. tostring(nPort) .. ': ' .. tostring(strStatus))
end

function StartDiscovery()
	StopDiscovery()
	if (not DISCOVERY.enabled) then
		UpdateDriverProperty('Discovery Status', 'Off')
		return
	end
	local listening = {}
	for _, port in ipairs(PORTS) do
		local ok, handle = pcall(function() return C4:CreateServer(port, '', true) end)
		if (ok and handle) then
			DISCOVERY.servers[handle] = port
			listening[#listening + 1] = tostring(port)
		else
			UpdateDriverProperty('Last Error', 'could not listen on UDP ' .. port .. ': ' .. tostring(handle))
		end
	end
	UpdateDriverProperty('Discovery Status', #listening > 0 and ('Listening on UDP ' .. table.concat(listening, ', ')) or 'Not listening')
	-- Forget addresses that went quiet, so a replaced device's old packet can't mask the new one.
	DISCOVERY.sweep = SetTimer(60000, function()
		local cutoff = os.time() - SEEN_TIMEOUT_S
		for key, entry in pairs(DISCOVERY.last) do
			if (entry.seen < cutoff) then DISCOVERY.last[key] = nil end
		end
	end, true)
end

function StopDiscovery()
	DISCOVERY.sweep = CancelTimer(DISCOVERY.sweep)
	if (next(DISCOVERY.servers)) then
		pcall(function() C4:DestroyServer() end)
	end
	DISCOVERY.servers = {}
end
