--[[
	RingBuffer: penyimpanan log berukuran tetap. Entri tertua otomatis tertimpa,
	sehingga memori tidak tumbuh tanpa batas selama sesi panjang.
	Setiap entri mendapat nomor urut (seq) untuk konsumsi inkremental (GetSince).
]]

local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.new(capacity: number)
	assert(capacity > 0, "capacity harus > 0")
	return setmetatable({
		capacity = capacity,
		items = table.create(capacity),
		seqs = table.create(capacity),
		head = 0,
		count = 0,
		total = 0,
	}, RingBuffer)
end

function RingBuffer:Push(item: any): number
	self.head = self.head % self.capacity + 1
	self.total += 1
	self.items[self.head] = item
	self.seqs[self.head] = self.total
	if self.count < self.capacity then
		self.count += 1
	end
	return self.total
end

-- Urut dari lama ke baru.
function RingBuffer:ToArray(): { any }
	local out = table.create(self.count)
	local start = (self.head - self.count) % self.capacity
	for i = 1, self.count do
		out[i] = self.items[(start + i - 1) % self.capacity + 1]
	end
	return out
end

function RingBuffer:GetSince(seq: number, limit: number?): ({ any }, number)
	local out = {}
	local start = (self.head - self.count) % self.capacity
	local last = seq
	for i = 1, self.count do
		local idx = (start + i - 1) % self.capacity + 1
		if self.seqs[idx] > seq then
			table.insert(out, self.items[idx])
			last = self.seqs[idx]
			if limit and #out >= limit then
				break
			end
		end
	end
	return out, last
end

function RingBuffer:Clear()
	table.clear(self.items)
	table.clear(self.seqs)
	self.head = 0
	self.count = 0
end

return RingBuffer
