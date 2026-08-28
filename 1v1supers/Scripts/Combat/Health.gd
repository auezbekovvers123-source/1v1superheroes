extends Node
class_name Health
## Health.gd — reusable health component with i-frames, flash & knockback sink

signal damaged(amount: float, from: Node, knockback: Vector3, is_critical: bool)
signal healed(amount: float)
signal died(killer: Node)
signal health_changed(current: float, max_val: float)

@export var max_health: float = 100.0
@export var invuln_time: float = 0.08
@export var can_die: bool = true
@export var auto_regen: bool = false
@export var regen_per_second: float = 5.0

var current: float = 100.0
var is_dead: bool = false
var _invuln_timer: float = 0.0
var _flash_tween: Tween

@onready var _owner_body: CharacterBody3D = get_parent() as CharacterBody3D

func _ready() -> void:
	current = max_health
	add_to_group("health")

func _physics_process(delta: float) -> void:
	if _invuln_timer > 0.0:
		_invuln_timer -= delta
	if auto_regen and not is_dead and current < max_health:
		current = min(max_health, current + regen_per_second * delta)
		health_changed.emit(current, max_health)

func can_take_damage() -> bool:
	return not is_dead and _invuln_timer <= 0.0

func take_damage(amount: float, from: Node = null, knockback: Vector3 = Vector3.ZERO, hitstop: float = 0.0, shake: float = 0.0) -> bool:
	if not can_take_damage():
		return false
	current -= amount
	_invuln_timer = invuln_time
	health_changed.emit(current, max_health)
	var is_crit := amount >= 18.0
	# Apply knockback to owner if CharacterBody3D
	if _owner_body and knockback != Vector3.ZERO:
		_owner_body.velocity += knockback
		# brief stun: add meta
		_owner_body.set_meta("stun_time", 0.22 if is_crit else 0.14)
	damaged.emit(amount, from, knockback, is_crit)
	_do_flash(is_crit)
	_do_hitstop(hitstop)
	if current <= 0.0 and can_die and not is_dead:
		is_dead = true
		died.emit(from)
		_do_death_effect(from)
	else:
		_spawn_hit_feedback(amount, from, is_crit)
	if shake > 0.0 and from and from.has_method("get_camera_shake_source"):
		pass
	return true

func heal(amount: float) -> void:
	if is_dead:
		return
	current = min(max_health, current + amount)
	healed.emit(amount)
	health_changed.emit(current, max_health)

func _do_hitstop(duration: float) -> void:
	if duration <= 0.0:
		return
	# Use Engine.time_scale hitstop — also pause physics briefly via timer
	var prev_scale := Engine.time_scale
	Engine.time_scale = 0.02
	# Unscaled timer via SceneTree
	await Engine.get_main_loop().create_timer(duration, true, false, true).timeout
	Engine.time_scale = prev_scale

func _do_flash(is_crit: bool) -> void:
	var body = get_parent()
	if body == null or not is_instance_valid(body):
		return
	var mesh_node = body.get_node_or_null("Mesh")
	if mesh_node == null or not is_instance_valid(mesh_node):
		return
	# Find all MeshInstance3D under mesh
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(mesh_node, meshes)
	# Filter out any freed/queued instances
	meshes = meshes.filter(func(m): return is_instance_valid(m) and not m.is_queued_for_deletion())
	if meshes.is_empty():
		return
	for mi in meshes:
		if not is_instance_valid(mi):
			continue
		if mi.get_surface_override_material_count() == 0:
			continue
	# Flash via modulate/tween on Mesh node scale + color flash via overlay
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	if not is_instance_valid(body):
		return
	_flash_tween = body.create_tween()
	if _flash_tween == null:
		return
	var col := Color(1.4, 0.35, 0.35, 1.0) if not is_crit else Color(1.6, 1.0, 0.4, 1.0)
	_flash_tween.tween_method(_apply_flash.bind(meshes), 0.0, 1.0, 0.05)
	_flash_tween.tween_method(_apply_flash.bind(meshes), 1.0, 0.0, 0.18)

func _apply_flash(intensity: float, meshes: Array[MeshInstance3D]) -> void:
	# Guard against freed instances (tween may outlive mesh during respawn)
	for mi in meshes:
		if not is_instance_valid(mi):
			continue
		# Use material override flash: lerp albedo toward white/red
		if mi.is_queued_for_deletion():
			continue
		var mat: Material = null
		if is_instance_valid(mi):
			mat = mi.get_active_material(0)
		if mat is StandardMaterial3D:
			var base = (mat as StandardMaterial3D).albedo_color
			# We don't permanently change, use overlay via instance param — instead modulate mesh
			pass
		if is_instance_valid(mi):
			mi.material_overlay = null
	# fallback: modulate parent mesh node via intensity (use Mesh node modulate proxy)
	var parent = get_parent()
	if parent == null or not is_instance_valid(parent):
		return
	var p = parent.get_node_or_null("Mesh")
	if p and is_instance_valid(p):
		if p is Node3D:
			# use scale punch as flash
			var s: float = 1.0 + intensity * 0.06
			p.scale = Vector3(s, 1.0 - intensity * 0.04, s)

func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if not is_instance_valid(node):
		return
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for c in node.get_children():
		if is_instance_valid(c):
			_collect_meshes(c, out)

func _spawn_hit_feedback(amount: float, from: Node, is_crit: bool) -> void:
	# Spawn particles + sound at body position (no asset dependency)
	var body = get_parent() as Node3D
	if body == null:
		return
	var particles = GPUParticles3D.new()
	var mat = ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 45.0
	mat.initial_velocity_min = 4.0
	mat.initial_velocity_max = 9.0 if not is_crit else 14.0
	mat.gravity = Vector3(0, -18, 0)
	mat.scale_min = 0.08
	mat.scale_max = 0.18
	var quad = QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)
	particles.draw_pass_1 = quad
	particles.process_material = mat
	particles.amount = 12 if not is_crit else 28
	particles.lifetime = 0.35
	particles.one_shot = true
	particles.explosiveness = 0.9
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = Color(1.0, 0.85, 0.2) if is_crit else Color(1.0, 0.45, 0.15)
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = pm
	body.get_tree().current_scene.add_child(particles)
	particles.global_position = body.global_position + Vector3(0, 1.0, 0) + Vector3(randf_range(-0.2, 0.2), 0, randf_range(-0.2, 0.2))
	particles.emitting = true
	# Auto free
	var t := body.get_tree().create_timer(1.0)
	t.timeout.connect(func(): if is_instance_valid(particles): particles.queue_free())
	# Screen shake on owner? handled by attacker
	# Hit sound procedural: short click via AudioStreamWAV
	_play_hit_sound(body, amount, is_crit)

func _play_hit_sound(at: Node3D, amount: float, is_crit: bool) -> void:
	var player := AudioStreamPlayer3D.new()
	player.max_distance = 22.0
	player.unit_size = 8.0
	# Generate a tiny WAV burst
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = false
	stream.mix_rate = 22050
	var dur := 0.09 if not is_crit else 0.16
	var samples := int(22050 * dur)
	var data := PackedByteArray()
	data.resize(samples * 2)
	var base_freq := 180.0 if not is_crit else 90.0
	for i in range(samples):
		var t: float = float(i) / 22050.0
		var env: float = exp(-t * 38.0) # decay
		var freq: float = base_freq * (1.0 + 0.6 * exp(-t * 70.0))
		var s: float = sin(TAU * freq * t) * env
		if is_crit:
			s += 0.35 * sin(TAU * freq * 2.1 * t) * env
			s *= 0.7
		# soft clip
		s = clamp(s, -0.9, 0.9)
		var iv := int(s * 9000)
		data[ i*2 ] = iv & 0xFF
		data[i*2+1] = (iv >> 8) & 0xFF
	stream.data = data
	player.stream = stream
	player.pitch_scale = randf_range(0.92, 1.08)
	player.volume_db = -6.0 + (amount / 22.0) * 4.0
	at.get_tree().current_scene.add_child(player)
	player.global_position = at.global_position + Vector3(0, 1.0, 0)
	player.play()
	var tl := at.get_tree().create_timer(dur + 0.2)
	tl.timeout.connect(func(): if is_instance_valid(player): player.queue_free())

func _do_death_effect(_killer: Node) -> void:
	var body = get_parent() as CharacterBody3D
	if body == null:
		return
	# Simple knockdown: disable collision briefly, flash, then respawn if dummy
	var col = body.get_node_or_null("CollisionShape3D")
	if col:
		# keep collision but maybe
		pass
	# For player, respawn after delay
	if body.is_in_group("dummy") or body.name.contains("Dummy"):
		var t := body.get_tree().create_timer(1.4)
		t.timeout.connect(func():
			if is_instance_valid(body):
				current = max_health
				is_dead = false
				if body.has_method("respawn"):
					body.respawn()
				else:
					body.global_position += Vector3(0, 0.1, 0)
				health_changed.emit(current, max_health)
		)
	else:
		# player death: slight time slow + respawn after 1.2s at y+2
		var t2 := body.get_tree().create_timer(1.2)
		t2.timeout.connect(func():
			if is_instance_valid(body):
				current = max_health
				is_dead = false
				body.global_position = Vector3(0, 2.2, 0)
				body.velocity = Vector3.ZERO
				health_changed.emit(current, max_health)
		)
