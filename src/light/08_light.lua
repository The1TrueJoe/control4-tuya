-- Tuya bulbs and dimmers as a light_v2: datapoint profiles, level and colour mapping.
--
-- Two datapoint layouts cover nearly every Tuya light:
--   standard  20 switch, 21 mode, 22 brightness 10-1000, 23 temperature 0-1000,
--             24 colour "hhhhssssvvvv" (hue 0-360, sat/value 0-1000)
--   legacy    1 switch, 2 mode, 3 brightness 25-255, 4 temperature 0-255,
--             5 colour "rrggbbhhhhssvv" (sat/value 0-255)
-- "Auto" picks one from the first status report. Tuya has no transition time on the LAN,
-- so ramp rates from Control4 are accepted and changes are applied at once.

local PROFILES = {
	standard = {
		name = 'Standard (DP 20-24)',
		switch = '20', mode = '21', bright = '22', temp = '23', colour = '24',
		brightMin = 10, brightMax = 1000, tempMax = 1000, svMax = 1000, vMin = 10,
	},
	legacy = {
		name = 'Legacy (DP 1-5)',
		switch = '1', mode = '2', bright = '3', temp = '4', colour = '5',
		brightMin = 25, brightMax = 255, tempMax = 255, svMax = 255, vMin = 25,
	},
}

LIGHT = {
	profileSetting = 'Auto',
	profile = nil,
	typeSetting = 'Auto',
	kelvinMin = 2700,
	kelvinMax = 6500,
	on = false,
	level = 100, -- last lit level, 1..100
	mode = 'white', -- 'white' or 'colour'
	hue = 0, sat = 0, -- 0..360, 0..1
	kelvin = 4000,
	caps = nil,
	told = {}, -- what the proxy was last told, to send only changes
}

function KnownDps()
	local p = LIGHT.profile or PROFILES.standard
	return { tonumber(p.switch), tonumber(p.mode), tonumber(p.bright), tonumber(p.temp), tonumber(p.colour) }
end

local function ResolveProfile()
	if (LIGHT.profileSetting == PROFILES.standard.name) then
		return PROFILES.standard
	elseif (LIGHT.profileSetting == PROFILES.legacy.name) then
		return PROFILES.legacy
	end
	if (DPS['20'] ~= nil or DPS['22'] ~= nil) then
		return PROFILES.standard
	end
	if (DPS['1'] ~= nil) then
		return PROFILES.legacy
	end
	return nil
end

-- What the light can do: from the Light Type property, or from the datapoints it reports.
local function ResolveCaps(p)
	local t = LIGHT.typeSetting
	if (t == 'Color + Tunable White') then
		return { dimmer = true, color = true, cct = true }
	elseif (t == 'Color Only') then
		return { dimmer = true, color = true, cct = false }
	elseif (t == 'Tunable White') then
		return { dimmer = true, color = false, cct = true }
	elseif (t == 'Dimmable') then
		return { dimmer = true, color = false, cct = false }
	elseif (t == 'On/Off Only') then
		return { dimmer = false, color = false, cct = false }
	end
	if (not p) then
		return nil
	end
	return {
		dimmer = DPS[p.bright] ~= nil or DPS[p.colour] ~= nil,
		color = DPS[p.colour] ~= nil,
		cct = DPS[p.temp] ~= nil,
	}
end

local function TellCapabilities()
	local caps = LIGHT.caps
	if (not caps) then return end
	Notify('DYNAMIC_CAPABILITIES_CHANGED', {
		dimmer = caps.dimmer,
		set_level = caps.dimmer,
		supports_target = true,
		supports_color = caps.color,
		supports_color_correlated_temperature = caps.cct,
		color_correlated_temperature_min = LIGHT.kelvinMin,
		color_correlated_temperature_max = LIGHT.kelvinMax,
	})
end

-- Level 1..100 <-> a datapoint range, linear, with 1 at the device's minimum.
local function LevelToRange(level, lo, hi)
	return Round(lo + (Clamp(level, 1, 100) - 1) * (hi - lo) / 99)
end

local function RangeToLevel(value, lo, hi)
	if (hi <= lo) then return 100 end
	return Clamp(Round(1 + (value - lo) * 99 / (hi - lo)), 1, 100)
end

local function KelvinToTemp(p, k)
	local span = LIGHT.kelvinMax - LIGHT.kelvinMin
	if (span <= 0) then return 0 end
	return Round(Clamp((k - LIGHT.kelvinMin) / span, 0, 1) * p.tempMax)
end

local function TempToKelvin(p, t)
	return LIGHT.kelvinMin + (Clamp(t / p.tempMax, 0, 1)) * (LIGHT.kelvinMax - LIGHT.kelvinMin)
end

function EncodeColour(p, h, s, level)
	local v = LevelToRange(level, p.vMin, p.svMax)
	if (p == PROFILES.standard) then
		return string.format('%04x%04x%04x', Round(h) % 360, Round(s * 1000), v)
	end
	local r, g, b = HsvToRgb(h, s, v / 255)
	return string.format('%02x%02x%02x%04x%02x%02x', Round(r * 255), Round(g * 255), Round(b * 255),
		Round(h) % 360, Round(s * 255), v)
end

-- Returns h (degrees), s (0..1), level (1..100), or nil for a value it cannot read.
function DecodeColour(p, text)
	if (type(text) ~= 'string') then return nil end
	if (p == PROFILES.standard and #text == 12) then
		local h, s, v = tonumber(text:sub(1, 4), 16), tonumber(text:sub(5, 8), 16), tonumber(text:sub(9, 12), 16)
		if (not (h and s and v)) then return nil end
		return h, s / 1000, RangeToLevel(v, p.vMin, p.svMax)
	elseif (#text == 14) then
		local h, s, v = tonumber(text:sub(7, 10), 16), tonumber(text:sub(11, 12), 16), tonumber(text:sub(13, 14), 16)
		if (not (h and s and v)) then return nil end
		return h, s / 255, RangeToLevel(v, p.vMin, p.svMax)
	end
	return nil
end

local function CurrentXy()
	if (LIGHT.mode == 'colour') then
		local x, y = HsToXy(LIGHT.hue, LIGHT.sat)
		return x, y, 0
	end
	local x, y = KelvinToXy(LIGHT.kelvin)
	return x, y, 1
end

local function TellBrightness()
	local level = LIGHT.on and LIGHT.level or 0
	if (LIGHT.told.level ~= level) then
		LIGHT.told.level = level
		Notify('LIGHT_BRIGHTNESS_CHANGED', { LIGHT_BRIGHTNESS_CURRENT = level })
	end
end

local function TellColor(x, y, mode)
	if (not (LIGHT.caps and (LIGHT.caps.color or LIGHT.caps.cct))) then return end
	if (not x) then x, y, mode = CurrentXy() end
	local key = string.format('%.4f,%.4f,%d', x, y, mode)
	if (LIGHT.told.color ~= key) then
		LIGHT.told.color = key
		Notify('LIGHT_COLOR_CHANGED', {
			LIGHT_COLOR_CURRENT_X = x,
			LIGHT_COLOR_CURRENT_Y = y,
			LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
		})
	end
end

-- Device -> proxy.
function OnDpsChanged(changed)
	local p = ResolveProfile()
	if (p ~= LIGHT.profile) then
		LIGHT.profile = p
		UpdateDriverProperty('Detected Profile', p and p.name or 'Unknown')
	end
	if (not p) then return end
	local caps = ResolveCaps(p)
	if (caps and (not LIGHT.caps or caps.dimmer ~= LIGHT.caps.dimmer or caps.color ~= LIGHT.caps.color or caps.cct ~= LIGHT.caps.cct)) then
		LIGHT.caps = caps
		TellCapabilities()
	end

	if (DPS[p.switch] ~= nil) then
		LIGHT.on = DPS[p.switch] == true
	end
	local mode = DPS[p.mode]
	if (mode == 'colour') then
		LIGHT.mode = 'colour'
	elseif (mode == 'white') then
		LIGHT.mode = 'white'
	end

	if (LIGHT.mode == 'colour' and DPS[p.colour] ~= nil) then
		local h, s, level = DecodeColour(p, DPS[p.colour])
		if (h) then
			LIGHT.hue, LIGHT.sat, LIGHT.level = h, s, level
		end
	elseif (tonumber(DPS[p.bright])) then
		LIGHT.level = RangeToLevel(tonumber(DPS[p.bright]), p.brightMin, p.brightMax)
	end
	if (tonumber(DPS[p.temp])) then
		LIGHT.kelvin = TempToKelvin(p, tonumber(DPS[p.temp]))
	end
	if (not LIGHT.caps.dimmer) then
		LIGHT.level = 100
	end

	TellBrightness()
	TellColor()
end

function OnDeviceOnline(online)
	if (online) then
		-- A reconnect re-tells everything, in case Director restarted meanwhile.
		LIGHT.told = {}
	end
end

-- Proxy -> device.
local function Profile()
	return LIGHT.profile or PROFILES.standard
end

function LightOn()
	local p = Profile()
	LIGHT.on = true
	SendDps({ [p.switch] = true })
	TellBrightness()
end

function LightOff()
	local p = Profile()
	LIGHT.on = false
	SendDps({ [p.switch] = false })
	TellBrightness()
end

function LightToggle()
	if (LIGHT.on) then LightOff() else LightOn() end
end

function LightSetLevel(level)
	level = tonumber(level) or 0
	if (level <= 0) then
		LightOff()
		return
	end
	local p = Profile()
	level = Clamp(Round(level), 1, 100)
	local dps = { [p.switch] = true }
	if (LIGHT.caps == nil or LIGHT.caps.dimmer) then
		if (LIGHT.mode == 'colour') then
			dps[p.colour] = EncodeColour(p, LIGHT.hue, LIGHT.sat, level)
		else
			dps[p.bright] = LevelToRange(level, p.brightMin, p.brightMax)
		end
	end
	LIGHT.on, LIGHT.level = true, level
	SendDps(dps)
	TellBrightness()
end

function LightSetColor(x, y, mode)
	local p = Profile()
	x, y = tonumber(x), tonumber(y)
	if (not (x and y)) then return end
	local caps = LIGHT.caps or { color = true, cct = true }
	local wantWhite = (tonumber(mode) == 1 and caps.cct) or not caps.color
	local dps = { [p.switch] = true }
	if (wantWhite) then
		if (not caps.cct) then return end
		LIGHT.kelvin = Clamp(XyToKelvin(x, y), LIGHT.kelvinMin, LIGHT.kelvinMax)
		LIGHT.mode = 'white'
		dps[p.mode] = 'white'
		dps[p.temp] = KelvinToTemp(p, LIGHT.kelvin)
		mode = 1
	else
		LIGHT.hue, LIGHT.sat = XyToHs(x, y)
		LIGHT.mode = 'colour'
		dps[p.mode] = 'colour'
		dps[p.colour] = EncodeColour(p, LIGHT.hue, LIGHT.sat, LIGHT.level)
		mode = 0
	end
	LIGHT.on = true
	SendDps(dps)
	TellBrightness()
	-- Tell the colour that was asked for, so the colour wheel does not jump to the
	-- (slightly different) round trip through HSV.
	TellColor(x, y, mode)
end

-- Variant properties.
function ApplyVariantProperty(name, value)
	if (name == 'DP Profile') then
		LIGHT.profileSetting = value
		LIGHT.profile = ResolveProfile()
		return true
	elseif (name == 'Light Type') then
		LIGHT.typeSetting = value
		LIGHT.caps = ResolveCaps(LIGHT.profile)
		TellCapabilities()
		return true
	elseif (name == 'Color Temperature Min (K)') then
		LIGHT.kelvinMin = tonumber(value) or 2700
		TellCapabilities()
		return true
	elseif (name == 'Color Temperature Max (K)') then
		LIGHT.kelvinMax = tonumber(value) or 6500
		TellCapabilities()
		return true
	end
	return false
end

function GetLevel()
	return LIGHT.on and LIGHT.level or 0
end

function IsOn()
	return LIGHT.on
end
