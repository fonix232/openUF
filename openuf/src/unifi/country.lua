--[[
	country.lua -- ISO 3166-1 country codes both ways: the controller speaks
	numeric codes, OpenWrt's `country` option alpha-2 ones.
]]--

local M = {}

-- ISO 3166-1 alpha-2 -> numeric, for the payload's country_code field. The
-- wifi-device's UCI `country` option (the regdomain OpenWrt programs) is the
-- source; best-effort coverage of common regulatory domains -- an unlisted
-- code falls back to 840 (US), the old hardcoded value, rather than sending
-- nothing.
M.NUMERIC = {
	US = 840, CA = 124, MX = 484, BR = 76, AU = 36, NZ = 554, JP = 392,
	CN = 156, KR = 410, IN = 356, GB = 826, IE = 372, DE = 276, FR = 250,
	NL = 528, BE = 56, LU = 442, AT = 40, CH = 756, IT = 380, ES = 724,
	PT = 620, DK = 208, SE = 752, NO = 578, FI = 246, IS = 352, PL = 616,
	CZ = 203, SK = 703, HU = 348, SI = 705, HR = 191, RO = 642, BG = 100,
	GR = 300, EE = 233, LV = 428, LT = 440, UA = 804, TR = 792, ZA = 710,
	SG = 702, TW = 158, HK = 344, TH = 764, MY = 458, ID = 360, PH = 608,
	VN = 704, IL = 376, AE = 784, SA = 682, AR = 32, CL = 152, CO = 170,
}

-- The same map inverted, for the inbound direction: the controller pushes its
-- site's regulatory domain as a NUMERIC code (system_cfg's
-- radio.<n>.countrycode), while UCI's `country` option wants the alpha-2 one.
-- Built from the table above so the two directions can never disagree.
M.ALPHA = {}
for alpha, numeric in pairs(M.NUMERIC) do M.ALPHA[numeric] = alpha end

return M
