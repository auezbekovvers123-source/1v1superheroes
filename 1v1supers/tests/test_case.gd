extends SceneTree
## Base for headless gameplay tests. Run one with
##   godot --headless --path 1v1supers -s tests/test_movement.gd
## or all of them with tests/run_tests.sh. Exit code 0 = pass.
##
## Tests drive the player only through ScriptedPlayerInput, the same way an AI
## or network opponent would. Expected numbers marked "golden" were measured on
## the game before the refactor, so these tests prove the feel did not change.

var failures: Array[String] = []
var player: Player
var pin: ScriptedPlayerInput

func _initialize() -> void:
	await run()
	print("TEST RESULT: %s" % ("ALL PASS" if failures.is_empty() else "%d FAILED" % failures.size()))
	for f in failures:
		print("  FAIL: ", f)
	quit(0 if failures.is_empty() else 1)

## Override in each test file.
func run() -> void:
	pass

func load_level(path: String = "res://prototype.tscn") -> void:
	change_scene_to_file(path)
	await frames(30)
	player = current_scene.find_child("Player", true, false) as Player
	pin = ScriptedPlayerInput.new()
	player.set_input(pin)
	await frames(30)

func frames(n: int) -> void:
	for i in n:
		await physics_frame

func seconds(t: float) -> void:
	await frames(int(round(t * Engine.physics_ticks_per_second)))

## Puts the player somewhere open, facing `yaw` (camera and body), at rest.
func place_player(pos: Vector3 = Vector3(-15, 0.05, -15), yaw: float = -PI / 2.0) -> void:
	pin.reset()
	await frames(1)
	if player.state.name != &"free" and player.state.name != &"dead":
		player.change_state(&"free")
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.camera_rig.rotation.y = yaw
	player.mesh.rotation = Vector3(0, yaw + Player.YAW_OFFSET, 0)
	player.stamina.refill()
	await frames(45)

func hdist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		failures.append(msg)

## Passes when |actual - expected| <= tol.
func near(actual: float, expected: float, tol: float, what: String) -> void:
	check(abs(actual - expected) <= tol, "%s = %.3f (expected %.3f ± %.3f)" % [what, actual, expected, tol])

func section(title: String) -> void:
	print("-- ", title)
