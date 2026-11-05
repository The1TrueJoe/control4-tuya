-- Tuya cloud (IoT platform OpenAPI). Placeholder until the cloud client lands: the bridge
-- runs LAN-only meanwhile.

CLOUD = { ready = false }

function StartCloud() end
function StopCloud() end
function CloudRefreshDevices() end
function CloudCommand(deviceId, dps) return false end
function CloudWatch(deviceId, childId, on) end
