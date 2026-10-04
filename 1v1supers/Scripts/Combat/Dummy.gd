extends CharacterBody3D
class_name Dummy
## Training dummy: takes hits (knockback, stun, flinch), shows a health bar,
## ragdolls on death and respawns at its start point. No input.

const HEALTH_BAR_SHADER = preload("res://Assets/Shaders/health_bar.gdshader")

@export var max_health: float = 120.0
@export var respawn_time: float = 2.5 # seconds after death (gives the ragdoll time to settle)
@export var gravity: float = 50.0
@export var friction: float = 6.0
@export var show_health_bar: bool = true

const RESPAWN_LOCK_TIME: float = 0.85 # collision off + pinned after teleport (avoids depenetration slide)
const RESPAWN_ANCHOR_TIME: float = 0.8 # pinned in place after respawn
const RESPAWN_INVULN_TIME: float = 1.3

var health: Health
var hurtbox: Hurtbox3D
var ragdoll: RagdollController
var anim_player: AnimationPlayer = null

var _stun_timer: float = 0.0
var _respawn_pos: Vector3
var _respawn_yaw: float = 0.0
var _respawn_lock: float = 0.0
var _anchor_timer: float = 0.0
var _mesh: Node3D
var _collision: CollisionShape3D
var _health_bar: MeshInstance3D
var _health_bar_mat: ShaderMaterial
var _scale_tween: Tween = null

func _ready() -> void:
	add_to_group("dummy")
	add_to_group("fighter")
	# Floor snap covers the small air gap the dummy spawns with
	floor_stop_on_slope = true
	floor_constant_speed = false
	floor_snap_length = 0.75
	wall_min_slide_angle = deg_to_rad(55.0)
	safe_margin = 0.02
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	collision_layer = 1
	collision_mask = 1
	_respawn_pos = global_position
	_respawn_yaw = rotation.y
	_mesh = get_node_or_null("Mesh") as Node3D
	_collision = get_node_or_null("CollisionShape3D") as CollisionShape3D

	health = Health.new()
	health.name = "Health"
	health.max_health = max_health
	health.invuln_time = 0.05
	add_child(health)
	hurtbox = Hurtbox3D.new()
	hurtbox.name = "Hurtbox3D"
	add_child(hurtbox)
	hurtbox.position = Vector3(0, 0.92, 0)
	ragdoll = RagdollController.new()
	ragdoll.name = "RagdollController"
	add_child(ragdoll)
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	ragdoll.about_to_start.connect(_reset_mesh_scale)

	anim_player = RagdollController._find_first(_mesh, "AnimationPlayer") as AnimationPlayer if _mesh else null
	if anim_player:
		anim_player.playback_default_blend_time = 0.08
		for n in ["Idle", "Walk", "running"]:
			if anim_player.has_animation(n):
				anim_player.get_animation(n).loop_mode = Animation.LOOP_LINEAR
		_play("Idle", 0.2)
	if show_health_bar:
		_setup_health_bar()

func _play(anim: String, blend: float = 0.12) -> void:
	if anim_player and anim_player.has_animation(anim):
		anim_player.play(anim, blend)

func _setup_health_bar() -> void:
	# One camera-facing quad; the shader draws background + fill (see health_bar.gdshader).
	_health_bar = MeshInstance3D.new()
	_health_bar.name = "HealthBar"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 0.16)
	_health_bar.mesh = quad
	_health_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_health_bar_mat = ShaderMaterial.new()
	_health_bar_mat.shader = HEALTH_BAR_SHADER
	_health_bar.material_override = _health_bar_mat
	add_child(_health_bar)
	_health_bar.position = Vector3(0, 2.05, 0)
	_health_bar.visible = false

func _update_health_bar() -> void:
	if _health_bar == null:
		return
	var pct: float = clampf(health.current / health.max_health, 0.0, 1.0)
	_health_bar_mat.set_shader_parameter("fill", pct)
	var col := Color(0.18, 1.0, 0.35, 0.95)
	if pct <= 0.28:
		col = Color(1.0, 0.22, 0.22, 0.95)
	elif pct <= 0.55:
		col = Color(1.0, 0.85, 0.15, 0.95)
	_health_bar_mat.set_shader_parameter("fill_color", col)
	_health_bar.visible = pct < 0.999 # hidden at full health

func _physics_process(delta: float) -> void:
	_update_health_bar()
	if ragdoll.is_ragdolled():
		velocity = Vector3.ZERO # the physical bones move the body now
		return
	# Respawn lock: hard pin with collision off, so depenetration can't push the body
	if _respawn_lock > 0.0:
		_respawn_lock -= delta
		velocity = Vector3.ZERO
		global_position = _respawn_pos
		if _respawn_lock <= 0.0 and _collision:
			_collision.disabled = false
		return
	# Anchor: keep pinned a little longer after collision returns
	if _anchor_timer > 0.0:
		_anchor_timer -= delta
		velocity = Vector3.ZERO
		global_position = _respawn_pos
		if _anchor_timer > 0.4:
			_stun_timer = 0.0
		return
	if health.is_dead:
		velocity.x = lerpf(velocity.x, 0.0, delta * 2.0)
		velocity.z = lerpf(velocity.z, 0.0, delta * 2.0)
		velocity.y -= gravity * delta
		move_and_slide()
		return
	if _stun_timer > 0.0:
		_stun_timer -= delta
		velocity.x = lerpf(velocity.x, 0.0, friction * delta)
		velocity.z = lerpf(velocity.z, 0.0, friction * delta)
	else:
		velocity.x = lerpf(velocity.x, 0.0, friction * delta * 0.5)
		velocity.z = lerpf(velocity.z, 0.0, friction * delta * 0.5)
		if abs(velocity.x) < 0.02:
			velocity.x = 0.0
		if abs(velocity.z) < 0.02:
			velocity.z = 0.0
		if anim_player and not anim_player.is_playing():
			_play("Idle")
	velocity.y -= gravity * delta
	move_and_slide()
	if is_on_floor():
		if abs(velocity.x) < 0.05:
			velocity.x = 0.0
		if abs(velocity.z) < 0.05:
			velocity.z = 0.0
		if velocity.y > -0.5 and velocity.y < 0.5:
			velocity.y = 0.0
	elif velocity.length() < 0.08 and _stun_timer <= 0.0:
		velocity.x = 0.0
		velocity.z = 0.0

func _on_damaged(hit: HitInfo) -> void:
	var crit := hit.is_critical()
	_stun_timer = 0.36 if crit else 0.18
	if crit:
		_play("Landing_hard" if anim_player and anim_player.has_animation("Landing_hard") else "Landing", 0.06)
	_do_hit_flash(crit, hit.damage)
	# Face the attacker (shortest way round)
	if hit.attacker and is_instance_valid(hit.attacker) and hit.attacker != self:
		var dir: Vector3 = hit.attacker.global_position - global_position
		dir.y = 0
		if dir.length() > 0.1:
			var target_yaw: float = rotation.y + angle_difference(rotation.y, atan2(-dir.x, -dir.z))
			create_tween().tween_property(self, "rotation:y", target_yaw, 0.12)
	# Knockback (not while ragdolled or pinned after a respawn)
	if ragdoll.is_ragdolled() or _respawn_lock > 0.0 or _anchor_timer > 0.0:
		return
	HitReaction.knock(self, hit)
	if crit:
		velocity.y = maxf(velocity.y, 2.5) # extra lift
	HitReaction.hitstop(self, hit.hitstop)

func _do_hit_flash(is_crit: bool, amount: float) -> void:
	if _mesh == null:
		return
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = create_tween()
	var tw := _scale_tween
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var scale_hit: float = 1.0 + minf(amount / 110.0, 0.11) + (0.05 if is_crit else 0.0)
	tw.tween_property(_mesh, "scale", Vector3(scale_hit, 0.92, scale_hit), 0.06)
	tw.tween_property(_mesh, "scale", Vector3.ONE, 0.16)
	# Colour flash overlay
	var flash := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.62, 1.82, 0.5)
	flash.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.78, 0.18, 0.55) if is_crit else Color(1.0, 0.32, 0.28, 0.45)
	flash.material_override = mat
	_mesh.add_child(flash)
	flash.position = Vector3(0, 0.92, 0)
	var tw2 := create_tween()
	tw2.tween_property(mat, "albedo_color:a", 0.0, 0.19)
	tw2.tween_callback(flash.queue_free)

func _reset_mesh_scale() -> void:
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	if _mesh:
		_mesh.scale = Vector3.ONE

func _on_died(_hit: HitInfo) -> void:
	_stun_timer = 999.0
	# RagdollController launches the body. Respawn after a delay, but never while
	# someone is carrying the ragdoll.
	await get_tree().create_timer(respawn_time).timeout
	while is_instance_valid(ragdoll) and ragdoll.is_held():
		await ragdoll.held_changed
	if is_instance_valid(self) and health.is_dead:
		respawn()

func respawn() -> void:
	ragdoll.reset_ragdoll(false) # collision comes back when the respawn lock ends
	if _collision:
		_collision.disabled = true
	_stun_timer = 0.0
	velocity = Vector3.ZERO
	global_position = _respawn_pos
	rotation.y = _respawn_yaw
	reset_physics_interpolation()
	_respawn_lock = RESPAWN_LOCK_TIME
	_anchor_timer = RESPAWN_ANCHOR_TIME
	_reset_mesh_scale()
	health.revive(RESPAWN_INVULN_TIME)
	_play("Idle", 0.12)
	# Spawn flash
	var flash := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.55
	sph.height = 1.1
	flash.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.9, 1.0, 0.5)
	flash.material_override = mat
	add_child(flash)
	flash.position = Vector3(0, 0.92, 0)
	var tw := create_tween()
	tw.tween_property(flash, "scale", Vector3(2.2, 2.2, 2.2), 0.28)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.28)
	tw.tween_callback(flash.queue_free)
