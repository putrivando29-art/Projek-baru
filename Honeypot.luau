--[[
	Honeypot
	Remote umpan yang TIDAK PERNAH dipanggil oleh kode game yang sah. Dibuat server saat
	runtime (namanya hanya ada di ServerConfig, server-only), sehingga client resmi tidak
	tahu keberadaannya kecuali dengan menelusuri ReplicatedStorage.
	Setiap panggilan => temuan CRITICAL + strike.

	Batas: exploiter berpengalaman bisa curiga dan tidak memanggilnya. Honeypot adalah alat
	deteksi tambahan, bukan pengganti validasi server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Serializer = require(ReplicatedStorage:WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local Honeypot = {}
Honeypot.__index = Honeypot

function Honeypot.new(audit: any, serverConfig: any)
	return setmetatable({ audit = audit, cfg = serverConfig.Honeypot, instances = {}, conns = {} }, Honeypot)
end

function Honeypot:_trip(player: Player, remote: Instance, ...)
	local desc = Serializer.DescribeArgs(...)
	local parts = {}
	for i, a in desc.args do
		if i > 6 then
			break
		end
		table.insert(parts, Serializer.Summarize(a, 60))
	end
	self.audit:Event("honeypot.trip", player.Name .. " memanggil " .. remote.Name, { args = parts })
	self.audit:Finding({
		severity = "CRITICAL",
		rule = "honeypot.triggered",
		object = remote.Name,
		path = Serializer.SafeFullName(remote) .. "#" .. player.Name,
		detail = string.format("%s memanggil remote umpan %s dengan %d argumen: %s", player.Name, remote.Name, desc.argc, table.concat(parts, ", ")),
		reason = "Remote ini tidak dipakai oleh kode game. Pemanggilan berarti client menjalankan kode di luar game resmi.",
		recommendation = "Tinjau pemain ini. Di game live, pertimbangkan Enforcement='kick'. Jangan beri tahu client bahwa honeypot terpicu.",
	}, player)
end

function Honeypot:Start()
	if not self.cfg.Enabled then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild(self.cfg.FolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = self.cfg.FolderName
		folder.Parent = ReplicatedStorage
	end
	for _, name in self.cfg.EventNames do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
		table.insert(self.instances, r)
		table.insert(self.conns, r.OnServerEvent:Connect(function(player, ...)
			self:_trip(player, r, ...)
		end))
	end
	for _, name in self.cfg.FunctionNames do
		local f = Instance.new("RemoteFunction")
		f.Name = name
		f.Parent = folder
		table.insert(self.instances, f)
		f.OnServerInvoke = function(player, ...)
			self:_trip(player, f, ...)
			return nil
		end
	end
end

function Honeypot:IsHoneypot(inst: Instance): boolean
	return table.find(self.instances, inst) ~= nil
end

function Honeypot:Destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	for _, i in self.instances do
		i:Destroy()
	end
end

return Honeypot
