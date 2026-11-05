-- One persistent TCP connection to the device: connect, 3.4 key negotiation, heartbeat,
-- status pushes, and reconnect with backoff.
--
-- Tuya devices accept very few simultaneous LAN connections (often one), so the driver keeps
-- a single socket open and the device pushes STATUS frames on every change; the periodic
-- query only catches anything missed. Not here: the Tuya cloud — everything is local.

local reconnectDelay = RECONNECT_MIN_MS
-- Values commanded while offline, sent on reconnect if still fresh.
local pendingDps, pendingAt = nil, 0
local PENDING_MAX_AGE_S = 30
local reconnectTimer = nil
local pollTimer = nil
local generation = 0

local function Write(conn, cmd, payload, key)
	local frame = EncodeFrame(DEVICE.version, key or conn.key, conn.seq, cmd, payload)
	conn.seq = conn.seq + 1
	DebugLog(string.format('-> cmd %d %s', cmd, payload))
	conn.client:Write(frame)
end

function SessionReady()
	return CONN ~= nil and CONN.ready
end

local function ScheduleReconnect()
	reconnectTimer = CancelTimer(reconnectTimer)
	local delay = reconnectDelay
	reconnectDelay = math.min(reconnectDelay * 2, RECONNECT_MAX_MS)
	DebugLog('reconnecting in ' .. delay .. ' ms')
	reconnectTimer = SetTimer(delay, function()
		reconnectTimer = nil
		StartSession()
	end)
end

local function Teardown(conn)
	conn.heartbeatTimer = CancelTimer(conn.heartbeatTimer)
	conn.queryTimer = CancelTimer(conn.queryTimer)
	conn.connectTimer = CancelTimer(conn.connectTimer)
	if (conn.client) then
		pcall(function() conn.client:Close() end)
	end
end

local function Lost(conn, why)
	if (CONN ~= conn) then
		return
	end
	CONN = nil
	local wasReady = conn.ready
	Teardown(conn)
	SetConnectionStatus('Offline', why)
	if (wasReady) then
		Notify('ONLINE_CHANGED', { STATE = false })
		if (OnDeviceOnline) then OnDeviceOnline(false) end
	end
	ScheduleReconnect()
end

local function SendQuery(conn)
	local cmd, payload
	if (conn.device22) then
		cmd, payload = Device22QueryPayload(DEVICE.id, KnownDps())
	else
		cmd, payload = QueryPayload(DEVICE.version, DEVICE.id)
	end
	Write(conn, cmd, payload)
end

local function Ready(conn)
	conn.ready = true
	conn.connectTimer = CancelTimer(conn.connectTimer)
	reconnectDelay = RECONNECT_MIN_MS
	SetConnectionStatus('Online')
	UpdateDriverProperty('Last Error', '')
	Notify('ONLINE_CHANGED', { STATE = true })
	if (OnDeviceOnline) then OnDeviceOnline(true) end

	conn.heartbeatTimer = SetTimer(HEARTBEAT_MS, function()
		if (CONN ~= conn) then return end
		if (conn.missed >= MAX_MISSED_HEARTBEATS) then
			Lost(conn, 'device stopped answering heartbeats')
			return
		end
		conn.missed = conn.missed + 1
		local cmd, payload = HeartbeatPayload(DEVICE.id)
		Write(conn, cmd, payload)
	end, true)

	SendQuery(conn)
	conn.queryTimer = SetTimer(QUERY_TIMEOUT_MS, function()
		conn.queryTimer = nil
		if (CONN == conn and not conn.answered) then
			SetConnectionStatus('No Response', 'connected, but the device does not answer: check Local Key and Protocol Version')
		end
	end)
	if (pendingDps) then
		local dps = pendingDps
		pendingDps = nil
		if (os.time() - pendingAt <= PENDING_MAX_AGE_S) then
			SendDps(dps)
		end
	end
end

-- 3.4: the device proves it holds the local key, then both sides derive a session key.
local function FinishNegotiation(conn, payload)
	local p = payload
	if (#p >= 4 and string.sub(p, 1, 3) == '\0\0\0' and (#p - 4) % 16 == 0) then
		p = string.sub(p, 5)
	end
	local plain = AesDecrypt(DEVICE.key, p)
	if (not plain or #plain < 48) then
		Lost(conn, 'session negotiation: short reply')
		return
	end
	local remoteNonce = string.sub(plain, 1, 16)
	if (string.sub(plain, 17, 48) ~= HmacSha256(DEVICE.key, conn.localNonce)) then
		-- Retrying cannot help: the key is wrong. Stop until a property changes.
		conn.fatal = true
		Lost(conn, 'device rejected the Local Key (3.4 negotiation failed)')
		reconnectTimer = CancelTimer(reconnectTimer)
		SetConnectionStatus('Bad Local Key')
		return
	end
	Write(conn, CMD.SESS_KEY_NEG_FINISH, HmacSha256(DEVICE.key, remoteNonce), DEVICE.key)
	conn.key = AesEncrypt(DEVICE.key, XorStrings(conn.localNonce, remoteNonce))
	conn.negotiating = false
	Ready(conn)
end

local function HandleFrame(conn, frame)
	if (not frame.ok) then
		DebugLog('dropped frame: ' .. tostring(frame.err))
		conn.badFrames = (conn.badFrames or 0) + 1
		if (conn.badFrames >= 3) then
			Lost(conn, frame.err)
		end
		return
	end
	conn.missed = 0
	if (frame.cmd == CMD.SESS_KEY_NEG_RESP) then
		FinishNegotiation(conn, frame.payload)
		return
	end
	if (frame.cmd == CMD.HEART_BEAT) then
		return
	end
	local decoded = DecodePayload(frame.payload, DEVICE.version, conn.key)
	if (decoded.err) then
		SetConnectionStatus(conn.ready and 'Online' or 'Connecting', decoded.err)
		return
	end
	if (decoded.text ~= '') then
		DebugLog(string.format('<- cmd %d %s', frame.cmd, decoded.text))
	end
	local dps = DpsOf(decoded.json)
	if (dps) then
		if (not conn.answered) then
			conn.answered = true
			conn.queryTimer = CancelTimer(conn.queryTimer)
			SetConnectionStatus('Online')
		end
		local changed = {}
		for dp, value in pairs(dps) do
			dp = tostring(dp)
			DPS[dp] = value
			changed[dp] = value
		end
		UpdateDriverProperty('Last Update', os.date('%Y-%m-%d %H:%M:%S'))
		OnDpsChanged(changed)
	elseif (string.find(decoded.text, 'data unvalid', 1, true) and not conn.device22) then
		-- Firmware that only answers queries sent as CONTROL_NEW.
		DebugLog('device rejected DP_QUERY; retrying as a device22 query')
		conn.device22 = true
		SendQuery(conn)
	elseif (decoded.text ~= '' and not decoded.json) then
		UpdateDriverProperty('Last Error', 'device said: ' .. decoded.text)
	end
end

function StartSession()
	StopSession()
	if (DEVICE.ip == '' or DEVICE.id == '') then
		SetConnectionStatus('Not Configured', 'set Device IP and Device ID')
		return
	end
	if (#DEVICE.key ~= 16) then
		SetConnectionStatus('Not Configured', 'Local Key must be exactly 16 characters')
		return
	end

	generation = generation + 1
	local conn = { seq = 1, buffer = '', key = DEVICE.key, ready = false, missed = 0, generation = generation }
	CONN = conn
	SetConnectionStatus('Connecting')

	local client = C4:CreateTCPClient()
	conn.client = client
	client:OnConnect(function(c)
		if (CONN ~= conn) then c:Close() return end
		if (DEVICE.version >= 3.4) then
			conn.negotiating = true
			conn.localNonce = RandomBytes(16)
			Write(conn, CMD.SESS_KEY_NEG_START, conn.localNonce, DEVICE.key)
		else
			Ready(conn)
		end
		c:ReadAtLeast(1)
	end)
	client:OnRead(function(c, data)
		if (CONN ~= conn) then return end
		local frames
		local key = conn.negotiating and DEVICE.key or conn.key
		frames, conn.buffer = SplitFrames(conn.buffer .. data, DEVICE.version, key)
		for _, frame in ipairs(frames) do
			if (CONN ~= conn) then return end
			HandleFrame(conn, frame)
		end
		if (CONN == conn) then c:ReadAtLeast(1) end
	end)
	client:OnDisconnect(function(c, code, msg)
		Lost(conn, 'device closed the connection')
	end)
	client:OnError(function(c, code, msg)
		Lost(conn, 'connection error: ' .. tostring(msg or code))
	end)
	conn.connectTimer = SetTimer(CONNECT_TIMEOUT_MS, function()
		if (CONN == conn and not conn.ready) then
			if (conn.negotiating) then
				Lost(conn, 'no answer to the 3.4 handshake: check Local Key and Protocol Version')
			else
				Lost(conn, 'timed out connecting to ' .. DEVICE.ip .. ':' .. TUYA_PORT)
			end
		end
	end)
	client:Connect(DEVICE.ip, TUYA_PORT)
end

function StopSession()
	reconnectTimer = CancelTimer(reconnectTimer)
	local conn = CONN
	CONN = nil
	if (conn) then
		Teardown(conn)
		if (conn.ready) then
			Notify('ONLINE_CHANGED', { STATE = false })
		end
	end
end

function RestartSession()
	reconnectDelay = RECONNECT_MIN_MS
	StartSession()
end

-- Sends datapoint values. While offline the latest values are kept and sent on reconnect, so
-- a command given during a blip still lands.
function SendDps(dps)
	if (not SessionReady()) then
		pendingDps = pendingDps or {}
		for k, v in pairs(dps) do pendingDps[k] = v end
		pendingAt = os.time()
		DebugLog('offline; queued ' .. JsonObject(dps))
		return
	end
	local cmd, payload = ControlPayload(DEVICE.version, DEVICE.id, dps)
	Write(CONN, cmd, payload)
end

function RefreshNow()
	if (SessionReady()) then
		SendQuery(CONN)
		if (RefreshExtras) then RefreshExtras(CONN) end
	else
		RestartSession()
	end
end

function SendUpdateDps(dpList)
	if (SessionReady()) then
		local cmd, payload = UpdateDpsPayload(dpList)
		Write(CONN, cmd, payload)
	end
end

function StartPolling(seconds)
	pollTimer = CancelTimer(pollTimer)
	seconds = tonumber(seconds) or 60
	if (seconds < 10) then seconds = 10 end
	pollTimer = SetTimer(seconds * 1000, function()
		if (SessionReady()) then RefreshNow() end
	end, true)
end

function StopPolling()
	pollTimer = CancelTimer(pollTimer)
end
