--[[
	Batcher: mengumpulkan item lalu mengirimnya sekaligus (flush) setiap interval
	atau saat jumlah item mencapai maxBatch. Dipakai untuk log streaming ke dashboard
	agar tidak satu remote per event.
]]

local Batcher = {}
Batcher.__index = Batcher

function Batcher.new(interval: number, maxBatch: number, flush: ({ any }) -> ())
	return setmetatable({
		interval = interval,
		maxBatch = maxBatch,
		flushFn = flush,
		items = {},
		scheduled = nil,
		destroyed = false,
		dropped = 0,
		maxQueued = maxBatch * 20,
	}, Batcher)
end

function Batcher:Flush()
	if self.scheduled then
		if coroutine.status(self.scheduled) == "suspended" then
			pcall(task.cancel, self.scheduled)
		end
		self.scheduled = nil
	end
	if #self.items == 0 then
		return
	end
	local batch = self.items
	self.items = {}
	local ok, err = pcall(self.flushFn, batch)
	if not ok then
		warn("[RuntimeInspector] Batcher flush error: " .. tostring(err))
	end
end

function Batcher:Add(item: any)
	if self.destroyed then
		return
	end
	if #self.items >= self.maxQueued then
		self.dropped += 1
		return
	end
	table.insert(self.items, item)
	if #self.items >= self.maxBatch then
		self:Flush()
	elseif not self.scheduled then
		self.scheduled = task.delay(self.interval, function()
			self.scheduled = nil
			self:Flush()
		end)
	end
end

function Batcher:Destroy()
	self.destroyed = true
	if self.scheduled then
		pcall(task.cancel, self.scheduled)
		self.scheduled = nil
	end
	table.clear(self.items)
end

return Batcher
