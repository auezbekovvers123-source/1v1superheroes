extends "res://tests/test_case.gd"
## Block, parry, guard break and dodge invincibility, with a second scripted
## fighter throwing real punches (a = attacker, b = defender).

var a: Player
var b: Player
var b_in: ScriptedPlayerInput

const PUNCH := 11.0 # first combo hit
const HIT_FRAME := 18 # the first swing connects about 0.28 s after the press

func run() -> void:
	await load_level()
	a = player
	a.turn_enabled = false
	b = (load("res://Scenes/Characters/player.tscn") as PackedScene).instantiate() as Player
	b.name = "Defender"
	current_scene.add_child(b)
	b_in = ScriptedPlayerInput.new()
	b.set_input(b_in)
	b.turn_enabled = false
	await frames(10)

	section("block from the front")
	await _face_off()
	b_in.hold(&"block", true)
	await seconds(0.6) # past the parry window
	check(b.state.name == &"block" and b.guard.is_raised(), "holding block raises the guard")
	pin.tap(&"attack")
	await seconds(0.8)
	near(b.health.current, 100.0 - PUNCH * b.guard.chip_damage, 0.01, "a blocked punch only chips")
	check(b.state.name == &"block" and b.stun_timer == 0.0, "no stun, the guard stays up")
	check(b.stamina.value < 90.0, "blocking cost stamina (%.0f left)" % b.stamina.value)

	section("hits from behind ignore the guard")
	await _face_off(true)
	b_in.hold(&"block", true)
	await seconds(0.6)
	pin.tap(&"attack")
	await seconds(0.8)
	near(b.health.current, 100.0 - PUNCH, 0.01, "a punch in the back lands in full")

	section("parry: guard raised just in time")
	await _face_off()
	pin.tap(&"attack")
	await frames(HIT_FRAME - 4)
	b_in.hold(&"block", true)
	await frames(8)
	near(b.health.current, 100.0, 0.01, "a parried punch does nothing")
	check(a.state.name == &"stagger", "the attacker staggers")
	await seconds(1.0)
	check(a.state.name == &"free", "and recovers")

	section("mashing block doesn't parry")
	await _face_off()
	b_in.hold(&"block", true)
	await frames(4)
	b_in.hold(&"block", false)
	await frames(4)
	pin.tap(&"attack") # guard goes back up only 8 frames after it came down
	await frames(HIT_FRAME - 4)
	b_in.hold(&"block", true)
	await seconds(0.6)
	near(b.health.current, 100.0 - PUNCH * b.guard.chip_damage, 0.01, "re-raising right away only blocks")
	check(a.state.name != &"stagger", "the attacker is not staggered")

	section("guard break")
	await _face_off()
	b_in.hold(&"block", true)
	await seconds(0.6)
	b.stamina.value = 5.0
	pin.tap(&"attack")
	await seconds(0.5)
	near(b.health.current, 100.0 - PUNCH, 0.01, "out of stamina, the punch lands in full")
	check(b.state.name == &"stagger" and b.stamina.value == 0.0, "the guard breaks: defender staggers")
	b_in.hold(&"block", false)
	await seconds(1.0)
	check(b.state.name == &"free", "and recovers")

	section("dodge invincibility")
	await _face_off()
	pin.tap(&"attack")
	await frames(HIT_FRAME - 6)
	b_in.tap(&"dash") # into the punch
	await seconds(0.6)
	near(b.health.current, 100.0, 0.01, "dashing through the swing dodges it")
	check(b.health.take_damage(HitInfo.make(1.0, a, Vector3(-1, 0, 0))), "hittable again once the dash is over")

	section("guard rules")
	await _face_off()
	b.pick_up_item(load("res://Assets/Item/Usable Assets/rock_item.tres"))
	await frames(2)
	b_in.hold(&"block", true)
	await frames(5)
	check(b.state.name != &"block", "can't block with something in the hand")
	b_in.hold(&"block", false)
	b.inventory.clear()
	await frames(30)
	b_in.hold(&"block", true)
	await seconds(0.6)
	b.health.revive()
	var from_front := HitInfo.make(10.0, null, Vector3(-3, 0.35, 0)) # pushed back = came from +X, where b faces
	check(b.health.take_damage(from_front) and from_front.blocked, "a thrown item from the front is blocked")
	await frames(10)
	var from_back := HitInfo.make(10.0, null, Vector3(3, 0.35, 0))
	check(b.health.take_damage(from_back) and not from_back.blocked, "one from behind is not")
	await _face_off() # settle the knockback before timing the walk
	b_in.hold(&"block", true)
	await seconds(0.6)
	var p0 := b.global_position
	b_in.set_move(Vector2(0, 1)) # back away from a
	await seconds(1.0)
	b_in.set_move(Vector2.ZERO)
	# 45% of walking speed; the first ~0.1 s is spent accelerating
	near(hdist(b.global_position, p0), b.walk_speed * 0.45 * 0.92, 0.1, "walking with the guard up is slow (m in 1 s)")
	b_in.tap(&"attack")
	await frames(2)
	check(b.state.name == &"attack", "attack straight out of the guard")
	b_in.hold(&"block", false)
	await seconds(2.0) # let the hit sounds finish before exiting

## a and b 1.1 m apart; b faces a (or away with `b_back`). Fresh health, stamina, states.
func _face_off(b_back: bool = false) -> void:
	pin.reset()
	b_in.reset()
	await frames(2)
	for f: Player in [a, b]:
		if f.state.name != &"free":
			f.change_state(&"free")
		f.health.revive()
		f.stamina.refill()
		f.velocity = Vector3.ZERO
	_place(a, Vector3(-10.9, 0.05, -12), -PI / 2.0) # faces -X, towards b
	_place(b, Vector3(-12, 0.05, -12), -PI / 2.0 if b_back else PI / 2.0)
	await seconds(0.6)

func _place(f: Player, pos: Vector3, mesh_yaw: float) -> void:
	f.global_position = pos
	f.mesh.rotation = Vector3(0, mesh_yaw, 0)
	f.camera_rig.rotation.y = mesh_yaw - Player.YAW_OFFSET
	f.reset_physics_interpolation()
