extends MeshInstance3D
class_name SpeedLightning
## Super speed's lightning: jagged bolts that crackle off the runner's limbs and
## body, plus longer ones streaking back along the path. Each bolt lives a few
## frames and strikes again somewhere else, so the light flickers. Drawn every
## frame as camera-facing ribbons in world space: a coloured glow (normal
## blending, so it stays coloured against a bright sky) with an additive
## white-hot core on top.

const CORE_COLOR := Color(1.0, 0.97, 0.85)
const GLOW_COLOR := Color(1.0, 0.68, 0.12) # gold, like the afterimages
const CORE_WIDTH := 0.018
const GLOW_WIDTH := 0.075
const BODY_BOLTS := 5 # short bolts on the body at once
const TRAIL_BOLTS := 2 # long bolts streaking back at once
const BOLT_LIFE := Vector2(0.04, 0.09) # seconds, random in this range
const ROUGHNESS := 0.35 # sideways jitter, as a fraction of the bolt's length
## Where bolts strike from: limbs and body.
const BONES := ["spine_02.x", "spine_03.x", "head.x", "arm_stretch.l", "arm_stretch.r", "forearm_stretch.l",
	"forearm_stretch.r", "hand.l", "hand.r", "thigh_stretch.l", "thigh_stretch.r", "leg_stretch.l",
	"leg_stretch.r", "foot.l", "foot.r"]

## Bolts strike while this is on (the runner is going fast).
var active: bool = false
var runner: Player

var _bolts: Array[Dictionary] = [] # {points (relative to the runner), branch, age, life, trail}
var _bone_ids: PackedInt32Array = []
var _imesh := ImmediateMesh.new()
var _glow_mat: StandardMaterial3D
var _core_mat: StandardMaterial3D
var _light: OmniLight3D

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _imesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glow_mat = _material(BaseMaterial3D.BLEND_MODE_MIX)
	_core_mat = _material(BaseMaterial3D.BLEND_MODE_ADD)
	_core_mat.render_priority = 1 # the core draws over its glow
	_light = OmniLight3D.new()
	_light.light_color = GLOW_COLOR
	_light.omni_range = 3.0
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)
	var skel := runner.get_skeleton() if runner else null
	if skel:
		for b in BONES:
			var idx := skel.find_bone(b)
			if idx >= 0:
				_bone_ids.append(idx)

static func _material(blend: BaseMaterial3D.BlendMode) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = blend
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	return m

func bolt_count() -> int:
	return _bolts.size()

func _process(delta: float) -> void:
	if runner == null or not is_instance_valid(runner):
		return
	if _bolts.is_empty() and not active:
		if _imesh.get_surface_count() > 0:
			_imesh.clear_surfaces()
			_light.visible = false
		return
	var alive: Array[Dictionary] = []
	for b in _bolts:
		b.age += delta
		if b.age < b.life:
			alive.append(b)
	_bolts = alive
	if active:
		while _count(false) < BODY_BOLTS:
			_bolts.append(_strike(false))
		while _count(true) < TRAIL_BOLTS:
			_bolts.append(_strike(true))
	_light.visible = not _bolts.is_empty()
	if _light.visible:
		_light.global_position = runner.global_position + Vector3(0, 1.0, 0)
		_light.light_energy = randf_range(0.6, 2.2) # flicker
	_draw()

func _count(trail: bool) -> int:
	var n := 0
	for b in _bolts:
		if b.trail == trail:
			n += 1
	return n

## A new bolt from a random spot on the body. Body bolts are short and fly
## off sideways and back; trail bolts stretch back along the path.
func _strike(trail: bool) -> Dictionary:
	var start := _body_point()
	var back := -Vector3(runner.velocity.x, 0.0, runner.velocity.z).normalized()
	if back.length() < 0.5:
		back = -runner.mesh.global_basis.z
	var side := Vector3(randf_range(-1, 1), randf_range(-0.6, 0.8), randf_range(-1, 1)).normalized()
	var end: Vector3
	if trail:
		end = start + back * randf_range(1.2, 2.4) + side * 0.35
		end.y = clampf(end.y, runner.global_position.y + 0.05, runner.global_position.y + 1.8)
	else:
		end = start + (side + back * 0.8).normalized() * randf_range(0.25, 0.6)
	var origin := runner.global_position
	var points := _jag(start - origin, end - origin, 4)
	var branch := PackedVector3Array()
	if randf() < 0.6:
		var from: Vector3 = points[randi_range(2, points.size() - 4)]
		var dir := (end - start).normalized().lerp(side, 0.6).normalized()
		branch = _jag(from, from + dir * (end - start).length() * randf_range(0.25, 0.45), 3)
	return {"points": points, "branch": branch, "age": 0.0, "life": randf_range(BOLT_LIFE.x, BOLT_LIFE.y), "trail": trail}

func _body_point() -> Vector3:
	var skel := runner.get_skeleton()
	if skel == null or _bone_ids.is_empty():
		return runner.global_position + Vector3(randf_range(-0.25, 0.25), randf_range(0.3, 1.7), randf_range(-0.25, 0.25))
	var idx := _bone_ids[randi() % _bone_ids.size()]
	return skel.global_transform * skel.get_bone_global_pose(idx).origin

## Midpoint displacement: a straight line from a to b, split `depth` times,
## each new point pushed sideways a little less than the last.
static func _jag(a: Vector3, b: Vector3, depth: int) -> PackedVector3Array:
	var pts := PackedVector3Array([a, b])
	var offset := a.distance_to(b) * ROUGHNESS
	for level in depth:
		var next := PackedVector3Array()
		for i in pts.size() - 1:
			var p: Vector3 = pts[i]
			var q: Vector3 = pts[i + 1]
			next.append(p)
			var dir := (q - p).normalized()
			var perp := dir.cross(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))).normalized()
			next.append((p + q) * 0.5 + perp * randf_range(-offset, offset))
		next.append(pts[pts.size() - 1])
		pts = next
		offset *= 0.55
	return pts

func _draw() -> void:
	_imesh.clear_surfaces()
	if _bolts.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	var eye: Vector3 = cam.global_position if cam else runner.global_position + Vector3(0, 3, 4)
	var origin := runner.global_position
	for glow in [true, false]:
		_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _glow_mat if glow else _core_mat)
		var width := GLOW_WIDTH if glow else CORE_WIDTH
		for b in _bolts:
			var col := GLOW_COLOR if glow else CORE_COLOR
			col.a = (1.0 - b.age / b.life) * (0.6 if glow else 1.0)
			_ribbon(b.points, origin, eye, width, col)
			if not (b.branch as PackedVector3Array).is_empty():
				_ribbon(b.branch, origin, eye, width * 0.7, col)
		_imesh.surface_end()

## A strip of quads along `pts` (relative to `origin`), turned to face `eye`,
## thinning towards the tip.
func _ribbon(pts: PackedVector3Array, origin: Vector3, eye: Vector3, width: float, col: Color) -> void:
	var n := pts.size()
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	left.resize(n)
	right.resize(n)
	for i in n:
		var p: Vector3 = pts[i] + origin
		var tangent: Vector3 = pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		var side := tangent.cross(eye - p).normalized() * width * 0.5 * (1.0 - 0.6 * float(i) / float(n - 1))
		left[i] = p - side
		right[i] = p + side
	_imesh.surface_set_color(col)
	for i in n - 1:
		_imesh.surface_add_vertex(left[i])
		_imesh.surface_add_vertex(right[i])
		_imesh.surface_add_vertex(right[i + 1])
		_imesh.surface_add_vertex(left[i])
		_imesh.surface_add_vertex(right[i + 1])
		_imesh.surface_add_vertex(left[i + 1])
