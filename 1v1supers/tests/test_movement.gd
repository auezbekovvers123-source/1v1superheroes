extends "res://tests/test_case.gd"
## Walking, running, jumping, dashing and stamina, against golden numbers.

func run() -> void:
	await load_level()
	player.turn_enabled = false

	section("walk / run")
	await place_player()
	var p0 := player.global_position
	pin.set_move(Vector2(0, -1))
	await seconds(1.0)
	near(hdist(player.global_position, p0), 1.942, 0.06, "walk distance after 1s (golden)")
	await seconds(1.0)
	near(hdist(player.global_position, p0), 4.042, 0.12, "walk distance after 2s (golden)")

	await place_player()
	p0 = player.global_position
	pin.set_move(Vector2(0, -1))
	pin.hold(&"run", true)
	await seconds(1.0)
	near(hdist(player.global_position, p0), 4.624, 0.14, "run distance after 1s (golden)")
	await seconds(1.0)
	near(hdist(player.global_position, p0), 9.624, 0.3, "run distance after 2s (golden)")
	near(player.stamina.value, 84.0, 0.5, "stamina after 2s sprint (golden: 8/s drain)")

	section("jump")
	await place_player()
	var y0 := player.global_position.y
	pin.hold(&"jump", true)
	var peak := await _track_jump(y0)
	near(peak.x, 2.376, 0.05, "held jump peak height (golden)")
	near(peak.y, 0.55, 0.05, "held jump airtime (golden)")
	await place_player()
	y0 = player.global_position.y
	pin.hold(&"jump", true)
	await frames(2)
	pin.hold(&"jump", false)
	peak = await _track_jump(y0)
	near(peak.x, 0.686, 0.05, "tapped jump peak height (golden)")

	section("dash")
	for rate in [30, 60, 144]:
		Engine.physics_ticks_per_second = rate
		await place_player()
		p0 = player.global_position
		pin.tap(&"dash")
		await frames(rate) # one second of game time
		near(hdist(player.global_position, p0), 3.53, 0.08, "dash distance at %d Hz (same at every tick rate)" % rate)
	Engine.physics_ticks_per_second = 60
	await place_player()
	pin.tap(&"dash")
	await frames(1)
	check(player.state.name == &"dash", "dash starts from Free")
	near(player.stamina.value, 75.0, 0.5, "dash costs 25 stamina")
	await seconds(1.0)
	pin.hold(&"run", true)
	pin.set_move(Vector2(0, -1))
	await frames(2)
	pin.tap(&"dash")
	await frames(1)
	check(player.state.name != &"dash", "no dash while sprinting")

func _track_jump(y0: float) -> Vector2:
	var peak := 0.0
	var air := 0
	for i in 120:
		await frames(1)
		peak = maxf(peak, player.global_position.y - y0)
		if not player.is_on_floor():
			air += 1
		elif i > 5:
			break
	pin.hold(&"jump", false)
	return Vector2(peak, air / 60.0)
