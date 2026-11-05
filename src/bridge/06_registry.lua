-- The bridge's device registry: every Tuya device it knows, from LAN broadcasts and the
-- cloud, and which child drivers want to hear about which device.
--
-- A device record: id, ip, version, productKey (LAN); name, key, category, product, online
-- (cloud); seen (os.time of the last broadcast). Children are told only when a field they
-- use (ip, key, version, name) changes, so a steady network costs them nothing.

REGISTRY = {
	devices = {}, -- id -> record
	subscribers = {}, -- device id -> { [childId] = true }
	children = {}, -- childId -> true: every child that said hello (gets list updates)
}

local PERSIST_KEY = 'tuya_bridge_devices'
local saveTimer = nil

local function ChildFields(d)
	return {
		DEVICE_ID = d.id,
		IP = d.ip or '',
		KEY = d.key or '',
		VERSION = d.version or '',
		NAME = d.name or '',
		CATEGORY = d.category or '',
		CLOUD = (CLOUD and CLOUD.ready and d.key) and '1' or '0',
	}
end

local function Fingerprint(d)
	return table.concat({ d.ip or '', d.key or '', d.version or '', d.name or '' }, '|')
end

-- Director keeps PersistSetValue data with the project, so a reboot does not need the cloud
-- (or a wait for broadcasts) before children get their keys back.
local function SaveSoon()
	if (saveTimer) then return end
	saveTimer = SetTimer(5000, function()
		saveTimer = nil
		local list = {}
		for id, d in pairs(REGISTRY.devices) do
			list[#list + 1] = { id = id, ip = d.ip, key = d.key, version = d.version, name = d.name,
				category = d.category, product = d.product, productKey = d.productKey }
		end
		pcall(function() C4:PersistSetValue(PERSIST_KEY, list) end)
	end)
end

function LoadRegistry()
	local ok, list = pcall(function() return C4:PersistGetValue(PERSIST_KEY) end)
	if (ok and type(list) == 'table') then
		for _, d in ipairs(list) do
			if (d.id) then
				d.told = Fingerprint(d)
				REGISTRY.devices[d.id] = d
			end
		end
	end
	UpdateDeviceSummary()
end

function SendToChild(childId, command, params)
	pcall(function() C4:SendToDevice(tonumber(childId), command, params or {}) end)
end

-- Merges what one source knows about a device and tells its subscribers if it mattered.
function UpdateDevice(id, fields)
	if (not id or id == '') then return end
	local d = REGISTRY.devices[id]
	local isNew = (d == nil)
	if (isNew) then
		d = { id = id }
		REGISTRY.devices[id] = d
	end
	for k, v in pairs(fields) do
		if (v ~= nil and v ~= '') then d[k] = v end
	end
	local fp = Fingerprint(d)
	if (fp ~= d.told) then
		d.told = fp
		SaveSoon()
		for childId, _ in pairs(REGISTRY.subscribers[id] or {}) do
			SendToChild(childId, 'TUYA_INFO', ChildFields(d))
		end
	end
	if (isNew or fields.name) then
		ListChanged()
	end
end

-- Children show the device list in a dropdown; rebuilding it is cheap but telling every child
-- is not, so changes are batched for a few seconds.
local listTimer = nil
function ListChanged()
	UpdateDeviceSummary()
	if (listTimer) then return end
	listTimer = SetTimer(3000, function()
		listTimer = nil
		local items = DeviceListItems()
		for childId, _ in pairs(REGISTRY.children) do
			SendToChild(childId, 'TUYA_LIST', { ITEMS = items })
		end
	end)
end

-- "Name (id)" sorted by name; children parse the id back out of the parentheses.
function DeviceListItems()
	local rows = {}
	for id, d in pairs(REGISTRY.devices) do
		local name = string.gsub(d.name or d.product or 'Tuya device', '[,()]', ' ')
		rows[#rows + 1] = Trim(name) .. ' (' .. id .. ')'
	end
	table.sort(rows)
	return table.concat(rows, ',')
end

function UpdateDeviceSummary()
	local total, lan, keys = 0, 0, 0
	for _, d in pairs(REGISTRY.devices) do
		total = total + 1
		if (d.seen) then lan = lan + 1 end
		if (d.key) then keys = keys + 1 end
	end
	UpdateDriverProperty('Devices', string.format('%d known: %d seen on this LAN, %d with a local key', total, lan, keys))
end

function Subscribe(childId, deviceId)
	childId = tostring(childId)
	REGISTRY.children[childId] = true
	-- A child follows one device: drop it from whatever it followed before.
	for _, subs in pairs(REGISTRY.subscribers) do
		subs[childId] = nil
	end
	SendToChild(childId, 'TUYA_LIST', { ITEMS = DeviceListItems() })
	if (deviceId and deviceId ~= '') then
		REGISTRY.subscribers[deviceId] = REGISTRY.subscribers[deviceId] or {}
		REGISTRY.subscribers[deviceId][childId] = true
		local d = REGISTRY.devices[deviceId]
		if (d) then
			SendToChild(childId, 'TUYA_INFO', ChildFields(d))
		end
	end
end

function ForgetDevices()
	REGISTRY.devices = {}
	pcall(function() C4:PersistSetValue(PERSIST_KEY, {}) end)
	ListChanged()
end
