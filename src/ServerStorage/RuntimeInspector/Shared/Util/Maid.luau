--[[
	Maid: pengelola cleanup. Setiap koneksi, Instance, thread, atau fungsi yang
	diberikan ke Maid akan dibersihkan saat Cleanup()/Destroy() dipanggil.
	Dipakai di semua modul untuk mencegah listener menumpuk saat Character respawn.
]]

local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {}, _destroyed = false }, Maid)
end

function Maid:Give(item: any): any
	if self._destroyed then
		Maid._cleanTask(item)
		return item
	end
	table.insert(self._tasks, item)
	return item
end

-- Menyimpan item dengan key; item lama pada key yang sama dibersihkan dulu.
function Maid:Set(key: any, item: any)
	self._keyed = self._keyed or {}
	local old = self._keyed[key]
	if old ~= nil and old ~= item then
		Maid._cleanTask(old)
	end
	self._keyed[key] = item
	if self._destroyed and item ~= nil then
		Maid._cleanTask(item)
		self._keyed[key] = nil
	end
end

function Maid:Remove(key: any)
	if self._keyed and self._keyed[key] ~= nil then
		Maid._cleanTask(self._keyed[key])
		self._keyed[key] = nil
	end
end

function Maid._cleanTask(item: any)
	local t = typeof(item)
	if t == "RBXScriptConnection" then
		item:Disconnect()
	elseif t == "function" then
		local ok, err = pcall(item)
		if not ok then
			warn("[RuntimeInspector] Maid cleanup error: " .. tostring(err))
		end
	elseif t == "Instance" then
		pcall(item.Destroy, item)
	elseif t == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif t == "table" then
		if type(item.Destroy) == "function" then
			pcall(item.Destroy, item)
		elseif type(item.Disconnect) == "function" then
			pcall(item.Disconnect, item)
		end
	end
end

function Maid:Cleanup()
	local tasks = self._tasks
	self._tasks = {}
	for i = #tasks, 1, -1 do
		Maid._cleanTask(tasks[i])
	end
	if self._keyed then
		local keyed = self._keyed
		self._keyed = {}
		for _, item in keyed do
			Maid._cleanTask(item)
		end
	end
end

function Maid:Destroy()
	self:Cleanup()
	self._destroyed = true
end

return Maid
