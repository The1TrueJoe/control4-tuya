-- The bridge's DriverWorks callbacks: properties, commands, and messages from child drivers.
--
-- Children talk to the bridge with C4:SendToDevice, which arrives here as ExecuteCommand:
--   TUYA_HELLO      { CHILD, DEVICE_ID }   subscribe (DEVICE_ID may be empty: list only)
--   TUYA_CLOUD_SET  { CHILD, DEVICE_ID, DPS (JSON) }  control a device through the cloud
--   TUYA_CLOUD_WATCH { CHILD, DEVICE_ID, ON = 1|0 }   poll its state through the cloud
-- and the bridge answers on the child's ExecuteCommand: TUYA_LIST, TUYA_INFO, TUYA_STATUS.
-- Its own actions: REFRESH_NOW, FORGET_DEVICES, SMART_LIFE_LOGIN, SMART_LIFE_LOGOUT.

local function TellChildrenBridgeUp()
	for _, filename in ipairs(CHILD_FILENAMES) do
		local ok, devices = pcall(function() return C4:GetDevicesByC4iName(filename) end)
		if (ok and type(devices) == 'table') then
			for childId, _ in pairs(devices) do
				SendToChild(childId, 'TUYA_BRIDGE_UP', { BRIDGE = tostring(C4:GetDeviceID()) })
			end
		end
	end
end

function ApplyProperty(name)
	local value = (Properties and Properties[name]) or ''
	if (name == 'Debug Mode') then
		DEBUGPRINT = (value == 'On')
	elseif (name == 'Discovery') then
		DISCOVERY.enabled = (value ~= 'Off')
		return 'discovery'
	elseif (name == 'Cloud Account' or name == 'Cloud Region' or name == 'Cloud Access ID' or name == 'Cloud Access Secret') then
		return 'cloud'
	elseif (name == 'Cloud Poll Interval (seconds)' or name == 'Key Refresh (hours)') then
		return 'cloud'
	end
	return nil
end

function OnPropertyChanged(name)
	if (DRIVER_DESTROYING) then return end
	local what = ApplyProperty(name)
	if (not LATE_INIT_DONE) then return end
	if (what == 'discovery') then
		StartDiscovery()
	elseif (what == 'cloud') then
		StartCloud()
	end
end

function OnDriverInit()
	DRIVER_DESTROYING = false
	LATE_INIT_DONE = false
	UpdateDriverProperty('Driver Version', DRIVER_VERSION)
	math.randomseed(os.time())
end

-- Director's server callbacks are shared by discovery (UDP) and the login page (TCP).
OnServerConnectionStatusChanged = Tracked(function(nHandle, nPort, strStatus)
	LoginServerConnection(nHandle, nPort, strStatus)
end, 'server')

OnServerDataIn = Tracked(function(nHandle, strData, strClientAddress, strPort)
	if (IsLoginConnection(nHandle)) then
		LoginServerData(nHandle, strData)
	else
		DiscoveryDataIn(nHandle, strData, strClientAddress, strPort)
	end
end, 'server')

function OnServerStatusChanged(nPort, strStatus)
	DebugLog('server ' .. tostring(nPort) .. ': ' .. tostring(strStatus))
end

function OnDriverLateInit()
	for name, _ in pairs(Properties or {}) do
		ApplyProperty(name)
	end
	LATE_INIT_DONE = true
	LoadRegistry()
	StartDiscovery()
	StartCloud()
	StartResourceReport()
	-- Children may have started first; tell them the bridge is here so they say hello.
	TellChildrenBridgeUp()
end

function OnDriverDestroyed()
	DRIVER_DESTROYING = true
	StopDiscovery()
	StopCloud()
end

local function HandleCommand(strCommand, tParams)
	tParams = tParams or {}
	local command = Normalize(strCommand)
	if (command == 'LUA_ACTION') then
		command = Normalize(tParams.ACTION or tParams.action or '')
	end
	if (command == 'TUYA_HELLO') then
		Subscribe(tParams.CHILD, tParams.DEVICE_ID)
	elseif (command == 'TUYA_CLOUD_SET') then
		local dps = JsonDecode(tParams.DPS or '')
		if (not (dps and CloudCommand(tParams.DEVICE_ID, dps))) then
			SendToChild(tParams.CHILD, 'TUYA_CLOUD_FAILED', { DEVICE_ID = tParams.DEVICE_ID })
		end
	elseif (command == 'TUYA_CLOUD_WATCH') then
		CloudWatch(tParams.DEVICE_ID, tParams.CHILD, tParams.ON == '1')
	elseif (command == 'REFRESH_NOW') then
		CloudRefreshDevices(true)
		TellChildrenBridgeUp()
	elseif (command == 'FORGET_DEVICES') then
		ForgetDevices()
	elseif (command == 'SMART_LIFE_LOGIN') then
		if (Properties['Cloud Account'] ~= 'Smart Life') then
			UpdateDriverProperty('Smart Life Login', 'Set Cloud Account to Smart Life first')
		else
			SmartLifeStartLogin()
		end
	elseif (command == 'SMART_LIFE_LOGOUT') then
		SmartLifeLogout()
	else
		DebugLog('Unhandled ExecuteCommand: ' .. tostring(strCommand))
	end
end

ExecuteCommand = Tracked(HandleCommand, 'command')
