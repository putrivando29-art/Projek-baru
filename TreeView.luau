--[[
	TreeView: directory tree yang bisa dibuka/tutup, di atas VirtualList.
	Children dimuat malas (lazy) lewat provider dan dipaging (tombol "muat lagi").
	provider = {
		Roots    = function() -> { node }                        (boleh yield)
		Children = function(key, offset, limit) -> { node }, total (boleh yield)
	}
	node = { key, label?, name, class, childCount, vis, runtime }
]]

local Theme = require(script.Parent.Theme)
local VirtualList = require(script.Parent.VirtualList)

local TreeView = {}
TreeView.__index = TreeView

local PAGE = 200

function TreeView.new(parent: Instance, provider: any, onSelect: (any) -> ())
	local self = setmetatable({ provider = provider, onSelect = onSelect, roots = {}, flat = {}, generation = 0 }, TreeView)
	self.list = VirtualList.new(parent, {
		render = function(row, node)
			local indent = string.rep("  ", node.depth)
			if node.isMore then
				row.Text = indent .. "  [+ muat " .. node.remaining .. " lagi]"
				row.TextColor3 = Theme.Colors.Accent
				return
			end
			local arrow = node.childCount and node.childCount > 0 and (node.expanded and "- " or "+ ") or "  "
			local label = node.label or node.name
			local badge = node.vis and (" {" .. node.vis .. "}") or ""
			local runtime = node.runtime and " *NEW" or ""
			local loading = node.loading and " (memuat...)" or ""
			row.Text = string.format("%s%s%s  [%s]%s%s%s", indent, arrow, label, node.class or "?", badge, runtime, loading)
			row.TextColor3 = node.vis and Theme.Visibility[node.vis] or Theme.Colors.Text
		end,
		onSelect = function(node)
			if node.isMore then
				self:_loadMore(node)
				return
			end
			self:Toggle(node)
			self.onSelect(node)
		end,
	})
	return self
end

function TreeView:_flatten()
	local flat = {}
	local stack = {}
	for i = #self.roots, 1, -1 do
		table.insert(stack, self.roots[i])
	end
	while #stack > 0 do
		local node = table.remove(stack)
		table.insert(flat, node)
		if node.expanded and node.children then
			for i = #node.children, 1, -1 do
				table.insert(stack, node.children[i])
			end
		end
	end
	self.flat = flat
	self.list:SetItems(flat, true)
end

local function adopt(nodes: { any }, depth: number, parentNode: any?)
	for _, n in nodes do
		n.depth = depth
		n.parentNode = parentNode
	end
	return nodes
end

function TreeView:Load()
	self.generation += 1
	local gen = self.generation
	self.roots = {}
	self:_flatten()
	task.spawn(function()
		local ok, roots = pcall(self.provider.Roots, self.provider)
		if gen ~= self.generation then
			return
		end
		self.roots = ok and adopt(roots or {}, 0, nil) or {}
		self:_flatten()
	end)
end

function TreeView:_fetch(node: any, offset: number)
	node.loading = true
	self:_flatten()
	task.spawn(function()
		local ok, nodes, total = pcall(self.provider.Children, self.provider, node.key, offset, PAGE)
		node.loading = false
		if not ok then
			nodes, total = {}, 0
		end
		local children = node.children or {}
		if children[#children] and children[#children].isMore then
			table.remove(children)
		end
		for _, n in adopt(nodes or {}, node.depth + 1, node) do
			table.insert(children, n)
		end
		local loaded = #children
		if total and total > loaded then
			table.insert(children, { isMore = true, depth = node.depth + 1, remaining = total - loaded, owner = node, offset = loaded })
		end
		node.children = children
		node.childCount = math.max(node.childCount or 0, loaded)
		self:_flatten()
	end)
end

function TreeView:Toggle(node: any)
	if not node.childCount or node.childCount == 0 then
		return
	end
	if node.expanded then
		node.expanded = false
		self:_flatten()
		return
	end
	node.expanded = true
	if node.children == nil then
		self:_fetch(node, 0)
	else
		self:_flatten()
	end
end

function TreeView:_loadMore(moreNode: any)
	self:_fetch(moreNode.owner, moreNode.offset)
end

function TreeView:Redraw()
	self.list:SetItems(self.flat, true)
end

function TreeView:SetVisible(v: boolean)
	self.list.frame.Visible = v
end

function TreeView:Destroy()
	self.list:Destroy()
end

return TreeView
