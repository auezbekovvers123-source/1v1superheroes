extends Power
class_name SuperSpeedPower
## Speed boots: hold Shift to run at super speed, leaving an electric streak;
## the dodge (Ctrl) becomes a long dash.

const RUN_SPEED := 17.0 # m/s (a normal run is 5)
const DASH_SCALE := 2.2
const STREAK_MIN_SPEED := 8.0
const STREAK_EVERY := 0.035 # seconds between afterimages
const STREAK_COLOR := Color(1.0, 0.6, 0.15, 0.35)

var _streak_timer: float = 0.0
var _sparks: GPUParticles3D = null

func added() -> void:
	_sparks = _make_sparks()
	player.add_child(_sparks)

func removed() -> void:
	if _sparks and is_instance_valid(_sparks):
		_sparks.queue_free()
	_sparks = null

func run_speed() -> float:
	return RUN_SPEED

func dash_scale() -> float:
	return DASH_SCALE

func physics_update(delta: float) -> void:
	var flat := Vector2(player.velocity.x, player.velocity.z)
	var fast := flat.length() > STREAK_MIN_SPEED and not player.is_dead()
	if _sparks:
		_sparks.emitting = fast
	if not fast:
		_streak_timer = 0.0
		return
	_streak_timer -= delta
	if _streak_timer <= 0.0:
		_streak_timer = STREAK_EVERY
		_spawn_afterimage()

func hint() -> String:
	return "Super speed: hold Shift  (Ctrl dashes far)"

## A fading, body-sized glow left where the runner just was.
func _spawn_afterimage() -> void:
	var ghost := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.32
	capsule.height = 1.75
	ghost.mesh = capsule
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = STREAK_COLOR
	ghost.material_override = mat
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	HitEffects.parent_for(player).add_child(ghost)
	ghost.global_position = player.global_position + Vector3(0, 0.92, 0)
	var tw := ghost.create_tween().set_parallel(true)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.22)
	tw.tween_property(ghost, "scale", Vector3(0.6, 0.9, 0.6), 0.22)
	tw.chain().tween_callback(ghost.queue_free)

## Little electric streaks crackling off the runner.
func _make_sparks() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "SpeedSparks"
	p.amount = 40
	p.lifetime = 0.25
	p.local_coords = false
	p.emitting = false
	p.position = Vector3(0, 0.9, 0)
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(0.3, 0.8, 0.3)
	m.direction = Vector3(0, 1, 0)
	m.spread = 180.0
	m.initial_velocity_min = 2.0
	m.initial_velocity_max = 5.0
	m.gravity = Vector3.ZERO
	m.damping_min = 8.0
	m.damping_max = 12.0
	m.color = Color(1.0, 0.9, 0.35)
	p.process_material = m
	var streak := QuadMesh.new()
	streak.size = Vector2(0.025, 0.22)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.vertex_color_use_as_albedo = true
	qm.albedo_color = Color(1.0, 0.95, 0.6)
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	streak.material = qm
	p.draw_pass_1 = streak
	return p
