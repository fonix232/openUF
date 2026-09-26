--[[
	AES-128-CBC and AES-128-GCM wrappers over lua-openssl (a package
	dependency), in-process.

	All keys and IVs are passed as 32-char hex strings (16 raw bytes).
	Plaintext and ciphertext are Lua binary strings.
]]--

local ossl = require("openssl")

local M = {}

M.DEFAULT_KEY = "ba86f2bbe107c7c57eb5f2690775c712"

-- Injectable for tests: override to return deterministic IVs
M._random_bytes = nil

-- Convert 32-char hex string → 16-byte binary string
function M.hex_to_bin(hex)
	return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Convert binary string → hex string
function M.bin_to_hex(bin)
	return (bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Generate a random binary string of `len` bytes (default 16)
function M.random_iv(len)
	len = len or 16
	if M._random_bytes then
		return M._random_bytes(len)
	end
	return ossl.random(len)
end

-- PKCS#7 pad to block boundary
local function pkcs7_pad(data, blocksize)
	blocksize = blocksize or 16
	local pad = blocksize - (#data % blocksize)
	return data .. string.rep(string.char(pad), pad)
end

-- Strip PKCS#7 padding; raises error on invalid padding
local function pkcs7_unpad(data)
	if #data == 0 then error("pkcs7_unpad: empty input") end
	local pad = string.byte(data, #data)
	if pad < 1 or pad > 16 then
		error("pkcs7_unpad: invalid padding byte " .. tostring(pad))
	end
	for i = #data - pad + 1, #data do
		if string.byte(data, i) ~= pad then
			error("pkcs7_unpad: padding mismatch at byte " .. i)
		end
	end
	return data:sub(1, #data - pad)
end

-- AES-128-CBC encrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string (from M.random_iv())
-- plaintext: binary string
-- returns: ciphertext binary string (PKCS#7 padded)
function M.aes_cbc_encrypt(key_hex, iv, plaintext)
	-- Pad ourselves (padding(false)) so the wire format matches the
	-- controller, which PKCS#7-pads then encrypts with no extra padding.
	local ctx = ossl.cipher.get("aes-128-cbc"):new(true, M.hex_to_bin(key_hex), iv)
	ctx:padding(false)
	return ctx:update(pkcs7_pad(plaintext, 16)) .. ctx:final()
end

-- AES-128-CBC decrypt
-- key_hex: 32-char hex string
-- iv: 16-byte binary string
-- ciphertext: binary string
-- returns: plaintext binary string (PKCS#7 stripped)
function M.aes_cbc_decrypt(key_hex, iv, ciphertext)
	local ctx = ossl.cipher.get("aes-128-cbc"):new(false, M.hex_to_bin(key_hex), iv)
	ctx:padding(false)
	return pkcs7_unpad(ctx:update(ciphertext) .. ctx:final())
end

-- AES-128-GCM encrypt
-- aad: optional binary string for authenticated additional data (the 40-byte
--      TNBU header per amd989/unifi-gateway; nil = no AAD)
-- Returns: ciphertext (binary string), auth_tag (16-byte binary string)
function M.aes_gcm_encrypt(key_hex, iv, plaintext, aad)
	-- The TNBU IV field is 16 bytes; OpenSSL GCM defaults to a 12-byte
	-- nonce, so SET_IVLEN must precede init to accept the full IV.
	local C   = ossl.cipher
	local ctx = C.get("aes-128-gcm"):encrypt_new()
	ctx:ctrl(C.EVP_CTRL_GCM_SET_IVLEN, #iv)
	ctx:init(M.hex_to_bin(key_hex), iv)
	ctx:padding(false)
	if aad and #aad > 0 then ctx:update(aad, true) end  -- true = AAD, not plaintext
	local ct  = ctx:update(plaintext) .. ctx:final()
	local tag = ctx:ctrl(C.EVP_CTRL_GCM_GET_TAG, 16)
	return ct, tag
end

-- AES-128-GCM decrypt
-- aad: optional binary string for AAD verification (must match what was used to encrypt)
-- Raises an error if authentication tag verification fails
function M.aes_gcm_decrypt(key_hex, iv, ciphertext, tag, aad)
	local C   = ossl.cipher
	local ctx = C.get("aes-128-gcm"):decrypt_new()
	ctx:ctrl(C.EVP_CTRL_GCM_SET_IVLEN, #iv)
	ctx:init(M.hex_to_bin(key_hex), iv)
	ctx:padding(false)
	if aad and #aad > 0 then ctx:update(aad, true) end
	local pt = ctx:update(ciphertext)
	ctx:ctrl(C.EVP_CTRL_GCM_SET_TAG, tag)
	local final = ctx:final()  -- verifies the tag; falsy on mismatch
	if not final then error("aes_gcm_decrypt: authentication tag verification failed") end
	return pt .. final
end

return M
