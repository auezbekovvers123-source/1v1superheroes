extends "res://tests/test_case.gd"
## Power combos: a punch thrown at super speed (boots), the laser fired while
## flying (cape + visor), and the ground slam (attack while flying).

const CLOAK := "res://Assets/Item/Cloak Assets/cloak_item.tres"
const BOOTS := "res://Assets/Item/Hero Gear/speed_boots_item.tres"
const VISOR := "res://Assets/Item/Hero Gear/laser_visor_item.tres"
const PUNCH := 11.0 # first combo hit

var dummy: Dummy

func run() -> void:
	await load_level()
	player.turn_enabled = false
	dummy = current_scene.get_node("Dummy") as Dummy

	section("speed punch")
	_wear(BOOTS)
	await _punch_dummy_at_speed(false)
	var hp := dummy.health.current
	near(dummy.health.max_health - hp, PUNCH, 0.01, "a punch thrown walking up is normal")
	await _punch_dummy_at_speed(true)
	var lost := dummy.health.max_health - dummy.health.current
	near(lost, PUNCH * SuperSpeedPower.SPEED_PUNCH_DAMAGE, 0.01, "a punch thrown at super speed hits much harder")
	check(dummy.health.last_hit.label == "SPEED PUNCH!", "and says so")
	check(dummy.health.last_hit.knockback.length() > 6.0, "and throws the target back (knockback %.1f)" % dummy.health.last_hit.knockback.length())
	player.inventory.clear()
	player.unequip_to_hand(ItemData.EquipSlot.BOOTS)
	player.inventory.clear()

	section("laser while flying")
	_wear(CLOAK)
	_wear(VISOR)
	await place_player(Vector3(-15, 0.05, -15))
	pin.tap(&"power")
	await seconds(0.6)
	check(player.is_flying(), "flying")
	var y0 := player.global_position.y
	pin.hold(&"aim", true)
	await seconds(0.2)
	pin.hold(&"attack", true)
	await frames(2)
	check(player.state.name == &"laser" and player.get_node_or_null("LaserBeam") != null, "aim + attack fires the laser in the air")
	await seconds(1.0)
	check(not player.is_on_floor() and player.global_position.y > y0 - 0.3, "hovering while it fires (%.2f m up, was %.2f)" % [player.global_position.y, y0])
	pin.hold(&"attack", false)
	await frames(2)
	check(player.state.name == &"fly", "letting go goes back to flying")
	pin.reset()
	await frames(5)

	section("ground slam")
	var centre := Vector3(10, 0.05, -15)
	dummy.global_position = centre + Vector3(1.0, 0, 0)
	dummy.velocity = Vector3.ZERO
	dummy.health.revive()
	var far := current_scene.get_node("Dummy2") as Dummy
	far.visible = true
	far.global_position = centre + Vector3(-7.0, 0, 0)
	far.health.revive()
	var b := (load("res://Scenes/Characters/player.tscn") as PackedScene).instantiate() as Player
	b.name = "Bystander"
	current_scene.add_child(b)
	b.set_input(ScriptedPlayerInput.new())
	b.turn_enabled = false
	b.global_position = centre + Vector3(0, 0, 3.0)
	await place_player(centre)
	pin.tap(&"power")
	await frames(3)
	pin.tap(&"attack")
	await frames(2)
	check(player.state.name == &"fly", "no slam right off the ground (too low)")
	pin.hold(&"jump", true)
	await seconds(0.6)
	pin.hold(&"jump", false)
	await frames(5)
	var height := player.height_above_ground()
	var b_was := hdist(b.global_position, centre)
	pin.tap(&"attack")
	await frames(2)
	check(player.state.name == &"slam", "attack in flight starts a slam (%.1f m up)" % height)
	var landed := false
	for i in 120:
		await physics_frame
		if player.is_on_floor():
			landed = true
			break
	check(landed and player.state.name == &"slam", "it dives straight down")
	await frames(2)
	var slam := player._states[&"slam"] as SlamState
	near(dummy.health.max_health - dummy.health.current, lerpf(SlamState.DAMAGE_MIN, SlamState.DAMAGE_MAX, 1.0 - 1.0 / SlamState.RADIUS), 1.5,
		"the shockwave hits hard close by")
	var b_lost := b.health.max_health - b.health.current
	check(b_lost > SlamState.DAMAGE_MIN and b_lost < dummy.health.max_health - dummy.health.current, "and less farther out (%.1f)" % b_lost)
	check(far.health.current == far.health.max_health, "nothing beyond its radius")
	check(player.health.current == player.health.max_health, "the slammer takes no damage")
	check(dummy.health.last_hit.label == "SLAM!", "SLAM! over the target")
	await seconds(SlamState.RECOVERY + 0.2)
	check(slam.last_hits.size() == 2 and hdist(b.global_position, centre) > b_was + 1.0,
		"and throws them back (%.1f m -> %.1f m)" % [b_was, hdist(b.global_position, centre)])
	check(player.state.name == &"free", "then recovers")
	await seconds(1.0) # let the hit sounds finish before exiting

func _wear(path: String) -> void:
	var item: ItemData = load(path)
	player.pick_up_item(item)
	player.equip_from_hand(item.slot)

## Runs at the dummy from 8 m (sprinting with `fast`, else walking) and punches
## when 2.4 m away. Fresh dummy each time.
func _punch_dummy_at_speed(fast: bool) -> void:
	var spot := Vector3(10, 0.05, -15)
	dummy.global_position = spot
	dummy.velocity = Vector3.ZERO
	dummy.reset_physics_interpolation()
	dummy.health.revive()
	await place_player(spot - Vector3(8.0, 0, 0)) # facing +X, at the dummy
	pin.set_move(Vector2(0, -1))
	pin.hold(&"run", fast)
	for i in 240:
		await physics_frame
		if hdist(player.global_position, dummy.global_position) < (2.4 if fast else 1.1):
			break
	pin.tap(&"attack")
	await seconds(0.8)
	pin.reset()
	await seconds(0.5)
