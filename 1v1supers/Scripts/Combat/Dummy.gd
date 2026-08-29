extends CharacterBody3D
const HealthCls = preload("res://Scripts/Combat/Health.gd")
const HurtboxCls = preload("res://Scripts/Combat/Hurtbox3D.gd")
const RagdollCls = preload("res://Scripts/Combat/RagdollController.gd")
## Dummy.gd — training dummy / opponent. Takes hits satisfyingly, shows health bar, respawns.
## Shares C11 model for visual parity. No input — gravity + knockback + stun + flinch.

@export var max_health: float = 120.0
@export var respawn_time: float = 1.6
@export var gravity: float = 50.0
@export var friction: float = 6.0
@export var show_health_bar: bool = true

var health: Node
var hurtbox: Area3D
var c11_ap: AnimationPlayer = null
var ragdoll: RagdollController = null
var _stun_timer: float = 0.0
var _respawn_pos: Vector3
var _respawn_yaw: float = 0.0
var _mesh: Node3D
var _health_bar: ProgressBar
var _bar_host: Control
var _respawn_lock: float = 0.0
var _anchor_timer: float = 0.0

func _ready() -> void:
	add_to_group("dummy")
	add_to_group("fighter")
	# Fix air-spawn (capsule bottom 0.60 above floor at y 0.92) by allowing floor snap to cover gap
	floor_stop_on_slope = true
	floor_constant_speed = false
	floor_snap_length = 0.75
	wall_min_slide_angle = deg_to_rad(55.0)
	safe_margin = 0.02
	up_direction = Vector3.UP
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_respawn_pos = global_position
	_respawn_yaw = rotation.y
	_mesh = get_node_or_null("Mesh") as Node3D
	_setup_health()
	_setup_c11_anim()
	_setup_health_bar()
	_setup_ragdoll()
	if health:
		health.damaged.connect(_on_damaged)
		health.died.connect(_on_died)
	# Ensure collision layer 1
	collision_layer = 1
	collision_mask = 1

func _setup_ragdoll() -> void:
	var existing = get_node_or_null("RagdollController")
	if existing and existing is RagdollController:
		ragdoll = existing as RagdollController
		return
	ragdoll = RagdollCls.new()
	ragdoll.name = "RagdollController"
	ragdoll.impulse_multiplier = 1.45
	add_child(ragdoll)

func _setup_health() -> void:
	var h = get_node_or_null("Health")
	if h == null:
		h = HealthCls.new()
		h.name = "Health"
		add_child(h)
	h.set("max_health", max_health)
	h.set("current", max_health)
	h.set("invuln_time", 0.05)
	health = h
	var hb = get_node_or_null("Hurtbox3D") as Area3D
	if hb == null:
		hb = HurtboxCls.new()
		hb.name = "Hurtbox3D"
		add_child(hb)
		hb.position = Vector3(0, 0.92, 0)
	hurtbox = hb as Area3D

func _setup_c11_anim() -> void:
	# Find AnimationPlayer under Mesh/C11
	var ap: AnimationPlayer = null
	var mesh_c11 = get_node_or_null("Mesh/C11") as Node
	if mesh_c11:
		ap = mesh_c11.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if ap == null:
			ap = _find_ap(mesh_c11)
	if ap == null:
		# search Mesh children
		var m = get_node_or_null("Mesh")
		if m:
			for c in m.get_children():
				var f = _find_ap(c)
				if f and f.has_animation("Idle"):
					ap = f
					break
	c11_ap = ap
	if c11_ap:
		c11_ap.playback_default_blend_time = 0.08
		for n in ["Idle", "Walk", "running"]:
			if c11_ap.has_animation(n):
				c11_ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
		_play("Idle", 0.2)

func _find_ap(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for c in node.get_children():
		var f = _find_ap(c)
		if f:
			return f
	return null

func _play(anim: String, blend: float = 0.12) -> void:
	if c11_ap == null or not c11_ap.has_animation(anim):
		return
	c11_ap.play(anim, blend)

func _setup_health_bar() -> void:
	if not show_health_bar:
		return
	# World-space billboard health bar using SubViewport + Sprite3D (cheap)
	# For simplicity, use a 3D ProgressBar via Control + Sprite technique: just add a CanvasLayer UI?
	# Instead create a Billboard Sprite3D that scales with health via code-spawned UI
	var bar_root := Node3D.new()
	bar_root.name = "HealthBarRoot"
	add_child(bar_root)
	bar_root.position = Vector3(0, 2.05, 0)
	var bg := MeshInstance3D.new()
	var bg_mesh := PlaneMesh.new()
	bg_mesh.size = Vector2(1.4, 0.16)
	bg.mesh = bg_mesh
	var bg_mat := StandardMaterial3D.new()
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.albedo_color = Color(0.08, 0.08, 0.08, 0.82)
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg.material_override = bg_mat
	bar_root.add_child(bg)
	bg.position = Vector3(0, 0, 0)
	var fg := MeshInstance3D.new()
	fg.name = "FG"
	var fg_mesh := PlaneMesh.new()
	fg_mesh.size = Vector2(1.34, 0.11)
	fg.mesh = fg_mesh
	var fg_mat := StandardMaterial3D.new()
	fg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fg_mat.albedo_color = Color(0.18, 1.0, 0.35, 0.95)
	fg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fg.material_override = fg_mat
	bar_root.add_child(fg)
	fg.position = Vector3(0, 0, 0.01)
	_health_bar = null # we use fg scale
	# Store refs via meta
	bar_root.set_meta("bg", bg)
	bar_root.set_meta("fg", fg)
	bar_root.set_meta("fg_mat", fg_mat)

func _update_health_bar() -> void:
	var root = get_node_or_null("HealthBarRoot") as Node3D
	if root == null or health == null:
		return
	var fg = root.get_node_or_null("FG") as MeshInstance3D
	if fg == null:
		return
	var fg_mat = root.get_meta("fg_mat") as StandardMaterial3D
	var pct: float = clamp(health.current / health.max_health, 0.0, 1.0)
	fg.scale.x = pct
	fg.position.x = -(1.34 * (1.0 - pct)) * 0.5 # keep left anchored
	if fg_mat:
		if pct > 0.55:
			fg_mat.albedo_color = Color(0.18, 1.0, 0.35, 0.95)
		elif pct > 0.28:
			fg_mat.albedo_color = Color(1.0, 0.85, 0.15, 0.95)
		else:
			fg_mat.albedo_color = Color(1.0, 0.22, 0.22, 0.95)
	# Hide when full, show when damaged for 3s
	root.visible = pct < 0.999
	# Billboard: keep facing camera is via material, root yaw auto? material does it

func _physics_process(delta: float) -> void:
	_update_health_bar()
	# GTA ragdoll: if ragdolled, let physical bones drive — don't apply CharacterBody gravity
	if ragdoll and ragdoll.is_ragdolled():
		# Still update health bar but freeze body motion — also pin to death pos so ragdoll doesn't inherit CharacterBody slide
		velocity = Vector3.ZERO
		return
	# Respawn lock — HARD pin after teleport, keep collision disabled whole lock
	# Original only disabled first half ( >0.25 ) leaving 0.25s where depenetration injected horizontal velocity
	if _respawn_lock > 0.0:
		_respawn_lock -= delta
		velocity = Vector3.ZERO
		global_position = _respawn_pos
		var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs:
			cs.disabled = true
		return
	else:
		var cs2 := get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs2 and cs2.disabled:
			cs2.disabled = false
		# Restore collision layers if respawn disabled them
		if has_meta("_saved_layer"):
			collision_layer = int(get_meta("_saved_layer"))
			remove_meta("_saved_layer")
		if has_meta("_saved_mask"):
			collision_mask = int(get_meta("_saved_mask"))
			remove_meta("_saved_mask")
		if collision_layer == 0:
			collision_layer = 1
		if collision_mask == 0:
			collision_mask = 1
	# Anchor — pin position for 0.8s after respawn to prevent depenetration from sliding the body
	if _anchor_timer > 0.0:
		_anchor_timer -= delta
		velocity = Vector3.ZERO
		global_position = _respawn_pos
		if _anchor_timer > 0.4:
			_stun_timer = 0.0
		return
	if health and health.is_dead:
		velocity.x = lerp(velocity.x, 0.0, delta * 2.0)
		velocity.z = lerp(velocity.z, 0.0, delta * 2.0)
		velocity.y -= gravity * delta
		move_and_slide()
		if velocity.length() < 0.05:
			velocity = Vector3.ZERO
		return
	if _stun_timer > 0.0:
		_stun_timer -= delta
		velocity.x = lerp(velocity.x, 0.0, friction * delta)
		velocity.z = lerp(velocity.z, 0.0, friction * delta)
	else:
		velocity.x = lerp(velocity.x, 0.0, friction * delta * 0.5)
		velocity.z = lerp(velocity.z, 0.0, friction * delta * 0.5)
		if abs(velocity.x) < 0.02:
			velocity.x = 0.0
		if abs(velocity.z) < 0.02:
			velocity.z = 0.0
		if c11_ap and not c11_ap.is_playing():
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
	else:
		if velocity.length() < 0.08 and _stun_timer <= 0.0:
			velocity.x = 0.0
			velocity.z = 0.0
	# Keep health bar facing camera: handled by billboard material

func _on_damaged(amount: float, from: Node, knockback: Vector3, is_crit: bool) -> void:
	_stun_timer = 0.36 if is_crit else 0.18
	# Flinch anim
	if is_crit:
		_play("Landing_hard" if c11_ap and c11_ap.has_animation("Landing_hard") else "Landing", 0.06)
	else:
		# slight hit tilt
		if c11_ap and c11_ap.has_animation("punch_hook"):
			# use hurt flash scale on mesh
			pass
	_do_hit_flash(is_crit, amount)
	# Face attacker
	if from is Node3D and from != self:
		var dir: Vector3 = (from as Node3D).global_position - global_position
		dir.y = 0
		if dir.length() > 0.1:
			var target_yaw := atan2(-dir.x, -dir.z) # face attacker
			var tw := create_tween()
			tw.tween_property(self, "rotation:y", target_yaw, 0.12)
	# Knockback already applied to velocity via Health, but add extra lift for crit
	if is_crit:
		velocity.y = max(velocity.y, 2.5)

func _do_hit_flash(is_crit: bool, amount: float) -> void:
	if _mesh == null:
		return
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var scale_hit: float = 1.0 + min(amount / 110.0, 0.11) + (0.05 if is_crit else 0.0)
	tw.tween_property(_mesh, "scale", Vector3(scale_hit, 0.92, scale_hit), 0.06)
	tw.tween_property(_mesh, "scale", Vector3.ONE, 0.16)
	# Color flash overlay
	var flash := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.62, 1.82, 0.5)
	flash.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.32, 0.28, 0.45) if not is_crit else Color(1.0, 0.78, 0.18, 0.55)
	flash.material_override = mat
	_mesh.add_child(flash)
	flash.position = Vector3(0, 0.92, 0)
	var tw2 := create_tween()
	tw2.tween_property(mat, "albedo_color:a", 0.0, 0.19)
	tw2.tween_callback(func(): if is_instance_valid(flash): flash.queue_free())

func _on_died(_killer: Node) -> void:
	_stun_timer = 999.0
	if ragdoll == null:
		_setup_ragdoll()
	if ragdoll:
		var dir: Vector3 = Vector3.ZERO
		var pos: Vector3 = global_position + Vector3(0, 0.9, 0)
		var strength: float = 7.0
		if _killer is Node3D and _killer != self:
			dir = (global_position - (_killer as Node3D).global_position)
			dir.y = 0.18
			if dir.length() < 0.1:
				dir = Vector3.FORWARD
			dir = dir.normalized()
			if _killer is CharacterBody3D:
				var kv: Vector3 = (_killer as CharacterBody3D).velocity
				if kv.length() > 1.0:
					dir = (dir + kv.normalized()*0.5).normalized()
					strength += kv.length() * 0.22
			# Use last knockback from Health if available (more accurate)
			if health and health.get("_last_knockback") != null:
				var kb: Vector3 = health.get("_last_knockback")
				if kb.length() > 0.5:
					dir = kb.normalized()
					strength = kb.length() * 0.9 + 5.0
		else:
			dir = Vector3(randf_range(-1,1), 0.18, randf_range(-1,1)).normalized()
		ragdoll.start_ragdoll(dir, pos, strength)
		# Also play falling anim before ragdoll takes over? No, ragdoll freezes anim
	else:
		_play("falling_idle" if c11_ap and c11_ap.has_animation("falling_idle") else "Idle", 0.08)
		if _mesh:
			var tw := create_tween()
			tw.tween_property(_mesh, "scale", Vector3(1.18, 0.68, 1.18), 0.14)
	# Respawn is handled solely by Health._do_death_effect to avoid double timers
	# (previously this and Health both scheduled respawn causing double teleport + slide)

func respawn() -> void:
	if has_meta("is_being_grabbed") and bool(get_meta("is_being_grabbed")):
		print("[Dummy] respawn BLOCKED while grabbed %s" % name)
		return
	if not health.is_dead and not (ragdoll and ragdoll.is_ragdolled()):
		return
	var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs:
		cs.disabled = true
	# Reset ragdoll first — this restores original collision layers/masks
	if ragdoll and ragdoll.is_ragdolled():
		ragdoll.reset_ragdoll()
		if cs:
			cs.disabled = true
	# Capture the correct original layers after ragdoll reset
	var saved_layer := collision_layer
	var saved_mask := collision_mask
	collision_layer = 0
	collision_mask = 0
	_stun_timer = 0.0
	velocity = Vector3.ZERO
	global_position = _respawn_pos
	rotation.y = _respawn_yaw
	velocity = Vector3.ZERO
	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()
	set_meta("_saved_layer", saved_layer)
	set_meta("_saved_mask", saved_mask)
	_respawn_lock = 0.85
	_anchor_timer = 0.8
	if _mesh:
		_mesh.scale = Vector3.ONE
		# Reset skeleton pose explicitly (ragdoll may have left bones offset)
		var skel := get_node_or_null("Mesh/C11/root/Skeleton3D") as Skeleton3D
		if skel == null:
			skel = _find_skeleton_for_reset()
		if skel:
			# Zero any leftover bone velocities again (ragdoll may have set them)
			for child in skel.get_children():
				if child is PhysicalBone3D:
					var pb := child as PhysicalBone3D
					pb.linear_velocity = Vector3.ZERO
					pb.angular_velocity = Vector3.ZERO
			if skel.has_method("reset_bone_poses"):
				skel.reset_bone_poses()
			elif skel.has_method("clear_bones_global_pose_override"):
				skel.clear_bones_global_pose_override()
			if skel.has_method("force_update_bone_child_transforms"):
				skel.force_update_bone_child_transforms()
	_play("Idle", 0.12)
	# Spawn flash
	if _mesh:
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
		tw.tween_callback(func(): if is_instance_valid(flash): flash.queue_free())
	if health:
		health.set("_invuln_timer", 1.3)
	# Debug — if still slides, will print velocity/pos next frames
	#print("[Dummy] respawn at ", global_position, " vel ", velocity, " lock ", _respawn_lock)

func _find_skeleton_for_reset() -> Skeleton3D:
	# helper to locate skeleton without depending on ragdoll
	var m := get_node_or_null("Mesh")
	if m:
		for c in m.get_children():
			var sk := c.get_node_or_null("root/Skeleton3D") as Skeleton3D
			if sk:
				return sk
			sk = c.find_child("Skeleton3D", true, false) as Skeleton3D
			if sk:
				return sk
	return null
