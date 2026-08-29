extends Node3D
## SpringArmPivot.gd — mouse look + SATISFYING camera feedback
## Adds trauma-based shake, FOV kick, hitstop-friendly damping

@export_group("FOV")
@export var change_fov_on_run: bool = true
@export var normal_fov: float = 75.0
@export var run_fov: float = 90.0
@export var aim_fov: float = 62.0 # tight FOV while holding RMB to aim
@export var attack_fov_kick: float = 6.0 # extra FOV on punch (snap back)

@export_group("Shake")
@export var trauma_decay: float = 5.0
@export var trauma_power: float = 2.2 # exponent
@export var max_yaw_shake: float = 0.52 # degrees
@export var max_pitch_shake: float = 0.42
@export var max_roll_shake: float = 0.65
@export var shake_freq: float = 18.0
@export var positional_shake: float = 0.045

@export_group("Aim Camera")
@export var aim_cam_offset: Vector3 = Vector3(1.1, 0.0, 0.0) # shift camera right (+X) when aiming — over-the-shoulder, needs ~1m to be visible
@export var aim_cam_blend: float = 10.0

const CAMERA_BLEND: float = 0.08
const PITCH_BLEND: float = 0.12

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/CameraHolder/Camera3D

var trauma: float = 0.0
var _noise_time: float = 0.0
var _base_spring_length: float = 3.0
var _fov_kick: float = 0.0
var _kick_decay: float = 9.0
var _recoil_pitch: float = 0.0
var aiming: bool = false

func set_aiming(on: bool) -> void:
	aiming = on

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if spring_arm:
		_base_spring_length = spring_arm.spring_length
	if camera == null:
		camera = get_node_or_null("SpringArm3D/CameraHolder/Camera3D") as Camera3D

func add_trauma(amount: float) -> void:
	trauma = clamp(trauma + amount, 0.0, 1.0)
	# Also add micro FOV kick
	_fov_kick = clamp(_fov_kick + amount * 4.0, 0.0, attack_fov_kick)

func add_recoil(pitch_deg: float) -> void:
	_recoil_pitch += deg_to_rad(pitch_deg)

func kick_fov(amount: float = 5.0) -> void:
	_fov_kick = clamp(_fov_kick + amount, 0.0, attack_fov_kick + 4.0)

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var sens: float = 0.005
		# Reduce sensitivity during hitstop (time_scale small) — keep feeling
		rotate_y(-event.relative.x * sens)
		spring_arm.rotate_x(-event.relative.y * sens)
		spring_arm.rotation.x = clamp(spring_arm.rotation.x, -PI/4, PI/4)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta: float):
	# Use unscaled delta for shake so hitstop still shakes
	var udelta: float = delta
	if Engine.time_scale < 0.5:
		udelta = delta / max(Engine.time_scale, 0.02) * delta # approximate unscaled
		udelta = clamp(udelta, 0.0, 0.032)
	_noise_time += udelta * shake_freq
	# Decay trauma
	if trauma > 0.0:
		trauma = max(trauma - trauma_decay * delta, 0.0)
	if _fov_kick > 0.0:
		_fov_kick = max(_fov_kick - _kick_decay * delta, 0.0)
	if abs(_recoil_pitch) > 0.001:
		_recoil_pitch = lerp(_recoil_pitch, 0.0, 9.0 * delta)
		spring_arm.rotation.x += _recoil_pitch * delta * 5.0
	# Apply shake (offset camera, not whole pivot to avoid affecting movement)
	if camera:
		# Aim over-the-shoulder offset (lerp so it eases in/out, doesn't fight shake yaw/roll)
		if aiming:
			camera.position = camera.position.lerp(aim_cam_offset, clampf(aim_cam_blend * udelta, 0.0, 1.0))
		else:
			camera.position = camera.position.lerp(Vector3.ZERO, clampf(aim_cam_blend * udelta, 0.0, 1.0))
		var shake_amount: float = pow(trauma, trauma_power)
		# Perlin-ish via sin hash
		var yaw: float = sin(_noise_time * 1.37) * cos(_noise_time * 0.77) * deg_to_rad(max_yaw_shake) * shake_amount
		var pitch: float = sin(_noise_time * 1.91 + 1.3) * deg_to_rad(max_pitch_shake) * shake_amount
		var roll: float = sin(_noise_time * 0.62 + 2.1) * deg_to_rad(max_roll_shake) * shake_amount
		camera.rotation.y = yaw
		camera.rotation.x = pitch
		camera.rotation.z = roll
		# positional jitter
		camera.h_offset = sin(_noise_time * 2.4) * positional_shake * shake_amount
		camera.v_offset = cos(_noise_time * 1.8) * positional_shake * shake_amount * 0.6
	else:
		# fallback: shake spring_arm
		var shake2: float = pow(trauma, trauma_power)
		spring_arm.rotation.z = sin(_noise_time * 0.9) * deg_to_rad(max_roll_shake) * 0.5 * shake2
	# FOV handling
	if camera:
		var target_fov: float = normal_fov
		if aiming:
			target_fov = aim_fov
		elif change_fov_on_run and owner and owner is CharacterBody3D and (owner as CharacterBody3D).is_on_floor():
			if Input.is_action_pressed("run") and (owner as CharacterBody3D).velocity.length() > 0.6 and not (owner as CharacterBody3D).get("is_attacking"):
				target_fov = run_fov
		target_fov += _fov_kick
		# During attack, slight FOV tighten on windup then kick on hit is via _fov_kick
		camera.fov = lerp(camera.fov, target_fov, CAMERA_BLEND + trauma * 0.12)
		# Spring length punch on hit (forward)
		var target_len: float = _base_spring_length + trauma * 0.55 + _fov_kick * 0.04
		spring_arm.spring_length = lerp(spring_arm.spring_length, target_len, 0.18)

func _process(_delta):
	# Keep shake in _physics but also smooth in _process for 60fps feel
	pass
