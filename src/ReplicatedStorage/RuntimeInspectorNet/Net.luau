--[[
	Net: wrapper instrumentasi untuk RemoteEvent, UnreliableRemoteEvent, RemoteFunction,
	BindableEvent, dan BindableFunction MILIK GAME ANDA SENDIRI.

	Kenapa wrapper?
	Roblox tidak menyediakan API resmi untuk "menyadap" FireServer/InvokeServer/OnServerInvoke
	yang dipanggil script lain. Satu-satunya cara sah untuk mencatat panggilan KELUAR dan
	callback (RemoteFunction/BindableFunction) adalah memanggilnya lewat modul ini.
	Event MASUK (OnClientEvent/OnServerEvent/BindableEvent.Event) juga bisa diamati pasif
	oleh NetworkMonitor, tetapi argumen keluar hanya terlihat lewat wrapper.

	Pemakaian (client):
		local Net = require(ReplicatedStorage.RuntimeInspectorNet.Net)
		Net.FireServer(remote, "Attack", aimDir)
		Net.FireServerSecure(remote, "Attack", aimDir) -- menambah (seq, sentAt) untuk ReplayGuard
	Pemakaian (server):
		Net.OnServerEvent(remote, function(player, ...) end)
		Net.FireClient(remote, player, data)
]]

local RunService = game:GetService("RunService")

local Serializer = require(script.Parent.Serializer)

local IS_SERVER = RunService:IsServer()

local Net = {}

Net.Enabled = RunService:IsStudio()
Net.Capacity = 600
Net.Directions = table.freeze({
	ClientToServer = "Client->Server",
	ServerToClient = "Server->Client",
	Local = "Local",
	Return = "Return",
})

local entries = table.create(Net.Capacity)
local head, count, seq = 0, 0, 0
local listeners: { [number]: (any) -> () } = {}
local listenerId = 0
local sequenceByRemote = setmetatable({}, { __mode = "k" })

local function push(entry)
	head = head % Net.Capacity + 1
	entries[head] = entry
	if count < Net.Capacity then
		count += 1
	end
end

local function record(direction: string, remote: Instance, player: Player?, note: string?, ...)
	if not Net.Enabled then
		return
	end
	seq += 1
	local ok, desc = pcall(Serializer.DescribeArgs, ...)
	local entry = {
		seq = seq,
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		env = IS_SERVER and "server" or "client",
		via = "wrapper",
		direction = direction,
		note = note,
		remote = remote.Name,
		path = Serializer.SafeFullName(remote),
		class = remote.ClassName,
		player = player and player.Name or nil,
		userId = player and player.UserId or nil,
		argc = ok and desc.argc or select("#", ...),
		args = ok and desc.args or {},
		types = ok and desc.types or {},
		issues = ok and desc.issues or { "serializer error: " .. tostring(desc) },
		bytes = ok and desc.bytes or 0,
		_inst = remote, -- referensi lokal; dibuang sebelum ekspor/pengiriman
	}
	push(entry)
	for _, fn in listeners do
		local okCall, err = pcall(fn, entry)
		if not okCall then
			warn("[RuntimeInspector] Net listener error: " .. tostring(err))
		end
	end
end

local function assertClass(inst: any, classNames: { string }, fnName: string)
	if typeof(inst) ~= "Instance" then
		error(fnName .. ": argumen pertama harus Instance", 3)
	end
	for _, c in classNames do
		if inst.ClassName == c then
			return
		end
	end
	error(fnName .. ": " .. inst:GetFullName() .. " bukan " .. table.concat(classNames, "/"), 3)
end

local REMOTE_EVENTS = { "RemoteEvent", "UnreliableRemoteEvent" }

---------------------------------------------------------------- konsumen log

function Net.SetEnabled(enabled: boolean)
	Net.Enabled = enabled
end

function Net.Subscribe(fn: (any) -> ()): () -> ()
	listenerId += 1
	local id = listenerId
	listeners[id] = fn
	return function()
		listeners[id] = nil
	end
end

-- Mengembalikan entri dengan seq > sinceSeq, urut lama ke baru.
function Net.GetLog(sinceSeq: number?): { any }
	local out = {}
	local start = (head - count) % Net.Capacity
	for i = 1, count do
		local e = entries[(start + i - 1) % Net.Capacity + 1]
		if e and e.seq > (sinceSeq or 0) then
			table.insert(out, e)
		end
	end
	return out
end

---------------------------------------------------------------- client -> server

function Net.FireServer(remote: Instance, ...)
	assertClass(remote, REMOTE_EVENTS, "Net.FireServer")
	record(Net.Directions.ClientToServer, remote, nil, nil, ...)
	;(remote :: any):FireServer(...)
end

-- Menambah nomor urut dan waktu server di depan argumen. Pasangkan dengan
-- SecureRemote { replay = true } di server. Ini mencegah replay naif, BUKAN
-- jaminan keamanan: exploiter mengendalikan client dan bisa membuat nomor urut sendiri.
function Net.FireServerSecure(remote: Instance, ...)
	local n = (sequenceByRemote[remote] or 0) + 1
	sequenceByRemote[remote] = n
	Net.FireServer(remote, n, workspace:GetServerTimeNow(), ...)
end

function Net.InvokeServer(remote: Instance, ...)
	assertClass(remote, { "RemoteFunction" }, "Net.InvokeServer")
	record(Net.Directions.ClientToServer, remote, nil, "invoke", ...)
	local result = table.pack(pcall((remote :: any).InvokeServer, remote, ...))
	if not result[1] then
		record(Net.Directions.Return, remote, nil, "invoke error", tostring(result[2]))
		error(result[2], 2)
	end
	record(Net.Directions.Return, remote, nil, "invoke return", table.unpack(result, 2, result.n))
	return table.unpack(result, 2, result.n)
end

function Net.OnClientEvent(remote: Instance, handler: (...any) -> ()): RBXScriptConnection
	assertClass(remote, REMOTE_EVENTS, "Net.OnClientEvent")
	return (remote :: any).OnClientEvent:Connect(function(...)
		record(Net.Directions.ServerToClient, remote, nil, nil, ...)
		handler(...)
	end)
end

-- Server sebaiknya tidak memakai InvokeClient (client bisa tidak pernah membalas).
function Net.SetClientInvoke(remote: Instance, handler: (...any) -> ...any)
	assertClass(remote, { "RemoteFunction" }, "Net.SetClientInvoke")
	;(remote :: any).OnClientInvoke = function(...)
		record(Net.Directions.ServerToClient, remote, nil, "invoke", ...)
		local r = table.pack(handler(...))
		record(Net.Directions.Return, remote, nil, "invoke return", table.unpack(r, 1, r.n))
		return table.unpack(r, 1, r.n)
	end
end

---------------------------------------------------------------- server

local function requireServer(fnName: string)
	if not IS_SERVER then
		error(fnName .. " hanya boleh dipanggil dari server", 3)
	end
end

function Net.OnServerEvent(remote: Instance, handler: (Player, ...any) -> ()): RBXScriptConnection
	requireServer("Net.OnServerEvent")
	assertClass(remote, REMOTE_EVENTS, "Net.OnServerEvent")
	return (remote :: any).OnServerEvent:Connect(function(player, ...)
		record(Net.Directions.ClientToServer, remote, player, nil, ...)
		handler(player, ...)
	end)
end

function Net.SetServerInvoke(remote: Instance, handler: (Player, ...any) -> ...any)
	requireServer("Net.SetServerInvoke")
	assertClass(remote, { "RemoteFunction" }, "Net.SetServerInvoke")
	;(remote :: any).OnServerInvoke = function(player, ...)
		record(Net.Directions.ClientToServer, remote, player, "invoke", ...)
		local r = table.pack(handler(player, ...))
		record(Net.Directions.Return, remote, player, "invoke return", table.unpack(r, 1, r.n))
		return table.unpack(r, 1, r.n)
	end
end

function Net.FireClient(remote: Instance, player: Player, ...)
	requireServer("Net.FireClient")
	assertClass(remote, REMOTE_EVENTS, "Net.FireClient")
	record(Net.Directions.ServerToClient, remote, player, nil, ...)
	;(remote :: any):FireClient(player, ...)
end

function Net.FireAllClients(remote: Instance, ...)
	requireServer("Net.FireAllClients")
	assertClass(remote, REMOTE_EVENTS, "Net.FireAllClients")
	record(Net.Directions.ServerToClient, remote, nil, "all clients", ...)
	;(remote :: any):FireAllClients(...)
end

---------------------------------------------------------------- bindable (lokal satu environment)

function Net.Fire(bindable: Instance, ...)
	assertClass(bindable, { "BindableEvent" }, "Net.Fire")
	record(Net.Directions.Local, bindable, nil, "fire", ...)
	;(bindable :: any):Fire(...)
end

function Net.OnEvent(bindable: Instance, handler: (...any) -> ()): RBXScriptConnection
	assertClass(bindable, { "BindableEvent" }, "Net.OnEvent")
	return (bindable :: any).Event:Connect(handler)
end

function Net.Invoke(bindable: Instance, ...)
	assertClass(bindable, { "BindableFunction" }, "Net.Invoke")
	record(Net.Directions.Local, bindable, nil, "invoke", ...)
	local r = table.pack((bindable :: any):Invoke(...))
	record(Net.Directions.Return, bindable, nil, "invoke return", table.unpack(r, 1, r.n))
	return table.unpack(r, 1, r.n)
end

function Net.SetInvoke(bindable: Instance, handler: (...any) -> ...any)
	assertClass(bindable, { "BindableFunction" }, "Net.SetInvoke")
	;(bindable :: any).OnInvoke = handler
end

return Net
