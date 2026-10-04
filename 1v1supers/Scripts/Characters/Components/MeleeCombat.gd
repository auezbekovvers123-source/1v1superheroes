extends Node
class_name MeleeCombat
## The punch/kick combo: per-swing data, the two hitboxes, and target finding.
## AttackState drives the timing; this node owns the numbers and the hitboxes.

signal hit_landed(target: Node3D, hit: HitInfo)

# Combo (LMB): right hook > left punch > right cross > spinning kick.
# Hit windows sit around the middle of each clip, where the fist/foot is extended.
const COMBO_ANIMS: Array[String] = ["punch_hook", "punch_left_simple1", "punch_cross", "kick_spin"]
const COMBO_DAMAGE: Array[float] = [11.0, 9.0, 17.0, 24.0]
const COMBO_HIT_START: Array[float] = [0.28, 0.16, 0.21, 0.40] # seconds after the swing starts
const COMBO_HIT_END: Array[float] = [0.43, 0.25, 0.32, 0.66]
const COMBO_LUNGE: Array[float] = [2.2, 1.7, 3.0, 3.8] # forward impulse
const COMBO_HITSTOP: Array[float] = [0.055, 0.045, 0.085, 0.12]
const COMBO_SHAKE: Array[float] = [0.28, 0.22, 0.42, 0.68]
const COMBO_KNOCKBACK: Array[float] = [2.3, 1.6, 4.0, 6.0]
const COMBO_DAMAGE_RAMP: float = 0.08 # each later swing in the chain hits 8% harder
const PUNCH_SPEED: float = 2.7 # animation speed for punches
const KICK_SPEED: float = 1.35 # animation speed for the kick
const BLEND: float = 0.12
const RESET_TIME: float = 1.2 # combo counter resets this long after the last swing

@export var attack_lunge_decay: float = 8.0
@export var hit_punch_scale: float = 0.14 # attacker "pop" on a landed hit
@export var target_snap_angle: float = 180.0 # degrees: any target within range snaps
@export var aim_snap_angle: float = 45.0 # degrees: cone around the crosshair while aiming
@export var target_snap_range: float = 8.0

var hitbox_main: Hitbox3D
var hitbox_kick: Hitbox3D
var debug_visible: bool = false

## Combo progress, read by the HUD.
var combo_index: int = 0
var combo_reset_timer: float = 0.0
var has_hit_this_swing: bool = false

var _body: CharacterBody3D

func setup(body: CharacterBody3D) -> void:
	_body = body
	hitbox_main = _make_hitbox("Hitbox_Main", 0.62, Color(1, 0.2, 0.2, 0.18), Vector3(0, 1.02, 1.0))
	hitbox_kick = _make_hitbox("Hitbox_Kick", 0.68, Color(0.2, 0.6, 1, 0.18), Vector3(0, 0.45, 1.1))

func _make_hitbox(box_name: String, radius: float, color: Color, pos: Vector3) -> Hitbox3D:
	var hb := Hitbox3D.new()
	hb.name = box_name
	hb.owner_body = _body
	hb.setup_sphere(radius, color)
	_body.add_child(hb)
	hb.position = pos
	hb.hit_landed.connect(func(target, hit): hit_landed.emit(target, hit))
	return hb

func is_kick(idx: int) -> bool:
	return idx == COMBO_ANIMS.size() - 1

func last_index() -> int:
	return COMBO_ANIMS.size() - 1

func anim_speed(idx: int) -> float:
	return KICK_SPEED if is_kick(idx) else PUNCH_SPEED

func damage(idx: int) -> float:
	return COMBO_DAMAGE[idx] * (1.0 + idx * COMBO_DAMAGE_RAMP)

func box_for(idx: int) -> Hitbox3D:
	return hitbox_kick if is_kick(idx) else hitbox_main

## Opens the hit window of swing `idx` for its configured duration.
func open_window(idx: int) -> void:
	var kind := HitInfo.Kind.KICK if is_kick(idx) else HitInfo.Kind.PUNCH
	var template := HitInfo.make(damage(idx), _body, Vector3.ZERO, kind, COMBO_HITSTOP[idx], COMBO_SHAKE[idx])
	box_for(idx).activate(template, COMBO_KNOCKBACK[idx], COMBO_HIT_END[idx] - COMBO_HIT_START[idx])
	_set_debug(idx, true)

func close_window() -> void:
	hitbox_main.deactivate()
	hitbox_kick.deactivate()
	_set_debug(-1, false)

func toggle_debug() -> void:
	debug_visible = not debug_visible
	if not debug_visible:
		_set_debug(-1, false)

func _set_debug(idx: int, on: bool) -> void:
	hitbox_main.debug_mesh.visible = on and debug_visible and not is_kick(idx)
	hitbox_kick.debug_mesh.visible = on and debug_visible and is_kick(idx)

## Keeps the hitboxes in front of the character's visual facing. The body itself
## never rotates (only the Mesh does), so these local offsets are world offsets.
func update_hitbox_transforms(mesh: Node3D, attacking: bool) -> void:
	var fwd: Vector3 = mesh.global_basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
	var right: Vector3 = -mesh.global_basis.x
	right.y = 0
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	var side: float = 0.0 # hook comes from the right, the left punch from the left
	if attacking:
		if combo_index == 0:
			side = 0.28
		elif combo_index == 1:
			side = -0.25
	var main_off: Vector3 = fwd * 0.72 + right * side
	hitbox_main.position = Vector3(main_off.x, 1.02, main_off.z)
	var kick_off: Vector3 = fwd * 0.88
	hitbox_kick.position = Vector3(kick_off.x, 0.42, kick_off.z)

## The fighter closest to `aim_dir` (smallest angle, then nearest) within range and cone.
func find_target(aim_dir: Vector3, cone_deg: float) -> Node3D:
	var best: Node3D = null
	var best_ang: float = cone_deg
	var best_dist: float = INF
	for n in _body.get_tree().get_nodes_in_group("fighter"):
		var body := n as Node3D
		if body == null or body == _body:
			continue
		var to: Vector3 = body.global_position - _body.global_position
		var dist: float = to.length()
		if dist > target_snap_range or dist < 0.4:
			continue
		to.y = 0
		if to.length() < 0.01:
			continue
		var ang: float = rad_to_deg(aim_dir.angle_to(to.normalized()))
		if ang > cone_deg:
			continue
		if ang < best_ang - 0.01 or (abs(ang - best_ang) < 0.01 and dist < best_dist):
			best_ang = ang
			best_dist = dist
			best = body
	return best
