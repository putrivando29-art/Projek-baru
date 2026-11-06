--[[
	CharacterProfiler
	Profiling movement, combat, tool, input, dan animasi karakter secara real-time.
	- Client: hanya LocalPlayer (plus input lokal).
	- Server: semua pemain (tanpa input; input tidak pernah dikirim ke server).

	Siklus hidup koneksi:
	- Setiap pemain punya Maid; setiap karakter punya Maid sendiri yang dibersihkan
	  pada CharacterRemoving, Destroying, atau saat pemain keluar. Respawn tidak
	  menumpuk listener.
	- Sampling posisi memakai SATU koneksi Heartbeat untuk semua karakter.

	Keterbatasan resmi:
	- Tidak ada API untuk mengetahui fungsi/script yang memutar animasi atau membuat hitbox.
	  Kolom "nearestCharacter" pada hitbox adalah heuristik jarak, bukan bukti pemilik.
	- Di server, posisi karakter berasal dari replikasi fisika client (network owner).
	  Properti seperti WalkSpeed yang diubah di client TIDAK terlihat di server.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Shared = script.Parent.Parent
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()

local CharacterProfiler = {}
CharacterProfiler.__index = CharacterProfiler

local MOVEMENT_PROPS = { "WalkSpeed", "JumpPower", "JumpHeight", "AutoRotate", "UseJumpPower", "HipHeight" }

function CharacterProfiler.new(config: any, timeline: any)
	local cfg = config.Character
	local attackInputs = {}
	for _, n in cfg.AttackInputs do
		attackInputs[n] = true
	end
	local combatAttrs = {}
	for _, n in cfg.CombatAttributes do
		combatAttrs[n] = true
	end
	local effectClasses = {}
	for _, n in cfg.EffectClasses do
		effectClasses[n] = true
	end
	return setmetatable({
		config = config,
		cfg = cfg,
		timeline = timeline,
		env = IS_SERVER and "server" or "client",
		players = {}, -- player -> { maid, char = state }
		attackInputs = attackInputs,
		combatAttrs = combatAttrs,
		effectClasses = effectClasses,
		maid = Maid.new(),
		-- Hook untuk AnomalyDetector
		HumanoidPropertyChanged = Signal.new(), -- (player, humanoid, prop, old, new)
		Teleported = Signal.new(), -- (player, fromPos, toPos, distance, dt)
		ToolActivated = Signal.new(), -- (player, tool, cooldownInfo?)
		HitboxSeen = Signal.new(), -- (part, size, nearestPlayerName, distance)
		AttributeChanged = Signal.new(), -- (player, inst, name, old, new)
	}, CharacterProfiler)
end

function CharacterProfiler:_rec(category: string, kind: string, summary: string, data: any?)
	return self.timeline:Record(category, kind, summary, data)
end

local function v3(v: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function attrSummary(v: any): string
	return Serializer.Summarize((Serializer.Describe(v)), 60)
end

-- Info cooldown dari atribut karakter/tool (nama atribut dari config).
function CharacterProfiler:_cooldownInfo(char: Model, tool: Tool?): string?
	for _, holder in { tool, char } do
		if holder then
			for _, name in { "Cooldown", "OnCooldown", "Stunned", "Stun" } do
				local v = holder:GetAttribute(name)
				if v == true or (type(v) == "number" and v > 0) then
					return holder.Name .. "." .. name .. "=" .. tostring(v)
				end
			end
		end
	end
	return nil
end

function CharacterProfiler:_bindTool(player: Player, state: any, tool: Tool)
	if state.tools[tool] then
		return
	end
	local m = Maid.new()
	state.tools[tool] = m
	local name = tool.Name
	m:Give(tool.Equipped:Connect(function()
		self:_rec("Tool", "Tool.Equipped", player.Name .. " equip " .. name, { tool = name })
	end))
	m:Give(tool.Unequipped:Connect(function()
		self:_rec("Tool", "Tool.Unequipped", player.Name .. " unequip " .. name, { tool = name })
	end))
	m:Give(tool.Activated:Connect(function()
		local cd = state.char and self:_cooldownInfo(state.char, tool) or nil
		self:_rec("Tool", "Tool.Activated", player.Name .. " activate " .. name .. (cd and (" [cooldown aktif: " .. cd .. "]") or ""), { tool = name, cooldown = cd })
		self.ToolActivated:Fire(player, tool, cd)
	end))
	m:Give(tool.Deactivated:Connect(function()
		self:_rec("Tool", "Tool.Deactivated", player.Name .. " deactivate " .. name, { tool = name })
	end))
	m:Give(tool.AncestryChanged:Connect(function()
		-- Lepas bila tool tidak lagi milik pemain ini (dibuang / dihancurkan)
		local backpack = player:FindFirstChildOfClass("Backpack")
		local stillOwned = (backpack and tool:IsDescendantOf(backpack)) or (state.char and tool:IsDescendantOf(state.char))
		if not stillOwned then
			m:Destroy()
			state.tools[tool] = nil
		end
	end))
end

function CharacterProfiler:_bindAnimator(player: Player, state: any, animator: Animator)
	state.charMaid:Give(animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		local okId, animId = pcall(function()
			return track.Animation and track.Animation.AnimationId or "?"
		end)
		local data = {
			animationId = okId and animId or "?",
			trackName = track.Name,
			priority = tostring(track.Priority),
			speed = track.Speed,
			weight = track.WeightCurrent,
			isPlaying = track.IsPlaying,
			length = track.Length,
		}
		self:_rec("Animation", "Animator.AnimationPlayed",
			string.format("%s play %s id=%s prio=%s speed=%.2f", player.Name, track.Name, tostring(data.animationId), data.priority, track.Speed),
			data)
		-- WeightCurrent biasanya 0 tepat saat Play (fade-in); sampling ulang sesaat kemudian.
		task.delay(0.12, function()
			if track then
				local okW, w = pcall(function()
					return track.WeightCurrent
				end)
				self:_rec("Animation", "AnimationTrack.Sample",
					string.format("%s %s weight=%.2f playing=%s", player.Name, track.Name, okW and w or -1, tostring(track.IsPlaying)),
					{ trackName = track.Name, weight = okW and w or nil, isPlaying = track.IsPlaying })
			end
		end)
		-- Once: koneksi lepas otomatis setelah sekali fire, tidak menumpuk di Maid
		track.Stopped:Once(function()
			self:_rec("Animation", "AnimationTrack.Stopped", player.Name .. " stop " .. track.Name, { trackName = track.Name })
		end)
	end))
end

function CharacterProfiler:_bindHumanoid(player: Player, state: any, humanoid: Humanoid)
	local m = state.charMaid
	state.humanoid = humanoid
	m:Give(humanoid.StateChanged:Connect(function(old, new)
		local cat = (new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall or new == Enum.HumanoidStateType.Landed) and "Jump" or "Movement"
		self:_rec(cat, "Humanoid.StateChanged", player.Name .. " " .. old.Name .. " -> " .. new.Name, { old = old.Name, new = new.Name })
	end))
	m:Give(humanoid.Jumping:Connect(function(active)
		if active then
			self:_rec("Jump", "Humanoid.Jumping", player.Name .. " jumping", { active = active })
		end
	end))
	local lastSpeed = -1
	m:Give(humanoid.Running:Connect(function(speed)
		if math.abs(speed - lastSpeed) >= self.cfg.RunningSpeedDelta or (speed == 0) ~= (lastSpeed == 0) then
			lastSpeed = speed
			self:_rec("Movement", "Humanoid.Running", string.format("%s running speed=%.2f", player.Name, speed), { speed = speed })
		end
	end))
	local lastMoveT = 0
	m:Give(humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		local now = os.clock()
		if now - lastMoveT >= self.cfg.MoveDirectionThrottle then
			lastMoveT = now
			local md = humanoid.MoveDirection
			self:_rec("Movement", "Humanoid.MoveDirection", player.Name .. " moveDir " .. v3(md), { moveDirection = Serializer.Vec3(md) })
		end
	end))
	for _, prop in MOVEMENT_PROPS do
		local okRead, initial = pcall(function()
			return (humanoid :: any)[prop]
		end)
		if okRead then
			local old = initial
			m:Give(humanoid:GetPropertyChangedSignal(prop):Connect(function()
				local new = (humanoid :: any)[prop]
				self:_rec("Movement", "Humanoid." .. prop, string.format("%s %s %s -> %s", player.Name, prop, tostring(old), tostring(new)), { prop = prop, old = old, new = new })
				self.HumanoidPropertyChanged:Fire(player, humanoid, prop, old, new)
				old = new
			end))
		end
	end
	self:_watchAttributes(player, state, humanoid)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		self:_bindAnimator(player, state, animator)
	else
		m:Give(task.spawn(function()
			local a = humanoid:WaitForChild("Animator", 10)
			if a and a:IsA("Animator") and state.humanoid == humanoid then
				self:_bindAnimator(player, state, a)
			end
		end))
	end
end

function CharacterProfiler:_watchAttributes(player: Player, state: any, inst: Instance)
	local okAttrs, attrs = pcall(inst.GetAttributes, inst)
	local snapshot = okAttrs and attrs or {}
	state.charMaid:Give(inst.AttributeChanged:Connect(function(name)
		local old = snapshot[name]
		local new = inst:GetAttribute(name)
		snapshot[name] = new
		local isCombat = self.combatAttrs[name] == true
		self:_rec(isCombat and "Attack" or "Movement", isCombat and "Combat.Attribute" or "Character.Attribute",
			string.format("%s %s.%s %s -> %s", player.Name, inst.Name, name, attrSummary(old), attrSummary(new)),
			{ holder = inst.Name, attribute = name, old = attrSummary(old), new = attrSummary(new) })
		self.AttributeChanged:Fire(player, inst, name, old, new)
	end))
end

function CharacterProfiler:_bindCharacter(player: Player, char: Model)
	local pState = self.players[player]
	if not pState then
		return
	end
	if pState.char then
		self:_unbindCharacter(player)
	end
	local state = {
		char = char,
		charMaid = Maid.new(),
		tools = {},
		humanoid = nil,
		hrp = nil,
		lastPos = nil,
		lastT = 0,
		spawnT = os.clock(),
	}
	pState.char = state
	self:_rec("Movement", "Character.Added", player.Name .. " character spawned", { character = char.Name })

	state.charMaid:Give(char.Destroying:Connect(function()
		if pState.char == state then
			self:_unbindCharacter(player)
		end
	end))
	self:_watchAttributes(player, state, char)

	local function onChild(child: Instance)
		if child:IsA("Tool") then
			self:_bindTool(player, state, child)
		elseif child:IsA("Humanoid") and state.humanoid == nil then
			self:_bindHumanoid(player, state, child)
		elseif child.Name == "HumanoidRootPart" and child:IsA("BasePart") then
			state.hrp = child
		end
	end
	for _, child in char:GetChildren() do
		onChild(child)
	end
	state.charMaid:Give(char.ChildAdded:Connect(onChild))

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				self:_bindTool(player, state, child)
			end
		end
		state.charMaid:Give(backpack.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				self:_bindTool(player, state, child)
			end
		end))
	end
end

function CharacterProfiler:_unbindCharacter(player: Player)
	local pState = self.players[player]
	if not pState or not pState.char then
		return
	end
	local state = pState.char
	pState.char = nil
	for tool, m in state.tools do
		m:Destroy()
		state.tools[tool] = nil
	end
	state.charMaid:Destroy()
	self:_rec("Movement", "Character.Removed", player.Name .. " character removed", nil)
end

function CharacterProfiler:_addPlayer(player: Player)
	if self.players[player] then
		return
	end
	local pState = { maid = Maid.new(), char = nil }
	self.players[player] = pState
	pState.maid:Give(player.CharacterAdded:Connect(function(char)
		self:_bindCharacter(player, char)
	end))
	pState.maid:Give(player.CharacterRemoving:Connect(function()
		self:_unbindCharacter(player)
	end))
	if player.Character then
		self:_bindCharacter(player, player.Character)
	end
end

function CharacterProfiler:_removePlayer(player: Player)
	local pState = self.players[player]
	if not pState then
		return
	end
	self:_unbindCharacter(player)
	pState.maid:Destroy()
	self.players[player] = nil
end

function CharacterProfiler:_sample()
	local now = os.clock()
	for player, pState in self.players do
		local state = pState.char
		if state and state.hrp and state.hrp.Parent then
			if now - state.lastT >= self.cfg.SampleInterval then
				local pos = state.hrp.Position
				if state.lastPos then
					local dt = now - state.lastT
					local delta = (pos - state.lastPos).Magnitude
					local vel = state.hrp.AssemblyLinearVelocity
					-- Lompatan posisi yang tidak dijelaskan oleh velocity => kandidat teleport
					local explained = vel.Magnitude * dt * 1.5 + 4
					if delta > self.config.Anomaly.TeleportDistance and delta > explained and now - state.spawnT > 2 then
						self:_rec("Movement", "HRP.PositionJump", string.format("%s lompatan posisi %.1f studs dalam %.2fs", player.Name, delta, dt), { from = Serializer.Vec3(state.lastPos), to = Serializer.Vec3(pos), distance = delta })
						self.Teleported:Fire(player, state.lastPos, pos, delta, dt)
					end
				end
				state.lastPos = pos
				state.lastT = now
			end
		end
	end
end

-- Dipanggil InstanceMonitor.InstanceAdded (agar tidak membuat koneksi DescendantAdded tambahan).
function CharacterProfiler:OnInstanceAdded(inst: Instance)
	if inst:IsA("BasePart") then
		local lname = string.lower(inst.Name)
		local isHitbox = CollectionService:HasTag(inst, self.cfg.HitboxTag)
		if not isHitbox then
			for _, pattern in self.cfg.HitboxNamePatterns do
				if string.find(lname, pattern, 1, true) then
					isHitbox = true
					break
				end
			end
		end
		if isHitbox then
			local nearestName, nearestDist = nil, math.huge
			for player, pState in self.players do
				local s = pState.char
				if s and s.hrp and s.hrp.Parent then
					local d = (s.hrp.Position - inst.Position).Magnitude
					if d < nearestDist then
						nearestName, nearestDist = player.Name, d
					end
				end
			end
			self:_rec("Hitbox", "Hitbox.Created",
				string.format("%s size=%s near=%s (%.1f studs, heuristik)", inst.Name, v3(inst.Size), tostring(nearestName), nearestDist),
				{ path = Serializer.SafeFullName(inst), size = Serializer.Vec3(inst.Size), nearest = nearestName, distance = nearestDist })
			self.HitboxSeen:Fire(inst, inst.Size, nearestName, nearestDist)
		end
		return
	end
	if self.effectClasses[inst.ClassName] then
		local owner = nil
		for player, pState in self.players do
			local s = pState.char
			if s and s.char and inst:IsDescendantOf(s.char) then
				owner = player.Name
				break
			end
		end
		if not owner then
			local parentPart = inst:FindFirstAncestorWhichIsA("BasePart")
			if parentPart then
				for player, pState in self.players do
					local s = pState.char
					if s and s.hrp and (s.hrp.Position - parentPart.Position).Magnitude <= self.cfg.EffectRadius then
						owner = player.Name .. " (radius)"
						break
					end
				end
			end
		end
		if owner then
			self:_rec("Effect", "Effect.Created", inst.ClassName .. " " .. inst.Name .. " near " .. owner, { path = Serializer.SafeFullName(inst), owner = owner })
		end
	end
end

function CharacterProfiler:_bindInput()
	local function keyName(input: InputObject): string
		if input.UserInputType == Enum.UserInputType.Keyboard or input.UserInputType == Enum.UserInputType.Gamepad1 then
			return input.KeyCode.Name
		end
		return input.UserInputType.Name
	end
	self.maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			return
		end
		-- Jangan merekam ketikan saat TextBox fokus (chat, form) demi privasi
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == self.config.ToggleKey then
			return
		end
		local name = keyName(input)
		local kind = "Input.Began"
		local cat = "Input"
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			kind = "Input.JumpBegan"
		elseif self.attackInputs[name] then
			kind = "Input.AttackBegan"
		end
		self:_rec(cat, kind, name .. (gameProcessed and " (gameProcessed)" or ""), { key = name, gameProcessed = gameProcessed })
	end))
	self.maid:Give(UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		self:_rec("Input", "Input.Ended", keyName(input) .. (gameProcessed and " (gameProcessed)" or ""), { key = keyName(input), gameProcessed = gameProcessed })
	end))
end

function CharacterProfiler:Start()
	if IS_SERVER then
		for _, p in Players:GetPlayers() do
			self:_addPlayer(p)
		end
		self.maid:Give(Players.PlayerAdded:Connect(function(p)
			self:_addPlayer(p)
		end))
		self.maid:Give(Players.PlayerRemoving:Connect(function(p)
			self:_removePlayer(p)
		end))
	else
		local lp = Players.LocalPlayer
		self:_addPlayer(lp)
		self:_bindInput()
	end
	self.maid:Give(RunService.Heartbeat:Connect(function()
		self:_sample()
	end))
end

-- Snapshot movement saat ini (untuk Overview / divergence check).
function CharacterProfiler:Snapshot(player: Player): { [string]: any }?
	local pState = self.players[player]
	local s = pState and pState.char
	if not s or not s.humanoid then
		return nil
	end
	local h = s.humanoid
	local out = {
		WalkSpeed = h.WalkSpeed,
		JumpPower = h.JumpPower,
		JumpHeight = h.JumpHeight,
		UseJumpPower = h.UseJumpPower,
		AutoRotate = h.AutoRotate,
		Health = h.Health,
		MaxHealth = h.MaxHealth,
		State = h:GetState().Name,
	}
	if s.hrp then
		out.Position = Serializer.Vec3(s.hrp.Position)
		out.Velocity = Serializer.Vec3(s.hrp.AssemblyLinearVelocity)
	end
	return out
end

function CharacterProfiler:Destroy()
	for p in self.players do
		self:_removePlayer(p)
	end
	self.maid:Destroy()
end

return CharacterProfiler
