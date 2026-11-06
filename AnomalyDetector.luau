--[[
	AnomalyDetector
	Aturan deteksi yang dipasang ke sinyal modul lain. Setiap temuan memiliki:
	severity (LOW/MEDIUM/HIGH/CRITICAL), objek, waktu, detail, alasan, rekomendasi.

	PENTING soal kepercayaan data:
	- Temuan dari environment "server" berasal dari state yang dikendalikan server.
	- Temuan dari environment "client" adalah INDIKATOR untuk pengujian di Studio.
	  Di game live, client bisa dimodifikasi, jadi deteksi client tidak boleh menjadi
	  dasar hukuman. Penegakan ada di Security/* pada ServerScriptService.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = script.Parent.Parent
local Maid = require(Shared.Util.Maid)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()
local ENV = IS_SERVER and "server" or "client"

local AnomalyDetector = {}
AnomalyDetector.__index = AnomalyDetector

function AnomalyDetector.new(config: any, findings: any)
	local cfg = config.Anomaly
	local suspicious = {}
	for _, c in cfg.SuspiciousCharacterClasses do
		suspicious[c] = true
	end
	local protected = {}
	for _, n in cfg.ProtectedAttributes do
		protected[n] = true
	end
	return setmetatable({
		config = config,
		cfg = cfg,
		findings = findings,
		suspicious = suspicious,
		protected = protected,
		errorTimes = {},
		maid = Maid.new(),
	}, AnomalyDetector)
end

function AnomalyDetector:Report(f: { [string]: any })
	f.env = f.env or ENV
	if not IS_SERVER and f.source == nil then
		f.source = "client-observed (indikator, tidak otoritatif)"
	end
	return self.findings:Report(f)
end

local function characterOwner(inst: Instance): Player?
	local model = inst:FindFirstAncestorOfClass("Model")
	while model do
		local p = Players:GetPlayerFromCharacter(model)
		if p then
			return p
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

---------------------------------------------------------------- aturan

function AnomalyDetector:OnInstanceAdded(inst: Instance)
	if self.suspicious[inst.ClassName] then
		local owner = characterOwner(inst)
		if owner and not self.cfg.AllowedMoverNames[inst.Name] then
			self:Report({
				severity = "MEDIUM",
				rule = "runtime.mover_in_character",
				object = inst.Name,
				path = Serializer.SafeFullName(inst),
				player = owner.Name,
				detail = inst.ClassName .. " muncul di karakter " .. owner.Name,
				reason = "Mover fisika di karakter sering dipakai untuk speed/fly/dash. Bila bukan bagian sistem game, ini mencurigakan.",
				recommendation = "Daftarkan nama mover milik game di Config.Anomaly.AllowedMoverNames. Validasi pergerakan di server (MovementValidator), jangan percaya mover client.",
			})
		end
	end
end

function AnomalyDetector:OnHumanoidProperty(player: Player, humanoid: Humanoid, prop: string, old: any, new: any)
	local cfg = self.cfg
	if prop == "WalkSpeed" then
		local allowed = table.find(cfg.AllowedWalkSpeeds, new) ~= nil
		if not allowed then
			local severity = (type(new) == "number" and new > cfg.MaxWalkSpeed) and "HIGH" or "MEDIUM"
			self:Report({
				severity = severity,
				rule = "movement.walkspeed_change",
				object = humanoid.Name,
				path = Serializer.SafeFullName(humanoid),
				player = player.Name,
				detail = string.format("WalkSpeed %s -> %s (diizinkan: %s, maks %s)", tostring(old), tostring(new), table.concat(cfg.AllowedWalkSpeeds, "/"), tostring(cfg.MaxWalkSpeed)),
				reason = IS_SERVER and "Nilai WalkSpeed di server berubah ke nilai di luar daftar yang diharapkan."
					or "WalkSpeed client berubah ke nilai tak terduga. Perubahan WalkSpeed di client TIDAK direplikasi ke server, tetapi pergerakan yang dihasilkannya direplikasi. Exploiter nyata dapat mengubah properti tanpa memicu event lokal, jadi deteksi ini hanya berguna untuk pengujian.",
				recommendation = "Tetapkan WalkSpeed hanya dari server; tambahkan nilai sah ke AllowedWalkSpeeds; andalkan MovementValidator (validasi delta posisi), bukan nilai properti.",
			})
		end
	elseif prop == "JumpPower" or prop == "JumpHeight" then
		local max = prop == "JumpPower" and cfg.MaxJumpPower or cfg.MaxJumpHeight
		if type(new) == "number" and new > max then
			self:Report({
				severity = "HIGH",
				rule = "movement." .. string.lower(prop) .. "_exceeds",
				object = humanoid.Name,
				path = Serializer.SafeFullName(humanoid),
				player = player.Name,
				detail = string.format("%s %s -> %s (maks %s)", prop, tostring(old), tostring(new), tostring(max)),
				reason = prop .. " melebihi batas konfigurasi.",
				recommendation = "Set nilai lompatan dari server dan validasi kenaikan vertikal di MovementValidator.",
			})
		end
	end
end

function AnomalyDetector:OnTeleport(player: Player, from: Vector3, to: Vector3, distance: number, dt: number)
	self:Report({
		severity = IS_SERVER and "HIGH" or "MEDIUM",
		rule = "movement.position_jump",
		object = player.Name,
		path = "Players." .. player.Name,
		player = player.Name,
		detail = string.format("Posisi melompat %.1f studs dalam %.2fs dari %s ke %s", distance, dt, tostring(from), tostring(to)),
		reason = "Perpindahan posisi tidak dapat dijelaskan oleh velocity HumanoidRootPart.",
		recommendation = "Bila teleport sah dilakukan oleh game, panggil MovementValidator.AllowTeleport(player, detik) sebelum memindahkan karakter.",
	})
end

function AnomalyDetector:OnToolActivated(player: Player, tool: Tool, cooldownInfo: string?)
	if cooldownInfo then
		self:Report({
			severity = "LOW",
			rule = "combat.tool_during_cooldown",
			object = tool.Name,
			path = Serializer.SafeFullName(tool),
			player = player.Name,
			detail = "Tool.Activated saat " .. cooldownInfo,
			reason = "Tool diaktifkan ketika atribut cooldown/stun masih aktif. Bisa wajar (input pemain), bisa juga upaya bypass cooldown.",
			recommendation = "Pastikan cooldown divalidasi di server (CombatAuthority). Client hanya boleh menampilkan cooldown.",
		})
	end
end

function AnomalyDetector:OnHitbox(part: BasePart, size: Vector3, nearest: string?, distance: number)
	local max = self.cfg.MaxHitboxSize
	if size.X > max.X or size.Y > max.Y or size.Z > max.Z then
		self:Report({
			severity = "HIGH",
			rule = "combat.hitbox_oversize",
			object = part.Name,
			path = Serializer.SafeFullName(part),
			player = nearest,
			detail = string.format("Ukuran hitbox (%.1f, %.1f, %.1f) melebihi batas (%.1f, %.1f, %.1f)", size.X, size.Y, size.Z, max.X, max.Y, max.Z),
			reason = "Hitbox berukuran tidak wajar memperluas jangkauan serangan.",
			recommendation = "Gunakan ukuran hitbox dari definisi senjata di server; jangan terima ukuran dari client.",
		})
	end
end

function AnomalyDetector:OnRemoteRate(info: any, count: number, limit: number, playerName: string?)
	self:Report({
		severity = count > limit * 3 and "HIGH" or "MEDIUM",
		rule = "network.rate_exceeded",
		object = info.name,
		path = info.path .. (playerName and ("#" .. playerName) or ""),
		player = playerName,
		detail = string.format("%s dipanggil > %d kali/detik", info.name, limit),
		reason = "Frekuensi panggilan remote melebihi batas wajar. Bisa spam/exploit atau bug loop di script.",
		recommendation = "Terapkan rate limit server (SecureRemote) dan atur batas di Config.Network.PerRemoteRateLimit.",
	})
end

function AnomalyDetector:OnInvalidPayload(entry: any)
	self:Report({
		severity = IS_SERVER and "MEDIUM" or "LOW",
		rule = "network.invalid_payload",
		object = entry.remote,
		path = entry.path,
		player = entry.player,
		detail = table.concat(entry.issues, "; "),
		reason = "Payload berisi nilai yang tidak valid atau tidak dapat dikirim utuh (NaN/inf, tabel campuran, fungsi, metatable).",
		recommendation = "Validasi tipe & rentang di server sebelum memakai argumen (Schema). Tolak NaN/inf secara eksplisit.",
	})
end

function AnomalyDetector:OnSchemaMismatch(entry: any, err: string)
	self:Report({
		severity = IS_SERVER and "HIGH" or "MEDIUM",
		rule = "network.schema_mismatch",
		object = entry.remote,
		path = entry.path,
		player = entry.player,
		detail = err,
		reason = "Argumen remote tidak sesuai skema yang didaftarkan.",
		recommendation = "Tolak panggilan yang gagal validasi di server dan catat pelakunya.",
	})
end

function AnomalyDetector:OnScriptError(e: any)
	if e.kind == "warning" then
		return
	end
	local now = os.clock()
	table.insert(self.errorTimes, now)
	while #self.errorTimes > 0 and now - self.errorTimes[1] > self.cfg.ErrorBurstWindow do
		table.remove(self.errorTimes, 1)
	end
	local burst = #self.errorTimes >= self.cfg.ErrorBurstCount
	self:Report({
		severity = burst and "MEDIUM" or "LOW",
		rule = "script.error",
		object = e.script or "?",
		path = (e.script or "?") .. "|" .. string.sub(e.message, 1, 60),
		detail = e.message,
		reason = burst and "Banyak error dalam waktu singkat." or "Script menghasilkan error.",
		recommendation = "Periksa stack trace. Error di handler remote bisa dipicu input client yang tidak divalidasi.",
	})
end

function AnomalyDetector:OnUnknownAsset(rec: any, inst: Instance)
	self:Report({
		severity = self.cfg.UnknownAssetSeverity,
		rule = "asset.unknown_runtime",
		object = rec.key,
		path = Serializer.SafeFullName(inst),
		detail = "Aset " .. rec.key .. " muncul saat gameplay di " .. inst.ClassName,
		reason = "Aset tidak ada di baseline scan maupun RuntimeAllowlist.",
		recommendation = "Bila aset ini sah, tambahkan ke AssetPolicy.RuntimeAllowlist. Bila tidak, telusuri script yang membuat Instance tersebut.",
	})
end

function AnomalyDetector:OnAttributeChanged(player: Player?, inst: Instance, name: string, old: any, new: any)
	if not self.protected[name] then
		return
	end
	self:Report({
		severity = "LOW",
		rule = "attribute.protected_changed",
		object = inst.Name .. "." .. name,
		path = Serializer.SafeFullName(inst) .. "@" .. name,
		player = player and player.Name or nil,
		detail = string.format("%s: %s -> %s", name, tostring(old), tostring(new)),
		reason = IS_SERVER and "Atribut terlindungi berubah di server (pastikan berasal dari sistem game)."
			or "Atribut terlindungi berubah di client. Bisa berupa replikasi dari server; DivergenceCheck akan menaikkan severity bila nilai client berbeda dari server.",
		recommendation = "Ubah atribut terlindungi hanya dari server. Atribut yang diubah client tidak direplikasi ke server, jadi server tidak boleh membaca state dari client.",
	})
end

-- Dipanggil client setelah membandingkan nilai lokal dengan nilai server.
function AnomalyDetector:OnDivergence(path: string, name: string, clientValue: any, serverValue: any)
	self:Report({
		severity = "HIGH",
		rule = "verify.client_server_divergence",
		object = name,
		path = path .. "@" .. name,
		detail = string.format("Client=%s, Server=%s", tostring(clientValue), tostring(serverValue)),
		reason = "Nilai di client berbeda dari server secara konsisten (bukan sekadar latensi replikasi). Indikasi modifikasi lokal.",
		recommendation = "Jangan pernah membaca nilai ini dari client untuk keputusan gameplay. Gunakan nilai server.",
	})
end

---------------------------------------------------------------- wiring

-- modules = { monitor, profiler, network, scripts, assets }
function AnomalyDetector:Bind(modules: { [string]: any })
	local m = self.maid
	if modules.monitor then
		m:Give(modules.monitor.InstanceAdded:Connect(function(inst)
			self:OnInstanceAdded(inst)
		end))
	end
	if modules.profiler then
		local p = modules.profiler
		m:Give(p.HumanoidPropertyChanged:Connect(function(...)
			self:OnHumanoidProperty(...)
		end))
		m:Give(p.Teleported:Connect(function(...)
			self:OnTeleport(...)
		end))
		m:Give(p.ToolActivated:Connect(function(...)
			self:OnToolActivated(...)
		end))
		m:Give(p.HitboxSeen:Connect(function(...)
			self:OnHitbox(...)
		end))
		m:Give(p.AttributeChanged:Connect(function(...)
			self:OnAttributeChanged(...)
		end))
	end
	if modules.network then
		local n = modules.network
		m:Give(n.RateExceeded:Connect(function(...)
			self:OnRemoteRate(...)
		end))
		m:Give(n.InvalidPayload:Connect(function(...)
			self:OnInvalidPayload(...)
		end))
		m:Give(n.SchemaMismatch:Connect(function(...)
			self:OnSchemaMismatch(...)
		end))
	end
	if modules.scripts then
		m:Give(modules.scripts.ErrorAdded:Connect(function(e)
			self:OnScriptError(e)
		end))
	end
	if modules.assets then
		m:Give(modules.assets.UnknownAsset:Connect(function(...)
			self:OnUnknownAsset(...)
		end))
	end
end

function AnomalyDetector:Destroy()
	self.maid:Destroy()
end

return AnomalyDetector
