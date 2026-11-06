--[[
	RateLimiter: token bucket per key.
	rate  = token yang diisi ulang per detik
	burst = kapasitas maksimum bucket
	Prune() menghapus key yang lama tidak dipakai agar tidak bocor memori.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(rate: number, burst: number)
	return setmetatable({ rate = rate, burst = burst, buckets = {} }, RateLimiter)
end

function RateLimiter:Allow(key: any, cost: number?): (boolean, number)
	local now = os.clock()
	local b = self.buckets[key]
	if not b then
		b = { tokens = self.burst, last = now }
		self.buckets[key] = b
	end
	b.tokens = math.min(self.burst, b.tokens + (now - b.last) * self.rate)
	b.last = now
	local c = cost or 1
	if b.tokens >= c then
		b.tokens -= c
		return true, b.tokens
	end
	return false, b.tokens
end

function RateLimiter:Remove(key: any)
	self.buckets[key] = nil
end

function RateLimiter:Prune(idleSeconds: number)
	local now = os.clock()
	for key, b in self.buckets do
		if now - b.last > idleSeconds then
			self.buckets[key] = nil
		end
	end
end

return RateLimiter
