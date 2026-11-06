--[[
	Config (shared, NON-RAHASIA)
	Modul ini ikut di-clone ke client admin. Jangan menaruh UserId admin, damage senjata,
	URL webhook, atau data sensitif lain di sini: itu ada di ServerData/ServerConfig.
]]

return table.freeze({
	Version = "1.0.0",
	LogPrefix = "[RuntimeInspector]",
	ToggleKey = Enum.KeyCode.F6,

	Scan = {
		FrameBudgetMs = 2, -- waktu CPU maks per frame untuk traversal besar
		MaxNodes = 250000, -- batas keras jumlah Instance per scan
		SearchLimit = 400,
	},

	Monitor = {
		QueueMax = 6000, -- antrean DescendantAdded sebelum diproses; lebih dari ini dibuang (dihitung)
		ProcessBudgetMs = 1.5,
		RingSize = 2500,
		MaxWatchedInstances = 1500, -- batas Instance yang dipasangi property watcher
		-- Kelas yang diberi perhatian khusus saat muncul selama gameplay
		WatchedClasses = {
			"Part", "MeshPart", "Model", "Attachment", "WeldConstraint", "Motor6D",
			"LinearVelocity", "VectorForce", "BodyVelocity", "BodyGyro", "BodyPosition",
			"AlignPosition", "ParticleEmitter", "Trail", "Beam", "Sound", "Highlight",
			"ProximityPrompt", "Tool", "Humanoid",
		},
		-- Properti yang dipantau via GetPropertyChangedSignal (berdasarkan IsA).
		-- Catatan: perubahan CFrame/Position akibat simulasi fisika TIDAK memicu sinyal ini.
		WatchedProperties = {
			BasePart = { "Size", "Anchored", "CanCollide", "Transparency", "Massless" },
			Humanoid = { "WalkSpeed", "JumpPower", "JumpHeight", "Health", "MaxHealth", "PlatformStand" },
			LinearVelocity = { "VectorVelocity", "MaxForce", "Enabled" },
			VectorForce = { "Force", "Enabled" },
			BodyVelocity = { "Velocity", "MaxForce" },
			BodyGyro = { "MaxTorque", "CFrame" },
			ParticleEmitter = { "Enabled", "Rate", "Texture" },
			Sound = { "SoundId", "Playing" },
			Highlight = { "Enabled", "Adornee" },
			ProximityPrompt = { "Enabled", "MaxActivationDistance", "HoldDuration" },
			Tool = { "Enabled" },
			Motor6D = { "Part0", "Part1", "Enabled" },
			WeldConstraint = { "Part0", "Part1", "Enabled" },
		},
		MonitorPlayerGuiOnClient = true,
	},

	Character = {
		SampleInterval = 0.1, -- sampling posisi HumanoidRootPart
		MoveDirectionThrottle = 0.15,
		RunningSpeedDelta = 1.5, -- Humanoid.Running dicatat bila perubahan speed > nilai ini
		CombatAttributes = { "Combo", "ComboIndex", "Stunned", "Stun", "Cooldown", "Attacking", "Blocking", "IFrames" },
		HitboxNamePatterns = { "hitbox" }, -- dicocokkan lowercase
		HitboxTag = "Hitbox",
		EffectClasses = { "ParticleEmitter", "Trail", "Beam", "Sound", "Highlight", "Explosion" },
		EffectRadius = 30,
		AttackInputs = { "MouseButton1", "E", "Q", "R", "F" }, -- nama KeyCode/UserInputType yang dianggap "attack"
		RingSize = 2000,
		Correlation = { Window = 0.6, PreWindow = 0.08, MaxChains = 60 },
	},

	Network = {
		RingSize = 2000,
		PassiveListen = true,
		-- Jeda sebelum listener pasif dipasang ke remote baru. Remote yang belum punya
		-- listener mengantrekan event; listener pertama akan menerima antrean itu.
		-- Jeda ini memberi kesempatan script game terhubung lebih dulu.
		PassiveAttachDelay = 2,
		MaxLoggedPerRemotePerSecond = 30,
		DefaultRateLimit = 25, -- panggilan/detik per remote sebelum dianggap anomali
		PerRemoteRateLimit = {}, -- [remoteName] = number
	},

	Scripts = {
		-- require() menjalankan ModuleScript bila belum pernah di-require. Itu bisa memicu
		-- efek samping. Karena itu probing default MATI dan butuh allowlist eksplisit.
		AllowRequireProbe = false,
		ProbeTimeout = 3,
		ProbeAllowlist = {}, -- daftar FullName, contoh "ReplicatedStorage.Modules.Util"
	},

	Anomaly = {
		Capacity = 600,
		DedupeWindow = 30,
		AllowedWalkSpeeds = { 16 },
		MaxWalkSpeed = 32,
		MaxJumpPower = 60,
		MaxJumpHeight = 12,
		TeleportDistance = 60,
		SuspiciousCharacterClasses = {
			"BodyVelocity", "BodyGyro", "BodyPosition", "BodyAngularVelocity", "BodyThrust",
			"LinearVelocity", "AngularVelocity", "VectorForce", "AlignPosition", "AlignOrientation",
		},
		AllowedMoverNames = {}, -- nama mover milik game sendiri, contoh { DashVelocity = true }
		MaxHitboxSize = Vector3.new(14, 14, 14),
		ProtectedAttributes = { "Stunned", "Cooldown", "Damage", "Level", "Coins" },
		ErrorBurstCount = 5,
		ErrorBurstWindow = 10,
		UnknownAssetSeverity = "MEDIUM",
	},

	Verify = {
		ReplicationBatch = 100,
		ReplicationInterval = 1,
		DivergenceInterval = 2,
		DivergenceProperties = { "WalkSpeed", "JumpPower", "JumpHeight", "MaxHealth" },
	},

	UI = {
		RefreshHz = 3,
		RowHeight = 22,
		DetailMaxChars = 16000,
		ExportPageChars = 20000,
	},
})
