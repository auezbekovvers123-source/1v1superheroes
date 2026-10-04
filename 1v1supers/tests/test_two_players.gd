extends "res://tests/test_case.gd"
## Two fighters in one scene: separate inputs, one local camera, and they can hit each other.

func run() -> void:
	change_scene_to_file("res://prototype.tscn")
	await frames(30)
	var a := current_scene.find_child("Player", true, false) as Player # keeps LocalPlayerInput
	var b := (load("res://Scenes/Characters/player.tscn") as PackedScene).instantiate() as Player
	b.name = "Player2"
	current_scene.add_child(b)
	b.global_position = Vector3(-10, 0.05, -10)
	var b_input := ScriptedPlayerInput.new()
	b.set_input(b_input)
	await frames(30)
	a.turn_enabled = false
	b.turn_enabled = false

	section("ownership")
	check(a.is_in_group("local_player") and not b.is_in_group("local_player"), "only the keyboard player is the local player")
	check(a.aim_camera.current and not b.aim_camera.current, "only the local player's camera is active")
	var hud := current_scene.get_node("CombatHUD") as CombatHUD
	check(hud.player == a, "the HUD shows the local player")

	section("separate inputs")
	var a0 := a.global_position
	var b0 := b.global_position
	b_input.set_move(Vector2(0, -1))
	await seconds(1.0)
	b_input.set_move(Vector2.ZERO)
	check(hdist(b.global_position, b0) > 1.5, "player 2 walks from its own input")
	check(hdist(a.global_position, a0) < 0.05, "player 1 does not move")

	section("player 2 punches player 1")
	a.global_position = Vector3(0, 0.05, 9.3)
	b.global_position = Vector3(0, 0.05, 8.0)
	b.camera_rig.rotation.y = PI
	b.mesh.rotation.y = 0.0
	await seconds(1.0)
	var hp0 := a.health.current
	b_input.tap(&"attack")
	await seconds(0.5)
	check(a.health.current < hp0, "the punch damages player 1 (%.0f -> %.0f)" % [hp0, a.health.current])
	check(b.health.current == b.health.max_health, "player 2 does not hit itself")
