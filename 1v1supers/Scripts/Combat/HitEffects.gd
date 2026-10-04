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
	var crit := hit.is_critical()
	var particles := _burst(Color(1.0, 0.85, 0.2) if crit else Color(1.0, 0.45, 0.15), 12 if not crit else 28, 0.35,
		Vector3(0, 1, 0), 45.0, 4.0, 9.0 if not crit else 14.0, Vector3(0, -18.0, 0), 0.08, 0.18, 0.12)
	parent_for(body).add_child(particles)
	particles.global_position = body.global_position + Vector3(0, 1.0, 0) + Vector3(randf_range(-0.2, 0.2), 0, randf_range(-0.2, 0.2))
	particles.emitting = true
	_free_later(particles, 1.0)
	_play_hit_sound(body, hit)

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
