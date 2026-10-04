extends PlayerState
class_name FlyState
## Cape power: free flight. Started mid-air with the power button while wearing
## the cape; ends on touchdown, on the power button, or when the cape comes off.
## Camera-relative movement, jump = up, fly_down = down, run = sprint-flight
## (superman pose with a strong forward pitch).

var _tilt_x: float = 0.0
var _roll_z: float = 0.0

func can_enter(_args: Dictionary) -> bool:
	return not player.is_on_floor() and player.has_power("fly")

func enter(_args: Dictionary) -> void:
	player.velocity.y = minf(player.velocity.y, 1.0)
	player.stop_mesh_tilt_tween()
	_tilt_x = player.mesh.rotation.x
	_roll_z = player.mesh.rotation.z
	player.animator.set_flying(true)

func exit() -> void:
	player.animator.set_flying(false)
	player.ease_mesh_upright()

func physics_update(_delta: float) -> void:
	if not player.has_power("fly"):
		player.change_state(&"free") # cape lost mid-air: fall

func overrides_movement() -> bool:
	return true

func move(delta: float) -> void:
	var i := player.intent
	var raw := Vector3(i.move.x, 0, i.move.y)
	var horiz: Vector3 = raw.rotated(Vector3.UP, player.camera_yaw())
	var up := i.jump_held
	var down := i.fly_down_held
	var sprinting: bool = i.run and not player.is_aiming
	var h_speed: float = player.fly_sprint_speed if sprinting else player.fly_cruise_speed
	var v_speed: float = player.fly_vertical_speed * (player.fly_vertical_sprint_mult if sprinting else 1.0)
	var target := horiz * h_speed
	target.y = (v_speed if up else 0.0) - (v_speed if down else 0.0)
	var v := player.velocity
	v.x = player.smooth(v.x, target.x, player.fly_accel, delta)
	v.z = player.smooth(v.z, target.z, player.fly_accel, delta)
	v.y = player.smooth(v.y, target.y, player.fly_accel * 1.2, delta)
	player.velocity = v
	player.apply_floor_snap()
	player.move_and_slide()
	player.stamina.tick(delta)
	if player.is_on_floor():
		player.footsteps.sync_floor(true)
		player.note_landed_from_flight()
		player.change_state(&"free") # touchdown ends flight
		return
	player.footsteps.sync_floor(false)
	player.note_airborne(player.velocity.y)
	# Facing: sprint-flight faces travel; hover stays strafe-locked to the camera
	var moving_h: bool = horiz.length() > 0.12
	if sprinting and moving_h:
		player.face_yaw(atan2(horiz.x, horiz.z), player.sprint_rotation_speed, delta)
	else:
		player.face_camera(delta)
	# Pitch/roll: superman pose while sprint-moving (nose up when climbing, down when
	# diving), else a slight lean toward the input. The character's right is the
	# Mesh's -X (it faces +Z), so banking right is positive rotation.z.
	var moving_any: bool = moving_h or up or down
	var target_tilt: float = 0.0
	var target_roll: float = 0.0
	if sprinting and moving_any:
		target_tilt = deg_to_rad(player.fly_tilt_deg)
		if up and not down:
			target_tilt -= deg_to_rad(player.fly_sprint_vertical_slant_deg)
		elif down and not up:
			target_tilt += deg_to_rad(player.fly_sprint_vertical_slant_deg)
	elif moving_any:
		var lean: float = deg_to_rad(player.fly_cruise_lean_deg)
		target_tilt = -raw.z * lean
		if up and not down:
			target_tilt -= lean
		elif down and not up:
			target_tilt += lean
		target_roll = raw.x * lean
	var w := player.exp_weight(player.fly_tilt_speed, delta)
	_tilt_x = lerpf(_tilt_x, target_tilt, w)
	_roll_z = lerpf(_roll_z, target_roll, w)
	player.mesh.rotation.x = _tilt_x
	player.mesh.rotation.z = _roll_z
	player.animator.update_fly_blend(sprinting and moving_any, delta)

func suppresses_footsteps() -> bool:
	return true
