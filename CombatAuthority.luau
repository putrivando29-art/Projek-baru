--[[
	CombatAuthority (server-authoritative combat)
	Client HANYA mengirim niat: ("Attack", aimDirection). Server yang:
	  - memeriksa karakter hidup, tool terpasang, stun, cooldown (os.clock server)
	  - menghitung combo dari state server
	  - membuat hitbox dari CFrame HumanoidRootPart versi server + definisi senjata server
	  - memvalidasi sudut bidik, jarak (range), dan line-of-sight (Raycast)
	  - menghitung & membatasi damage (maxDamage per senjata dan GlobalMaxDamage)
	  - menerapkan damage via Humanoid:TakeDamage (menghormati ForceField)

	Remote: ReplicatedStorage.<RemoteFolderName>.<RemoteName> (dibuat bila belum ada).
	Client: Net.FireServerSecure(remote, "Attack", aimDirUnit)

	ValidateDamage() juga diekspos untuk sistem damage lain di game Anda.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Schema = require(ReplicatedStorage:WaitForChild("RuntimeInspectorNet"):WaitForChild("Schema"))

local CombatAuthority = {}
CombatAuthority.__index = CombatAuthority

function CombatAuthority.new(audit: any, secureRemote: any, serverConfig: any, weapons: { [string]: any })
	return setmetatable({
		audit = audit,
		secure = secureRemote,
		cfg = serverConfig.Combat,
		weapons = weapons,
		state = {}, -- player -> { lastAttack = {weapon -> t}, combo, comboT }
		conns = {},
		remote = nil,
	}, CombatAuthority)
end

local function getFolder(name: string): Folder
	local folder = ReplicatedStorage:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function equippedTool(char: Model): Tool?
	return char:FindFirstChildOfClass("Tool")
end

local function isStunned(char: Model): boolean
	local v = char:GetAttribute("Stunned")
	return v == true or (type(v) == "number" and v > os.clock())
end

function CombatAuthority:_state(player: Player)
	local s = self.state[player]
	if not s then
		s = { lastAttack = {}, combo = 0, comboT = 0 }
		self.state[player] = s
	end
	return s
end

function CombatAuthority:_finding(player: Player, severity: string, rule: string, detail: string, recommendation: string)
	self.audit:Finding({
		severity = severity,
		rule = rule,
		object = player.Name,
		path = "Players." .. player.Name .. "#combat",
		detail = detail,
		reason = "Permintaan serangan gagal validasi server.",
		recommendation = recommendation,
	}, player)
end

--[[
	ValidateDamage(attacker, targetHumanoid, amount, weaponName?) -> ok, clampedAmount, reason
	Dipakai oleh sistem damage lain (proyektil, skill) agar semua damage melewati satu pintu.
]]
function CombatAuthority:ValidateDamage(attacker: Player?, target: Humanoid, amount: number, weaponName: string?): (boolean, number, string?)
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount == math.huge then
		return false, 0, "amount tidak valid"
	end
	local def = weaponName and self.weapons[weaponName]
	local cap = def and def.maxDamage or self.cfg.GlobalMaxDamage
	if amount > self.cfg.GlobalMaxDamage then
		if attacker then
			self:_finding(attacker, "CRITICAL", "combat.damage_exceeds_global",
				string.format("damage %.1f > GlobalMaxDamage %.1f (target %s)", amount, self.cfg.GlobalMaxDamage, target:GetFullName()),
				"Damage di atas batas global hampir pasti bug konfigurasi atau manipulasi. Telusuri sumber angka damage.")
		end
		return false, 0, "melebihi GlobalMaxDamage"
	end
	if amount > cap then
		return true, cap, "dipotong ke maxDamage senjata"
	end
	return true, amount
end

function CombatAuthority:_handleAttack(player: Player, action: string, aimDir: Vector3)
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = humanoid and humanoid.RootPart
	if not (char and humanoid and hrp) or humanoid.Health <= 0 then
		return
	end
	local tool = equippedTool(char)
	local def = tool and self.weapons[tool.Name]
	if not def then
		self:_finding(player, "MEDIUM", "combat.no_weapon", "Attack tanpa tool terdaftar terpasang (" .. tostring(tool and tool.Name) .. ")",
			"Client resmi tidak mengirim Attack tanpa senjata. Pastikan nama Tool sesuai WeaponDefinitions.")
		return
	end
	if isStunned(char) then
		self:_finding(player, "MEDIUM", "combat.attack_while_stunned", "Attack saat Stunned", "Stun divalidasi server; client tidak boleh bisa menyerang saat stun.")
		return
	end

	local s = self:_state(player)
	local now = os.clock()
	local last = s.lastAttack[tool.Name] or 0
	if now - last < def.cooldown then
		self:_finding(player, "MEDIUM", "combat.cooldown_bypass",
			string.format("Attack %.3fs setelah serangan terakhir (cooldown %.2fs)", now - last, def.cooldown),
			"Cooldown otoritatif ada di server. Frekuensi di bawah cooldown berarti client melewati cooldown lokal.")
		return
	end
	s.lastAttack[tool.Name] = now

	-- sudut bidik terhadap arah hadap server
	local flatAim = Vector3.new(aimDir.X, 0, aimDir.Z)
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	if flatAim.Magnitude < 1e-3 then
		flatAim = look
	end
	flatAim = flatAim.Unit
	local angle = math.deg(math.acos(math.clamp(flatAim:Dot(look.Unit), -1, 1)))
	if angle > self.cfg.MaxAimAngleDeg then
		self:_finding(player, "LOW", "combat.aim_angle", string.format("Sudut bidik %.0f° > %d°", angle, self.cfg.MaxAimAngleDeg),
			"Sudut besar bisa karena lag; bila sering, kemungkinan client memalsukan arah untuk mengenai target di belakang.")
		flatAim = look.Unit
	end

	-- combo dari state server
	if now - s.comboT > def.comboResetTime then
		s.combo = 0
	end
	s.combo = s.combo % #def.comboMultipliers + 1
	s.comboT = now
	char:SetAttribute("ComboIndex", s.combo) -- direplikasi ke client untuk UI/animasi

	-- hitbox server
	local hitboxCFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatAim) * CFrame.new(0, 0, -def.hitboxSize.Z / 2)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { char }
	local parts = workspace:GetPartBoundsInBox(hitboxCFrame, def.hitboxSize, overlap)

	local hitHumanoids = {}
	local targets = 0
	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		local targetHum = model and model:FindFirstChildOfClass("Humanoid")
		if targetHum and not hitHumanoids[targetHum] and targetHum.Health > 0 then
			hitHumanoids[targetHum] = true
			local targetRoot = targetHum.RootPart
			if targetRoot then
				local dist = (targetRoot.Position - hrp.Position).Magnitude
				if dist <= def.range + self.cfg.RangeTolerance then
					local blocked = false
					if self.cfg.RequireLineOfSight then
						local rp = RaycastParams.new()
						rp.FilterType = Enum.RaycastFilterType.Exclude
						rp.FilterDescendantsInstances = { char, model :: Model }
						local result = workspace:Raycast(hrp.Position, targetRoot.Position - hrp.Position, rp)
						blocked = result ~= nil and not CollectionService:HasTag(result.Instance, "IgnoreLOS")
					end
					if not blocked then
						local raw = def.damage * def.comboMultipliers[s.combo]
						local ok, amount = self:ValidateDamage(player, targetHum, raw, tool.Name)
						if ok and amount > 0 then
							targetHum:TakeDamage(amount)
							targets += 1
							self.audit:Event("combat.hit", string.format("%s -> %s %.1f dmg (combo %d, dist %.1f)", player.Name, model and model.Name or "?", amount, s.combo, dist), {
								attacker = player.Name,
								target = model and model.Name,
								damage = amount,
								combo = s.combo,
								distance = dist,
							})
						end
					end
				end
			end
		end
		if targets >= def.maxTargets then
			break
		end
	end
	self.audit:Event("combat.attack", string.format("%s attack %s combo=%d targets=%d", player.Name, tool.Name, s.combo, targets), nil)
end

function CombatAuthority:Start()
	local folder = getFolder(self.cfg.RemoteFolderName)
	local remote = folder:FindFirstChild(self.cfg.RemoteName)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = self.cfg.RemoteName
		remote.Parent = folder
	end
	self.remote = remote

	local S = Schema
	self.secure:Bind(remote, {
		schema = S.Tuple({
			S.OneOf({ "Attack" }),
			S.Vector3({ maxMagnitude = 1.05 }),
		}),
		rate = self.cfg.RateLimit,
		replay = true,
		maxPayloadBytes = 256,
		handler = function(player, action, aimDir)
			if action == "Attack" then
				self:_handleAttack(player, action, aimDir)
			end
		end,
	})
	table.insert(self.conns, Players.PlayerRemoving:Connect(function(p)
		self.state[p] = nil
	end))
end

function CombatAuthority:Destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
end

return CombatAuthority
