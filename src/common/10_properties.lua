-- Composer property handling. Connection properties restart the session; the rest belong to
-- the variant (ApplyVariantProperty).

local RESTART_ON = {
	['Device IP'] = true,
	['Device ID'] = true,
	['Local Key'] = true,
	['Protocol Version'] = true,
}

local restartTimer = nil

-- Several connection properties usually change together (pasting IP, ID and key); restart once.
local function RestartSoon()
	restartTimer = CancelTimer(restartTimer)
	restartTimer = SetTimer(500, function()
		restartTimer = nil
		RestartSession()
	end)
end

function ApplyProperty(name)
	local value = (Properties and Properties[name]) or ''
	if (name == 'Device IP') then
		DEVICE.ip = Trim(value)
	elseif (name == 'Device ID') then
		DEVICE.id = Trim(value)
	elseif (name == 'Local Key') then
		-- Not trimmed beyond whitespace: a local key may contain any printable character.
		DEVICE.key = Trim(value)
	elseif (name == 'Protocol Version') then
		local v, err = ParseVersion(value)
		if (v) then
			DEVICE.version = v
		else
			UpdateDriverProperty('Last Error', err)
		end
	elseif (name == 'Poll Interval (seconds)') then
		StartPolling(value)
	elseif (name == 'Debug Mode') then
		DEBUGPRINT = (value == 'On')
	elseif (ApplyVariantProperty) then
		ApplyVariantProperty(name, value)
	end
	return RESTART_ON[name] == true
end

function OnPropertyChanged(name)
	if (DRIVER_DESTROYING) then
		return
	end
	if (ApplyProperty(name) and LATE_INIT_DONE) then
		RestartSoon()
	end
end
