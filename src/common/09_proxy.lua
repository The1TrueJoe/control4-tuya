-- ReceivedFromProxy: light_v2 commands, translated into the variant's LightOn/LightOff/
-- LightSetLevel/LightSetColor. Brightness and colour rates are accepted and ignored (Tuya
-- has no LAN transition time).

local function Param(tParams, ...)
	for _, name in ipairs({ ... }) do
		if (tParams[name] ~= nil) then return tParams[name] end
	end
	return nil
end

local function ButtonAction(buttonId, action)
	if (tonumber(action) ~= BUTTON_ACTION_RELEASE_CLICK) then
		return
	end
	buttonId = tonumber(buttonId)
	if (buttonId == BUTTON_TOP) then
		LightOn()
	elseif (buttonId == BUTTON_BOTTOM) then
		LightOff()
	elseif (buttonId == BUTTON_TOGGLE) then
		LightToggle()
	end
end

local PROXY = {
	ON = function() LightOn() end,
	OFF = function() LightOff() end,
	TOGGLE = function() LightToggle() end,
	DYNAMIC_ON = function() LightOn() end,
	DYNAMIC_OFF = function() LightOff() end,
	SET_LEVEL = function(p) LightSetLevel(Param(p, 'LEVEL', 'LIGHT_BRIGHTNESS_TARGET')) end,
	RAMP_TO_LEVEL = function(p) LightSetLevel(Param(p, 'LEVEL', 'LIGHT_BRIGHTNESS_TARGET')) end,
	SET_BRIGHTNESS_TARGET = function(p) LightSetLevel(Param(p, 'LIGHT_BRIGHTNESS_TARGET', 'LEVEL')) end,
	SET_COLOR_TARGET = function(p)
		LightSetColor(Param(p, 'LIGHT_COLOR_TARGET_X'), Param(p, 'LIGHT_COLOR_TARGET_Y'),
			Param(p, 'LIGHT_COLOR_TARGET_MODE', 'LIGHT_COLOR_TARGET_COLOR_MODE'))
	end,
	GET_CONNECTED_STATE = function()
		Notify('ONLINE_CHANGED', { STATE = SessionReady() })
	end,
	GET_LIGHT_LEVEL = function()
		Notify('LIGHT_BRIGHTNESS_CHANGED', { LIGHT_BRIGHTNESS_CURRENT = GetLevel() })
	end,
	BUTTON_ACTION = function(p)
		ButtonAction(Param(p, 'BUTTON_ID'), Param(p, 'ACTION'))
		Notify('BUTTON_ACTION', { BUTTON_ID = Param(p, 'BUTTON_ID'), ACTION = Param(p, 'ACTION') })
	end,
}

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	DebugLog('proxy ' .. tostring(idBinding) .. ' ' .. tostring(strCommand))
	if (idBinding == PROXY_BINDING) then
		local handler = PROXY[strCommand]
		if (handler) then
			handler(tParams)
		end
		return
	end
	-- Keypad button links: DO_CLICK / DO_PUSH / DO_RELEASE on bindings 300-302.
	local buttonId = BUTTON_BINDINGS[idBinding]
	if (buttonId ~= nil and strCommand == 'DO_CLICK') then
		ButtonAction(buttonId, BUTTON_ACTION_RELEASE_CLICK)
	end
end
