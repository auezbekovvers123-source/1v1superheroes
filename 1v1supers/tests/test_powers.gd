extends "res://tests/test_case.gd"
## Superpowers from worn items: picking gear up off the ground puts it on, each
## piece gives its power (cape: flight, speed boots: super speed, laser visor:
## heat beam from the eyes), and taking it off takes the power away.

const CLOAK := "res://Assets/Item/Cloak Assets/cloak_item.tres"

var dummy: Dummy
var hud: CombatHUD
var _run_cam_dist := 0.0 # camera arm length at the end of the last _run_speed

func run() -> void:
	await load_level()
	player.turn_enabled = false
	dummy = current_scene.get_node("Dummy") as Dummy
	hud = current_scene.get_node("CombatHUD") as CombatHUD

	section("no gear, no powers")
	check(player.powers.list().is_empty(), "starts without powers")
	check(not hud._powers_label.visible, "no power hints on the HUD")
	var plain_run := await _run_speed()
	near(plain_run, player.run_speed, 0.1, "normal run speed")
	await place_player(Vector3(3.2, 0.05, 3.15), -PI) # 3 m from the dummy, facing it
	pin.hold(&"aim", true)
	await seconds(0.3)
	pin.hold(&"attack", true)
	await frames(10)
	check(player.state.name != &"laser", "no laser without the visor")
	pin.reset()
	await seconds(1.0)

	section("speed boots")
	await _take_from_ground("SpeedBootsPickup")
	check(player.equipment.has_equipped(ItemData.EquipSlot.BOOTS), "picking the boots up puts them on")
	check(player.held_item == null, "not into the hand")
	check(player.has_power("speed") and player.powers.has("speed"), "boots give super speed")
	check(hud._powers_label.visible and "Super speed" in hud._powers_label.text, "the HUD shows how to use it")
	var fast_run := await _run_speed()
	check(fast_run > 15.0, "super speed sprint: %.1f m/s (normal %.1f)" % [fast_run, plain_run])
	near(_run_cam_dist, player.camera_rig.spring_arm.spring_length, 0.05, "the camera stays back at super speed (arm m)")
	check(player.get_node_or_null("SpeedSparks") != null, "sparks fly off the runner")
	await place_player(Vector3(-22, 0.05, -20))
	var p0 := player.global_position
	pin.set_move(Vector2(0, -1))
	await seconds(1.0)
	pin.set_move(Vector2.ZERO)
	near(hdist(player.global_position, p0), 1.942, 0.06, "walking is unchanged (m in 1 s)")
	await place_player(Vector3(-22, 0.05, -20))
	p0 = player.global_position
	pin.tap(&"dash")
	await seconds(0.8)
	var dash := hdist(player.global_position, p0)
	check(dash > 3.53 * 1.8, "the dodge becomes a long dash: %.2f m (normal 3.53)" % dash)
	player.unequip_to_hand(ItemData.EquipSlot.BOOTS)
	await frames(2)
	check(not player.powers.has("speed") and player.get_node_or_null("SpeedSparks") == null, "boots off: power gone")
	near(await _run_speed(), plain_run, 0.1, "back to the normal run")
	player.inventory.clear()

	section("laser visor")
	await _take_from_ground("LaserVisorPickup")
	check(player.equipment.has_equipped(ItemData.EquipSlot.HELMET) and player.has_power("laser"), "picking the visor up puts it on: laser eyes")
	var hp0 := dummy.health.current
	await place_player(Vector3(3.2, 0.05, 3.15), -PI)
	pin.hold(&"aim", true)
	await seconds(0.3)
	var aim := player.aim_point() - player.global_position
	check(rad_to_deg(Vector2(aim.x, aim.z).angle_to(Vector2(0, 1))) < 5.0, "aiming at the dummy")
	var st0 := player.stamina.value
	pin.hold(&"attack", true)
	await frames(2)
	check(player.state.name == &"laser", "aim + attack fires the laser")
	check(player.get_node_or_null("LaserBeam") != null, "the beam is drawn")
	await seconds(1.0)
	# One tick as it starts, then one every 0.1 s
	near(hp0 - dummy.health.current, LaserState.DPS * (1.0 + LaserState.TICK), LaserState.DPS * LaserState.TICK + 0.01, "the beam burns the dummy (HP in 1 s)")
	check(st0 - player.stamina.value > LaserState.STAMINA_PER_SEC * 0.8, "it costs stamina (%.0f used)" % (st0 - player.stamina.value))
	var eyes := player.eye_points()
	var head_y: float = player.global_position.y + 1.7
	check(eyes[0].y > head_y and eyes[1].y > head_y and eyes[0].distance_to(eyes[1]) > 0.1, "it comes from the eyes")
	pin.hold(&"attack", false)
	await frames(2)
	check(player.state.name == &"free", "letting go of attack stops it")
	await frames(2)
	check(player.get_node_or_null("LaserBeam") == null, "and the beam goes away")

	section("walls stop the beam")
	dummy.global_position = Vector3(0, 0.05, 0) # behind the wall at z = -3
	dummy.velocity = Vector3.ZERO
	dummy.reset_physics_interpolation()
	await place_player(Vector3(0, 0.05, -6), -PI)
	pin.hold(&"aim", true)
	await seconds(0.3)
	hp0 = dummy.health.current
	pin.hold(&"attack", true)
	await seconds(0.6)
	check(player.state.name == &"laser", "firing at the wall")
	near(dummy.health.current, hp0, 0.01, "the dummy behind it takes nothing")

	section("a guard soaks the beam")
	pin.reset()
	await frames(5)
	dummy.global_position = Vector3(12, 0.05, 12)
	dummy.reset_physics_interpolation()
	var b := (load("res://Scenes/Characters/player.tscn") as PackedScene).instantiate() as Player
	b.name = "Blocker"
	current_scene.add_child(b)
	var b_in := ScriptedPlayerInput.new()
	b.set_input(b_in)
	b.turn_enabled = false
	b.global_position = Vector3(3.2, 0.05, 6.15)
	b.mesh.rotation = Vector3(0, PI, 0) # facing the laser
	b.camera_rig.rotation.y = PI - Player.YAW_OFFSET
	await place_player(Vector3(3.2, 0.05, 3.15), -PI)
	pin.hold(&"aim", true)
	await seconds(0.3)
	b_in.hold(&"block", true)
	pin.hold(&"attack", true) # the first tick lands inside the parry window
	await seconds(1.0)
	check(player.state.name == &"laser", "a beam can't be parried: still firing")
	var lost := b.health.max_health - b.health.current
	check(lost > 0.0 and lost < LaserState.DPS * 0.3, "the guard soaks it: %.1f HP lost in 1 s" % lost)
	pin.reset()
	b.queue_free()
	await frames(5)

	section("stamina and the visor")
	await place_player(Vector3(0, 0.05, -6), -PI)
	pin.hold(&"aim", true)
	pin.hold(&"attack", true)
	await frames(5)
	player.stamina.value = 4.0
	await seconds(0.3)
	check(player.state.name == &"free", "the beam stops when the stamina runs out (%.1f left)" % player.stamina.value)
	pin.reset()
	await frames(5)
	player.stamina.refill()
	pin.hold(&"aim", true)
	pin.hold(&"attack", true)
	await frames(5)
	check(player.state.name == &"laser", "firing again")
	player.unequip_to_hand(ItemData.EquipSlot.HELMET)
	await frames(2)
	check(player.state.name == &"free" and not player.has_power("laser"), "visor off: the beam stops, power gone")
	pin.reset()
	player.inventory.clear()
	await frames(10)

	section("cape from the ground")
	await _take_from_ground("CloakPickup")
	check(player.has_power("fly") and player.held_item == null, "picking the cape up puts it on")
	check("Flight" in hud._powers_label.text, "the HUD shows how to fly")
	var y0 := player.global_position.y
	pin.tap(&"power")
	await seconds(0.5)
	check(player.is_flying() and player.global_position.y - y0 > 1.5, "power takes off from the ground")
	pin.tap(&"power")
	await seconds(1.5)
	await _take_from_ground("CloakPickup2")
	check(NetCodec.item_path(player.held_item) == CLOAK, "a second cape goes to the hand (the slot is taken)")
	player.inventory.clear()

	section("two powers at once")
	player.pick_up_item(load("res://Assets/Item/Hero Gear/speed_boots_item.tres"))
	player.equip_from_hand(ItemData.EquipSlot.BOOTS)
	await frames(2)
	check(player.powers.has("fly") and player.powers.has("speed"), "cape and boots together")
	check(hud._powers_label.text.split("\n").size() == 2, "one HUD line per power")
	await seconds(1.0) # let the hit sounds finish before exiting

## Sprint speed reached on open floor after 1.5 s.
func _run_speed() -> float:
	await place_player(Vector3(-22, 0.05, -20))
	pin.set_move(Vector2(0, -1))
	pin.hold(&"run", true)
	await seconds(1.5)
	var v := Vector2(player.velocity.x, player.velocity.z).length()
	_run_cam_dist = player.camera_rig.spring_arm.get_hit_length()
	pin.reset()
	await seconds(0.5)
	return v

## Walks up to a pickup in the level and presses interact.
func _take_from_ground(pickup_name: String) -> void:
	var pickup := current_scene.get_node(pickup_name) as ItemPickup
	await place_player(Vector3(pickup.global_position.x, 0.05, pickup.global_position.z + 0.5))
	check(player.find_nearest_pickup() == pickup, "standing next to the %s" % pickup_name)
	pin.tap(&"interact")
	await seconds(0.5)
	check(not pickup.is_pickable(), "the %s is taken" % pickup_name)
