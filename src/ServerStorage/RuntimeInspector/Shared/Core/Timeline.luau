--[[
	Timeline: urutan kejadian aksi (input, lompat, tool, animasi, remote, efek, hitbox)
	dengan timestamp os.clock() dan workspace:GetServerTimeNow().

	Correlate() mengelompokkan kejadian di sekitar "anchor" (misal input serangan atau
	Tool.Activated) dalam jendela waktu. Ini KORELASI WAKTU, bukan bukti kausalitas:
	Roblox tidak memberi tahu script mana yang membuat suatu Instance atau memutar animasi.
]]

local RingBuffer = require(script.Parent.Parent.Util.RingBuffer)
local Signal = require(script.Parent.Parent.Util.Signal)

local Timeline = {}
Timeline.__index = Timeline

Timeline.DefaultAnchors = table.freeze({
	["Input.AttackBegan"] = true,
	["Input.JumpBegan"] = true,
	["Humanoid.Jumping"] = true,
	["Tool.Activated"] = true,
	["Combat.Request"] = true,
})

function Timeline.new(capacity: number)
	return setmetatable({ ring = RingBuffer.new(capacity), Added = Signal.new() }, Timeline)
end

-- category: Movement | Jump | Attack | Tool | Animation | Input | Network | Combat | Effect | Hitbox
function Timeline:Record(category: string, kind: string, summary: string, data: { [string]: any }?)
	local entry = {
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		cat = category,
		kind = kind,
		summary = summary,
		data = data,
	}
	entry.seq = self.ring:Push(entry)
	self.Added:Fire(entry)
	return entry
end

function Timeline:ToArray()
	return self.ring:ToArray()
end

function Timeline:GetSince(seq: number, limit: number?)
	return self.ring:GetSince(seq, limit)
end

--[[
	Correlate(opts) -> { { anchor = entry, events = { { dtMs = number, entry = entry } } } }
	opts = { Window = 0.6, PreWindow = 0.08, anchors = set kind, MaxChains = 60 }
	(nama key sama dengan Config.Character.Correlation)
]]
function Timeline:Correlate(opts: { [string]: any }?)
	return Timeline.CorrelateEntries(self.ring:ToArray(), opts)
end

-- Versi statis: dipakai juga untuk cermin timeline server di client.
function Timeline.CorrelateEntries(all: { any }, opts: { [string]: any }?)
	local o = opts or {}
	local window = o.Window or o.window or 0.6
	local pre = o.PreWindow or o.pre or 0.08
	local anchors = o.anchors or Timeline.DefaultAnchors
	local maxChains = o.MaxChains or o.maxChains or 60
	local chains = {}
	-- mulai dari anchor terbaru
	for i = #all, 1, -1 do
		local a = all[i]
		if anchors[a.kind] then
			local events = {}
			-- mundur sedikit (pre) lalu maju sampai window
			local j = i
			while j > 1 and a.t - all[j - 1].t <= pre do
				j -= 1
			end
			while j <= #all and all[j].t - a.t <= window do
				if all[j] ~= a then
					table.insert(events, { dtMs = math.floor((all[j].t - a.t) * 1000 + 0.5), entry = all[j] })
				end
				j += 1
			end
			table.insert(chains, { anchor = a, events = events })
			if #chains >= maxChains then
				break
			end
		end
	end
	return chains
end

function Timeline.FormatChain(chain: { [string]: any }): string
	local a = chain.anchor
	local lines = { string.format("[t=%.3f] ANCHOR %s :: %s", a.t, a.kind, a.summary) }
	for _, ev in chain.events do
		table.insert(lines, string.format("   %+5d ms  %-10s %-24s %s", ev.dtMs, ev.entry.cat, ev.entry.kind, ev.entry.summary))
	end
	return table.concat(lines, "\n")
end

return Timeline
