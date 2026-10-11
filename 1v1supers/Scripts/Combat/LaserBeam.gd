extends Node3D
class_name LaserBeam
## The heat beam's look: a hot core and a soft glow from each eye to the impact
## point, glowing eyes, and sparks where it hits. Positions are world space.

const CORE_COLOR := Color(1.0, 0.55, 0.45, 1.0)
const GLOW_COLOR := Color(1.0, 0.08, 0.05, 0.45)

var _cores: Array[MeshInstance3D] = []
var _glows: Array[MeshInstance3D] = []
var _eye_glows: Array[MeshInstance3D] = []
var _impact: MeshInstance3D
var _sparks: GPUParticles3D

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	for k in 2:
		_cores.append(_cylinder(0.018, CORE_COLOR))
		_glows.append(_cylinder(0.055, GLOW_COLOR))
		_eye_glows.append(_sphere(0.05, Color(1.0, 0.2, 0.1, 0.9)))
	_impact = _sphere(0.14, Color(1.0, 0.35, 0.15, 0.8))
	_sparks = _make_sparks()
	add_child(_sparks)
	visible = false

## Beams from both eyes to `end`; `touching` = the beam hits something there.
func show_beam(eye_l: Vector3, eye_r: Vector3, end: Vector3, touching: bool) -> void:
	visible = true
	var eyes := [eye_l, eye_r]
	var flicker := randf_range(0.85, 1.15)
	for k in 2:
		_stretch(_cores[k], eyes[k], end, flicker)
		_stretch(_glows[k], eyes[k], end, flicker)
		_eye_glows[k].global_position = eyes[k]
	_impact.visible = touching
	_impact.global_position = end
	_impact.scale = Vector3.ONE * flicker
	_sparks.global_position = end
	_sparks.emitting = touching

## Lays a unit cylinder (Y axis, height 1) from a to b.
func _stretch(mi: MeshInstance3D, a: Vector3, b: Vector3, thickness: float) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.01:
		mi.visible = false
		return
	mi.visible = true
	var y := d / length
	var helper := Vector3.UP if abs(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := y.cross(helper).normalized()
	var z := x.cross(y)
	mi.global_transform = Transform3D(Basis(x * thickness, y * length, z * thickness), (a + b) * 0.5)

func _cylinder(radius: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = 1.0
	c.radial_segments = 8
	c.rings = 1
	mi.mesh = c
	mi.material_override = _glow_material(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _sphere(radius: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = 12
	s.rings = 6
	mi.mesh = s
	mi.material_override = _glow_material(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

static func _glow_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	return m

## Molten streaks flying off the impact point.
func _make_sparks() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.35
	p.local_coords = false
	p.emitting = false
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 80.0
	m.initial_velocity_min = 1.5
	m.initial_velocity_max = 4.0
	m.gravity = Vector3(0, -9.8, 0)
	p.process_material = m
	var streak := QuadMesh.new()
	streak.size = Vector2(0.02, 0.12)
	var qm := _glow_material(Color(1.0, 0.6, 0.2, 1.0))
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	streak.material = qm
	p.draw_pass_1 = streak
	return p
