--[[
	AssetPolicy (SERVER-ONLY)
	Sensitive        : aset yang TIDAK boleh terlihat client (misal animasi/skin belum rilis).
	                   Ditemukan di container replikasi => temuan HIGH.
	RuntimeAllowlist : aset yang sah muncul saat gameplay walau tidak ada di baseline.
	                   Daftar ini dikirim ke dashboard admin (tidak rahasia).
	Key adalah ID numerik dalam bentuk string.
]]

return {
	Sensitive = {
		-- ["1234567890"] = "Animasi boss belum rilis",
	},
	RuntimeAllowlist = {
		-- ["507766388"] = true,
	},
}
