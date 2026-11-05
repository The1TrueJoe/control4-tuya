-- AES-128-ECB and HMAC-SHA256 through Director's crypto API.
--
-- Padding is always done here (Pkcs7Pad/Pkcs7Unpad) and Director is told not to pad, so the
-- bytes on the wire do not depend on how a given OS release interprets `padding`.

local RAW = { return_encoding = 'NONE', key_encoding = 'NONE', iv_encoding = 'NONE', data_encoding = 'NONE', padding = false }
-- ECB has no IV, and Director refuses one ("The specified iv was too long").
local NO_IV = ''

function AesEncrypt(key, data)
	local out, err = C4:Encrypt('AES-128-ECB', key, NO_IV, data, RAW)
	if (not out) then
		error('AES encrypt failed: ' .. tostring(err))
	end
	return out
end

function AesDecrypt(key, data)
	local out, err = C4:Decrypt('AES-128-ECB', key, NO_IV, data, RAW)
	if (not out) then
		return nil, 'AES decrypt failed: ' .. tostring(err)
	end
	return out
end

local HMAC_OPTS = { return_encoding = 'NONE', key_encoding = 'NONE', data_encoding = 'NONE' }

function HmacSha256(key, data)
	local out = C4:HMAC('SHA256', key, data, HMAC_OPTS)
	if (not out or #out ~= 32) then
		error('HMAC-SHA256 unavailable on this controller')
	end
	return out
end

local HASH_OPTS = { return_encoding = 'NONE', data_encoding = 'NONE' }

function Sha256Hex(data)
	local out = C4:Hash('SHA256', data or '', HASH_OPTS)
	if (not out or #out ~= 32) then
		error('SHA-256 unavailable on this controller')
	end
	return ToHex(out)
end
