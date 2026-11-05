-- Colour conversion between light_v2's CIE 1931 xy (plus a mode: 0 full colour, 1 colour
-- temperature) and Tuya's hue/saturation and white temperature.
--
-- Only hue and saturation come from xy: a Tuya colour also carries a value (brightness),
-- which the driver takes from the light's level instead, as light_v2 keeps them separate.

local function Gamma(c)
	if (c <= 0.0031308) then return 12.92 * c end
	return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

local function InverseGamma(c)
	if (c <= 0.04045) then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end

-- xy (Y = 1) -> sRGB in 0..1, scaled so the largest channel is 1.
function XyToRgb(x, y)
	if (y <= 0) then return 1, 1, 1 end
	local Y = 1
	local X = (Y / y) * x
	local Z = (Y / y) * (1 - x - y)
	local r = X * 3.2406 - Y * 1.5372 - Z * 0.4986
	local g = -X * 0.9689 + Y * 1.8758 + Z * 0.0415
	local b = X * 0.0557 - Y * 0.2040 + Z * 1.0570
	r, g, b = math.max(r, 0), math.max(g, 0), math.max(b, 0)
	local m = math.max(r, g, b)
	if (m <= 0) then return 1, 1, 1 end
	return Gamma(r / m), Gamma(g / m), Gamma(b / m)
end

function RgbToXy(r, g, b)
	r, g, b = InverseGamma(r), InverseGamma(g), InverseGamma(b)
	local X = r * 0.4124 + g * 0.3576 + b * 0.1805
	local Y = r * 0.2126 + g * 0.7152 + b * 0.0722
	local Z = r * 0.0193 + g * 0.1192 + b * 0.9505
	local sum = X + Y + Z
	if (sum <= 0) then return 0.3127, 0.3290 end
	return X / sum, Y / sum
end

-- h in degrees 0..360, s and v in 0..1.
function RgbToHsv(r, g, b)
	local maxc, minc = math.max(r, g, b), math.min(r, g, b)
	local d = maxc - minc
	local h = 0
	if (d > 0) then
		if (maxc == r) then
			h = 60 * (((g - b) / d) % 6)
		elseif (maxc == g) then
			h = 60 * ((b - r) / d + 2)
		else
			h = 60 * ((r - g) / d + 4)
		end
	end
	local s = (maxc > 0) and (d / maxc) or 0
	return h, s, maxc
end

function HsvToRgb(h, s, v)
	local c = v * s
	local hp = (h % 360) / 60
	local x = c * (1 - math.abs(hp % 2 - 1))
	local r, g, b = 0, 0, 0
	if (hp < 1) then r, g, b = c, x, 0
	elseif (hp < 2) then r, g, b = x, c, 0
	elseif (hp < 3) then r, g, b = 0, c, x
	elseif (hp < 4) then r, g, b = 0, x, c
	elseif (hp < 5) then r, g, b = x, 0, c
	else r, g, b = c, 0, x end
	local m = v - c
	return r + m, g + m, b + m
end

function XyToHs(x, y)
	local h, s = RgbToHsv(XyToRgb(x, y))
	return h, s
end

function HsToXy(h, s)
	return RgbToXy(HsvToRgb(h, s, 1))
end

-- McCamy's approximation, good to a few kelvin along the Planckian locus.
function XyToKelvin(x, y)
	local n = (x - 0.3320) / (0.1858 - y)
	return 449 * n ^ 3 + 3525 * n ^ 2 + 6823.3 * n + 5520.33
end

-- Kim et al.'s cubic fit of the Planckian locus, 1667 K to 25000 K.
function KelvinToXy(k)
	k = Clamp(k, 1667, 25000)
	local x
	if (k <= 4000) then
		x = -0.2661239e9 / k ^ 3 - 0.2343589e6 / k ^ 2 + 0.8776956e3 / k + 0.179910
	else
		x = -3.0258469e9 / k ^ 3 + 2.1070379e6 / k ^ 2 + 0.2226347e3 / k + 0.240390
	end
	local y
	if (k <= 2222) then
		y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
	elseif (k <= 4000) then
		y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
	else
		y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483
	end
	return x, y
end
