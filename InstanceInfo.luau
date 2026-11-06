--[[
	InstanceInfo
	Membaca informasi Instance secara aman (semua akses properti dibungkus pcall)
	dan mengklasifikasikan visibilitasnya.

	Yang TIDAK tersedia lewat API resmi dan karena itu TIDAK diklaim:
	- Waktu pembuatan Instance (yang dicatat adalah "firstSeen": kapan inspector melihatnya).
	- Script yang membuat atau mengubah Instance.
	- Source/bytecode Script dan LocalScript (Source adalah ProtectedString; hanya
	  plugin / Command Bar Studio yang bisa membacanya).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()

local InstanceInfo = {}

InstanceInfo.Visibility = table.freeze({
	SERVER_ONLY = "SERVER_ONLY", -- ServerStorage / ServerScriptService: tidak pernah direplikasi
	REPLICATED = "REPLICATED", -- container yang direplikasi ke client (diamati dari server)
	OWNER_ONLY = "OWNER_ONLY", -- PlayerGui: hanya direplikasi ke pemilik
	SERVER_UNCLASSIFIED = "SERVER_UNCLASSIFIED",
	CLIENT_UNVERIFIED = "CLIENT_UNVERIFIED", -- terlihat client, belum dicek ke server
	CLIENT_REPLICATED = "CLIENT_REPLICATED", -- terverifikasi: Instance juga ada di server
	CLIENT_LOCAL = "CLIENT_LOCAL", -- terverifikasi: hanya ada di client (dibuat lokal)
})

-- Diklasifikasikan berdasarkan ClassName service (Name service bisa diganti).
InstanceInfo.ServerOnlyServices = table.freeze({
	ServerStorage = true,
	ServerScriptService = true,
})

InstanceInfo.ReplicatedServices = table.freeze({
	Workspace = true,
	ReplicatedStorage = true,
	ReplicatedFirst = true,
	Lighting = true,
	SoundService = true,
	Teams = true,
	Players = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayer = true,
	TextChatService = true,
	Chat = true,
	MaterialService = true,
})

-- Properti penting per kelas (dicek dengan IsA, urutan umum -> spesifik).
InstanceInfo.PropertySchema = {
	{ "Instance", { "Archivable" } },
	{ "PVInstance", {} },
	{ "BasePart", { "Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless", "Transparency", "Size", "Position", "Orientation", "Material", "Color", "AssemblyLinearVelocity" } },
	{ "MeshPart", { "MeshId", "TextureID" } },
	{ "Model", { "PrimaryPart", "WorldPivot", "ModelStreamingMode" } },
	{ "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower", "AutoRotate", "HipHeight", "PlatformStand", "Sit", "RigType", "MoveDirection" } },
	{ "BaseScript", { "Enabled", "RunContext" } },
	{ "Sound", { "SoundId", "Volume", "Playing", "Looped", "PlaybackSpeed", "TimeLength" } },
	{ "Animation", { "AnimationId" } },
	{ "Tool", { "Enabled", "RequiresHandle", "CanBeDropped", "ManualActivationOnly", "TextureId", "ToolTip" } },
	{ "ProximityPrompt", { "Enabled", "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "RequiresLineOfSight", "KeyboardKeyCode" } },
	{ "ParticleEmitter", { "Enabled", "Texture", "Rate" } },
	{ "Trail", { "Enabled", "Texture", "Lifetime" } },
	{ "Beam", { "Enabled", "Texture" } },
	{ "Highlight", { "Enabled", "Adornee", "DepthMode" } },
	{ "Attachment", { "Position", "WorldPosition" } },
	{ "JointInstance", { "Part0", "Part1", "C0", "C1", "Enabled" } },
	{ "WeldConstraint", { "Part0", "Part1", "Enabled" } },
	{ "Constraint", { "Enabled", "Attachment0", "Attachment1" } },
	{ "LinearVelocity", { "VectorVelocity", "MaxForce" } },
	{ "VectorForce", { "Force", "RelativeTo" } },
	{ "BodyVelocity", { "Velocity", "MaxForce", "P" } },
	{ "BodyGyro", { "MaxTorque", "CFrame", "P", "D" } },
	{ "LayerCollector", { "Enabled", "ResetOnSpawn" } },
	{ "GuiObject", { "Visible", "Size", "Position", "ZIndex" } },
	{ "ImageLabel", { "Image" } },
	{ "ImageButton", { "Image" } },
	{ "Decal", { "Texture", "Transparency" } },
	{ "ValueBase", { "Value" } },
	{ "Light", { "Enabled", "Brightness" } },
	{ "Player", { "UserId", "DisplayName", "Team", "AccountAge" } },
	{ "Team", { "TeamColor", "AutoAssignable" } },
	{ "Camera", { "CFrame", "FieldOfView", "CameraType" } },
	{ "Lighting", { "ClockTime", "Brightness" } },
	{ "Workspace", { "StreamingEnabled", "Gravity" } },
	{ "Animator", {} },
	{ "RemoteEvent", {} },
}

local function read(inst: Instance, prop: string): (boolean, any)
	return pcall(function()
		return (inst :: any)[prop]
	end)
end
InstanceInfo.Read = read

-- Service paling atas (anak langsung dari game) untuk inst.
function InstanceInfo.TopService(inst: Instance): Instance?
	local cur: Instance? = inst
	while cur and cur.Parent ~= game do
		cur = cur.Parent
	end
	return cur
end

function InstanceInfo.IsUnder(inst: Instance, ancestor: Instance?): boolean
	return ancestor ~= nil and (inst == ancestor or inst:IsDescendantOf(ancestor))
end

-- Klasifikasi visibilitas statis (tanpa verifikasi jaringan).
function InstanceInfo.StaticVisibility(inst: Instance): string
	local V = InstanceInfo.Visibility
	if not IS_SERVER then
		return V.CLIENT_UNVERIFIED
	end
	local top = InstanceInfo.TopService(inst)
	if not top then
		return V.SERVER_UNCLASSIFIED
	end
	if InstanceInfo.ServerOnlyServices[top.ClassName] then
		return V.SERVER_ONLY
	end
	if top.ClassName == "Players" then
		local player = inst:FindFirstAncestorOfClass("Player")
		if player then
			local gui = player:FindFirstChildOfClass("PlayerGui")
			if gui and InstanceInfo.IsUnder(inst, gui) then
				return V.OWNER_ONLY
			end
		end
		return V.REPLICATED
	end
	if InstanceInfo.ReplicatedServices[top.ClassName] then
		return V.REPLICATED
	end
	return V.SERVER_UNCLASSIFIED
end

function InstanceInfo.Enabled(inst: Instance): boolean?
	local ok, v = read(inst, "Enabled")
	if ok and type(v) == "boolean" then
		return v
	end
	return nil
end

function InstanceInfo.Attributes(inst: Instance): { [string]: string }
	local out = {}
	local ok, attrs = pcall(inst.GetAttributes, inst)
	if ok then
		for k, v in attrs do
			out[k] = Serializer.Summarize((Serializer.Describe(v)), 120)
		end
	end
	return out
end

function InstanceInfo.Tags(inst: Instance): { string }
	local ok, tags = pcall(inst.GetTags, inst)
	return ok and tags or {}
end

function InstanceInfo.PropertyList(inst: Instance): { string }
	local list, seen = {}, {}
	for _, entry in InstanceInfo.PropertySchema do
		local okIsA, isA = pcall(inst.IsA, inst, entry[1])
		if okIsA and isA then
			for _, prop in entry[2] do
				if not seen[prop] then
					seen[prop] = true
					table.insert(list, prop)
				end
			end
		end
	end
	return list
end

-- Properti penting sebagai pasangan { name, value(string) }.
function InstanceInfo.Properties(inst: Instance): { { any } }
	local out = {}
	for _, prop in InstanceInfo.PropertyList(inst) do
		local ok, v = read(inst, prop)
		if ok then
			table.insert(out, { prop, Serializer.Summarize((Serializer.Describe(v)), 160) })
		else
			table.insert(out, { prop, "<tidak dapat dibaca: " .. string.sub(tostring(v), 1, 80) .. ">" })
		end
	end
	return out
end

-- Ringkasan untuk baris tree (murah).
function InstanceInfo.Summary(inst: Instance): { [string]: any }
	local okChildren, children = pcall(inst.GetChildren, inst)
	return {
		name = inst.Name,
		class = inst.ClassName,
		childCount = okChildren and #children or 0,
		enabled = InstanceInfo.Enabled(inst),
	}
end

-- Detail lengkap (untuk panel detail; lebih mahal, panggil hanya saat dipilih).
function InstanceInfo.Details(inst: Instance, extra: { [string]: any }?): { [string]: any }
	local okChildren, children = pcall(inst.GetChildren, inst)
	local descendantCount: any = "n/a"
	local top = InstanceInfo.TopService(inst)
	if inst.Parent ~= game and inst ~= game then
		local okD, desc = pcall(inst.GetDescendants, inst)
		descendantCount = okD and #desc or "n/a"
	else
		descendantCount = "(service: lihat Overview)"
	end
	local d = {
		name = inst.Name,
		class = inst.ClassName,
		fullName = Serializer.SafeFullName(inst),
		parent = inst.Parent and Serializer.SafeFullName(inst.Parent) or "nil",
		service = top and top.ClassName or "?",
		childCount = okChildren and #children or 0,
		descendantCount = descendantCount,
		enabled = InstanceInfo.Enabled(inst),
		attributes = InstanceInfo.Attributes(inst),
		tags = InstanceInfo.Tags(inst),
		properties = InstanceInfo.Properties(inst),
		visibility = InstanceInfo.StaticVisibility(inst),
		env = IS_SERVER and "server" or "client",
		creationTime = "tidak tersedia via API resmi (lihat firstSeen)",
	}
	if extra then
		for k, v in extra do
			d[k] = v
		end
	end
	return d
end

-- Teks detail siap tampil.
function InstanceInfo.FormatDetails(d: { [string]: any }): string
	local lines = {
		"Name        : " .. tostring(d.name),
		"ClassName   : " .. tostring(d.class),
		"FullName    : " .. tostring(d.fullName),
		"Parent      : " .. tostring(d.parent),
		"Service     : " .. tostring(d.service),
		"Environment : " .. tostring(d.env),
		"Visibility  : " .. tostring(d.visibility),
		"Enabled     : " .. (d.enabled == nil and "n/a" or tostring(d.enabled)),
		"Children    : " .. tostring(d.childCount),
		"Descendants : " .. tostring(d.descendantCount),
		"FirstSeen   : " .. tostring(d.firstSeen or "-"),
		"Runtime     : " .. tostring(d.runtimeSpawned and "YA (muncul setelah baseline scan)" or "tidak / baseline"),
		"Created     : " .. tostring(d.creationTime),
		"",
		"[Tags]",
	}
	if d.tags and #d.tags > 0 then
		table.insert(lines, "  " .. table.concat(d.tags, ", "))
	else
		table.insert(lines, "  (none)")
	end
	table.insert(lines, "")
	table.insert(lines, "[Attributes]")
	local hasAttr = false
	if d.attributes then
		local keys = {}
		for k in d.attributes do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in keys do
			hasAttr = true
			table.insert(lines, "  " .. k .. " = " .. d.attributes[k])
		end
	end
	if not hasAttr then
		table.insert(lines, "  (none)")
	end
	table.insert(lines, "")
	table.insert(lines, "[Properties]")
	for _, pair in d.properties or {} do
		table.insert(lines, "  " .. pair[1] .. " = " .. tostring(pair[2]))
	end
	if d.note then
		table.insert(lines, "")
		table.insert(lines, "[Catatan]")
		table.insert(lines, "  " .. tostring(d.note))
	end
	return table.concat(lines, "\n")
end

-- Untuk client: shortcut LocalPlayer containers.
function InstanceInfo.LocalPlayerRoots(): { { any } }
	local roots = {}
	local lp = Players.LocalPlayer
	if not lp then
		return roots
	end
	table.insert(roots, { lp, "LocalPlayer" })
	local gui = lp:FindFirstChildOfClass("PlayerGui")
	if gui then
		table.insert(roots, { gui, "PlayerGui" })
	end
	local ps = lp:FindFirstChildOfClass("PlayerScripts")
	if ps then
		table.insert(roots, { ps, "PlayerScripts" })
	end
	local bp = lp:FindFirstChildOfClass("Backpack")
	if bp then
		table.insert(roots, { bp, "Backpack" })
	end
	if lp.Character then
		table.insert(roots, { lp.Character, "Character" })
	end
	return roots
end

return InstanceInfo
