--[[
	API publik untuk script server game Anda.

	local API = require(game:GetService("ServerScriptService").RuntimeInspectorServer.API).WaitReady()
	API.SecureRemote:Bind(myRemote, { schema = ..., rate = ..., handler = ... })
	API.MovementValidator:AllowTeleport(player, 2)
	local ok, dmg = API.CombatAuthority:ValidateDamage(attacker, targetHumanoid, 20, "ExampleSword")
	API.AuditLog:Finding({ severity = "HIGH", rule = "custom.rule", object = "...", detail = "..." }, player)
]]

local API = { Ready = false }

function API._set(modules: { [string]: any })
	for k, v in modules do
		API[k] = v
	end
	API.Ready = true
end

function API.WaitReady(timeout: number?)
	local deadline = os.clock() + (timeout or 15)
	while not API.Ready and os.clock() < deadline do
		task.wait()
	end
	if not API.Ready then
		warn("[RuntimeInspector] API belum siap setelah " .. tostring(timeout or 15) .. " detik")
	end
	return API
end

return API
