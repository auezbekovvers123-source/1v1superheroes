extends "res://tests/test_case.gd"
## Inventory UI ownership, misc gestures, thrown-item damage, and the city level.

func run() -> void:
	await load_level()
	player.turn_enabled = false
	var ui := current_scene.get_node("InventoryUI") as InventoryUI

	section("inventory UI owns the input while open")
	await place_player()
	ui.open_inventory()
	await frames(2)
	check(not player.input.enabled and player.camera_rig.inventory_mode, "opening disables fighter input and swings the camera")
	pin.set_move(Vector2(0, -1))
	var p0 := player.global_position
	await seconds(0.5)
	check(hdist(player.global_position, p0) < 0.05, "no walking while the inventory is open")
	pin.set_move(Vector2.ZERO)
	check(ui._sockets.size() == 6, "six equip rings")
	check(ui._anchors[4].get_parent() is BoneAttachment3D and ui._anchors[5].get_parent() is BoneAttachment3D,
		"boots and accessory rings follow their bones")
	var cloak: ItemData = load("res://Assets/Item/Cloak Assets/cloak_item.tres")
	player.pick_up_item(cloak)
	await frames(1)
	check(ui._sockets[ItemData.EquipSlot.HAND].equipped_item == cloak, "the HAND ring shows the held item")
	player.equip_from_hand(ItemData.EquipSlot.CAPE)
	await frames(1)
	check(ui._sockets[ItemData.EquipSlot.CAPE].equipped_item == cloak and ui._sockets[ItemData.EquipSlot.HAND].equipped_item == null,
		"after equipping, the CAPE ring shows the cape and the HAND ring is empty")
	player.unequip_to_hand(ItemData.EquipSlot.CAPE)
	ui._on_hand_right_clicked(cloak)
	await frames(1)
	check(player.held_item == null, "right-clicking the HAND ring drops the item")
	ui.close_inventory()
	await frames(1)
	check(player.input.enabled and not player.camera_rig.inventory_mode, "closing gives the input back")

	section("gestures")
	await place_player()
	pin.hold(&"throw", true)
	await frames(1)
	pin.hold(&"throw", false)
	check(player.state.name == &"gesture", "throw with an empty hand plays the throw motion")
	await seconds(1.5)
	check(player.state.name == &"free", "and returns to Free")
	player.pick_up_item(load("res://Assets/Item/Usable Assets/usable_item.tres"))
	await frames(2)
	pin.tap(&"interact")
	await frames(1)
	check(player.state.name == &"use_item", "interact uses a held usable item")
	await seconds(1.5)
	player.inventory.clear()

	section("thrown items hurt, credited to the thrower")
	var dummy := current_scene.get_node("Dummy") as Dummy
	await place_player(Vector3(0, 0.05, 8), PI)
	dummy.global_position = Vector3(0, 0.05, 11)
	await seconds(1.0)
	var got: Array = []
	dummy.health.damaged.connect(func(hit: HitInfo): got.append(hit))
	player.pick_up_item(load("res://Assets/Item/Usable Assets/rock_item.tres"))
	await frames(5)
	player.hand.throw_item(0.6)
	await seconds(1.0)
	check(got.size() >= 1 and got[0].kind == HitInfo.Kind.THROWN and got[0].attacker == player,
		"the rock hits the dummy and the hit is credited to the player")

	section("city level")
	change_scene_to_file("res://Scenes/Levels/city.tscn")
	await frames(30)
	var city_player := current_scene.find_child("Player", true, false) as Player
	check(city_player != null and city_player.is_in_group("local_player"), "city level has a local player")
	check(current_scene.find_child("GeneratedCity", true, false) != null, "the city is generated")
