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

@export_group("Inventory View")
@export var inventory_view_dist: float = 3.4 # spring length while TAB inventory is open (used as fallback if no auto-fit)
@export var inventory_pitch_deg: float = -15.0 # gentle top-down hero angle (fallback)
@export var inventory_cam_fov: float = 36.0 # narrow cinematic lens (fallback if no auto-fit)
@export var inventory_cam_offset: Vector3 = Vector3(0.42, 0.10, 0.0) # off-center framing (right + slightly high)
@export var inventory_view_blend: float = 3.6 # slow exponential ease for a cinematic swing
@export var inventory_auto_fit: bool = true # when opening TAB, compute distance so the character fits the frame
@export var inventory_fit_margin: float = 1.55 # padding multiplier (>1 = extra space around the model)
@export var inventory_pitch_offset_deg: float = -10.0 # extra downward tilt added to the fitted pitch so the model sits low in frame
@export var inventory_min_dist: float = 1.6 # never closer than this even for tiny models
@export var inventory_max_dist: float = 12.0 # never farther than this even for huge models

## While true the camera smoothly orbits around to face the FRONT of the
## character model (driven by the TAB inventory). Keeps processing even when
## the tree is paused so the swing plays out during the inventory pause.
var inventory_mode: bool = false

# Cached fit values computed on inventory open so the camera frames the whole character.
var _fit_active: bool = false
var _fit_dist: float = 3.4
var _fit_pitch_deg: float = -5.0
var _fit_fov: float = 36.0

func set_inventory_mode(on: bool) -> void:
	inventory_mode = on
	aiming = false
	process_mode = Node.PROCESS_MODE_ALWAYS if on else Node.PROCESS_MODE_INHERIT
	if on and inventory_auto_fit:
		_compute_inventory_fit()
	else:
		_fit_active = false

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

## Walk the player's visual subtree and gather every mesh's world-space AABB,
## then pick a spring-arm distance + pitch so the model fills the frame.
func _compute_inventory_fit() -> void:
	if owner == null or not (owner is Node):
		_fit_active = false
		return
	var mesh_root := (owner as Node).get_node_or_null("Mesh") as Node3D
	if mesh_root == null:
		_fit_active = false
		return
	var aabb := _world_aabb_of_meshes(mesh_root)
	if aabb.size == Vector3.ZERO:
		_fit_active = false
		return

	# Aspect of the active viewport (fall back to 16:9 if unknown).
	var vp := get_viewport()
	var aspect: float = 16.0 / 9.0
	if vp:
		var sz: Vector2 = vp.get_visible_rect().size
		if sz.y > 0.1:
			aspect = sz.x / sz.y

	var fov := inventory_cam_fov
	var half_fov_y: float = deg_to_rad(fov) * 0.5
	var half_fov_x: float = atan(tan(half_fov_y) * aspect)
	# Distance needed to fit AABB height (vertical) and half-width (horizontal).
	var half_h: float = max(aabb.size.y, 0.001) * 0.5
	var half_w: float = max(aabb.size.x, 0.001) * 0.5
	var d_h: float = half_h / max(tan(half_fov_y), 0.001)
	var d_w: float = half_w / max(tan(half_fov_x), 0.001)
	var dist: float = max(d_h, d_w) * inventory_fit_margin
	dist = clamp(dist, inventory_min_dist, inventory_max_dist)

	# Vertical aim: target the AABB center so the model sits centered, not head-cropped.
	# Then add a flat downward-tilt offset so the model sits LOW in the frame.
	var cam_origin_y: float = global_position.y
	var target_y: float = aabb.position.y + half_h
	var dy: float = target_y - cam_origin_y
	var pitch_rad: float = atan2(dy, dist) + deg_to_rad(inventory_pitch_offset_deg)

	_fit_dist = dist
	_fit_pitch_deg = rad_to_deg(pitch_rad)
	_fit_fov = fov
	_fit_active = true

var _last_aabb: AABB = AABB()
var _last_aabb_found: bool = false

func _world_aabb_of_meshes(root: Node3D) -> AABB:
	_last_aabb = AABB()
	_last_aabb_found = false
	_collect_mesh_aabbs(root)
	return _last_aabb

func _collect_mesh_aabbs(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			var local := mesh.get_aabb()
			var world := mi.global_transform * local
			if not _last_aabb_found:
				_last_aabb = world
				_last_aabb_found = true
			else:
				_last_aabb = _last_aabb.merge(world)
	for c in n.get_children():
		_collect_mesh_aabbs(c)

func add_trauma(amount: float) -> void:
	trauma = clamp(trauma + amount, 0.0, 1.0)
	# Also add micro FOV kick
	_fov_kick = clamp(_fov_kick + amount * 4.0, 0.0, attack_fov_kick)

func add_recoil(pitch_deg: float) -> void:
	_recoil_pitch += deg_to_rad(pitch_deg)

func kick_fov(amount: float = 5.0) -> void:
	_fov_kick = clamp(_fov_kick + amount, 0.0, attack_fov_kick + 4.0)

func _unhandled_input(event):
	if inventory_mode:
		return # inventory owns the mouse; no look, no ESC capture toggling
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
	# --- Inventory front view: smoothly orbit to face the character's front ---
	if inventory_mode:
		# If we couldn't compute a fit on the open call (owner not set yet, etc.),
		# try again now that we're alive in the tree.
		if inventory_auto_fit and not _fit_active:
			_compute_inventory_fit()
		var mesh_root: Node3D = null
		if owner is Node:
			mesh_root = owner.get_node_or_null("Mesh") as Node3D
		var fwd := Vector3.FORWARD
		if mesh_root:
			fwd = mesh_root.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() < 0.0001:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
		# Mesh forward is its +Z (rotation.y = atan2(f.x, f.z) everywhere in Player.gd).
		# Pivoting to the same yaw parks the camera IN FRONT of the model, looking
		# back at its face.
		var target_yaw := atan2(fwd.x, fwd.z)
		var t := clampf(inventory_view_blend * delta, 0.0, 1.0)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
		# Use auto-fit values if we computed them on open; otherwise fall back to the
		# inspector defaults so the camera still works without a mesh.
		var target_dist: float = _fit_dist if _fit_active else inventory_view_dist
		var target_pitch_deg: float = _fit_pitch_deg if _fit_active else inventory_pitch_deg + inventory_pitch_offset_deg
		var target_fov: float = _fit_fov if _fit_active else inventory_cam_fov
		if spring_arm:
			spring_arm.rotation.x = lerpf(spring_arm.rotation.x, deg_to_rad(target_pitch_deg), t)
			spring_arm.spring_length = lerpf(spring_arm.spring_length, target_dist, t)
		if camera:
			# Ease into the cinematic framing and wash out any leftover shake
			camera.position = camera.position.lerp(inventory_cam_offset, t)
			camera.rotation = camera.rotation.lerp(Vector3.ZERO, t)
			camera.h_offset = lerpf(camera.h_offset, 0.0, t)
			camera.v_offset = lerpf(camera.v_offset, 0.0, t)
			camera.fov = lerpf(camera.fov, target_fov, t)
		return

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
