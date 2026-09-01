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

const PUNCH_HIT_SOUND: AudioStream = preload("res://Assets/Sounds/Punch/Punch.mp3")
const KICK_HIT_SOUND: AudioStream = preload("res://Assets/Sounds/Punch/Kick.mp3")

var current: float = 100.0
var is_dead: bool = false
var _invuln_timer: float = 0.0
var _flash_tween: Tween
var _last_knockback: Vector3 = Vector3.ZERO
var _last_hit_dir: Vector3 = Vector3.ZERO

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
	_last_knockback = knockback
	_last_hit_dir = knockback.normalized() if knockback.length() > 0.01 else Vector3.ZERO
	var is_ragdolled: bool = false
	if _owner_body and _owner_body.has_node("RagdollController"):
		var rc = _owner_body.get_node("RagdollController")
		if rc and rc.has_method("is_ragdolled") and rc.is_ragdolled():
			is_ragdolled = true
	var is_anchored: bool = false
	if _owner_body and _owner_body.get("_anchor_timer") != null and float(_owner_body.get("_anchor_timer")) > 0.0:
		is_anchored = true
	if _owner_body and _owner_body.get("_respawn_lock") != null and float(_owner_body.get("_respawn_lock")) > 0.0:
		is_anchored = true
	if _owner_body and knockback != Vector3.ZERO and not is_ragdolled and not is_anchored:
		_owner_body.velocity += knockback
		# brief stun: add meta
		_owner_body.set_meta("stun_time", 0.22 if is_crit else 0.14)
	damaged.emit(amount, from, knockback, is_crit)
	_do_flash(is_crit)
	_do_hitstop(hitstop)
	if current <= 0.0 and can_die and not is_dead:
		is_dead = true
		died.emit(from)
		# Play hit feedback FIRST so the killing-blow impact reads on audio. Then run death
		# effects (ragdoll, respawn, particles). Spawned AudioStreamPlayer3D is added to the
		# scene tree so it survives the death sequence.
		_spawn_hit_feedback(amount, from, is_crit)
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
	# Freeze gameplay time WITHOUT freezing the audio mix. Using Engine.time_scale pauses
	# audio globally, which makes hit sounds play slow/muffled. Instead we use
	# physics_jitter_fix on a freeze-like trick: cancel velocity-driven motion in the
	# victim by setting their velocity to zero, then use a real-time timer to wait.
	var body: CharacterBody3D = _owner_body
	if body == null:
		return
	var saved_vel: Vector3 = body.velocity
	body.velocity = Vector3.ZERO
	# Also brief attacker-stuck visual: small lunge freeze via meta (read by Player._physics_process)
	if body.has_meta("hit_confirm"):
		body.set_meta("hitstop_remaining", duration)
	await Engine.get_main_loop().create_timer(duration, true, false, true).timeout
	if is_instance_valid(body):
		body.velocity = saved_vel * 0.4 # return with damping, not full snap-back
		if body.has_meta("hitstop_remaining"):
			body.remove_meta("hitstop_remaining")

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
	mat.gravity = Vector3(0, -18.0, 0)
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
	# Hit sound: pick Punch.mp3 vs Kick.mp3 based on attacker's current attack anim.
	_play_hit_sound(body, amount, is_crit, from)

func _is_kick_attack(from: Node) -> bool:
	if from == null:
		return false
	# 1) Prefer the attacker's currently-playing upper anim (most reliable signal at hit moment)
	if "c11_current_anim" in from:
		var anim_name: String = String(from.get("c11_current_anim"))
		if anim_name != "":
			var lower: String = anim_name.to_lower()
			if "kick" in lower:
				return true
			# Throws/dashes aren't melee — fall through to combo_index check
	# 2) Fallback: combo_index 3 == kick_spin
	if "combo_index" in from:
		var idx: int = int(from.get("combo_index"))
		if idx >= 3:
			return true
	return false

func _play_hit_sound(at: Node3D, amount: float, is_crit: bool, from: Node = null) -> void:
	var player := AudioStreamPlayer3D.new()
	player.max_distance = 32.0
	player.unit_size = 18.0
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.attenuation_filter_db = 0.0
	player.attenuation_filter_cutoff_hz = 20500.0
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	var use_kick: bool = _is_kick_attack(from)
	var stream: AudioStream = KICK_HIT_SOUND if use_kick else PUNCH_HIT_SOUND
	player.stream = stream
	# NO pitch jitter — randomizing pitch on short transients shifts frequency content and
	# makes the punch sound dull/muffled. Play at native rate for maximum impact/crispness.
	player.pitch_scale = 1.0
	# Volume scales lightly with damage; crits a bit louder; kicks a bit heavier
	var base_db: float = -4.0
	if use_kick:
		base_db = -2.0
	if is_crit:
		base_db += 2.0
	base_db += (clampf(amount, 0.0, 30.0) / 22.0) * 3.0
	player.volume_db = base_db
	at.get_tree().current_scene.add_child(player)
	player.global_position = at.global_position + Vector3(0, 1.0, 0)
	player.play()
	# Free after the stream length + a small tail (use the actual stream length if available)
	var dur: float = 0.5
	if stream is AudioStreamMP3:
		dur = (stream as AudioStreamMP3).get_length()
	elif stream is AudioStreamWAV:
		dur = (stream as AudioStreamWAV).get_length()
	var tl := at.get_tree().create_timer(dur + 0.25)
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
	# For player, respawn after delay — delegate to body if it has ragdoll-aware respawn
	if body.is_in_group("dummy") or body.name.contains("Dummy"):
		var respawn_delay: float = 3.2 # longer so GTA ragdoll can settle and flop
		if body.has_method("get") and body.get("respawn_time") != null:
			respawn_delay = float(body.get("respawn_time"))
			# Clamp to at least 2.5 for ragdoll visibility
			respawn_delay = max(respawn_delay, 2.5)
		var t := body.get_tree().create_timer(respawn_delay)
		t.timeout.connect(func():
			if not is_instance_valid(body):
				return
			# While being grabbed, defer respawn — only after release
			await _wait_until_not_grabbed(body)
			if not is_instance_valid(body):
				return
			# If already respawned by grab-release logic, skip
			if not is_dead:
				return
			current = max_health
			is_dead = false
			_last_knockback = Vector3.ZERO
			if body.has_method("respawn"):
				body.respawn()
			else:
				body.global_position += Vector3(0, 0.1, 0)
			health_changed.emit(current, max_health)
		)
	else:
		# player death: slight time slow + respawn after 2.5s at y+2 (let ragdoll flop like GTA)
		var pd: float = 2.8
		var t2 := body.get_tree().create_timer(pd)
		t2.timeout.connect(func():
			if not is_instance_valid(body):
				return
			await _wait_until_not_grabbed(body)
			if not is_instance_valid(body):
				return
			if not is_dead:
				return
			current = max_health
			is_dead = false
			_last_knockback = Vector3.ZERO
			if body.has_method("_respawn_after_death"):
				body.call("_respawn_after_death")
			else:
				if body.has_node("RagdollController"):
					var rc = body.get_node("RagdollController")
					if rc and rc.has_method("reset_ragdoll"):
						rc.reset_ragdoll()
				body.global_position = Vector3(0, 2.2, 0)
				body.velocity = Vector3.ZERO
			health_changed.emit(current, max_health)
		)

func _wait_until_not_grabbed(body: Node) -> void:
	# Poll until grab released. If never grabbed, returns immediately.
	while is_instance_valid(body) and body.has_meta("is_being_grabbed") and bool(body.get_meta("is_being_grabbed")):
		if not is_instance_valid(body):
			return
		var tree = body.get_tree()
		if tree == null:
			return
		await tree.create_timer(0.2).timeout
	# Extra small delay so physics can settle after drop
	if is_instance_valid(body) and body.has_meta("is_being_grabbed"):
		pass
	else:
		# brief settle delay only if we actually waited
		pass
