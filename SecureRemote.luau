--[[
	SecureRemote
	Pipeline validasi server untuk remote MILIK GAME ANDA:
	  1. Pemain valid (masih di Players)
	  2. Rate limit token bucket per (pemain, remote)
	  3. Batas ukuran payload (estimasi)
	  4. Anti-replay (opsional; butuh Net.FireServerSecure di client)
	  5. Validasi skema argumen (Schema.Tuple)
	  6. Handler dijalankan dalam xpcall (error tidak mematikan koneksi, traceback dicatat)

	Contoh:
		SecureRemote:Bind(remote, {
			schema = S.Tuple({ S.OneOf({ "Attack" }), S.Vector3({ maxMagnitude = 1.01 }) }),
			rate = { perSecond = 8, burst = 12 },
			replay = true,
			handler = function(player, action, aimDir) ... end,
		})
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ServerStorage:WaitForChild("RuntimeInspector"):WaitForChild("Shared")
local RateLimiter = require(Shared.Util.RateLimiter)
local NetFolder = ReplicatedStorage:WaitForChild("RuntimeInspectorNet")
local Net = require(NetFolder.Net)
local Schema = require(NetFolder.Schema)
local Serializer = require(NetFolder.Serializer)
local ReplayGuard = require(script.Parent.ReplayGuard)

local SecureRemote = {}
SecureRemote.__index = SecureRemote

function SecureRemote.new(audit: any, serverConfig: any)
	local self = setmetatable({
		audit = audit,
		cfg = serverConfig.Remotes,
		replay = ReplayGuard.new(serverConfig.Remotes.ReplayWindowSeconds, serverConfig.Remotes.MaxSeqJump),
		bound = {},
		stats = {},
	}, SecureRemote)
	self.pruneThread = task.spawn(function()
		while true do
			task.wait(30)
			for _, b in self.bound do
				b.limiter:Prune(60)
			end
		end
	end)
	self.leaveConn = Players.PlayerRemoving:Connect(function(p)
		for _, b in self.bound do
			b.limiter:Remove(p)
		end
	end)
	return self
end

function SecureRemote:_reject(remote: Instance, player: Player, rule: string, severity: string, detail: string, recommendation: string)
	local st = self.stats[remote]
	if st then
		st.rejected += 1
	end
	self.audit:Event("remote.rejected", string.format("%s %s: %s", player.Name, remote.Name, detail), { rule = rule })
	self.audit:Finding({
		severity = severity,
		rule = rule,
		object = remote.Name,
		path = Serializer.SafeFullName(remote) .. "#" .. player.Name,
		detail = detail,
		reason = "Panggilan remote ditolak pipeline validasi server.",
		recommendation = recommendation,
	}, player)
end

-- Return: ok, packed args (setelah seq/sentAt dibuang)
function SecureRemote:_validate(remote: Instance, opts: any, b: any, player: Player, ...): (boolean, any)
	if typeof(player) ~= "Instance" or player.Parent ~= Players then
		return false, nil
	end
	local allowed = b.limiter:Allow(player)
	if not allowed then
		self:_reject(remote, player, "remote.rate_limited", "MEDIUM", "melebihi " .. b.rate.perSecond .. "/detik",
			"Periksa apakah client memanggil remote di loop. Pertahankan rate limit ini.")
		return false, nil
	end
	local maxBytes = opts.maxPayloadBytes or self.cfg.DefaultMaxPayloadBytes
	local bytes, exceeded = Serializer.EstimateBytes(table.pack(...), maxBytes)
	if exceeded then
		self:_reject(remote, player, "remote.payload_too_large", "HIGH", "payload ~" .. bytes .. " bytes > " .. maxBytes,
			"Tolak payload besar; kirim ID, bukan data mentah.")
		return false, nil
	end
	local args = table.pack(...)
	if opts.replay then
		local ok, err = self.replay:Check(player, remote.Name, args[1], args[2])
		if not ok then
			self:_reject(remote, player, "remote.replay", "MEDIUM", tostring(err),
				"Gunakan Net.FireServerSecure di client. Pastikan aksi server juga idempotent (cooldown, state).")
			return false, nil
		end
		args = table.pack(table.unpack(args, 3, args.n))
	end
	if opts.schema then
		local ok, err = Schema.CheckTuple(opts.schema, table.unpack(args, 1, args.n))
		if not ok then
			self:_reject(remote, player, "remote.schema_violation", "HIGH", tostring(err),
				"Client mengirim argumen di luar kontrak. Client resmi tidak melakukan ini; kemungkinan bug atau manipulasi.")
			return false, nil
		end
	end
	return true, args
end

function SecureRemote:_binding(remote: Instance, opts: any)
	local rate = opts.rate or { perSecond = 10, burst = 15 }
	local b = { rate = rate, limiter = RateLimiter.new(rate.perSecond, rate.burst) }
	self.bound[remote] = b
	self.stats[remote] = { accepted = 0, rejected = 0, errors = 0 }
	return b
end

function SecureRemote:_runHandler(remote: Instance, player: Player, handler: any, args: any)
	local results = table.pack(xpcall(handler, debug.traceback, player, table.unpack(args, 1, args.n)))
	local st = self.stats[remote]
	if not results[1] then
		st.errors += 1
		self.audit:Event("remote.handler_error", remote.Name .. ": " .. string.sub(tostring(results[2]), 1, 300), nil)
		self.audit:Finding({
			severity = "LOW",
			rule = "remote.handler_error",
			object = remote.Name,
			path = Serializer.SafeFullName(remote),
			detail = string.sub(tostring(results[2]), 1, 800),
			reason = "Handler remote error. Error yang bisa dipicu input client adalah celah DoS/logic.",
			recommendation = "Perbaiki handler; tambahkan validasi tambahan sebelum logika yang gagal.",
			strike = false,
		}, nil)
		return false
	end
	st.accepted += 1
	return true, table.unpack(results, 2, results.n)
end

function SecureRemote:Bind(remote: RemoteEvent | UnreliableRemoteEvent, opts: any): RBXScriptConnection
	assert(type(opts.handler) == "function", "SecureRemote:Bind butuh opts.handler")
	local b = self:_binding(remote, opts)
	return Net.OnServerEvent(remote, function(player, ...)
		local ok, args = self:_validate(remote, opts, b, player, ...)
		if ok then
			self:_runHandler(remote, player, opts.handler, args)
		end
	end)
end

-- RemoteFunction: handler dijalankan sinkron; nilai kembali diteruskan ke client.
-- Saat ditolak, client menerima nil.
function SecureRemote:BindFunction(remote: RemoteFunction, opts: any)
	assert(type(opts.handler) == "function", "SecureRemote:BindFunction butuh opts.handler")
	local b = self:_binding(remote, opts)
	Net.SetServerInvoke(remote, function(player, ...)
		local ok, args = self:_validate(remote, opts, b, player, ...)
		if not ok then
			return nil
		end
		local result = table.pack(self:_runHandler(remote, player, opts.handler, args))
		if not result[1] then
			return nil
		end
		return table.unpack(result, 2, result.n)
	end)
end

function SecureRemote:Stats(): { any }
	local out = {}
	for remote, st in self.stats do
		table.insert(out, { remote = Serializer.SafeFullName(remote), accepted = st.accepted, rejected = st.rejected, errors = st.errors })
	end
	return out
end

function SecureRemote:Destroy()
	pcall(task.cancel, self.pruneThread)
	self.leaveConn:Disconnect()
	self.replay:Destroy()
end

return SecureRemote
