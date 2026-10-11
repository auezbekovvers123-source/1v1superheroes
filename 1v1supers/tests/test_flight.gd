extends "res://tests/test_case.gd"
## Cape power: take-off (power key or double jump), flight speeds, landing,
## losing the cape mid-air.

func run() -> void:
	await load_level()
	player.turn_enabled = false
	await place_player()
	player.pick_up_item(load("res://Assets/Item/Cloak Assets/cloak_item.tres"))
	player.equip_from_hand(ItemData.EquipSlot.CAPE)

	section("take off")
	var ground_y := player.global_position.y
	pin.tap(&"power")
	await seconds(0.5)
	check(player.is_flying(), "power on the ground takes off")
	check(player.global_position.y - ground_y > 1.5, "and lifts clear of the ground (%.2f m)" % (player.global_position.y - ground_y))
	pin.tap(&"power")
	await frames(2)
	check(not player.is_flying(), "power again drops out of flight")
	await _until_landed()
	pin.tap(&"jump")
	await frames(3)
	pin.tap(&"jump") # too soon: the key bounced
	await frames(2)
	check(not player.is_flying(), "no flight from a jump bounced on the key")
	await _until_landed()
	pin.hold(&"jump", true)
	await frames(12)
	pin.hold(&"jump", false)
	await frames(4)
	pin.tap(&"jump")
	await frames(1)
	check(player.is_flying(), "jumping again mid-air starts flight")
	pin.tap(&"power")
	await _until_landed()
	pin.hold(&"jump", true)
	await frames(10)
	pin.hold(&"jump", false)
	pin.tap(&"power")
	await frames(1)
	check(player.is_flying(), "power mid-air starts flight")

	section("speeds (golden)")
	await frames(20)
	var p0 := player.global_position
	pin.set_move(Vector2(0, -1))
	await seconds(2.0)
	near(hdist(player.global_position, p0) / 2.0, 5.649, 0.15, "cruise speed (avg over 2s)")
	pin.hold(&"run", true)
	await frames(30)
	p0 = player.global_position
	await seconds(1.0)
	near(hdist(player.global_position, p0), 10.989, 0.2, "sprint-flight speed")
	check(player.mesh.rotation.x > deg_to_rad(60.0), "superman pitch while sprint-flying")
	pin.hold(&"run", false)
	pin.set_move(Vector2.ZERO)
	await seconds(1.0)
	var y0 := player.global_position.y
	pin.hold(&"jump", true)
	await seconds(1.0)
	pin.hold(&"jump", false)
	near(player.global_position.y - y0, 3.616, 0.15, "climb speed")

	section("touchdown ends flight")
	pin.hold(&"fly_down", true)
	for i in 600:
		await frames(1)
		if not player.is_flying():
			break
	pin.hold(&"fly_down", false)
	check(not player.is_flying() and player.is_on_floor(), "landing ends flight")
	await seconds(0.5)
	check(absf(player.mesh.rotation.x) < 0.01 and absf(player.mesh.rotation.z) < 0.01, "body back upright after landing")

	section("losing the cape mid-air")
	pin.hold(&"jump", true)
	await frames(10)
	pin.hold(&"jump", false)
	pin.tap(&"power")
	await frames(5)
	check(player.is_flying(), "flying again")
	player.unequip_to_hand(ItemData.EquipSlot.CAPE)
	await frames(2)
	check(not player.is_flying(), "losing the cape ends flight")

func _until_landed() -> void:
	for i in 300:
		await physics_frame
		if player.is_on_floor() and not player.is_flying():
			break
	await frames(20)
