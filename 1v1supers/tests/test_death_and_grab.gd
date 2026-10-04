extends "res://tests/test_case.gd"
## Ragdoll deaths, respawns, and carrying a ragdoll by the neck.

var dummy: Dummy

func run() -> void:
	await load_level()
	player.turn_enabled = false
	dummy = current_scene.get_node("Dummy") as Dummy

	section("player death and respawn")
	await place_player(Vector3(5, 0.05, 5))
	var spawn := player._spawn_point
	player.health.take_damage(HitInfo.make(999.0))
	await frames(2)
	check(player.is_dead() and player.ragdoll.is_ragdolled(), "dead and ragdolled")
	var t := 0
	while player.is_dead() and t < 400:
		await frames(1)
		t += 1
	near(t / 60.0, 2.8, 0.1, "respawn delay")
	check(not player.ragdoll.is_ragdolled() and player.health.current == player.health.max_health, "respawned with full health, ragdoll reset")
	check(player.global_position.distance_to(spawn) < 0.3, "respawned at the spawn point")
	await seconds(0.5)
	player.health.take_damage(HitInfo.make(999.0))
	await frames(2)
	check(player.ragdoll.is_ragdolled() and player.ragdoll.get_bones().size() > 10, "a second death ragdolls again (bones rebuilt)")
	await seconds(3.0)
	check(not player.is_dead(), "respawned again")

	section("dummy ragdoll follows the killing blow")
	dummy.global_position = Vector3(10, 0.05, 10)
	await seconds(1.5)
	var start := dummy.global_position
	dummy.health.take_damage(HitInfo.make(999.0, player, Vector3(6, 0.4, 0)))
	await frames(40)
	var hips := dummy.ragdoll.get_bone("root.x")
	check(hips != null and hips.global_position.x - start.x > 1.0 and absf(hips.global_position.z - start.z) < 0.5,
		"body flew along +X (dx=%.2f dz=%.2f)" % [hips.global_position.x - start.x, hips.global_position.z - start.z])

	section("grab the ragdoll by the neck")
	await seconds(1.0)
	player.global_position = hips.global_position + Vector3(-1.0, 0, 0)
	player.global_position.y = 0.05
	await frames(10)
	pin.tap(&"interact")
	await frames(1)
	var g := player.grabber
	check(g.is_grabbing(), "interact grabs the nearby ragdoll")
	check(g.get_joint_count() == 1 and String(g.get_grabbed_bone().bone_name) == "neck.x", "pinned by the neck with one joint")
	check(dummy.ragdoll.is_held(), "the dummy knows it is held")
	await seconds(1.5)
	check(g.get_grabbed_bone().global_position.distance_to(g.get_hand_position()) < 0.4, "neck stays in the hand")
	var neck0 := g.get_grabbed_bone().global_position
	for i in 120:
		player.global_position += Vector3(0.045, 0, 0)
		await frames(1)
	check(g.is_grabbing() and g.get_grabbed_bone().global_position.distance_to(neck0) > 1.0, "the body is dragged along")

	section("no respawn while carried")
	await seconds(1.5) # past the dummy's 2.5 s respawn time
	check(dummy.health.is_dead and dummy.ragdoll.is_ragdolled(), "carried dummy does not respawn")
	pin.tap(&"interact")
	await frames(2)
	check(not g.is_grabbing() and not dummy.ragdoll.is_held(), "interact releases")
	await seconds(0.5)
	check(not dummy.health.is_dead and not dummy.ragdoll.is_ragdolled(), "dummy respawns right after release")
