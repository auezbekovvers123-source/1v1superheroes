extends RefCounted
class_name HitEffects
## Transient hit feedback (particles, sparks, sounds). Pure presentation.

const PUNCH_HIT_SOUND: AudioStream = preload("res://Assets/Sounds/Punch/Punch.mp3")
const KICK_HIT_SOUND: AudioStream = preload("res://Assets/Sounds/Punch/Kick.mp3")

## Where transient effects go: the current scene, or the root when there is none (tests/tools).
static func parent_for(n: Node) -> Node:
	var tree := n.get_tree()
	return tree.current_scene if tree.current_scene else tree.root

## Burst of particles + impact sound at a body that took a hit.
static func on_damaged(body: Node3D, hit: HitInfo) -> void:
	if hit.parried or hit.blocked:
		_guard_burst(body, hit)
		return
	if hit.guard_broken:
		popup_text(body, "GUARD BREAK", Color(1.0, 0.45, 0.2))
	var crit := hit.is_critical()
	var particles := _burst(Color(1.0, 0.85, 0.2) if crit else Color(1.0, 0.45, 0.15), 12 if not crit else 28, 0.35,
		Vector3(0, 1, 0), 45.0, 4.0, 9.0 if not crit else 14.0, Vector3(0, -18.0, 0), 0.08, 0.18, 0.12)
	parent_for(body).add_child(particles)
	particles.global_position = body.global_position + Vector3(0, 1.0, 0) + Vector3(randf_range(-0.2, 0.2), 0, randf_range(-0.2, 0.2))
	particles.emitting = true
	_free_later(particles, 1.0)
	_play_hit_sound(body, hit)

## A hit caught on the guard: cool sparks, a higher clink, a word over the head.
static func _guard_burst(body: Node3D, hit: HitInfo) -> void:
	var color := Color(0.4, 0.9, 1.0) if hit.parried else Color(0.85, 0.92, 1.0)
	var p := _burst(color, 22 if hit.parried else 10, 0.3, Vector3(0, 0.6, 0), 70.0, 4.0, 9.0, Vector3(0, -9.8, 0), 0.05, 0.1, 0.1)
	parent_for(body).add_child(p)
	p.global_position = body.global_position + Vector3(0, 1.15, 0)
	p.emitting = true
	_free_later(p, 1.0)
	popup_text(body, "PARRY!" if hit.parried else "BLOCK", color)
	var sfx := AudioStreamPlayer3D.new()
	sfx.stream = PUNCH_HIT_SOUND
	sfx.pitch_scale = 2.0 if hit.parried else 1.6
	sfx.volume_db = -3.0 if hit.parried else -8.0
	sfx.max_distance = 32.0
	sfx.unit_size = 18.0
	parent_for(body).add_child(sfx)
	sfx.global_position = body.global_position + Vector3(0, 1.0, 0)
	sfx.play()
	_free_later(sfx, sfx.stream.get_length() / sfx.pitch_scale + 0.25)

## A word that pops above a body and floats away (BLOCK, PARRY!, GUARD BREAK).
static func popup_text(body: Node3D, text: String, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 64
	label.outline_size = 14
	label.pixel_size = 0.004
	parent_for(body).add_child(label)
	label.global_position = body.global_position + Vector3(0, 2.0, 0)
	var tw := label.create_tween().set_parallel(true)
	tw.tween_property(label, "global_position:y", label.global_position.y + 0.6, 0.7).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.25)
	_free_later(label, 0.75)

## Sparks between a hitbox and the body it hit.
static func sparks(at: Vector3, from: Node) -> void:
	var p := _burst(Color(1.0, 0.92, 0.35), 10, 0.28, Vector3(0, 0.4, 0), 55.0, 6.0, 11.0, Vector3(0, -9.8, 0), 0.04, 0.09, 0.09)
	p.explosiveness = 0.95
	parent_for(from).add_child(p)
	p.global_position = at
	p.emitting = true
	_free_later(p, 1.0)

static func _burst(color: Color, amount: int, lifetime: float, dir: Vector3, spread: float, vmin: float, vmax: float,
		gravity: Vector3, smin: float, smax: float, quad_size: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	var mat := ParticleProcessMaterial.new()
	mat.direction = dir
	mat.spread = spread
	mat.initial_velocity_min = vmin
	mat.initial_velocity_max = vmax
	mat.gravity = gravity
	mat.scale_min = smin
	mat.scale_max = smax
	var quad := QuadMesh.new()
	quad.size = Vector2(quad_size, quad_size)
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = color
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = pm
	particles.draw_pass_1 = quad
	particles.process_material = mat
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 0.9
	return particles

static func _play_hit_sound(at: Node3D, hit: HitInfo) -> void:
	var player := AudioStreamPlayer3D.new()
	player.max_distance = 32.0
	player.unit_size = 18.0
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	# No distance low-pass and no pitch jitter: both make short impact transients sound dull.
	player.attenuation_filter_db = 0.0
	player.attenuation_filter_cutoff_hz = 20500.0
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	var kick := hit.kind == HitInfo.Kind.KICK
	player.stream = KICK_HIT_SOUND if kick else PUNCH_HIT_SOUND
	# Volume scales lightly with damage; crits a bit louder; kicks a bit heavier
	var db: float = -2.0 if kick else -4.0
	if hit.is_critical():
		db += 2.0
	db += (clampf(hit.damage, 0.0, 30.0) / 22.0) * 3.0
	player.volume_db = db
	parent_for(at).add_child(player)
	player.global_position = at.global_position + Vector3(0, 1.0, 0)
	player.play()
	_free_later(player, player.stream.get_length() + 0.25)

static func _free_later(n: Node, seconds: float) -> void:
	# Bound method, not a lambda: the connection dies with the node if a scene change frees it first
	n.get_tree().create_timer(seconds).timeout.connect(n.queue_free)
