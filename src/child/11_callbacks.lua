-- DriverWorks callbacks invoked by Control4 Director.

function OnDriverInit(driverInitType)
	DRIVER_DESTROYING = false
	LATE_INIT_DONE = false
	DPS = {}
	math.randomseed(os.time())
	UpdateDriverProperty('Driver Version', DRIVER_VERSION)
end

function OnDriverLateInit(driverInitType)
	for name, _ in pairs(Properties or {}) do
		ApplyProperty(name)
	end
	LATE_INIT_DONE = true
	if (OnVariantInit) then OnVariantInit() end
	FindBridge()
	StartSession()
	BridgeHello()
	EvaluatePath()
	StartResourceReport()
end

function OnDriverDestroyed(driverInitType)
	DRIVER_DESTROYING = true
	LATE_INIT_DONE = false
	StopPolling()
	StopSession()
end

local function HandleCommand(strCommand, tParams)
	if (DRIVER_DESTROYING) then
		return
	end
	tParams = tParams or {}
	local command = Normalize(strCommand)
	if (command == 'LUA_ACTION') then
		command = Normalize(tParams.ACTION or tParams.action or '')
	end
	if (HandleBridgeCommand(command, tParams)) then
		return
	elseif (command == 'REFRESH_NOW') then
		RefreshNow()
	elseif (command == 'RECONNECT') then
		RestartSession()
	else
		DebugLog('Unhandled ExecuteCommand: ' .. tostring(strCommand))
	end
end

ExecuteCommand = Tracked(HandleCommand, 'command')
