extends CharacterBody3D
class_name Player
## Third-person superhero fighter.
##
## How it is put together — each part owns one job:
##  - Input (PlayerInput child): WHAT the fighter wants this frame. Swap the node
##    to change who controls it: LocalPlayerInput (keyboard/mouse/pad),
##    ScriptedPlayerInput (tests, AI, network). Nothing else reads Input.
##  - State machine (Scripts/Characters/States): WHAT the fighter is doing.
##    Exactly one state at a time — Free, Attack, Dash, Turn, Gesture,
##    ThrowCharge, UseItem, Fly, Dead — and the state decides what is allowed.
##  - Locomotion (this file): walking, running, gravity, jumping, facing.
##  - Components (children): Stamina, Footsteps, MeleeCombat, HandHold,
##    PlayerAnimator, Health, Hurtbox3D, RagdollController, RagdollGrabber,
##    Inventory, Equipment.

signal state_changed(from: StringName, to: StringName)
signal respawned()
## A world item (ItemPickup / ThrownItem) went into this fighter's hand.
signal picked_from_world(item: Node3D)

@export_group("Movement")
@export var walk_speed: float = 2.1
@export var run_speed: float = 5.0
@export var carry_speed_scale: float = 0.68 # walking while carrying a ragdoll
@export var jump_strength: float = 15.0
@export var gravity: float = 50.0

@export_group("Dash")
@export var dash_speed: float = 9.34 # burst velocity
@export var dash_duration: float = 0.22 # burst length
@export var dash_recovery: float = 0.18 # slowdown after the burst before full control returns
@export var dash_recovery_speed_start: float = 0.9 # fraction of dash_speed when recovery begins
@export var dash_recovery_speed_end: float = 0.72 # fraction of dash_speed when recovery ends
@export var dash_recovery_steer: float = 0.15 # how much movement input steers during recovery
@export var dash_anim_speed_scale: float = 1.6
@export var dash_cancel_attack_window: float = 0.55 # a swing younger than this can be cancelled by a dash

@export_group("Jump Feel")
@export var coyote_time: float = 0.14
@export var jump_buffer_time: float = 0.14
@export var jump_cut_multiplier: float = 0.45 # releasing jump early cuts the rise
@export var fall_gravity_multiplier: float = 1.6
@export var rising_no_hold_gravity_multiplier: float = 1.8 # rising without holding jump
@export var jump_horizontal_boost: float = 0.6

@export_group("Rotation")
@export var sprint_rotation_speed: float = 22.0
@export var strafe_rotation_speed: float = 32.0
@export var instant_strafe_lock: bool = false

@export_group("Smoothing (exponential rates)")
@export var ground_accel_rate: float = 12.0
@export var air_accel_rate: float = 4.0
@export var dash_enter_rate: float = 20.0
@export var attack_stop_rate: float = 10.0
@export var stun_stop_rate: float = 8.0
@export var snap_turn_rate: float = 16.0

@export_group("Turn In Place")
@export var turn_enabled: bool = true
@export var turn_threshold_deg: float = 90.0 # camera yaw change (idle) that triggers a turn
@export var turn_only_when_idle: bool = true
@export var turn_anim_speed: float = 1.8
@export var turn_rotation_duration: float = 0.16 # fallback mesh turn when a rig has no turn clips
@export var turn_cooldown: float = 0.02

@export_group("Flight (cape power)")
@export var fly_cruise_speed: float = 6.0
@export var fly_sprint_speed: float = 11.0
@export var fly_vertical_speed: float = 4.0
@export var fly_vertical_sprint_mult: float = 1.5
@export var fly_accel: float = 8.0
@export var fly_tilt_deg: float = 80.0 # forward pitch while sprint-flying (superman)
@export var fly_cruise_lean_deg: float = 14.0
@export var fly_sprint_vertical_slant_deg: float = 30.0
@export var fly_tilt_speed: float = 5.0

@export_group("Respawn")
@export var respawn_delay: float = 2.8 # seconds after death (the ragdoll flops meanwhile)
@export var respawn_height: float = 0.5 # respawn this far above the start position

## Mesh faces +Z and is rotated PI: mesh yaw = camera yaw + PI faces away from the camera.
const YAW_OFFSET: float = PI
const TURN_ROOT_BONE: String = "root.x"
const TURN_ROOT_TRACK: String = "root/Skeleton3D:root.x"

@onready var mesh: Node3D = $Mesh
@onready var camera_rig: SpringArmPivot = $SpringArmPivot
@onready var aim_camera: Camera3D = $SpringArmPivot/SpringArm3D/CameraHolder/Camera3D

var input: PlayerInput
var animator: PlayerAnimator
var stamina: Stamina
var footsteps: Footsteps
var combat: MeleeCombat
var hand: HandHold
var health: Health
var hurtbox: Hurtbox3D
var ragdoll: RagdollController
var grabber: RagdollGrabber
var inventory: Inventory
var equipment: Equipment

var state: PlayerState
var _states: Dictionary = {}

# Shared per-frame values (read by the states)
var intent: PlayerInput.Intent
var move_direction := Vector3.ZERO # world direction from the stick, camera-relative
var is_aiming: bool = false
var is_sprinting: bool = false
var stun_timer: float = 0.0
var dash_recovery_timer: float = 0.0
var dash_direction := Vector3.ZERO
var turn_cooldown_timer: float = 0.0

var _locomotion_speed: float = 0.0
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _was_on_floor: bool = false
var _prev_fall_velocity: float = 0.0
var _last_turn_cam_yaw: float = 0.0
var _turn_reference_set: bool = false
var _spawn_point := Vector3.ZERO
var _skeleton: Skeleton3D = null
var _upper_twist: UpperBodyTwist = null
var _upper_look_angle: float = 0.0
var _upper_look_weight: float = 0.0
var _tilt_tween: Tween = null
var _scale_tween: Tween = null # one squash/stretch effect at a time
var _aim_frame: int = -1
var _aim_dir_cached := Vector3.FORWARD

func _ready() -> void:
	add_to_group("player")
	add_to_group("fighter")
	collision_layer = 1
	collision_mask = 1
	_spawn_point = global_position + Vector3.UP * respawn_height
	_setup_components()
	_states = {
		&"free": FreeState.new(self, &"free"),
		&"attack": AttackState.new(self, &"attack"),
		&"dash": DashState.new(self, &"dash"),
		&"turn": TurnState.new(self, &"turn"),
		&"gesture": GestureState.new(self, &"gesture"),
		&"throw_charge": ThrowChargeState.new(self, &"throw_charge"),
		&"use_item": UseItemState.new(self, &"use_item"),
		&"fly": FlyState.new(self, &"fly"),
		&"dead": DeadState.new(self, &"dead"),
	}
	state = _states[&"free"]
	intent = input.current()
	_apply_input_ownership()

func _setup_components() -> void:
	input = _child("Input", func(): return LocalPlayerInput.new())
	health = _child("Health", func():
		var h := Health.new()
		h.max_health = 100.0
		h.invuln_time = 0.08
		return h)
	hurtbox = _child("Hurtbox3D", func(): return Hurtbox3D.new())
	hurtbox.position = Vector3(0, 0.92, 0)
	ragdoll = _child("RagdollController", func():
		var r := RagdollController.new()
		r.death_impulse = 7.5
		return r)
	grabber = _child("RagdollGrabber", func():
		var g := RagdollGrabber.new()
		g.grab_radius = 2.8
		g.grab_bone_radius = 1.6
		return g)
	inventory = _child("Inventory", func(): return Inventory.new())
	equipment = _child("Equipment", func(): return Equipment.new())
	stamina = _child("Stamina", func(): return Stamina.new())
	footsteps = _child("Footsteps", func(): return Footsteps.new())
	footsteps.walk_speed = walk_speed
	footsteps.run_speed = run_speed
	footsteps.dash_speed = dash_speed
	animator = _child("Animator", func(): return PlayerAnimator.new())
	animator.setup(get_node_or_null("AnimationTree") as AnimationTree,
		RagdollController._find_first(mesh, "AnimationPlayer") as AnimationPlayer)
	hand = _child("HandHold", func(): return HandHold.new())
	hand.setup(self, inventory)
	combat = _child("MeleeCombat", func(): return MeleeCombat.new())
	combat.setup(self)
	combat.hit_landed.connect(_on_hit_landed)
	ragdoll.about_to_start.connect(reset_mesh_scale)
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)

## Returns the child called `node_name`, creating it with `make` when the scene lacks it.
func _child(node_name: String, make: Callable) -> Node:
	var n := get_node_or_null(node_name)
	if n == null:
		n = make.call()
		n.name = node_name
		add_child(n)
	return n

## Replace who controls this fighter (keyboard, AI, network, tests).
func set_input(source: PlayerInput) -> void:
	if input and input != source:
		remove_child(input)
		input.queue_free()
	input = source
	source.name = "Input"
	if source.get_parent() == null:
		add_child(source)
	intent = input.current()
	_apply_input_ownership()

## Only a local human gets the camera and the mouse.
func _apply_input_ownership() -> void:
	var local := input.is_local_human()
	camera_rig.set_local(local)
	if local:
		add_to_group("local_player")
	elif is_in_group("local_player"):
		remove_from_group("local_player")

# --- State machine -------------------------------------------------------------

func change_state(to: StringName, args: Dictionary = {}) -> void:
	var from: StringName = state.name
	state.exit()
	state = _states[to]
	state.enter(args)
	state_changed.emit(from, to)

## Switches only if the target state accepts (its can_enter). Returns whether it did.
func try_change_state(to: StringName, args: Dictionary = {}) -> bool:
	if not _states[to].can_enter(args):
		return false
	change_state(to, args)
	return true

func is_attacking() -> bool:
	return state.name == &"attack"

func is_flying() -> bool:
	return state.name == &"fly"

func is_dead() -> bool:
	return state.name == &"dead"

## True when this fighter is a copy of one controlled on another machine (online).
func is_remote() -> bool:
	return input != null and input.is_remote()

# --- Frame ---------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	intent = input.poll()
	move_direction = Vector3(intent.move.x, 0, intent.move.y).rotated(Vector3.UP, camera_yaw())
	if intent.debug_hitbox_pressed:
		combat.toggle_debug()
	animator.set_hold(&"carry", grabber.is_grabbing())
	if intent.power_pressed:
		_toggle_power()
	state.handle_intent(intent)
	_update_aim()
	# Timers tick after this frame's actions started (a dash's recovery counts from its first frame)
	_tick_timers(delta)
	state.physics_update(delta)
	if state.name != &"free":
		_reset_turn_reference()
	if state.overrides_movement():
		state.move(delta)
	else:
		_locomotion(delta)
	combat.update_hitbox_transforms(mesh, is_attacking())

func _tick_timers(delta: float) -> void:
	stun_timer = maxf(stun_timer - delta, 0.0)
	dash_recovery_timer = maxf(dash_recovery_timer - delta, 0.0)
	turn_cooldown_timer = maxf(turn_cooldown_timer - delta, 0.0)
	if not is_attacking() and combat.combo_reset_timer > 0.0:
		combat.combo_reset_timer -= delta
		if combat.combo_reset_timer <= 0.0:
			combat.combo_reset_timer = 0.0
			combat.combo_index = 0

func _update_aim() -> void:
	var aim := intent.aim_held and state.can_aim()
	if aim != is_aiming:
		is_aiming = aim
		camera_rig.set_aiming(aim)

# --- Locomotion ----------------------------------------------------------------

func _locomotion(delta: float) -> void:
	var on_floor := is_on_floor()
	var carrying := is_carrying_body()
	is_sprinting = intent.run and state.allows_sprint() and not carrying and stun_timer <= 0.0 and not is_aiming
	if is_sprinting and not is_attacking() and on_floor and move_direction.length() > 0.1:
		stamina.use(stamina.run_drain_per_sec * delta)
	stamina.tick(delta)
	var speed: float = run_speed if is_sprinting else walk_speed
	if carrying:
		# Carrying a body locks to the 8-way walk (the run clip has no strafes);
		# holding run just hurries the walk instead of slowing it.
		var hustle := intent.run and stun_timer <= 0.0 and not is_aiming
		speed = walk_speed if hustle else walk_speed * carry_speed_scale
	speed *= state.move_speed_scale()
	_locomotion_speed = speed

	# Coyote time + jump buffer + gravity (heavier when falling or not holding jump)
	_coyote_timer = coyote_time if on_floor else _coyote_timer - delta
	_jump_buffer_timer = jump_buffer_time if intent.jump_pressed else _jump_buffer_timer - delta
	var grav_mult := 1.0
	if velocity.y < 0.0:
		grav_mult = fall_gravity_multiplier
	elif velocity.y > 0.0 and not intent.jump_held:
		grav_mult = rising_no_hold_gravity_multiplier
	velocity.y -= gravity * grav_mult * delta

	# Horizontal: the state may own it (dash, planted gestures); else dash recovery
	# or normal acceleration toward the stick.
	var stun_mult: float = 0.08 if stun_timer > 0.0 else 1.0
	var target := Vector2(move_direction.x, move_direction.z) * speed * stun_mult
	if not state.set_horizontal_velocity(delta, target):
		if dash_recovery_timer > 0.0:
			var t: float = clampf(1.0 - dash_recovery_timer / maxf(dash_recovery, 0.001), 0.0, 1.0)
			var rec_speed: float = dash_speed * lerpf(dash_recovery_speed_start, dash_recovery_speed_end, t)
			velocity.x = dash_direction.x * rec_speed + target.x * dash_recovery_steer
			velocity.z = dash_direction.z * rec_speed + target.y * dash_recovery_steer
		else:
			var rate: float = ground_accel_rate if on_floor else air_accel_rate
			velocity.x = smooth(velocity.x, target.x, rate, delta)
			velocity.z = smooth(velocity.z, target.y, rate, delta)
	state.after_velocity(delta)
	if stun_timer > 0.0:
		velocity.x = smooth(velocity.x, 0.0, stun_stop_rate, delta)
		velocity.z = smooth(velocity.z, 0.0, stun_stop_rate, delta)

	if not state.update_facing(delta):
		_face_default(delta)

	# Jump / land
	var just_landed := on_floor and not _was_on_floor
	var can_jump := _coyote_timer > 0.0 and _jump_buffer_timer > 0.0 and state.allows_jump() \
		and not hand.blocks(&"jump") and stun_timer <= 0.0
	if intent.jump_released and velocity.y > 2.0:
		velocity.y *= jump_cut_multiplier
	if can_jump:
		velocity.y = jump_strength
		if move_direction.length() > 0.1:
			velocity.x += move_direction.x * jump_horizontal_boost
			velocity.z += move_direction.z * jump_horizontal_boost
		_coyote_timer = 0.0
		_jump_buffer_timer = 0.0
		on_floor = false
		_squash(Vector3(0.88, 1.18, 0.88), 0.0, 0.12)
		if state.allows_air_anims():
			animator.play_jump()
	elif just_landed:
		var land_power: float = clampf(abs(_prev_fall_velocity) / 18.0, 0.0, 1.0)
		if land_power > 0.15:
			var w: float = 1.15 + land_power * 0.15
			_squash(Vector3(w, 0.88 - land_power * 0.08, w), 0.13 * 0.35, 0.13 * 0.65)
			camera_shake(land_power * 0.35)
			if state.allows_air_anims():
				animator.play_land(land_power)
	_prev_fall_velocity = velocity.y
	_was_on_floor = on_floor
	apply_floor_snap()
	move_and_slide()

	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var gait := Footsteps.Gait.WALK
	if state.name == &"dash":
		gait = Footsteps.Gait.DASH
	elif horiz_speed >= run_speed * 0.95 and intent.run:
		gait = Footsteps.Gait.RUN
	footsteps.update_steps(delta, is_on_floor(), horiz_speed, gait, state.suppresses_footsteps())
	camera_rig.run_fov_active = is_on_floor() and intent.run and horiz_speed > 0.6 and not is_attacking() and not carrying
	var running := is_equal_approx(_locomotion_speed, run_speed) and intent.run and not carrying
	animator.update_locomotion(delta, is_on_floor(), velocity.length() > 0.1, running, intent.move)

## Called by FlyState when flight ends on touchdown (no landing squash/anim).
func note_landed_from_flight() -> void:
	_was_on_floor = true
	_prev_fall_velocity = 0.0

func note_airborne(vertical_velocity: float) -> void:
	_was_on_floor = false
	_prev_fall_velocity = vertical_velocity

# --- Facing --------------------------------------------------------------------

func _face_default(delta: float) -> void:
	clear_upper_twist(delta)
	var has_input := move_direction.length() > 0.1
	if is_aiming:
		var aim := aim_direction_from_camera()
		face_yaw(atan2(aim.x, aim.z), strafe_rotation_speed, delta)
	elif is_sprinting_now() and has_input:
		face_yaw(atan2(move_direction.x, move_direction.z), sprint_rotation_speed, delta)
	elif has_input:
		face_camera(delta) # walking strafes with the body locked to the camera
	# Idle holds its facing; turn-in-place handles big camera swings.

func face_yaw(yaw: float, rate: float, delta: float) -> void:
	mesh.rotation.y = lerp_angle(mesh.rotation.y, yaw, exp_weight(rate, delta))

## Back to the camera (strafe-lock).
func face_camera(delta: float) -> void:
	face_yaw(camera_yaw() + YAW_OFFSET, 30.0 if instant_strafe_lock else strafe_rotation_speed, delta)

func face_instant(dir: Vector3) -> void:
	dir.y = 0
	if dir.length() > 0.05:
		mesh.rotation = Vector3(0, atan2(dir.x, dir.z), 0)

## Ease toward the crosshair, or dead-centre onto a fighter near it so hits never whiff.
func snap_facing_to_target(aim_dir: Vector3, delta: float) -> void:
	var target := combat.find_target(aim_dir, combat.aim_snap_angle if is_aiming else combat.target_snap_angle)
	var face_dir := aim_dir
	if target:
		var to: Vector3 = target.global_position - global_position
		to.y = 0
		if to.length() >= 0.01:
			face_dir = to.normalized()
	face_yaw(atan2(face_dir.x, face_dir.z), snap_turn_rate, delta)

func is_sprinting_now() -> bool:
	return intent.run and velocity.length() > 0.5 and not is_aiming and not is_carrying_body()

## True when the stick or the body is moving (decides upper-body vs full-body actions).
func is_moving(threshold: float = 0.12) -> bool:
	return intent.move.length() > 0.12 or velocity.length() > threshold

func mask_for_movement(threshold: float = 0.12) -> PlayerAnimator.Mask:
	return PlayerAnimator.Mask.UPPER if is_moving(threshold) else PlayerAnimator.Mask.FULL

## Upper-body twist toward look_dir (walking punches), clamped to +/-65 degrees.
func update_upper_twist(look_dir: Vector3, delta: float) -> void:
	look_dir.y = 0
	if look_dir.length() < 0.01:
		return
	look_dir = look_dir.normalized()
	var delta_yaw: float = clampf(angle_difference(mesh.rotation.y, atan2(look_dir.x, look_dir.z)), deg_to_rad(-65.0), deg_to_rad(65.0))
	_upper_look_angle = lerp_angle(_upper_look_angle, delta_yaw, exp_weight(12.0, delta))
	_upper_look_weight = lerpf(_upper_look_weight, 1.0, exp_weight(10.0, delta))
	_apply_upper_twist()

func clear_upper_twist(delta: float) -> void:
	if _upper_look_weight <= 0.0:
		return
	_upper_look_weight = lerpf(_upper_look_weight, 0.0, exp_weight(12.0, delta))
	_upper_look_angle = lerp_angle(_upper_look_angle, 0.0, exp_weight(12.0, delta))
	if _upper_look_weight < 0.02:
		_upper_look_weight = 0.0
		_upper_look_angle = 0.0
	_apply_upper_twist()

func _apply_upper_twist() -> void:
	if _upper_twist == null:
		var skel := get_skeleton()
		if skel == null:
			return
		_upper_twist = UpperBodyTwist.new()
		_upper_twist.name = "UpperBodyTwist"
		skel.add_child(_upper_twist)
	_upper_twist.twist = _upper_look_angle * _upper_look_weight

# --- Aim / camera helpers --------------------------------------------------------

func camera_yaw() -> float:
	if intent and intent.has_view:
		return intent.view_yaw # remote copy: the owner's camera
	return camera_rig.rotation.y

## Flat direction the camera looks along.
func camera_forward() -> Vector3:
	return Vector3.FORWARD.rotated(Vector3.UP, camera_yaw())

## Flat direction from the fighter to what the crosshair points at (cached per frame).
func aim_direction_from_camera() -> Vector3:
	var frame := Engine.get_physics_frames()
	if frame == _aim_frame:
		return _aim_dir_cached
	_aim_frame = frame
	var cam_dir := camera_forward()
	_aim_dir_cached = cam_dir
	var dir := aim_point() - global_position
	dir.y = 0
	# Points behind/sideways of the view (looking straight down) fall back to the
	# camera forward so the fighter never spins round.
	if dir.length() >= 0.05 and rad_to_deg(cam_dir.angle_to(dir.normalized())) <= 85.0:
		_aim_dir_cached = dir.normalized()
	return _aim_dir_cached

## World point under the crosshair (ray from the camera through the screen centre).
func aim_point() -> Vector3:
	if intent and intent.has_view:
		return intent.aim_point
	if aim_camera == null:
		return global_position + camera_forward() * 20.0
	var centre := get_viewport().get_visible_rect().size * 0.5
	var from := aim_camera.global_position
	var to := aim_camera.project_ray_origin(centre) + aim_camera.project_ray_normal(centre) * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	# Ignore our own body and hit/hurt boxes, or the ray stops at our own torso
	var exclude: Array[RID] = [get_rid()]
	for child in get_children():
		if child is CollisionObject3D:
			exclude.append((child as CollisionObject3D).get_rid())
	q.exclude = exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if hit else to

func camera_shake(amount: float) -> void:
	camera_rig.add_trauma(amount)

func get_skeleton() -> Skeleton3D:
	if _skeleton == null or not is_instance_valid(_skeleton):
		_skeleton = RagdollController._find_first(mesh, "Skeleton3D") as Skeleton3D
	return _skeleton

# --- Actions started from Free -------------------------------------------------

func attack_cost(idx: int) -> float:
	return stamina.cost_kick if combat.is_kick(idx) else stamina.cost_punch

## Attack button: use a held usable item, else start the combo.
func start_attack_or_use() -> void:
	if hand.is_holding_usable():
		try_change_state(&"use_item")
	else:
		try_change_state(&"attack", {"index": 0})

## Interact button: use the held item, drop/grab a ragdoll, or pick up an item.
func interact() -> void:
	if hand.is_holding_usable() and try_change_state(&"use_item"):
		return
	if grabber.is_grabbing():
		grabber.release_grab()
		return
	if hand.blocks(&"grab"):
		return
	if grabber.try_grab_nearest():
		change_state(&"gesture", {"kind": GestureState.Kind.GRAB})
		return
	var pickup := find_nearest_pickup()
	if pickup:
		try_change_state(&"gesture", {"kind": GestureState.Kind.PICKUP, "target": pickup})

## Throw button: charge a throw with an item in hand, or an empty-handed throw motion.
func start_throw() -> void:
	if hand.is_holding():
		try_change_state(&"throw_charge")
	else:
		try_change_state(&"gesture", {"kind": GestureState.Kind.EMPTY_THROW})

## Nearest ItemPickup or ThrownItem (both join the "pickup" group).
func find_nearest_pickup(max_dist: float = 3.5) -> Node3D:
	var best: Node3D = null
	var best_dist := max_dist
	for p in get_tree().get_nodes_in_group("pickup"):
		if (p is ItemPickup or p is ThrownItem) and p.is_pickable():
			var d: float = global_position.distance_to(p.global_position)
			if d < best_dist:
				best_dist = d
				best = p
	return best

func throw_release_anim() -> String:
	return animator.find([PlayerAnimator.THROWEND_ANIM, "throw"])

## Release motion after a throw: upper body when walking, whole body when standing.
func play_throw_release() -> void:
	animator.play_action(throw_release_anim(), hand.throw_release_anim_speed, 0.08, 0.16, mask_for_movement(0.18))

func _toggle_power() -> void:
	if is_flying():
		change_state(&"free")
	elif not is_dead() and has_power("fly"):
		try_change_state(&"fly") # only mid-air: jump first

func has_power(power_id: String) -> bool:
	return equipment.has_power(power_id)

# --- Turn in place -------------------------------------------------------------

## When idle, a big camera swing turns the body with a turn clip (Free state only).
func check_turn_in_place() -> void:
	if not turn_enabled or turn_cooldown_timer > 0.0 or camera_rig.inventory_mode or not is_on_floor() or is_aiming:
		return
	var cam_yaw := camera_yaw()
	var idle := not intent.has_move() and velocity.length() <= 0.45
	if (turn_only_when_idle and not idle) or not _turn_reference_set:
		_last_turn_cam_yaw = cam_yaw
		_turn_reference_set = true
		return
	var cam_delta: float = angle_difference(_last_turn_cam_yaw, cam_yaw)
	if abs(rad_to_deg(cam_delta)) < turn_threshold_deg - 0.7:
		return
	_last_turn_cam_yaw = cam_yaw # each threshold of NEW camera movement fires once
	var dir: int = 1 if cam_delta > 0.0 else -1
	var anim := animator.find(["Turn_left", "turn_left"] if dir > 0 else ["Turn_right", "turn_right"])
	if anim == "":
		# No turn clips on this rig: just ease the mesh round
		create_tween().tween_property(mesh, "rotation:y", mesh.rotation.y + deg_to_rad(turn_threshold_deg) * dir,
			maxf(turn_rotation_duration, 0.05)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		turn_cooldown_timer = turn_cooldown
		return
	change_state(&"turn", {"dir": dir, "anim": anim})

func _reset_turn_reference() -> void:
	_last_turn_cam_yaw = camera_yaw()
	_turn_reference_set = true

## How far a turn clip rotates the body: the root bone's yaw change across the
## clip (Turn_left is ~113 degrees, not 90), in the requested direction.
func turn_step(anim: String, dir: int) -> float:
	if animator.has(anim):
		var a: Animation = animator.anim_player.get_animation(anim)
		var track := a.find_track(NodePath(TURN_ROOT_TRACK), Animation.TYPE_ROTATION_3D)
		if track != -1 and a.track_get_key_count(track) >= 2:
			var y0: float = (a.track_get_key_value(track, 0) as Quaternion).get_euler().y
			var y1: float = (a.track_get_key_value(track, a.track_get_key_count(track) - 1) as Quaternion).get_euler().y
			var d: float = angle_difference(y0, y1)
			if abs(d) > deg_to_rad(30.0) and abs(d) < deg_to_rad(160.0):
				return abs(d) * dir
	return deg_to_rad(90.0) * dir

## Moves the turn the skeleton has done so far onto the mesh (before the clip is cut).
func bake_turn_into_mesh() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var idx := skel.find_bone(TURN_ROOT_BONE)
	if idx < 0:
		return
	# The root's parent (c_traj) is identity, so its local yaw is the visual yaw;
	# measured from the rest pose, which is where it sits once the clip is cut.
	var yaw_rest: float = skel.get_bone_rest(idx).basis.get_euler().y
	var yaw_now: float = skel.get_bone_pose_rotation(idx).get_euler().y
	mesh.rotation.y += angle_difference(yaw_rest, yaw_now)

# --- Damage / death ---------------------------------------------------------------

func _on_damaged(hit: HitInfo) -> void:
	var crit := hit.is_critical()
	stun_timer = 0.18 if crit else 0.11
	_hurt_flash(crit)
	camera_shake(0.62 if crit else 0.32)
	state.on_damaged(hit)
	if not ragdoll.is_ragdolled():
		HitReaction.knock(self, hit)
		HitReaction.hitstop(self, hit.hitstop)

func _on_hit_landed(target: Node3D, hit: HitInfo) -> void:
	camera_shake(hit.shake)
	state.on_hit_landed(target, hit)

func _on_died(_hit: HitInfo) -> void:
	change_state(&"dead") # RagdollController launches the body

## Where respawn() puts the fighter (online games give each fighter its own spot).
func set_spawn_point(pos: Vector3) -> void:
	_spawn_point = pos + Vector3.UP * respawn_height

func respawn() -> void:
	grabber.release_grab()
	ragdoll.reset_ragdoll()
	global_position = _spawn_point
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	stun_timer = 0.0
	dash_recovery_timer = 0.0
	reset_mesh_scale()
	mesh.rotation = Vector3(0, mesh.rotation.y, 0)
	combat.combo_index = 0
	combat.combo_reset_timer = 0.0
	health.revive(0.35)
	animator.reset()
	animator.set_hold(&"item", hand.is_holding())
	change_state(&"free")
	respawned.emit()

# --- Hands / gear (public API used by the UI, pickups and tests) --------------------

var held_item: ItemData:
	get:
		return hand.held_item

func is_holding_item() -> bool:
	return hand.is_holding()

func is_carrying_body() -> bool:
	return grabber.is_grabbing()

func pick_up_item(data: ItemData) -> bool:
	return hand.pick_up(data)

## Drops the held item (a very weak throw).
func drop_held_item() -> bool:
	if not hand.is_holding():
		return false
	if state.name == &"throw_charge":
		change_state(&"free")
	hand.throw_item(hand.drop_power)
	play_throw_release()
	return true

## Wear the item in the hand. Whatever was worn in that slot goes to the hand.
func equip_from_hand(slot: int) -> bool:
	var item := hand.held_item
	if item == null or item.slot != slot or slot == ItemData.EquipSlot.HAND or item.scene == null:
		return false
	var old := equipment.unequip(slot)
	inventory.remove_item(item) # free the hand first, so the old piece fits in it
	if equipment.equip(item) == null:
		inventory.add_item(item)
		if old:
			equipment.equip(old)
		return false
	if old:
		inventory.add_item(old)
	return true

## Take off the item in `slot` and hold it. Needs an empty hand.
func unequip_to_hand(slot: int) -> bool:
	if not equipment.has_equipped(slot) or not inventory.can_pickup():
		return false
	inventory.add_item(equipment.unequip(slot))
	return true

# --- Feel / juice ----------------------------------------------------------------

func exp_weight(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)

## Framerate-independent ease of `current` toward `target`.
func smooth(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, exp_weight(rate, delta))

## A new squash replaces the running one (no competing scale tweens).
func _new_scale_tween() -> Tween:
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = create_tween()
	return _scale_tween

func reset_mesh_scale() -> void:
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	mesh.scale = Vector3.ONE

func squash_mesh(to_scale: Vector3, in_time: float, out_time: float) -> void:
	_squash(to_scale, in_time, out_time)

func _squash(to_scale: Vector3, in_time: float, out_time: float) -> void:
	var tw := _new_scale_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if in_time > 0.0:
		tw.tween_property(mesh, "scale", to_scale, in_time)
	else:
		mesh.scale = to_scale
	tw.tween_property(mesh, "scale", Vector3.ONE, out_time)

func attack_anticipation(is_kick: bool) -> void:
	var sx: float = 1.08 if is_kick else 1.05
	_squash(Vector3(sx, 0.94, sx), 0.06, 0.09)
	if is_kick:
		_spin_trail()

func hit_pop(amount: float) -> void:
	var s: float = 1.0 + amount
	var tw := _new_scale_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(mesh, "scale", Vector3(s, 0.92, s), 0.06)
	tw.tween_property(mesh, "scale", Vector3.ONE, 0.14)

func _spin_trail() -> void:
	var trail := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.35
	cyl.height = 0.06
	cyl.radial_segments = 16
	trail.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.6, 0.18, 0.55)
	trail.material_override = mat
	add_child(trail)
	trail.position = Vector3(0, 0.45, 0)
	var tw := create_tween()
	tw.tween_property(trail, "scale", Vector3(2.2, 1, 2.2), 0.18)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.18)
	tw.tween_callback(trail.queue_free)

func _hurt_flash(is_crit: bool) -> void:
	var flash := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.65, 1.85, 0.55)
	flash.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.9, 0.2, 0.65) if is_crit else Color(1.0, 0.25, 0.25, 0.55)
	flash.material_override = mat
	mesh.add_child(flash)
	flash.position = Vector3(0, 0.92, 0)
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.18)
	tw.tween_callback(flash.queue_free)
	_squash(Vector3(1.07, 0.93, 1.07), 0.07, 0.13)

func stop_mesh_tilt_tween() -> void:
	if _tilt_tween and _tilt_tween.is_valid():
		_tilt_tween.kill()
	_tilt_tween = null

## Ease pitch/roll back upright without touching yaw (after flight).
func ease_mesh_upright() -> void:
	stop_mesh_tilt_tween()
	_tilt_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT).set_parallel(true)
	_tilt_tween.tween_property(mesh, "rotation:x", 0.0, 0.3)
	_tilt_tween.tween_property(mesh, "rotation:z", 0.0, 0.3)
