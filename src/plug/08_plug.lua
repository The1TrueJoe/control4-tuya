-- Tuya smart plugs and switches as an on/off light_v2, with optional power metering.
--
-- The switch is one datapoint (1 on nearly every plug; 2, 3, … for the other gangs of a
-- multi-gang switch). Metering plugs report current (mA), power (W x10) and voltage (V x10)
-- on DPs 18/19/20, or 4/5/6 on older firmware. Not here: several gangs from one driver
-- instance. ponytail: run one instance per gang only on devices that allow more than one LAN
-- connection; otherwise the instances fight over the socket.

local METERING = {
	['18-20'] = { current = '18', power = '19', voltage = '20' },
	['4-6'] = { current = '4', power = '5', voltage = '6' },
}

PLUG = {
	switchDp = '1',
	meteringSetting = 'Auto',
	metering = nil,
	on = false,
	told = nil,
	vars = false,
}

function KnownDps()
	local list = { tonumber(PLUG.switchDp) }
	local m = PLUG.metering or METERING['18-20']
	list[#list + 1] = tonumber(m.current)
	list[#list + 1] = tonumber(m.power)
	list[#list + 1] = tonumber(m.voltage)
	return list
end

local function ResolveMetering()
	local s = PLUG.meteringSetting
	if (s == 'None') then return nil end
	if (METERING[s]) then return METERING[s] end
	if (DPS['19'] ~= nil and PLUG.switchDp ~= '19') then return METERING['18-20'] end
	if (DPS['5'] ~= nil and DPS['6'] ~= nil and PLUG.switchDp == '1') then return METERING['4-6'] end
	return nil
end

local function EnsureVariables()
	if (PLUG.vars) then return end
	PLUG.vars = true
	pcall(function()
		C4:AddVariable('POWER_W', '0', 'NUMBER', true, false)
		C4:AddVariable('VOLTAGE_V', '0', 'NUMBER', true, false)
		C4:AddVariable('CURRENT_MA', '0', 'NUMBER', true, false)
	end)
end

local function SetReading(property, variable, value)
	UpdateDriverProperty(property, value)
	pcall(function() C4:SetVariable(variable, tostring(value)) end)
end

local function TellState()
	local level = PLUG.on and 100 or 0
	if (PLUG.told ~= level) then
		PLUG.told = level
		Notify('LIGHT_BRIGHTNESS_CHANGED', { LIGHT_BRIGHTNESS_CURRENT = level })
	end
end

function OnDpsChanged(changed)
	if (DPS[PLUG.switchDp] ~= nil) then
		PLUG.on = DPS[PLUG.switchDp] == true
	end
	local m = ResolveMetering()
	PLUG.metering = m
	if (m) then
		EnsureVariables()
		if (tonumber(changed[m.power])) then
			SetReading('Power (W)', 'POWER_W', tonumber(changed[m.power]) / 10)
		end
		if (tonumber(changed[m.voltage])) then
			SetReading('Voltage (V)', 'VOLTAGE_V', tonumber(changed[m.voltage]) / 10)
		end
		if (tonumber(changed[m.current])) then
			SetReading('Current (mA)', 'CURRENT_MA', tonumber(changed[m.current]))
		end
	end
	TellState()
end

function OnDeviceOnline(online)
	if (online) then
		PLUG.told = nil
	end
end

-- Metering plugs only report readings when asked or when they change a lot.
function RefreshExtras(conn)
	local m = PLUG.metering
	if (m) then
		SendUpdateDps({ tonumber(m.current), tonumber(m.power), tonumber(m.voltage) })
	end
end

function LightOn()
	PLUG.on = true
	SendDps({ [PLUG.switchDp] = true })
	TellState()
end

function LightOff()
	PLUG.on = false
	SendDps({ [PLUG.switchDp] = false })
	TellState()
end

function LightToggle()
	if (PLUG.on) then LightOff() else LightOn() end
end

function LightSetLevel(level)
	if ((tonumber(level) or 0) > 0) then LightOn() else LightOff() end
end

function LightSetColor(x, y, mode)
end

function ApplyVariantProperty(name, value)
	if (name == 'Switch DP') then
		PLUG.switchDp = tostring(tonumber(value) or 1)
		PLUG.told = nil
		return true
	elseif (name == 'Power Metering') then
		PLUG.meteringSetting = value
		PLUG.metering = ResolveMetering()
		return true
	end
	return false
end

function GetLevel()
	return PLUG.on and 100 or 0
end

function IsOn()
	return PLUG.on
end
