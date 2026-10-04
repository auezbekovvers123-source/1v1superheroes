extends PlayerState
class_name DashState
## Short dodge burst in the input direction (camera forward with no input).
## After the burst, Player's dash recovery eases the speed back down.

var _timer: float = 0.0
var _dir := Vector3.ZERO
var _diagonal: bool = false

## The one place that answers "can I dash right now?" (the current state
## decides separately whether it lets a dash interrupt it).
func can_enter(_args: Dictionary) -> bool:
	return player.is_on_floor() \
		and player.dash_recovery_timer <= 0.0 \
		and not player.intent.run \
		and not player.hand.blocks(&"dash") \
		and player.stamina.has(player.stamina.cost_dash) \
		and player.animator.is_ready()

func enter(_args: Dictionary) -> void:
	var stick := player.intent.move
	_dir = player.move_direction
	if _dir.length() < 0.01:
		_dir = player.camera_forward()
	_dir.y = 0
	_dir = _dir.normalized()
	_diagonal = abs(stick.x) > 0.1 and abs(stick.y) > 0.1
	_timer = player.dash_duration
	player.dash_direction = _dir
	player.dash_recovery_timer = player.dash_duration + player.dash_recovery
	player.stamina.use(player.stamina.cost_dash)
	player.animator.play_action(_pick_anim(stick), player.dash_anim_speed_scale, 0.06, 0.12, PlayerAnimator.Mask.FULL)

## Directional dodge clip. Diagonals use forward/backward (and turn the body);
## cardinals use the dominant axis.
func _pick_anim(stick: Vector2) -> String:
	var ix := stick.x
	var iz := stick.y
	if abs(ix) < 0.05 and abs(iz) < 0.05:
		# No stick input: express the dash direction in camera space
		var local: Vector3 = _dir.rotated(Vector3.UP, -player.camera_yaw())
		ix = local.x
		iz = local.z
		if abs(ix) < 0.05 and abs(iz) < 0.05:
			iz = -1.0
	var anim: String
	if abs(ix) > 0.1 and abs(iz) > 0.1:
		anim = "Dodge_forward" if iz < 0.0 else "Dodge_backward"
	elif abs(ix) > abs(iz):
		anim = "Dodge_right" if ix > 0.0 else "Dodge_left"
	else:
		anim = "Dodge_forward" if iz < 0.0 else "Dodge_backward"
	if not player.animator.has(anim):
		anim = player.animator.find(["Dodge_forward", "Dodge_backward", "Dodge_right", "Dodge_left", "running", "Idle"])
	return anim

func physics_update(_delta: float) -> void:
	if _timer <= 0.0:
		player.change_state(&"free")

func set_horizontal_velocity(delta: float, _target: Vector2) -> bool:
	# Ease into the burst instead of snapping velocity in one frame
	player.velocity.x = player.smooth(player.velocity.x, _dir.x * player.dash_speed, player.dash_enter_rate, delta)
	player.velocity.z = player.smooth(player.velocity.z, _dir.z * player.dash_speed, player.dash_enter_rate, delta)
	_timer -= delta
	return true

func update_facing(delta: float) -> bool:
	if not _diagonal:
		player.face_camera(delta) # cardinal dashes stay strafe-locked, like walking
		return true
	# Forward diagonals face the dash; backward diagonals face the opposite forward
	# diagonal so Dodge_backward never turns the back to the camera.
	var local: Vector3 = _dir.rotated(Vector3.UP, -player.camera_yaw())
	var face: Vector3 = -_dir if local.z > 0.05 else _dir
	var yaw: float = atan2(face.x, face.z)
	player.face_yaw(yaw, player.sprint_rotation_speed * 1.6, delta)
	if abs(angle_difference(player.mesh.rotation.y, yaw)) < 0.02:
		player.mesh.rotation.y = yaw
	return true

func on_damaged(hit: HitInfo) -> void:
	if hit.is_critical():
		# A heavy hit cancels the dash so the knockback plays cleanly
		player.animator.stop_action(true)
		player.change_state(&"free")
