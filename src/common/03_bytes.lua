-- Byte-level helpers: big-endian integers, hex, XOR and CRC32.
--
-- Director's Lua is 5.1: there is no string.pack, and a bit library is not guaranteed, so
-- these use one when present and fall back to plain arithmetic otherwise.

local TWO32 = 4294967296

local BXOR
if (type(bit32) == 'table' and bit32.bxor) then
	BXOR = function(a, b) return bit32.bxor(a, b) % TWO32 end
elseif (type(bit) == 'table' and bit.bxor) then
	-- LuaBitOp returns signed 32-bit results.
	BXOR = function(a, b) return bit.bxor(a, b) % TWO32 end
else
	-- No bit library: XOR four bits at a time through a 16x16 table, 8 steps for 32 bits
	-- instead of 32. This runs for every CRC'd byte on 3.3 devices, so it matters.
	local NIBBLE = {}
	for x = 0, 15 do
		for y = 0, 15 do
			local r, p, a, b = 0, 1, x, y
			for _ = 1, 4 do
				if (a % 2 ~= b % 2) then r = r + p end
				a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
			end
			NIBBLE[x * 16 + y] = r
		end
	end
	BXOR = function(a, b)
		local result, place = 0, 1
		while (a > 0 or b > 0) do
			local x, y = a % 16, b % 16
			result = result + NIBBLE[x * 16 + y] * place
			a, b, place = (a - x) / 16, (b - y) / 16, place * 16
		end
		return result
	end
end
-- Which XOR Director gave us, for the Resource Use property.
BIT_LIBRARY = (type(bit32) == 'table' and 'bit32') or (type(bit) == 'table' and 'bit') or 'none (table XOR)'
Bxor = BXOR

function U32(n)
	n = n % TWO32
	return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

function ReadU32(s, i)
	local a, b, c, d = string.byte(s, i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

function ToHex(s)
	return (string.gsub(s, '.', function(c) return string.format('%02x', string.byte(c)) end))
end

function FromHex(h)
	return (string.gsub(h, '%x%x', function(x) return string.char(tonumber(x, 16)) end))
end

function XorStrings(a, b)
	local out = {}
	for i = 1, math.min(#a, #b) do
		out[i] = string.char(BXOR(string.byte(a, i), string.byte(b, i)))
	end
	return table.concat(out)
end

local CRC_TABLE
local function BuildCrcTable()
	CRC_TABLE = {}
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			if (c % 2 == 1) then
				c = BXOR(math.floor(c / 2), 0xEDB88320)
			else
				c = math.floor(c / 2)
			end
		end
		CRC_TABLE[i] = c
	end
end

function Crc32(s)
	if (not CRC_TABLE) then BuildCrcTable() end
	local crc = 0xFFFFFFFF
	for i = 1, #s do
		local index = BXOR(crc % 256, string.byte(s, i))
		crc = BXOR(math.floor(crc / 256), CRC_TABLE[index])
	end
	return BXOR(crc, 0xFFFFFFFF)
end

function Pkcs7Pad(s)
	local n = 16 - (#s % 16)
	return s .. string.rep(string.char(n), n)
end

-- Returns nil when the padding is not valid PKCS#7, which here means the key is wrong.
function Pkcs7Unpad(s)
	local n = string.byte(s, #s)
	if (not n or n < 1 or n > 16 or n > #s) then
		return nil
	end
	if (string.sub(s, -n) ~= string.rep(string.char(n), n)) then
		return nil
	end
	return string.sub(s, 1, #s - n)
end

function RandomBytes(n)
	local out = {}
	for i = 1, n do
		out[i] = string.char(math.random(0, 255))
	end
	return table.concat(out)
end
