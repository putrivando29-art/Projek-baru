--[[
	Scheduler: traversal DataModel dengan batas waktu per frame (frame budget).
	Traversal memakai stack eksplisit (bukan rekursi) sehingga tidak ada risiko
	stack overflow / infinite recursion pada pohon Instance yang sangat dalam.
]]

local Scheduler = {}

-- Mengembalikan fungsi yang memanggil task.wait() bila budget frame habis.
function Scheduler.Budget(ms: number): () -> ()
	local limit = ms / 1000
	local start = os.clock()
	return function()
		if os.clock() - start >= limit then
			task.wait()
			start = os.clock()
		end
	end
end

--[[
	Walk(root, visit, opts)
	visit(inst, depth) -> return false untuk melewati subtree inst.
	opts = { budgetMs = 2, maxNodes = 200000, skip = function(inst) -> bool, includeRoot = true }
	Return: jumlah node dikunjungi, truncated(bool)
	HARUS dipanggil dari thread yang boleh yield (task.spawn).
]]
function Scheduler.Walk(root: Instance, visit: (Instance, number) -> boolean?, opts: any?): (number, boolean)
	local o = opts or {}
	local step = Scheduler.Budget(o.budgetMs or 2)
	local maxNodes = o.maxNodes or 200000
	local skip = o.skip
	local stack = { root }
	local depths = { 0 }
	local visited = 0
	local includeRoot = o.includeRoot ~= false

	while #stack > 0 do
		local inst = table.remove(stack)
		local depth = table.remove(depths)
		if inst and inst.Parent ~= nil or inst == game or (inst == root) then
			if not (skip and skip(inst)) then
				local descend = true
				if inst ~= root or includeRoot then
					visited += 1
					local ok, result = pcall(visit, inst, depth)
					if ok and result == false then
						descend = false
					end
				end
				if visited >= maxNodes then
					return visited, true
				end
				if descend then
					local okChildren, children = pcall(inst.GetChildren, inst)
					if okChildren then
						for i = #children, 1, -1 do
							table.insert(stack, children[i])
							table.insert(depths, depth + 1)
						end
					end
				end
			end
		end
		step()
	end
	return visited, false
end

return Scheduler
