-- Generic helpers shared by the rest of the driver.

function Trim(value)
	value = tostring(value or '')
	return (string.gsub(value, '^%s*(.-)%s*$', '%1'))
end

function Normalize(value)
	value = Trim(value)
	value = string.gsub(value, '[%s%-/]+', '_')
	return string.upper(value)
end

function DebugLog(message)
	if (DEBUGPRINT) then
		print(LOG_PREFIX .. tostring(message))
	end
end

function UpdateDriverProperty(name, value)
	if (C4 and C4.UpdateProperty) then
		pcall(function()
			C4:UpdateProperty(name, tostring(value or ''))
		end)
	end
end

function SetConnectionStatus(status, err)
	UpdateDriverProperty('Connection Status', status)
	if (err and err ~= '') then
		UpdateDriverProperty('Last Error', err)
		DebugLog('Error: ' .. tostring(err))
	end
end

function Clamp(value, lo, hi)
	if (value < lo) then return lo end
	if (value > hi) then return hi end
	return value
end

function Round(value)
	return math.floor(value + 0.5)
end

function Notify(command, params)
	if (C4 and C4.SendToProxy) then
		C4:SendToProxy(PROXY_BINDING, command, params or {}, 'NOTIFY')
	end
end

function SetTimer(ms, fn, rep)
	return C4:SetTimer(ms, function(timer)
		local ok, err = pcall(fn, timer)
		if (not ok) then
			print(LOG_PREFIX .. 'timer error: ' .. tostring(err))
			UpdateDriverProperty('Last Error', 'driver error: ' .. tostring(err))
		end
	end, rep or false)
end

function CancelTimer(timer)
	if (timer) then
		pcall(function() timer:Cancel() end)
	end
	return nil
end

-- A minimal JSON writer for the payloads Tuya expects. Written by hand rather than with
-- C4:JsonEncode because Tuya needs `null` values in DP queries (a Lua table cannot hold
-- nil), `{}` for an empty object, and integers without a decimal point.
local function JsonValue(v)
	local t = type(v)
	if (v == JSON_NULL) then
		return 'null'
	elseif (t == 'boolean') then
		return v and 'true' or 'false'
	elseif (t == 'number') then
		if (v == math.floor(v)) then
			return string.format('%d', v)
		end
		return tostring(v)
	elseif (t == 'string') then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			return string.format('\\u%04x', string.byte(c))
		end) .. '"'
	elseif (t == 'table') then
		return JsonObject(v)
	end
	return 'null'
end

JSON_NULL = setmetatable({}, { __tostring = function() return 'null' end })

-- Keys are written sorted so a payload is the same bytes every time (easier to diff in logs).
function JsonObject(tbl)
	local keys = {}
	for k, _ in pairs(tbl) do
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		local v = tbl[k]
		if (v == nil) then v = tbl[tonumber(k)] end
		parts[#parts + 1] = JsonValue(k) .. ':' .. JsonValue(v)
	end
	return '{' .. table.concat(parts, ',') .. '}'
end

function JsonDecode(text)
	local ok, result = pcall(function() return C4:JsonDecode(text) end)
	if (ok and type(result) == 'table') then
		return result
	end
	return nil
end
