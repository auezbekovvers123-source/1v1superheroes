extends Node
class_name PlayerAnimator
## The only thing that touches the character's AnimationTree.
##
## Tree layout (player.tscn, plus the Fly nodes added in setup()):
##   locomotion (Idle / 8-way WalkSpace / Run, ground<->air)
##     -> HoldOneShot   (upper-body hold pose: held item or carried body)
##     -> UpperOneShot  ("actions": punches, kick, dash, turn, throw, pickup, jump/land;
##                       bone-filtered to the upper body or full body per action)
##     -> FlyOneShot    (full-body flight: FlyBlend of fly_1 hover / fly_2 sprint)
##     -> output

enum Mask { UPPER, FULL }

const HOLD_ANIM: String = "UpperBody_ITEMHOLD"
const USE_ANIM: String = "UpperBody_ITEMUSE"
const THROWSTART_ANIM: String = "UpperBody_THROWSTART"
const THROWEND_ANIM: String = "UpperBody_THROWEND"
const FLY_IDLE_ANIM: String = "fly_1"
const FLY_MOVE_ANIM: String = "fly_2"
const PICKUP_ANIM: String = "pick_up"

@export var walk_anim_speed: float = 1.25 # WalkSpace playback speed (movement speed unaffected)
@export var walk_blend_smoothing: float = 14.0 # higher = snappier direction changes
@export var walk_blend_smoothing_idle: float = 20.0 # faster when leaving idle (no sluggish first step)
@export var locomotion_blend: float = 9.0 # Idle <-> Walk <-> Run blend rate
@export var fly_fade: float = 0.3 # FlyOneShot fade in/out
@export var fly_blend_speed: float = 3.0 # fly_1 <-> fly_2 blend rate

var tree: AnimationTree = null
var anim_player: AnimationPlayer = null
var _root: AnimationNodeBlendTree = null
var _upper_shot: AnimationNodeOneShot = null
var _hold_reasons: Dictionary = {}
var _walk_blend := Vector2(0, 1)
var _fly_blend: float = 0.0

## Wires the tree to the rig's AnimationPlayer. Returns false if either is missing.
func setup(p_tree: AnimationTree, p_player: AnimationPlayer) -> bool:
	tree = p_tree
	anim_player = p_player
	if tree == null or anim_player == null or tree.tree_root == null:
		push_warning("[PlayerAnimator] Missing AnimationTree or AnimationPlayer — animations disabled")
		return false
	_fix_loop_modes()
	anim_player.playback_default_blend_time = 0.18
	# Per-instance copy so runtime filter/fade edits never leak between fighters
	tree.tree_root = tree.tree_root.duplicate(true)
	_root = tree.tree_root as AnimationNodeBlendTree
	tree.anim_player = tree.get_path_to(anim_player)
	_upper_shot = _root.get_node("UpperOneShot") as AnimationNodeOneShot
	_upper_shot.filter_enabled = true
	_build_fly_nodes()
	tree.active = true
	reset()
	return true

func _fix_loop_modes() -> void:
	for n in ["Idle", "Walk", "Walk_left", "Walk_right", "Walk_backwards", "Walk_Left_forward", "Walk_Right_forward",
			"Walk_Left_backwards", "Walk_Right_backwards", "running", "falling_idle", FLY_IDLE_ANIM, FLY_MOVE_ANIM, "T_pose", HOLD_ANIM]:
		if anim_player.has_animation(n):
			anim_player.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	for anim_name in anim_player.get_animation_list():
		var low := String(anim_name).to_lower()
		if low.begins_with("pick") or "throw" in low or low.begins_with("dodge_") or low.begins_with("turn_") \
				or low.begins_with("punch") or low.begins_with("kick") or low.begins_with("landing") \
				or low == "jump_start" or low == USE_ANIM.to_lower():
			anim_player.get_animation(anim_name).loop_mode = Animation.LOOP_NONE
	# The running clip drifts horizontally between first and last key: close the loop
	if anim_player.has_animation("running"):
		var run_anim := anim_player.get_animation("running")
		for t in range(run_anim.get_track_count()):
			if run_anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
				continue
			var cnt := run_anim.track_get_key_count(t)
			if cnt < 2:
				continue
			var first: Vector3 = run_anim.track_get_key_value(t, 0)
			var last: Vector3 = run_anim.track_get_key_value(t, cnt - 1)
			if abs(first.x - last.x) > 0.005 or abs(first.z - last.z) > 0.005:
				run_anim.track_set_key_value(t, cnt - 1, Vector3(first.x, last.y, first.z))

func _build_fly_nodes() -> void:
	if _root.has_node("FlyOneShot") or not has(FLY_IDLE_ANIM):
		return
	var idle := AnimationNodeAnimation.new()
	idle.animation = StringName(FLY_IDLE_ANIM)
	_root.add_node("FlyIdle", idle, Vector2(900, 520))
	var move := AnimationNodeAnimation.new()
	move.animation = StringName(FLY_MOVE_ANIM if has(FLY_MOVE_ANIM) else FLY_IDLE_ANIM)
	_root.add_node("FlyMove", move, Vector2(900, 620))
	_root.add_node("FlyBlend", AnimationNodeBlend2.new(), Vector2(1080, 560))
	var shot := AnimationNodeOneShot.new()
	shot.filter_enabled = false
	shot.fadein_time = fly_fade
	shot.fadeout_time = fly_fade
	_root.add_node("FlyOneShot", shot, Vector2(1100, 400))
	_root.connect_node("FlyBlend", 0, "FlyIdle")
	_root.connect_node("FlyBlend", 1, "FlyMove")
	_root.disconnect_node("output", 0)
	_root.connect_node("FlyOneShot", 0, "UpperOneShot")
	_root.connect_node("FlyOneShot", 1, "FlyBlend")
	_root.connect_node("output", 0, "FlyOneShot")

func is_ready() -> bool:
	return _root != null

## Back to plain locomotion (spawn / respawn).
func reset() -> void:
	if not is_ready():
		return
	tree.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	if _root.has_node("FlyOneShot"):
		tree.set("parameters/FlyOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set("parameters/UpperScale/scale", 1.0)
	tree.set("parameters/HoldScale/scale", 1.0)
	tree.set("parameters/WalkScale/scale", walk_anim_speed)
	tree.set("parameters/WalkSpace/blend_mode", 0) # interpolated: smooth left<->right strafe
	tree.set("parameters/ground_air_transition/transition_request", "grounded")
	tree.set("parameters/iwr_blend/blend_amount", -1.0)
	_walk_blend = Vector2(0, 1)
	tree.set("parameters/WalkSpace/blend_position", _walk_blend)
	_hold_reasons.clear()
	_fly_blend = 0.0

func has(anim: String) -> bool:
	return anim_player != null and anim != "" and anim_player.has_animation(anim)

func length(anim: String) -> float:
	return anim_player.get_animation(anim).length if has(anim) else 0.0

## First existing animation from `names`, else the first one starting with `prefix`.
func find(names: Array, prefix: String = "") -> String:
	for n in names:
		if has(n):
			return n
	if prefix != "" and anim_player:
		for a in anim_player.get_animation_list():
			if String(a).to_lower().begins_with(prefix):
				return a
	return ""

# --- Actions (UpperOneShot) ---------------------------------------------------

## Plays a one-shot action. UPPER = upper body only (legs keep walking), FULL = whole body.
## Firing while another action plays restarts the shot at full weight.
func play_action(anim: String, speed: float, fadein: float, fadeout: float, mask: Mask) -> bool:
	if not is_ready() or not has(anim):
		return false
	(_root.get_node("UpperAction") as AnimationNodeAnimation).animation = StringName(anim)
	tree.set("parameters/UpperScale/scale", speed)
	_upper_shot.fadein_time = fadein
	_upper_shot.fadeout_time = fadeout
	_upper_shot.filter_enabled = mask == Mask.UPPER
	tree.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	return true

## Switch the current action between upper-body and full-body (e.g. start/stop walking).
func set_action_mask(mask: Mask) -> void:
	if is_ready():
		_upper_shot.filter_enabled = mask == Mask.UPPER

## Playback speed of the current action (near zero = hold the current frame).
func set_action_speed(speed: float) -> void:
	if is_ready():
		tree.set("parameters/UpperScale/scale", speed)

## Ends the current action: fade out normally, or cut it instantly with abort=true.
func stop_action(abort: bool = false) -> void:
	if not is_ready():
		return
	tree.set("parameters/UpperScale/scale", 1.0)
	tree.set("parameters/UpperOneShot/request",
		AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT if abort else AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)

func play_jump() -> void:
	play_action("jump_start", 1.35, 0.06, 0.08, Mask.FULL)

func play_land(power: float) -> void:
	var hard := power >= 0.65
	var anim := "Landing_hard" if hard and has("Landing_hard") else "Landing"
	play_action(anim, 1.1 if hard else 1.35, 0.06, 0.1, Mask.FULL)

# --- Hold pose (HoldOneShot) ----------------------------------------------------

## The upper-body hold pose is on while ANY reason wants it (held item, carried body).
func set_hold(reason: StringName, on: bool) -> void:
	if not is_ready() or bool(_hold_reasons.get(reason, false)) == on:
		return
	var was_on := not _hold_reasons.is_empty()
	if on:
		_hold_reasons[reason] = true
	else:
		_hold_reasons.erase(reason)
	var now_on := not _hold_reasons.is_empty()
	if now_on and not was_on and has(HOLD_ANIM):
		(_root.get_node("HoldAction") as AnimationNodeAnimation).animation = StringName(HOLD_ANIM)
		tree.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	elif was_on and not now_on:
		tree.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)

func is_holding_pose() -> bool:
	return not _hold_reasons.is_empty()

# --- Flight (FlyOneShot) --------------------------------------------------------

func set_flying(on: bool) -> void:
	if not is_ready() or not _root.has_node("FlyOneShot"):
		return
	_fly_blend = 0.0
	tree.set("parameters/FlyBlend/blend_amount", 0.0)
	tree.set("parameters/FlyOneShot/request",
		AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE if on else AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)

## Cross-blends hover (fly_1) toward sprint-flight (fly_2) without restarting either.
func update_fly_blend(sprinting: bool, delta: float) -> void:
	if not is_ready() or not _root.has_node("FlyBlend"):
		return
	var target: float = 1.0 if sprinting else 0.0
	_fly_blend = lerpf(_fly_blend, target, 1.0 - exp(-fly_blend_speed * delta))
	if abs(_fly_blend - target) < 0.002:
		_fly_blend = target
	tree.set("parameters/FlyBlend/blend_amount", _fly_blend)

# --- Locomotion -----------------------------------------------------------------

## moving: the body has velocity; running: sprinting at full run speed;
## move_input: the stick (x right, y backward) used for the 8-way walk direction.
func update_locomotion(delta: float, on_floor: bool, moving: bool, running: bool, move_input: Vector2) -> void:
	if not is_ready():
		return
	tree.set("parameters/WalkScale/scale", walk_anim_speed)
	if not on_floor:
		tree.set("parameters/ground_air_transition/transition_request", "air")
		return
	tree.set("parameters/ground_air_transition/transition_request", "grounded")
	var target: float = -1.0
	if moving:
		target = 1.0 if running else 0.0
	var w := 1.0 - exp(-locomotion_blend * delta)
	tree.set("parameters/iwr_blend/blend_amount", lerpf(tree.get("parameters/iwr_blend/blend_amount"), target, w))
	# 8-way walk: smoothed BlendSpace2D position (X strafe, Y forward positive)
	var walk_pos := Vector2(move_input.x, -move_input.y)
	var from_idle := _walk_blend.length() < 0.18 and walk_pos.length() > 0.3
	var k: float = walk_blend_smoothing_idle if from_idle else walk_blend_smoothing
	_walk_blend = _walk_blend.lerp(walk_pos, 1.0 - exp(-k * delta))
	if _walk_blend.distance_to(walk_pos) < 0.015:
		_walk_blend = walk_pos
	tree.set("parameters/WalkSpace/blend_position", _walk_blend)
