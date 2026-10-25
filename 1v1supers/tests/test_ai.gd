extends "res://tests/test_case.gd"
## The villain: a fighter driven by AIPlayerInput. Checks it shows up as a
## villain, then gives it one kind of gear at a time and checks it fights with
## it against a player who stands still: punches, blocking, collecting gear,
## the laser, speed punches, flying and slamming; and that it comes back after
## a knockout.

const CLOAK := "res://Assets/Item/Cloak Assets/cloak_item.tres"
const BOOTS := "res://Assets/Item/Hero Gear/speed_boots_item.tres"
const VISOR := "res://Assets/Item/Hero Gear/laser_visor_item.tres"

var villain: Player
var ai: AIPlayerInput
var _seen_states := {} # villain state names seen while waiting

func run() -> void:
	await load_level("res://prototype.tscn", true)
	player.turn_enabled = false
	villain = current_scene.get_node("Villain") as Player
	ai = villain.input as AIPlayerInput

	section("a villain in the level")
	check(ai != null and villain.is_in_group("enemy"), "computer-controlled, marked as an enemy")
	check(not villain.is_in_group("local_player") and not villain.input.is_local_human(), "never takes the camera or HUD")
	check(villain.has_power("fly"), "starts wearing its cape")
	check(villain.get_node_or_null("OverheadHealthBar") != null, "a name and health bar overhead")
	var body_mat := (villain.get_skeleton().get_child(0) as MeshInstance3D).get_active_material(0) as BaseMaterial3D
	var hero_mat := (player.get_skeleton().get_child(0) as MeshInstance3D).get_active_material(0) as BaseMaterial3D
	check(body_mat != hero_mat and body_mat.albedo_color.g < hero_mat.albedo_color.g, "tinted: an evil twin")
	ai.rng_seed = 7
	ai._rng.seed = 7

	section("walks up and punches")
	await _reset([], Vector3(0, 0.05, 12))
	await _wait_for(func(): return player.health.current < 100.0, 10.0)
	check(player.health.current < 100.0, "it hurts us (%.0f HP left)" % player.health.current)
	check(_seen_states.has(&"attack"), "with punches")
	check(hdist(villain.global_position, player.global_position) < 2.0, "up close")

	section("blocks our punches")
	await _reset([], Vector3(0, 0.05, 1.3))
	ai.block_chance = 1.0
	ai.parry_chance = 0.0
	ai.dodge_chance = 0.0
	ai.aggression = 0.0 # only defend
	await seconds(0.8)
	for k in 3:
		_face(player, villain)
		pin.tap(&"attack")
		await _wait_for(func(): return false, 0.9)
	var lost := villain.health.max_health - villain.health.current
	check(_seen_states.has(&"block"), "raises its guard")
	check(lost > 0.0 and lost < 11.0, "our punches only chip it (%.1f lost to 3 punches)" % lost)
	check(player.state.name != &"stagger", "a plain block, not a parry")
	ai.aggression = 0.7
	ai.block_chance = 0.5
	ai.parry_chance = 0.15
	ai.dodge_chance = 0.15

	section("collects gear")
	var boots_pickup := current_scene.get_node("SpeedBootsPickup") as ItemPickup
	await _reset([], boots_pickup.global_position + Vector3(4.0, -0.45, 4.0), Vector3(-20, 0.05, -20))
	await _wait_for(func(): return villain.has_power("speed"), 8.0)
	check(villain.has_power("speed"), "walks to the speed boots and puts them on")

	section("speed punch")
	await _reset([BOOTS], Vector3(0, 0.05, 12))
	await _wait_for(func(): return player.health.last_hit != null and player.health.last_hit.label == "SPEED PUNCH!", 8.0)
	check(player.health.last_hit != null and player.health.last_hit.label == "SPEED PUNCH!", "sprints in and lands a speed punch")

	section("laser from range")
	await _reset([VISOR], Vector3(0, 0.05, 10))
	await _wait_for(func(): return player.health.current < 100.0 and _seen_states.has(&"laser"), 10.0)
	check(_seen_states.has(&"laser"), "fires its laser")
	check(player.health.current < 100.0 and player.health.last_hit.kind == HitInfo.Kind.ENERGY, "and burns us with it")

	section("flies up and slams")
	await _reset([CLOAK], Vector3(0, 0.05, 8))
	await _wait_for(func(): return player.health.last_hit != null and player.health.last_hit.label == "SLAM!", 15.0)
	check(_seen_states.has(&"fly"), "takes off")
	check(player.health.last_hit != null and player.health.last_hit.label == "SLAM!", "and ground-slams us")

	section("comes back after a knockout")
	villain.health.take_damage(HitInfo.make(500.0, player, Vector3(0, 2, 0)))
	await seconds(0.5)
	check(villain.is_dead(), "knocked out")
	check(not villain.get_node("OverheadHealthBar").visible, "its bar hides while it is down")
	await seconds(villain.respawn_delay + 1.0)
	check(not villain.is_dead() and villain.health.current == villain.health.max_health, "respawns")
	player.health.revive()
	_seen_states.clear()
	await _wait_for(func(): return ai.activity() != &"idle" and _seen_states.size() > 1, 5.0)
	check(ai.activity() != &"idle", "and gets back to fighting (%s)" % ai.activity())

	section("online play has no villain")
	var net := root.get_node("Net")
	check(net.host_direct(24733, false) == OK, "hosting a session (level not reloaded)")
	await frames(3)
	check(not is_instance_valid(villain) or villain.is_queued_for_deletion(), "the villain leaves")
	check(net.fighter(net.my_id()) == player, "and our own fighter is the one online")
	net.leave()
	await seconds(1.0) # let the hit sounds finish before exiting

## Fresh fighters: the villain at `villain_at` wearing only `gear`, the player
## at `player_at`, both full health, the villain awake.
func _reset(gear: Array, villain_at: Vector3, player_at := Vector3(0, 0.05, 0)) -> void:
	pin.reset()
	for f: Player in [player, villain]:
		if f.state.name != &"free":
			f.change_state(&"free")
		for slot in [ItemData.EquipSlot.CAPE, ItemData.EquipSlot.HELMET, ItemData.EquipSlot.BOOTS]:
			f.equipment.unequip(slot)
		f.inventory.clear()
		f.health.revive()
		f.stamina.refill()
		f.velocity = Vector3.ZERO
	for path: String in gear:
		villain.take_from_world(load(path))
	player.global_position = player_at
	villain.global_position = villain_at
	player.reset_physics_interpolation()
	villain.reset_physics_interpolation()
	player.health.last_hit = null
	ai._reset_plans()
	ai._awake_at = ai._t
	ai._next_laser = 0.0
	ai._next_takeoff = 0.0
	_seen_states.clear()
	await frames(2)

## Waits until `cond` is true or `timeout` seconds pass, noting the villain's states.
func _wait_for(cond: Callable, timeout: float) -> void:
	for i in int(timeout * Engine.physics_ticks_per_second):
		await physics_frame
		_seen_states[villain.state.name] = true
		if cond.call():
			return

func _face(f: Player, other: Node3D) -> void:
	var d := other.global_position - f.global_position
	var yaw := atan2(d.x, d.z)
	f.mesh.rotation = Vector3(0, yaw, 0)
	f.camera_rig.rotation.y = yaw - Player.YAW_OFFSET
