extends "res://tests/test_case.gd"
## Picking up, holding, using, throwing, dropping and wearing items.

const ROCK := "res://Assets/Item/Usable Assets/rock_item.tres"
const CELL := "res://Assets/Item/Usable Assets/usable_item.tres"
const CLOAK := "res://Assets/Item/Cloak Assets/cloak_item.tres"

func run() -> void:
	await load_level()
	player.turn_enabled = false

	section("pick up from the world")
	await place_player(Vector3(-2, 0.05, 1.6), 0.0) # next to the level's RockPickup
	pin.tap(&"interact")
	await frames(1)
	check(player.state.name == &"gesture", "interact near a pickup plays the pickup gesture")
	await seconds(0.8)
	check(player.held_item != null and player.held_item.id == "holdable_01", "the rock is in the hand")
	check(player.hand.held_instance != null, "held item is visible in the hand")
	check(player.animator.is_holding_pose(), "hold pose is on")

	section("a full hand restricts actions")
	var y0 := player.global_position.y
	pin.tap(&"jump")
	await seconds(0.3)
	check(player.global_position.y - y0 < 0.1, "no jumping while holding")
	pin.tap(&"dash")
	await frames(1)
	check(player.state.name != &"dash", "no dashing while holding")
	check(not player.pick_up_item(load(CELL)), "a second item does not fit in the hand")

	section("drop and pick back up")
	check(player.drop_held_item(), "drop succeeds")
	await frames(2)
	check(player.held_item == null and not player.animator.is_holding_pose(), "hand empty and hold pose off after drop")
	var dropped: ThrownItem = null
	for n in get_nodes_in_group("pickup"):
		if n is ThrownItem and n.item_id == "holdable_01":
			dropped = n
	check(dropped != null, "dropped item is a pickable ThrownItem")
	await seconds(1.0)
	pin.tap(&"interact")
	await seconds(0.8)
	check(player.held_item != null and player.held_item.id == "holdable_01", "picked the dropped rock back up")

	section("throw distances (golden: where the item first touches down)")
	# Where it ends up after rolling is random (it tumbles), so compare first contact.
	player.inventory.clear()
	var golden := {0.05: 1.71, 0.5: 4.22, 1.0: 8.69}
	for power in golden:
		await place_player()
		player.pick_up_item(load(ROCK))
		await frames(10)
		var start := player.global_position
		player.hand.throw_item(power)
		var item := _last_thrown()
		var first := -1.0
		for i in 240:
			await frames(1)
			if item.get_contact_count() > 0:
				first = hdist(item.global_position, start)
				break
		near(first, golden[power], golden[power] * 0.04 + 0.05, "throw at %d%% first touches down at" % int(power * 100))
		item.queue_free()

	section("charged throw")
	await place_player()
	player.pick_up_item(load(ROCK))
	await frames(10)
	pin.hold(&"throw", true)
	await frames(1)
	check(player.state.name == &"throw_charge", "holding throw charges")
	await seconds(1.3)
	var charge_state := player.state as ThrowChargeState
	near(charge_state.power, 1.0, 0.001, "power reaches 100%")
	pin.hold(&"throw", false)
	await frames(1)
	check(player.state.name == &"free" and player.held_item == null, "releasing throws the item")
	check(_last_thrown() != null and _last_thrown().linear_velocity.length() > 7.0, "the thrown item flies fast")

	section("use a usable item")
	await place_player()
	player.pick_up_item(load(CELL))
	await frames(5)
	player.health.current = 50.0
	pin.tap(&"attack")
	await frames(2)
	check(player.state.name == &"use_item", "attack while holding a usable item uses it")
	near(player.health.current, 65.0, 0.01, "using the energy cell heals 15 (golden)")
	await seconds(1.5)
	check(player.state.name == &"free", "back to Free after using")
	player.inventory.clear()

	section("wear the cape")
	var cloak: ItemData = load(CLOAK)
	player.pick_up_item(cloak)
	check(player.equip_from_hand(ItemData.EquipSlot.CAPE), "equip the cape from the hand")
	check(player.equipment.has_equipped(ItemData.EquipSlot.CAPE) and player.held_item == null, "cape worn, hand empty")
	check(player.has_power("fly"), "the cape grants the fly power")
	player.pick_up_item(cloak)
	check(player.equip_from_hand(ItemData.EquipSlot.CAPE), "equip a second cape (swap)")
	check(player.equipment.has_equipped(ItemData.EquipSlot.CAPE) and player.held_item == cloak,
		"after a swap the old cape is in the hand, not lost")
	check(not player.unequip_to_hand(ItemData.EquipSlot.CAPE), "cannot unequip into a full hand")
	player.inventory.clear()
	check(player.unequip_to_hand(ItemData.EquipSlot.CAPE), "unequip into an empty hand")
	await frames(2)
	check(not player.has_power("fly") and player.held_item == cloak, "cape back in the hand, power gone")
	var wearables := 0
	for n in player.get_skeleton().get_children():
		if n is WearableItem and not n.is_queued_for_deletion():
			wearables += 1
	check(wearables == 0, "unequipped capes are freed, not left hidden on the skeleton")

func _last_thrown() -> ThrownItem:
	var found: ThrownItem = null
	for n in current_scene.get_children():
		if n is ThrownItem and not n.is_queued_for_deletion():
			found = n
	return found
