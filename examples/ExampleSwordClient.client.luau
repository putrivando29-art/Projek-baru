--[[
	Contoh LocalScript di dalam Tool bernama "ExampleSword" (harus punya Part "Handle").
	Client HANYA mengirim niat serangan + arah bidik. Damage, cooldown otoritatif, combo,
	hitbox, jangkauan, dan line-of-sight dihitung di server (CombatAuthority).

	Pasang: StarterPack > Tool "ExampleSword" > LocalScript ini.
	Opsional: atribut Tool "AttackAnimationId" (string, mis. "rbxassetid://<ID milik Anda>").
	Tidak ada ID animasi bawaan di contoh ini; gunakan aset Anda sendiri.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("RuntimeInspectorNet"):WaitForChild("Net"))
local remote = ReplicatedStorage:WaitForChild("GameRemotes"):WaitForChild("CombatRequest")

local tool = script.Parent
local player = Players.LocalPlayer

-- Cooldown lokal hanya untuk UX (mencegah spam klik). Server tetap memvalidasi.
local LOCAL_COOLDOWN = 0.45
local lastAttack = 0
local track: AnimationTrack? = nil

local function loadAnimation()
	local id = tool:GetAttribute("AttackAnimationId")
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if type(id) == "string" and id ~= "" and animator then
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
	end
end

tool.Equipped:Connect(loadAnimation)
tool.Unequipped:Connect(function()
	if track then
		track:Stop()
	end
	track = nil
end)

tool.Activated:Connect(function()
	local now = os.clock()
	if now - lastAttack < LOCAL_COOLDOWN then
		return
	end
	lastAttack = now
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local camera = workspace.CurrentCamera
	local aim = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
	if track then
		track:Play()
	end
	-- FireServerSecure menambah (seq, sentAt) untuk ReplayGuard, dan tercatat di Network Monitor.
	Net.FireServerSecure(remote, "Attack", aim.Unit)
end)
