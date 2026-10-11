extends "res://tests/test_case.gd"
## Turn-in-place when the camera swings round an idle player, and cancelling it.

func run() -> void:
	await load_level()
	await place_player()
	await seconds(1.5) # placing the player swings the camera too: let that turn finish

	section("camera swing triggers a turn")
	player.camera_rig.rotation.y += deg_to_rad(100.0)
	await frames(2)
	check(player.state.name == &"turn", "an idle 100 degree camera swing starts a turn")

	section("cancelling mid-turn keeps the visual heading")
	await frames(20)
	var before := _visual_yaw()
	# Jump cancels without steering the body (moving would strafe-lock it to the camera).
	# The jump clip then turns the hips by itself, so compare the baked mesh facing.
	pin.tap(&"jump")
	await frames(1)
	check(player.state.name == &"free", "jumping cancels the turn")
	var jump := rad_to_deg(absf(angle_difference(before, player.mesh.rotation.y)))
	check(jump < 3.0, "the body keeps its visual heading when cancelled (%.1f degrees off)" % jump)

	section("a completed turn faces the camera's side")
	await seconds(1.0)
	player.camera_rig.rotation.y -= deg_to_rad(100.0)
	await seconds(1.5)
	check(player.state.name == &"free", "turn finishes on its own")

## Facing of the hips in the world (mesh yaw + whatever the turn clip adds).
func _visual_yaw() -> float:
	var skel := player.get_skeleton()
	var g: Transform3D = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("root.x"))
	return atan2(g.basis.z.x, g.basis.z.z)
