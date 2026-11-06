--[[
	ServerConfig (SERVER-ONLY, ServerStorage)
	Tidak pernah direplikasi ke client. Simpan di sini semua hal yang tidak boleh
	diketahui client: daftar admin, ambang deteksi server, nama honeypot, endpoint ekspor.
]]

return {
	-- Inspector hanya aktif di Studio secara default.
	EnableInLiveGame = false,
	AllowAllInStudio = true, -- di Studio (Play Solo / Start Server) semua pemain uji = admin
	AdminUserIds = {
		-- [123456789] = true,
	},

	Bridge = {
		RequestsPerSecond = 40,
		Burst = 80,
		MaxPageSize = 300,
		StreamInterval = 0.5, -- detik antar batch log ke dashboard
		StreamMaxBatch = 120,
	},

	Security = {
		-- "log": hanya mencatat. "kick": kick setelah ambang strike (DIABAIKAN di Studio).
		Enforcement = "log",
		KickStrikeThreshold = 30,
		StrikeDecaySeconds = 60,
		Weights = { LOW = 1, MEDIUM = 3, HIGH = 6, CRITICAL = 15 },
	},

	Remotes = {
		DefaultMaxPayloadBytes = 4096,
		ReplayWindowSeconds = 6,
		MaxSeqJump = 5000,
	},

	Movement = {
		Enabled = true,
		SampleInterval = 0.25,
		SpeedTolerance = 1.4, -- pengali WalkSpeed server
		FlatBuffer = 6, -- studs tambahan per sampel (latensi, slope)
		VerticalBuffer = 8,
		TeleportDistance = 60,
		SpawnGrace = 3,
		ViolationsForHigh = 5,
		ViolationWindow = 10,
		Action = "log", -- "log" | "rubberband"
	},

	Combat = {
		RemoteName = "CombatRequest",
		RemoteFolderName = "GameRemotes", -- dibuat di ReplicatedStorage bila belum ada
		GlobalMaxDamage = 100,
		MaxAimAngleDeg = 80,
		RangeTolerance = 2.5,
		RequireLineOfSight = true,
		RateLimit = { perSecond = 8, burst = 12 },
	},

	Honeypot = {
		Enabled = true,
		-- Nama dibuat server saat runtime; tidak muncul di kode client mana pun.
		EventNames = { "AdminGiveCurrency", "SetPlayerStats" },
		FunctionNames = { "GetAdminPanelData" },
		FolderName = "GameRemotes",
	},

	Scripts = {
		AllowRequireProbe = false,
		ProbeAllowlist = {},
	},

	Export = {
		-- Ekspor HTTP opsional ke endpoint milik Anda sendiri (Game Settings > Security >
		-- Allow HTTP Requests harus aktif). Token disimpan di Secrets Store (HttpService:GetSecret).
		HttpEnabled = false,
		Url = "",
		SecretName = "", -- nama secret di Creator Hub (opsional)
		ChunkChars = 60000,
	},
}
