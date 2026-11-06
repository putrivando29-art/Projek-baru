--[[
	WeaponDefinitions (SERVER-ONLY)
	Angka damage, cooldown, jangkauan, dan ukuran hitbox HANYA hidup di server.
	Client tidak pernah mengirim damage atau ukuran hitbox; client hanya meminta "serang".
	Key = Tool.Name.
]]

return {
	ExampleSword = {
		damage = 12,
		comboMultipliers = { 1, 1.15, 1.5 }, -- hit ke-1, ke-2, ke-3
		maxDamage = 25,
		cooldown = 0.45,
		comboResetTime = 1.2,
		range = 7,
		hitboxSize = Vector3.new(5, 5, 6),
		maxTargets = 3,
	},
}
