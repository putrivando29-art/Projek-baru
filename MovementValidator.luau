--[[
	MovementValidator (server-authoritative movement check)
	Membandingkan delta posisi HumanoidRootPart antar sampel dengan batas yang dihitung
	dari nilai WalkSpeed/JumpPower/JumpHeight MILIK SERVER.

	Fakta platform yang mendasari desain ini:
	- Karakter pemain biasanya network-owned oleh client-nya, sehingga posisi yang dilihat
	  server berasal dari simulasi client. Server tidak bisa "membaca" WalkSpeed client
	  (perubahan properti di client tidak direplikasi), tetapi dapat mengukur hasilnya.
	- Karena itu validasi berbasis delta posisi + toleransi, bukan berbasis properti.

	Pengecualian: duduk di Seat/VehicleSeat, PlatformStand, jendela AllowTeleport,
	dan masa tenggang setelah spawn. Default Action = "log" untuk menghindari false positive;
	"rubberband" mengembalikan HRP ke posisi valid terakhir.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MovementValidator = {}
MovementValidator.__index = MovementValidator

function MovementValidator.new(audit: any, serverConfig: any)
	local self = setmetatable({
		audit = audit,
		cfg = serverConfig.Movement,
		states = {},
		allowUntil = {},
		conns = {},
	}, MovementValidator)
	return self
end

-- Panggil SEBELUM game memindahkan karakter secara sah (teleport, knockback besar, dash).
function MovementValidator:AllowTeleport(player: Player, seconds: number?)
	self.allowUntil[player] = os.clock() + (seconds or 1.5)
	local s = self.states[player]
	if s then
		s.lastPos = nil
	end
end

function MovementValidator:_maxRise(humanoid: Humanoid): number
	local g = workspace.Gravity
	if humanoid.UseJumpPower then
		-- tinggi lompatan dari JumpPower: h = v^2 / (2g)
		return (humanoid.JumpPower ^ 2) / (2 * g)
	end
	return humanoid.JumpHeight
end

function MovementValidator:_violation(player: Player, s: any, kind: string, detail: string, hrp: BasePart)
	local now = os.clock()
	table.insert(s.violations, now)
	while #s.violations > 0 and now - s.violations[1] > self.cfg.ViolationWindow do
		table.remove(s.violations, 1)
	end
	local high = #s.violations >= self.cfg.ViolationsForHigh
	local severity = kind == "teleport" and "HIGH" or (high and "HIGH" or "MEDIUM")
	self.audit:Event("movement." .. kind, player.Name .. ": " .. detail, nil)
	self.audit:Finding({
		severity = severity,
		rule = "movement." .. kind,
		object = player.Name,
		path = "Players." .. player.Name,
		detail = detail,
		reason = kind == "teleport" and "Perpindahan posisi melebihi TeleportDistance tanpa izin AllowTeleport."
			or "Kecepatan melebihi batas yang dihitung dari WalkSpeed server + toleransi.",
		recommendation = "Bila gerakan ini sah (dash, knockback, teleport), panggil MovementValidator:AllowTeleport sebelum memindahkan. Bila Action='rubberband', posisi dikembalikan.",
	}, player)
	if self.cfg.Action == "rubberband" and s.lastValid then
		hrp.CFrame = CFrame.new(s.lastValid) * hrp.CFrame.Rotation
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
end

function MovementValidator:_check(player: Player, s: any, now: number)
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = humanoid and humanoid.RootPart
	if not (humanoid and hrp) or humanoid.Health <= 0 then
		s.lastPos = nil
		return
	end
	if char ~= s.char then
		s.char = char
		s.spawnT = now
		s.lastPos = nil
	end
	local pos = hrp.Position
	-- Dokumentasi keamanan Roblox: exploiter dapat mereplikasi komponen Inf/NaN pada CFrame.
	if pos.X ~= pos.X or pos.Y ~= pos.Y or pos.Z ~= pos.Z or math.abs(pos.X) == math.huge or math.abs(pos.Y) == math.huge or math.abs(pos.Z) == math.huge then
		self.audit:Finding({
			severity = "CRITICAL",
			rule = "movement.non_finite_position",
			object = player.Name,
			path = "Players." .. player.Name,
			detail = "Posisi HumanoidRootPart berisi NaN/inf: " .. tostring(pos),
			reason = "Client tidak sah dapat mereplikasi komponen NaN/inf; nilai ini merusak perhitungan jarak di server.",
			recommendation = "Kembalikan karakter ke posisi valid terakhir / respawn; jangan pakai posisi ini untuk validasi lain.",
		}, player)
		if s.lastValid then
			hrp.CFrame = CFrame.new(s.lastValid)
		end
		return
	end
	if s.lastPos == nil
		or now - s.spawnT < self.cfg.SpawnGrace
		or (self.allowUntil[player] and now < self.allowUntil[player])
		or humanoid.SeatPart ~= nil
		or humanoid.PlatformStand
	then
		s.lastPos, s.lastT, s.lastValid = pos, now, pos
		return
	end
	local dt = now - s.lastT
	local delta = pos - s.lastPos
	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local rise = delta.Y
	local maxHorizontal = humanoid.WalkSpeed * self.cfg.SpeedTolerance * dt + self.cfg.FlatBuffer
	local maxRise = self:_maxRise(humanoid) * 1.25 + self.cfg.VerticalBuffer

	-- Jatuh bebas (delta.Y negatif) tidak dihitung: jatuh dari tempat tinggi bisa sangat cepat.
	local jump = Vector3.new(delta.X, math.max(delta.Y, 0), delta.Z).Magnitude

	if jump > self.cfg.TeleportDistance then
		self:_violation(player, s, "teleport", string.format("%.1f studs dalam %.2fs", jump, dt), hrp)
	elseif horizontal > maxHorizontal then
		self:_violation(player, s, "speed", string.format("horizontal %.1f > batas %.1f (WalkSpeed server %.1f, dt %.2f)", horizontal, maxHorizontal, humanoid.WalkSpeed, dt), hrp)
	elseif rise > maxRise then
		self:_violation(player, s, "vertical", string.format("naik %.1f > batas %.1f", rise, maxRise), hrp)
	else
		s.lastValid = pos
	end
	s.lastPos, s.lastT = pos, now
end

function MovementValidator:Start()
	if not self.cfg.Enabled then
		return
	end
	local function add(p: Player)
		self.states[p] = { lastPos = nil, lastT = 0, spawnT = os.clock(), violations = {}, char = nil }
	end
	for _, p in Players:GetPlayers() do
		add(p)
	end
	table.insert(self.conns, Players.PlayerAdded:Connect(add))
	table.insert(self.conns, Players.PlayerRemoving:Connect(function(p)
		self.states[p] = nil
		self.allowUntil[p] = nil
	end))
	local acc = 0
	table.insert(self.conns, RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < self.cfg.SampleInterval then
			return
		end
		acc = 0
		local now = os.clock()
		for player, s in self.states do
			local ok, err = pcall(self._check, self, player, s, now)
			if not ok then
				warn("[RuntimeInspector] MovementValidator: " .. tostring(err))
			end
		end
	end))
end

function MovementValidator:Destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
end

return MovementValidator
