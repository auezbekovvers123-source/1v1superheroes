extends PlayerState
class_name AttackState
## One swing of the punch/kick combo. Pressing attack during a swing queues the
## next one, which starts when this swing ends. The kick, and any swing thrown
## while standing still, is full-body; swings thrown while moving are upper-body
## only, so the legs keep walking.

const WHIFF_SHAKE: float = 0.08

var index: int = 0
var fullbody: bool = false
var _timer: float = 0.0
var _total: float = 0.0
var _window_open: bool = false
var _queued: bool = false
var _lunge := Vector3.ZERO

func can_enter(args: Dictionary) -> bool:
	var idx: int = args.get("index", 0)
	var anim: String = MeleeCombat.COMBO_ANIMS[idx]
	return player.is_on_floor() and player.stun_timer <= 0.0 and not player.hand.blocks(&"attack") \
		and player.stamina.has(player.attack_cost(idx)) and player.animator.has(anim)

func enter(args: Dictionary) -> void:
	var combat := player.combat
	index = args.get("index", 0)
	combat.combo_index = index
	combat.combo_reset_timer = 0.0
	combat.has_hit_this_swing = false
	_queued = false
	_timer = 0.0
	_window_open = false
	player.stamina.use(player.attack_cost(index))
	var anim: String = MeleeCombat.COMBO_ANIMS[index]
	var speed := combat.anim_speed(index)
	_total = player.animator.length(anim) / speed
	fullbody = combat.is_kick(index) or not player.is_moving()
	player.animator.play_action(anim, speed, MeleeCombat.BLEND, 0.14,
		PlayerAnimator.Mask.FULL if fullbody else PlayerAnimator.Mask.UPPER)
	# Face the crosshair (or the target near it), then lunge that way
	var aim_dir := player.aim_direction_from_camera()
	player.snap_facing_to_target(aim_dir, player.get_physics_process_delta_time())
	var forward: Vector3 = player.mesh.global_basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.2 else aim_dir
	_lunge = forward * MeleeCombat.COMBO_LUNGE[index] * 1.35
	player.attack_anticipation(combat.is_kick(index))

func exit() -> void:
	player.combat.close_window()

func handle_intent(i: PlayerInput.Intent) -> void:
	var last := player.combat.last_index()
	if i.attack_pressed and index < last and player.stamina.has(player.attack_cost(index + 1)):
		_queued = true
	if i.dash_pressed and _timer <= player.dash_cancel_attack_window:
		if player.try_change_state(&"dash"):
			return
	if i.interact_pressed and player.grabber.is_grabbing():
		player.grabber.release_grab()

func physics_update(delta: float) -> void:
	_timer += delta
	var active: bool = _timer >= MeleeCombat.COMBO_HIT_START[index] and _timer <= MeleeCombat.COMBO_HIT_END[index]
	if active and not _window_open:
		_window_open = true
		player.combat.open_window(index)
	elif not active and _window_open:
		_window_open = false
		player.combat.close_window()
	_lunge = _lunge.lerp(Vector3.ZERO, player.exp_weight(player.combat.attack_lunge_decay, delta)) if _lunge.length() > 0.01 else Vector3.ZERO
	if _timer >= _total:
		_finish()

func _finish() -> void:
	var combat := player.combat
	combat.close_window()
	if _queued and index < combat.last_index() and player.stamina.has(player.attack_cost(index + 1)):
		player.change_state(&"attack", {"index": index + 1})
		return
	if index == combat.last_index():
		combat.combo_index = 0
		combat.combo_reset_timer = 0.0
	else:
		combat.combo_reset_timer = MeleeCombat.RESET_TIME
		if not combat.has_hit_this_swing:
			player.camera_shake(WHIFF_SHAKE)
	player.change_state(&"free")

func after_velocity(delta: float) -> void:
	if player.is_on_floor() and _lunge.length() > 0.1:
		player.velocity.x += _lunge.x * delta * 11.0
		player.velocity.z += _lunge.z * delta * 11.0
	# Full-body swings plant the feet once the lunge has faded
	if fullbody and _lunge.length() < 0.2:
		player.velocity.x = player.smooth(player.velocity.x, 0.0, player.attack_stop_rate, delta)
		player.velocity.z = player.smooth(player.velocity.z, 0.0, player.attack_stop_rate, delta)

func update_facing(delta: float) -> bool:
	if fullbody:
		player.snap_facing_to_target(player.aim_direction_from_camera(), delta)
		player.clear_upper_twist(delta)
	elif player.is_sprinting_now():
		# Running punches keep the run facing (no upper-body twist while sprinting)
		player.clear_upper_twist(delta)
		if player.move_direction.length() > 0.1:
			player.face_yaw(atan2(player.move_direction.x, player.move_direction.z), player.sprint_rotation_speed, delta)
		else:
			player.face_camera(delta)
	else:
		# Walking punch: legs follow the strafe-locked body, the upper body twists to the target
		var aim_dir := player.aim_direction_from_camera()
		var look_dir := aim_dir
		var target := player.combat.find_target(aim_dir, player.combat.target_snap_angle)
		if target:
			var to: Vector3 = target.global_position - player.global_position
			to.y = 0
			if to.length() >= 0.01:
				look_dir = to.normalized()
		player.update_upper_twist(look_dir, delta)
		player.face_camera(delta)
	return true

func allows_sprint() -> bool:
	return not fullbody

func allows_jump() -> bool:
	return not fullbody

func suppresses_footsteps() -> bool:
	return fullbody

func on_damaged(hit: HitInfo) -> void:
	if hit.is_critical():
		_queued = false # a heavy hit breaks the chain

func on_hit_landed(_target: Node3D, _hit: HitInfo) -> void:
	var combat := player.combat
	if combat.has_hit_this_swing:
		return
	combat.has_hit_this_swing = true
	player.hit_pop(combat.hit_punch_scale + (0.06 if combat.is_kick(index) else 0.0))
	_lunge *= 0.18 # stick to the target
	# A landed hit shortens the recovery by 30% so chains feel responsive
	var remain: float = _total - _timer
	if remain > 0.12:
		_timer += remain * 0.30
