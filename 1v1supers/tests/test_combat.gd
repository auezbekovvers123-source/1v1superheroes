extends "res://tests/test_case.gd"
## The punch/kick combo against a training dummy.

var dummy: Dummy
var hits: Array = [] # [time, damage, knockback length, critical, kind]
var t0: int = 0

func run() -> void:
	await load_level()
	player.turn_enabled = false
	dummy = current_scene.get_node("Dummy") as Dummy
	dummy.health.damaged.connect(func(hit: HitInfo):
		hits.append([(Engine.get_physics_frames() - t0) / 60.0, hit.damage, hit.knockback.length(), hit.is_critical(), hit.kind]))

	section("full combo (golden numbers)")
	await _face_dummy()
	var hp0 := dummy.health.current
	var done := await _combo(240)
	check(hits.size() == 4, "4 hits land (got %d)" % hits.size())
	var golden_dmg := [11.0, 9.72, 19.72, 29.76]
	var golden_t := [0.267, 0.733, 1.117, 1.75]
	for i in mini(hits.size(), 4):
		near(hits[i][1], golden_dmg[i], 0.01, "hit %d damage" % (i + 1))
		near(hits[i][0], golden_t[i], 0.06, "hit %d time" % (i + 1))
	if hits.size() == 4:
		check(not hits[1][3] and hits[2][3] and hits[3][3], "hits 3 and 4 are critical")
		check(hits[3][4] == HitInfo.Kind.KICK and hits[0][4] == HitInfo.Kind.PUNCH, "hit kinds: punches then a kick")
	near(hp0 - dummy.health.current, 70.2, 0.05, "total damage (golden)")
	near(done, 2.2, 0.1, "combo duration (golden)")
	check(player.combat.combo_index == 0, "combo counter resets after the kick")

	section("stamina")
	await _face_dummy()
	player.stamina.value = 10.0
	pin.tap(&"attack")
	await frames(1)
	check(player.is_attacking(), "punch starts with 10 stamina (costs 8)")
	await seconds(1.0)
	await _face_dummy()
	player.stamina.regen_per_sec = 0.0
	player.stamina.value = 30.0 # three punches (24) but not the kick (14)
	var done2 := await _combo(240)
	check(hits.size() == 3, "queued kick without stamina ends the combo after 3 hits (got %d)" % hits.size())
	check(player.state.name == &"free" and done2 > 0.0, "back to Free after the short combo")
	near(player.stamina.value, 6.0, 0.01, "stamina left after 3 punches")
	player.stamina.regen_per_sec = 18.0

	section("dash cancels an early swing")
	await _face_dummy()
	pin.tap(&"attack")
	await seconds(0.2)
	pin.tap(&"dash")
	await frames(1)
	check(player.state.name == &"dash", "dash cancels a swing inside the cancel window")
	await seconds(1.0)
	await _face_dummy()
	dummy.global_position = Vector3(20, 0.05, 20) # whiff, so the swing keeps its full 0.7 s length
	pin.tap(&"attack")
	await seconds(0.6)
	check(player.is_attacking(), "the whiffed swing is still running at 0.6 s")
	pin.tap(&"dash")
	await frames(1)
	check(player.state.name != &"dash", "no dash cancel after the 0.55 s window")

	section("holding an item")
	await _face_dummy()
	player.pick_up_item(load("res://Assets/Item/Usable Assets/rock_item.tres"))
	await frames(2)
	pin.tap(&"attack")
	await frames(1)
	check(not player.is_attacking(), "no attacks while holding a non-usable item")
	player.inventory.clear()

## Player at z=8 facing +Z, dummy 1.3 m in front, both at rest.
func _face_dummy() -> void:
	await seconds(0.6) # let any previous swing finish and the combo reset
	dummy.global_position = Vector3(0, 0.05, 9.3)
	dummy.velocity = Vector3.ZERO
	await place_player(Vector3(0, 0.05, 8), PI)
	dummy.global_position = Vector3(0, 0.05, 9.3)
	dummy.health.revive()
	await seconds(1.5)
	hits.clear()

## Mashes attack until the combo ends. Returns its duration in seconds.
func _combo(max_frames: int) -> float:
	t0 = Engine.get_physics_frames()
	pin.tap(&"attack")
	for i in max_frames:
		await frames(1)
		if player.is_attacking():
			pin.tap(&"attack")
		elif i > 5:
			return (Engine.get_physics_frames() - t0) / 60.0
	return -1.0
