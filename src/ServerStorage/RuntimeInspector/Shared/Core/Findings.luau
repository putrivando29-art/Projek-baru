--[[
	Findings: penyimpanan temuan anomali/keamanan dengan deduplikasi.
	Temuan dengan rule + path yang sama dalam DedupeWindow digabung (count bertambah)
	agar log tidak banjir ketika anomali terjadi tiap frame.

	Skor risiko adalah HEURISTIK sistem ini (bukan standar industri):
	score = min(100, sum(weight(severity) * (1 + log2(count))))
]]

local Signal = require(script.Parent.Parent.Util.Signal)
local RingBuffer = require(script.Parent.Parent.Util.RingBuffer)

local Findings = {}
Findings.__index = Findings

Findings.Severity = table.freeze({ LOW = "LOW", MEDIUM = "MEDIUM", HIGH = "HIGH", CRITICAL = "CRITICAL", INFO = "INFO" })
Findings.Rank = table.freeze({ INFO = 0, LOW = 1, MEDIUM = 2, HIGH = 3, CRITICAL = 4 })
Findings.Weight = table.freeze({ INFO = 0, LOW = 1, MEDIUM = 3, HIGH = 7, CRITICAL = 15 })

function Findings.new(capacity: number?, dedupeWindow: number?)
	local self = setmetatable({
		capacity = capacity or 600,
		dedupeWindow = dedupeWindow or 30,
		list = {}, -- urut waktu dibuat
		byKey = {},
		byId = {},
		nextId = 0,
		changes = RingBuffer.new(2000), -- untuk konsumsi inkremental (streaming)
		Changed = Signal.new(),
	}, Findings)
	return self
end

--[[
	f = {
		severity, rule, object, path, detail, reason, recommendation,
		env = "client"|"server", source = "observed"|"client-reported"|...
	}
]]
function Findings:Report(f: { [string]: any }): { [string]: any }
	local now = os.clock()
	local key = tostring(f.rule) .. "|" .. tostring(f.path or f.object or "?") .. "|" .. tostring(f.env or "")
	local existing = self.byKey[key]
	if existing and now - existing.lastT <= self.dedupeWindow then
		existing.count += 1
		existing.lastT = now
		existing.lastSt = workspace:GetServerTimeNow()
		existing.detail = f.detail or existing.detail
		if (Findings.Rank[f.severity] or 0) > (Findings.Rank[existing.severity] or 0) then
			existing.severity = f.severity
		end
		self.changes:Push(existing)
		self.Changed:Fire(existing, false)
		return existing
	end

	self.nextId += 1
	local entry = {
		id = (f.env or "x") .. ":" .. self.nextId,
		severity = f.severity or "LOW",
		rule = f.rule or "unknown",
		object = f.object or "?",
		path = f.path or f.object or "?",
		detail = f.detail or "",
		reason = f.reason or "",
		recommendation = f.recommendation or "",
		env = f.env or "?",
		source = f.source or "observed",
		player = f.player,
		count = 1,
		firstT = now,
		lastT = now,
		st = workspace:GetServerTimeNow(),
		lastSt = workspace:GetServerTimeNow(),
		clock = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	self.byKey[key] = entry
	self.byId[entry.id] = entry
	table.insert(self.list, entry)
	if #self.list > self.capacity then
		local removed = table.remove(self.list, 1)
		self.byId[removed.id] = nil
		for k, v in self.byKey do
			if v == removed then
				self.byKey[k] = nil
				break
			end
		end
	end
	self.changes:Push(entry)
	self.Changed:Fire(entry, true)
	return entry
end

-- Menyisipkan temuan yang sudah berbentuk entry (misal dari server ke client).
function Findings:Upsert(entry: { [string]: any })
	local existing = self.byId[entry.id]
	if existing then
		for k, v in entry do
			existing[k] = v
		end
		self.Changed:Fire(existing, false)
		return
	end
	self.byId[entry.id] = entry
	table.insert(self.list, entry)
	if #self.list > self.capacity then
		local removed = table.remove(self.list, 1)
		self.byId[removed.id] = nil
	end
	self.Changed:Fire(entry, true)
end

function Findings:List(minSeverity: string?): { any }
	local minRank = Findings.Rank[minSeverity or "INFO"] or 0
	local out = {}
	for _, f in self.list do
		if (Findings.Rank[f.severity] or 0) >= minRank then
			table.insert(out, f)
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = Findings.Rank[a.severity] or 0, Findings.Rank[b.severity] or 0
		if ra ~= rb then
			return ra > rb
		end
		return a.lastT > b.lastT
	end)
	return out
end

function Findings:Counts(): { [string]: number }
	local c = { INFO = 0, LOW = 0, MEDIUM = 0, HIGH = 0, CRITICAL = 0, total = 0 }
	for _, f in self.list do
		c[f.severity] = (c[f.severity] or 0) + 1
		c.total += 1
	end
	return c
end

function Findings.ScoreOf(list: { any }): number
	local score = 0
	for _, f in list do
		local w = Findings.Weight[f.severity] or 0
		score += w * (1 + math.log(math.max(1, f.count or 1), 2))
	end
	return math.min(100, math.floor(score + 0.5))
end

function Findings:RiskScore(): number
	return Findings.ScoreOf(self.list)
end

function Findings:GetSince(seq: number, limit: number?)
	return self.changes:GetSince(seq, limit)
end

function Findings:Clear()
	table.clear(self.list)
	table.clear(self.byKey)
	table.clear(self.byId)
	self.changes:Clear()
end

return Findings
