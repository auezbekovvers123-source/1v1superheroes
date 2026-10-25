extends PlayerInput
class_name AIPlayerInput
## A computer-controlled fighter. It drives an ordinary Player through the same
## Intent a keyboard fills, so it moves, fights and uses powers by the same
## rules as you. Each frame it:
##  - picks a target (the nearest other fighter that is alive),
##  - defends: blocks, sometimes parries or dodges an attack it sees coming,
##    blocks a laser aimed at it,
##  - collects gear lying around when nobody is close,
##  - attacks with whatever its gear gives: punch combos (circling a raised
##    guard), speed punches, laser bursts (also from the air), flying above the
##    target and ground-slamming it.
## Skill is set with the exports; rng_seed makes a fight repeatable.

@export_group("Skill")
@export_range(0.0, 1.0) var block_chance: float = 0.5 ## share of attacks it blocks
@export_range(0.0, 1.0) var parry_chance: float = 0.15 ## share it tries to parry (times the guard late, in the window)
@export_range(0.0, 1.0) var dodge_chance: float = 0.15 ## share it dodges with a sideways dash
@export_range(0.0, 1.0) var aggression: float = 0.7 ## chance to keep a combo going, and to start attacks
## Seconds from seeing a swing to raising the guard or dodging. Keep it short:
## a guard raised within 0.15 s of the hit is a parry, later it is too late.
@export_range(0.0, 0.3) var reaction_time: float = 0.03
@export var seek_gear: bool = true ## picks up wearable gear lying around
@export var wake_delay: float = 1.0 ## idle seconds after (re)spawning
@export var rng_seed: int = 0 ## 0 = different every game

const MELEE_RANGE := 1.45
const SPEED_PUNCH_RANGE := 2.6
const LASER_RANGE := Vector2(3.5, 22.0)
const SLAM_HEIGHT := 3.5 # how high it flies before slamming
const GEAR_RANGE := 25.0
const FIGHT_RANGE := 7.0 # closer than this, fighting comes before gear
const PARRY_DELAY := 0.2 # after the attacker's swing starts (the first hit lands ~0.28 s in)

var fighter: Player
var target: Player

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _awake_at: float = 0.0
# Defence
var _seen_swing: bool = false
var _react_at: float = -1.0
var _react: StringName = &""
var _block_until: float = 0.0
# Offence
var _next_press: float = 0.0
var _circle_until: float = 0.0
var _circle_side: float = 1.0
var _retreat_until: float = 0.0
var _laser_until: float = 0.0
var _laser_fire_at: float = 0.0
var _next_laser: float = 0.0
var _air_plan: StringName = &"" # "slam" or "chase" while flying
var _air_plan_until: float = 0.0
var _next_takeoff: float = 0.0
# Getting around
var _stuck_time: float = 0.0
var _detour_until: float = 0.0
var _detour_side: float = 1.0
var _last_state: StringName = &""

func _ready() -> void:
	fighter = get_parent() as Player
	if rng_seed != 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()
	_awake_at = wake_delay

## What it is doing right now, for debugging and tests.
func activity() -> StringName:
	if fighter == null or fighter.is_dead() or _t < _awake_at:
		return &"idle"
	if fighter.state.name == &"laser" or _t < _laser_until:
		return &"laser"
	if _air_plan != &"":
		return _air_plan
	if _t < _block_until:
		return &"block"
	return &"fight" if target else &"roam"

func _read(i: Intent) -> void:
	_t += 1.0 / Engine.physics_ticks_per_second
	if fighter == null or not fighter.is_node_ready():
		return
	if fighter.is_dead():
		_awake_at = _t + wake_delay # catch breath after the respawn
		_reset_plans()
		return
	if _t < _awake_at:
		return
	if fighter.held_item:
		i.throw_pressed = true # not a fighter's item: drop it (a tap drops)
		i.throw_held = true
		return
	target = _pick_target()
	i.has_view = true
	if target == null:
		_roam(i)
		return
	var me := fighter.global_position
	var flat := Vector3(target.global_position.x - me.x, 0.0, target.global_position.z - me.z)
	var dist := flat.length()
	var dir := flat / dist if dist > 0.01 else fighter.mesh.global_basis.z
	_look(i, dir)
	i.aim_point = target.global_position + Vector3(0, 1.2, 0)

	if _defend(i, dist):
		return
	if _keep_lasering(i, dist):
		return
	if fighter.is_flying():
		_fly(i, dist, dir)
		return
	if fighter.state.name == &"slam":
		return
	var gear := _wanted_gear() if dist > FIGHT_RANGE else null
	if gear:
		_go_to(i, gear.global_position, true)
		if hdist(gear.global_position, me) < 1.0:
			i.interact_pressed = true
		return
	if _start_laser(i, dist):
		return
	if _maybe_take_off(i, dist):
		return
	_ground_fight(i, dist, dir)

# --- Targets and gear -----------------------------------------------------------

## The nearest fighter on the other side that is alive (villains don't fight each other).
func _pick_target() -> Player:
	var villain := fighter.is_in_group("enemy")
	var best: Player = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("player"):
		var p := n as Player
		if p == null or p == fighter or p.is_dead() or p.is_queued_for_deletion() or p.is_in_group("enemy") == villain:
			continue
		var d := fighter.global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best

## The nearest gear lying around that it can wear (its slot is free).
func _wanted_gear() -> ItemPickup:
	if not seek_gear:
		return null
	var best: ItemPickup = null
	var best_d := GEAR_RANGE
	for n in get_tree().get_nodes_in_group("pickup"):
		var p := n as ItemPickup
		if p == null or not p.is_pickable():
			continue
		var data := p.get_item_data()
		if data.scene == null or data.slot == ItemData.EquipSlot.NONE or data.slot == ItemData.EquipSlot.HAND \
				or fighter.equipment.has_equipped(data.slot):
			continue
		var d := hdist(p.global_position, fighter.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best

func _roam(i: Intent) -> void:
	var gear := _wanted_gear()
	if gear:
		_go_to(i, gear.global_position, true)
		if hdist(gear.global_position, fighter.global_position) < 1.0:
			i.interact_pressed = true
	elif fighter.is_flying():
		i.power_pressed = true # nobody to fight: land

# --- Defence --------------------------------------------------------------------

## Blocks, parries and dodges. Returns true while holding the guard (nothing else this frame).
func _defend(i: Intent, dist: float) -> bool:
	var swinging := target.state.name == &"attack" and dist < 2.8 and _faces_me(target)
	if swinging and not _seen_swing:
		_seen_swing = true
		var r := _rng.randf()
		if r < parry_chance:
			_react = &"parry"
			_react_at = _t + PARRY_DELAY
		elif r < parry_chance + block_chance:
			_react = &"block"
			_react_at = _t + reaction_time * _rng.randf_range(0.5, 1.5)
		elif r < parry_chance + block_chance + dodge_chance:
			_react = &"dodge"
			_react_at = _t + reaction_time * _rng.randf_range(0.5, 1.5)
		else:
			_react = &""
	elif not swinging:
		_seen_swing = false
	if _react != &"" and _t >= _react_at and fighter.state.name in [&"free", &"block", &"attack"]:
		var dodge := _react == &"dodge"
		_react = &""
		if dodge:
			i.move = Vector2(1.0 if _rng.randf() < 0.5 else -1.0, 0.3).normalized() # sideways and a bit back
			i.dash_pressed = true
			return true
		_block_until = _t + 0.45
	# A laser aimed at us: soak it on the guard when close, else sidestep
	if target.state.name == &"laser" and _beam_on_me():
		if dist < 9.0:
			_block_until = maxf(_block_until, _t + 0.3)
		else:
			i.move = Vector2(_circle_side, 0)
			i.run = true
			return true
	if _t < _block_until and not fighter.is_flying():
		if swinging:
			_block_until = maxf(_block_until, _t + 0.2) # hold it through the combo
		i.block_held = true
		return true
	return false

func _faces_me(other: Player) -> bool:
	var to_me := fighter.global_position - other.global_position
	to_me.y = 0
	var fwd := other.mesh.global_basis.z
	fwd.y = 0
	return to_me.length() < 0.01 or fwd.normalized().dot(to_me.normalized()) > 0.4

func _beam_on_me() -> bool:
	var aim := target.aim_point() - target.global_position
	var to_me := fighter.global_position + Vector3(0, 1.0, 0) - target.global_position
	return aim.length() > 0.1 and rad_to_deg(aim.angle_to(to_me)) < 10.0

# --- Laser ----------------------------------------------------------------------

func _has_laser() -> bool:
	return fighter.powers.has("laser")

func _start_laser(i: Intent, dist: float) -> bool:
	if not _has_laser() or _t < _next_laser or dist < LASER_RANGE.x or dist > LASER_RANGE.y \
			or fighter.stamina.value < 45.0 or not _can_see_target() or _rng.randf() > aggression * 0.08:
		return false
	_laser_fire_at = _t + 0.2 # aim first, then fire
	_laser_until = _t + _rng.randf_range(0.8, 1.6)
	i.aim_held = true
	return true

## Holds aim (and fire) for the laser burst in progress. Returns true while busy.
func _keep_lasering(i: Intent, dist: float) -> bool:
	if _t >= _laser_until:
		return false
	if dist < 2.0 or not _can_see_target():
		_laser_until = 0.0 # too close for a beam, or lost sight: stop
		_next_laser = _t + 1.5
		return false
	i.aim_held = true
	i.attack_held = _t >= _laser_fire_at
	if fighter.is_flying() or (fighter.state.name == &"laser" and not fighter.is_on_floor()):
		_hold_altitude(i, target.global_position.y + SLAM_HEIGHT)
	if _t + 1.0 / Engine.physics_ticks_per_second >= _laser_until:
		_next_laser = _t + _rng.randf_range(2.5, 5.0)
	return true

func _can_see_target() -> bool:
	var eyes := fighter.global_position + Vector3(0, 1.8, 0)
	var q := PhysicsRayQueryParameters3D.create(eyes, target.global_position + Vector3(0, 1.2, 0), 1)
	q.exclude = [fighter.get_rid()]
	var hit := fighter.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == target

# --- Flight and slams -----------------------------------------------------------

func _maybe_take_off(i: Intent, dist: float) -> bool:
	if not fighter.powers.has("fly") or _t < _next_takeoff or fighter.state.name != &"free":
		return false
	var plan := &""
	if target.is_flying() and target.global_position.y > fighter.global_position.y + 2.0:
		plan = &"chase"
	elif dist > 3.0 and dist < 14.0 and _rng.randf() < aggression * 0.015:
		plan = &"slam"
	if plan == &"":
		return false
	_air_plan = plan
	_air_plan_until = _t + 7.0
	_next_takeoff = _t + _rng.randf_range(4.0, 8.0)
	i.power_pressed = true
	return true

func _fly(i: Intent, dist: float, dir: Vector3) -> void:
	if _air_plan == &"":
		_air_plan = &"chase" if target.is_flying() else &"slam"
		_air_plan_until = _t + 7.0
	if _t > _air_plan_until:
		_air_plan = &""
		i.power_pressed = true # give up and land
		return
	if _start_laser(i, dist):
		return
	if _air_plan == &"chase":
		if not target.is_flying():
			_air_plan = &"slam"
		_steer(i, dir, dist > 2.0, dist > 8.0)
		_hold_altitude(i, target.global_position.y)
		return
	# Slam: get above the target, then dive
	var above := dist < 1.1
	if above and fighter.height_above_ground() >= SLAM_HEIGHT - 1.0:
		i.attack_pressed = true
		_air_plan = &""
		return
	_steer(i, dir, not above, dist > 6.0)
	if dist < 3.0:
		i.move *= clampf(dist / 3.0, 0.25, 1.0) # ease in so it stops over the target
	_hold_altitude(i, target.global_position.y + SLAM_HEIGHT)

func _hold_altitude(i: Intent, y: float) -> void:
	var dy := y - fighter.global_position.y
	i.jump_held = dy > 0.4
	i.fly_down_held = dy < -0.4

# --- On the ground --------------------------------------------------------------

func _ground_fight(i: Intent, dist: float, dir: Vector3) -> void:
	var state := fighter.state.name
	# Breathers after a full combo, or when out of stamina
	if state == &"free" and _last_state == &"attack" and fighter.combat.combo_index == 0 and _rng.randf() < 0.4:
		_retreat_until = _t + _rng.randf_range(0.3, 0.7)
	_last_state = state
	if fighter.stamina.value < 15.0 and dist < 3.0:
		_retreat_until = maxf(_retreat_until, _t + 0.5)
	if _t < _retreat_until:
		i.move = Vector2(_circle_side * 0.4, 1.0).normalized() # back off, a little sideways
		return
	var fast := fighter.powers.has("speed")
	# Speed punch: sprint in and swing while still at full speed
	if fast and dist > MELEE_RANGE and dist < 14.0 and fighter.stamina.value > 25.0:
		_steer(i, dir, true, true)
		var speed := Vector2(fighter.velocity.x, fighter.velocity.z).length()
		if dist < SPEED_PUNCH_RANGE and speed >= SuperSpeedPower.SPEED_PUNCH_MIN and state == &"free":
			i.attack_pressed = true
		return
	if dist > MELEE_RANGE:
		_steer(i, dir, true, dist > 4.0)
		return
	# In reach. A raised guard facing us: go round it (hits from behind ignore it)
	if target.state.name == &"block" and _faces_me(target):
		if _t >= _circle_until:
			_circle_until = _t + _rng.randf_range(0.5, 0.9)
			_circle_side = 1.0 if _rng.randf() < 0.5 else -1.0
		i.move = Vector2(_circle_side, -0.15)
		i.run = true
		return
	if state == &"free" and _t >= _next_press and _rng.randf() < aggression:
		i.attack_pressed = true
		_next_press = _t + 0.15
	elif state == &"attack" and _t >= _next_press and fighter.combat.combo_index < fighter.combat.last_index():
		_next_press = _t + 0.25 # one press per swing queues the next
		i.attack_pressed = _rng.randf() < aggression

## Moves along `dir` (world, flat), going round whatever it is stuck on.
func _steer(i: Intent, dir: Vector3, moving: bool, run: bool) -> void:
	if not moving:
		return
	var want := dir
	if _t < _detour_until:
		want = (dir + dir.cross(Vector3.UP) * _detour_side * 1.5).normalized()
	i.move = _stick(i, want)
	i.run = run
	var speed := Vector2(fighter.velocity.x, fighter.velocity.z).length()
	_stuck_time = _stuck_time + 1.0 / Engine.physics_ticks_per_second if speed < 0.6 else 0.0
	if _stuck_time > 0.5 and fighter.state.name == &"free":
		_stuck_time = 0.0
		_detour_until = _t + 0.9
		_detour_side = 1.0 if _rng.randf() < 0.5 else -1.0
		i.jump_pressed = true
		i.jump_held = true

func _go_to(i: Intent, where: Vector3, run: bool) -> void:
	var flat := Vector3(where.x - fighter.global_position.x, 0, where.z - fighter.global_position.z)
	if flat.length() < 0.05:
		return
	var dir := flat.normalized()
	_look(i, dir)
	_steer(i, dir, true, run and flat.length() > 3.0)

## Turns the "camera" to look along `dir`: the body faces it and the stick is read relative to it.
func _look(i: Intent, dir: Vector3) -> void:
	i.has_view = true
	i.view_yaw = atan2(-dir.x, -dir.z)
	i.aim_point = fighter.global_position + dir * 10.0 + Vector3(0, 1.2, 0)

## The stick that moves along world direction `dir` with this frame's view.
static func _stick(i: Intent, dir: Vector3) -> Vector2:
	var local := dir.rotated(Vector3.UP, -i.view_yaw)
	return Vector2(local.x, local.z).limit_length(1.0)

func _reset_plans() -> void:
	_air_plan = &""
	_laser_until = 0.0
	_block_until = 0.0
	_retreat_until = 0.0
	_react = &""

static func hdist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
