--[[
	ExecutionManager (Quick Execute)
	Mengatur status, menjalankan, menghentikan, dan menangani error MODUL DIAGNOSTIK yang
	SUDAH ADA (AssetAuditor, ScriptInspector, Explorer, Timeline, InspectorBridge, ...).
	Tidak menjalankan kode bebas/teks Luau: tidak ada loadstring, tidak ada API executor.

	Status: IDLE | RUNNING | DONE | STOPPED | ERROR | ACTIVE (modul kontinu) | NOT IMPLEMENTED
	STOP memakai task.cancel pada thread modul. Bila modul sedang menunggu jawaban server,
	pekerjaan di server tetap selesai; hasilnya diabaikan.
]]

local ExecutionManager = {}
ExecutionManager.__index = ExecutionManager

ExecutionManager.Status = table.freeze({
	IDLE = "IDLE", RUNNING = "RUNNING", DONE = "DONE", STOPPED = "STOPPED",
	ERROR = "ERROR", ACTIVE = "ACTIVE", NOT_IMPLEMENTED = "NOT IMPLEMENTED",
})
local S = ExecutionManager.Status

function ExecutionManager.new(agent: any)
	local RingBuffer = require(agent.shared.Util.RingBuffer)
	local Signal = require(agent.shared.Util.Signal)
	return setmetatable({
		agent = agent,
		RingBuffer = RingBuffer,
		defs = {},
		order = {},
		state = {},
		console = RingBuffer.new(800),
		Changed = Signal.new(),
	}, ExecutionManager)
end

-- def = { id, name, env, category, desc, run(ctx)?, continuous?, implemented = true|false, note? }
function ExecutionManager:Register(def: { [string]: any })
	assert(def.id and not self.defs[def.id], "id modul kosong/duplikat")
	self.defs[def.id] = def
	table.insert(self.order, def.id)
	self.state[def.id] = {
		status = def.implemented == false and S.NOT_IMPLEMENTED or (def.continuous and S.ACTIVE or S.IDLE),
		logs = self.RingBuffer.new(200),
		runs = 0,
		token = 0, -- naik setiap RUN/STOP; hasil thread lama diabaikan
	}
end

function ExecutionManager:Log(id: string?, level: string, msg: string)
	local entry = { t = os.clock(), id = id or "system", level = level, msg = msg }
	self.console:Push(entry)
	if id and self.state[id] then
		self.state[id].logs:Push(entry)
	end
	self.Changed:Fire(id)
end

function ExecutionManager:_set(id: string, status: string)
	self.state[id].status = status
	self.Changed:Fire(id)
end

function ExecutionManager:Run(id: string)
	local def, st = self.defs[id], self.state[id]
	if not def then
		return
	end
	if def.implemented == false then
		self:Log(id, "WARN", "NOT IMPLEMENTED: " .. (def.note or "fitur belum tersedia"))
		return
	end
	if st.status == S.RUNNING then
		self:Log(id, "WARN", "sudah berjalan")
		return
	end
	st.runs += 1
	st.token += 1
	local token = st.token
	st.startedAt = os.clock()
	self:_set(id, S.RUNNING)
	self:Log(id, "INFO", "RUN #" .. st.runs)
	local ctx = {
		agent = self.agent,
		log = function(msg: string)
			if st.token == token then
				self:Log(id, "INFO", msg)
			end
		end,
	}
	st.thread = task.spawn(function()
		local ok, err = xpcall(def.run, debug.traceback, ctx)
		if st.token ~= token or st.status ~= S.RUNNING then
			return -- sudah di-STOP; hasil diabaikan
		end
		st.thread = nil
		local ms = math.floor((os.clock() - st.startedAt) * 1000)
		if ok then
			self:Log(id, "INFO", "selesai dalam " .. ms .. " ms")
			self:_set(id, def.continuous and S.ACTIVE or S.DONE)
		else
			st.lastError = tostring(err)
			self:Log(id, "ERROR", string.sub(tostring(err), 1, 600))
			self:_set(id, S.ERROR)
		end
	end)
end

function ExecutionManager:Stop(id: string)
	local def, st = self.defs[id], self.state[id]
	if not def then
		return
	end
	if def.continuous then
		self:Log(id, "WARN", "STOP: NOT IMPLEMENTED (modul kontinu tidak punya API pause; hanya berhenti saat dashboard ditutup)")
		return
	end
	if st.status ~= S.RUNNING then
		self:Log(id, "INFO", "tidak sedang berjalan")
		return
	end
	local thread = st.thread
	st.thread = nil
	st.token += 1 -- membatalkan log & hasil run lama
	if thread and coroutine.status(thread) ~= "dead" then
		local ok, err = pcall(task.cancel, thread)
		if not ok then
			self:Log(id, "WARN", "task.cancel gagal: " .. tostring(err))
		end
	end
	self:Log(id, "WARN", "STOPPED (hasil scan bisa parsial)")
	self:_set(id, S.STOPPED)
end

function ExecutionManager:List(query: string?, category: string?): { any }
	local q = query and string.lower(query) or ""
	local out = {}
	for _, id in self.order do
		local def = self.defs[id]
		local hay = string.lower(def.name .. " " .. def.desc .. " " .. def.env)
		if (category == nil or category == "all" or def.category == category) and (q == "" or string.find(hay, q, 1, true)) then
			table.insert(out, def)
		end
	end
	return out
end

function ExecutionManager:StateOf(id: string)
	return self.state[id]
end

return ExecutionManager
