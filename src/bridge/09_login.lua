-- The Smart Life login page: while a QR login is in progress the bridge serves one page on
-- http://<controller>:8765/ that draws the QR code (with the vendored qrcode-generator, QR_JS,
-- embedded by build.sh) for the Smart Life app to scan. Composer properties can't show an
-- image; any browser on the LAN can.
--
-- Director's servers share one callback pair: TCP connections to this port are tracked by
-- handle (OnServerConnectionStatusChanged), everything else arriving on OnServerDataIn is a
-- discovery broadcast. C4:DestroyServer takes every server down at once, so stopping the
-- page restarts discovery.

local LOGIN_PORT = 8765

LOGINPAGE = { handles = {}, qr = nil, listening = false }

local function ControllerAddress()
	for _, name in ipairs({ 'GetControllerNetworkAddress', 'GetMyNetworkAddress' }) do
		local ok, ip = pcall(function() return C4[name](C4) end)
		if (ok and type(ip) == 'string' and ip ~= '') then return ip end
	end
	return nil
end

-- Takes every Director server down (discovery's too) and brings back the ones still wanted.
function RestartServers()
	pcall(function() C4:DestroyServer() end)
	DISCOVERY.servers = {}
	LOGINPAGE.listening, LOGINPAGE.handles = false, {}
	if (DISCOVERY.enabled and LATE_INIT_DONE) then
		StartDiscovery()
	end
	if (LOGINPAGE.qr) then
		LOGINPAGE.listening = pcall(function() C4:CreateServer(LOGIN_PORT, '', false) end)
	end
end

-- Returns where to open the page.
function ShowLoginQr(text)
	LOGINPAGE.qr = text
	if (not LOGINPAGE.listening) then
		LOGINPAGE.listening = pcall(function() C4:CreateServer(LOGIN_PORT, '', false) end)
	end
	return 'http://' .. (ControllerAddress() or '<controller IP>') .. ':' .. LOGIN_PORT .. '/'
end

function HideLoginQr()
	local was = LOGINPAGE.listening
	LOGINPAGE.qr = nil
	if (was) then RestartServers() end
end

local function Escape(s)
	return (string.gsub(tostring(s), '[<>&"\'\\]', function(c) return string.format('\\u%04x', string.byte(c)) end))
end

local function Page()
	local body
	if (LOGINPAGE.qr) then
		body = '<p>Scan this with the <b>Smart Life</b> app (Me &rarr; scan icon, top right), then confirm.</p>' ..
			'<div id="qr"></div><p class="small">This page stops working once you are signed in or after 5 minutes.</p>' ..
			'<script>' .. (QR_JS or '') .. '\nvar q = qrcode(0, "M"); q.addData("' .. Escape(LOGINPAGE.qr) .. '"); q.make();' ..
			'document.getElementById("qr").innerHTML = q.createSvgTag({ cellSize: 6, margin: 4 });</script>'
	else
		body = '<p>No Smart Life login is in progress. Run <b>Smart Life Login</b> on the Tuya Bridge in Composer.</p>'
	end
	return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' ..
		'<title>Tuya Bridge login</title><style>body{font-family:sans-serif;margin:2em;max-width:32em}' ..
		'.small{color:#666;font-size:.9em}#qr svg{max-width:100%;height:auto}</style></head><body>' ..
		'<h2>Tuya Bridge: Smart Life login</h2>' .. body .. '</body></html>'
end

local function Respond(nHandle, status, contentType, body)
	local head = 'HTTP/1.1 ' .. status .. '\r\nContent-Type: ' .. contentType .. '\r\nContent-Length: ' .. #body ..
		'\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n'
	pcall(function() C4:ServerSend(nHandle, head .. body) end)
	pcall(function() C4:ServerCloseClient(nHandle) end)
	LOGINPAGE.handles[nHandle] = nil
end

-- True when the connection belongs to the login page.
function LoginServerConnection(nHandle, nPort, strStatus)
	if (tonumber(nPort) ~= LOGIN_PORT) then return false end
	if (strStatus == 'ONLINE') then
		LOGINPAGE.handles[nHandle] = ''
	else
		LOGINPAGE.handles[nHandle] = nil
	end
	return true
end

function IsLoginConnection(nHandle)
	return LOGINPAGE.handles[nHandle] ~= nil
end

function LoginServerData(nHandle, strData)
	local buf = (LOGINPAGE.handles[nHandle] or '') .. strData
	if (#buf > 8192) then
		Respond(nHandle, '413 Payload Too Large', 'text/plain', 'request too large')
		return
	end
	LOGINPAGE.handles[nHandle] = buf
	if (not string.find(buf, '\r\n\r\n', 1, true)) then return end
	local method, path = string.match(buf, '^(%u+) (%S+)')
	if (method == 'GET' and (path == '/' or path == '/index.html')) then
		Respond(nHandle, '200 OK', 'text/html; charset=utf-8', Page())
	else
		Respond(nHandle, '404 Not Found', 'text/plain', 'not found')
	end
end
