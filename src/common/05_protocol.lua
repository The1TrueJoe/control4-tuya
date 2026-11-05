-- Tuya LAN protocol framing for protocol 3.3 and 3.4 (the 0x55AA frame).
--
-- Not here: 3.1 (MD5-signed base64 control messages) and 3.5 (the 0x6699 frame with
-- AES-GCM). ponytail: both are refused by name in ParseVersion; 3.5 needs AES-GCM from
-- C4:Encrypt, which is the upgrade path once a controller is shown to support it.
--
-- Frame: 000055AA | seq u32 | cmd u32 | len u32 | payload | crc32 u32 (3.3) or
-- HMAC-SHA256 (3.4) | 0000AA55. `len` counts everything after itself.

local PREFIX = '\0\0\85\170'
local SUFFIX = '\0\0\170\85'
local HEADER_LEN = 16

function ParseVersion(text)
	local v = tonumber(Trim(text))
	if (v == 3.3 or v == 3.4) then
		return v
	end
	return nil, 'protocol ' .. tostring(text) .. ' is not supported (use 3.3 or 3.4)'
end

local function VersionHeader(version)
	return string.format('%.1f', version) .. string.rep('\0', 12)
end

-- Builds one frame. `key` is the device's local key (3.3) or the negotiated session key (3.4).
function EncodeFrame(version, key, seq, cmd, payload)
	payload = payload or ''
	local useHmac = version >= 3.4
	if (version >= 3.4) then
		if (not NO_VERSION_HEADER[cmd]) then
			payload = VersionHeader(version) .. payload
		end
		payload = AesEncrypt(key, Pkcs7Pad(payload))
	else
		payload = AesEncrypt(key, Pkcs7Pad(payload))
		if (not NO_VERSION_HEADER[cmd]) then
			payload = VersionHeader(version) .. payload
		end
	end
	local trailer = useHmac and 36 or 8
	local body = PREFIX .. U32(seq) .. U32(cmd) .. U32(#payload + trailer) .. payload
	local check = useHmac and HmacSha256(key, body) or U32(Crc32(body))
	return body .. check .. SUFFIX
end

-- Splits a receive buffer into frames. Returns a list of { seq, cmd, payload, ok, err } and
-- the unconsumed remainder. Bytes before a prefix are discarded (resync after garbage).
function SplitFrames(buffer, version, key)
	local frames = {}
	while (true) do
		local start = string.find(buffer, PREFIX, 1, true)
		if (not start) then
			-- Keep a possible partial prefix at the end.
			return frames, string.sub(buffer, -3)
		end
		if (start > 1) then
			buffer = string.sub(buffer, start)
		end
		if (#buffer < HEADER_LEN) then
			return frames, buffer
		end
		local seq = ReadU32(buffer, 5)
		local cmd = ReadU32(buffer, 9)
		local len = ReadU32(buffer, 13)
		if (len < 8 or len > 65536) then
			-- Not a real header: skip this prefix and look for the next one.
			buffer = string.sub(buffer, 2)
		else
			local total = HEADER_LEN + len
			if (#buffer < total) then
				return frames, buffer
			end
			local frame = string.sub(buffer, 1, total)
			buffer = string.sub(buffer, total + 1)
			frames[#frames + 1] = CheckFrame(frame, seq, cmd, version, key)
		end
	end
end

function CheckFrame(frame, seq, cmd, version, key)
	local result = { seq = seq, cmd = cmd }
	if (string.sub(frame, -4) ~= SUFFIX) then
		result.err = 'bad frame suffix'
		return result
	end
	local useHmac = version >= 3.4
	local trailer = useHmac and 36 or 8
	local body = string.sub(frame, 1, #frame - trailer)
	local check = string.sub(frame, #frame - trailer + 1, #frame - 4)
	if (useHmac) then
		if (HmacSha256(key, body) ~= check) then
			result.err = 'HMAC mismatch (wrong local key?)'
			return result
		end
	elseif (U32(Crc32(body)) ~= check) then
		result.err = 'CRC mismatch'
		return result
	end
	result.payload = string.sub(body, HEADER_LEN + 1)
	result.ok = true
	return result
end

local function HasVersionHeader(s)
	return string.match(string.sub(s, 1, 3), '^3%.%d$') ~= nil
end

-- Turns a frame payload from a device into { retcode, text, json }. `text` is the
-- decrypted payload ('' for a bare acknowledgement); `json` is set when it parses.
function DecodePayload(payload, version, key)
	local out = { retcode = 0, text = '' }
	local p = payload
	-- Replies from a device start with a 4-byte return code; what follows is either empty,
	-- 16-byte blocks of ciphertext, or (3.3 pushes) a 15-byte version header + ciphertext.
	if (#p >= 4 and string.sub(p, 1, 3) == '\0\0\0') then
		local rest = #p - 4
		if (rest == 0 or rest % 16 == 0 or (rest - 15) % 16 == 0 or string.sub(p, 5, 5) == '{') then
			out.retcode = string.byte(p, 4)
			p = string.sub(p, 5)
		end
	end
	if (version < 3.4 and HasVersionHeader(p)) then
		p = string.sub(p, 16)
	end
	if (#p == 0) then
		return out
	end
	if (string.sub(p, 1, 1) == '{' or #p % 16 ~= 0) then
		-- Plaintext: some devices answer errors (`data format error`) unencrypted.
		out.text = p
	else
		local plain, err = AesDecrypt(key, p)
		if (not plain) then
			out.err = err
			return out
		end
		local unpadded = Pkcs7Unpad(plain)
		if (not unpadded) then
			out.err = 'could not decrypt the reply (check the Local Key)'
			return out
		end
		if (HasVersionHeader(unpadded)) then
			unpadded = string.sub(unpadded, 16)
		end
		out.text = unpadded
	end
	if (string.sub(out.text, 1, 1) == '{') then
		out.json = JsonDecode(out.text)
	end
	return out
end

-- The datapoints in a decoded reply, whichever shape the protocol uses:
-- 3.3 `{"devId":…,"dps":{…}}`, 3.4 `{"protocol":4,"data":{"dps":{…}}}`.
function DpsOf(json)
	if (type(json) ~= 'table') then
		return nil
	end
	if (type(json.dps) == 'table') then
		return json.dps
	end
	if (type(json.data) == 'table' and type(json.data.dps) == 'table') then
		return json.data.dps
	end
	return nil
end

function Now()
	return os.time()
end

-- Payloads, per protocol version.
function QueryPayload(version, id)
	if (version >= 3.4) then
		return CMD.DP_QUERY_NEW, '{}'
	end
	return CMD.DP_QUERY, JsonObject({ gwId = id, devId = id, uid = id, t = tostring(Now()) })
end

function ControlPayload(version, id, dps)
	if (version >= 3.4) then
		return CMD.CONTROL_NEW, JsonObject({ protocol = 5, t = Now(), data = { dps = dps } })
	end
	return CMD.CONTROL, JsonObject({ devId = id, uid = id, t = tostring(Now()), dps = dps })
end

-- "device22" firmware (22-character IDs on 3.3) rejects DP_QUERY and must be asked through
-- CONTROL_NEW with the datapoints it should report set to null.
function Device22QueryPayload(id, dpList)
	local dps = {}
	for _, dp in ipairs(dpList) do
		dps[tostring(dp)] = JSON_NULL
	end
	return CMD.CONTROL_NEW, JsonObject({ devId = id, uid = id, t = tostring(Now()), dps = dps })
end

function HeartbeatPayload(id)
	return CMD.HEART_BEAT, JsonObject({ gwId = id, devId = id })
end

function UpdateDpsPayload(dpList)
	local items = {}
	for _, dp in ipairs(dpList) do
		items[#items + 1] = string.format('%d', dp)
	end
	return CMD.UPDATEDPS, '{"dpId":[' .. table.concat(items, ',') .. ']}'
end
