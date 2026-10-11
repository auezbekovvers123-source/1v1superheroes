extends Power
class_name SuperSpeedPower
## Speed boots: hold Shift to run at super speed, crackling with lightning and
## leaving a trail of phantom copies of yourself; the dodge (Ctrl) becomes a
## long dash.

const RUN_SPEED := 17.0 # m/s (a normal run is 5)
const DASH_SCALE := 2.2
const STREAK_MIN_SPEED := 8.0
const STREAK_EVERY := 0.05 # seconds between afterimages
const STREAK_LIFE := 0.3 # seconds an afterimage takes to fade out
const STREAK_COLOR := Color(1.0, 0.6, 0.15)
const AFTERIMAGE_SHADER := preload("res://Assets/Shaders/afterimage.gdshader")

var _streak_timer: float = 0.0
var _lightning: SpeedLightning = null

func added() -> void:
	_lightning = SpeedLightning.new()
	_lightning.name = "SpeedLightning"
	_lightning.runner = player
	player.add_child(_lightning)

func removed() -> void:
	if _lightning and is_instance_valid(_lightning):
		_lightning.queue_free()
	_lightning = null

func run_speed() -> float:
	return RUN_SPEED

func dash_scale() -> float:
	return DASH_SCALE

func physics_update(delta: float) -> void:
	var flat := Vector2(player.velocity.x, player.velocity.z)
	var fast := flat.length() > STREAK_MIN_SPEED and not player.is_dead()
	if _lightning:
		_lightning.active = fast
	if not fast:
		_streak_timer = 0.0
		return
	_streak_timer -= delta
	if _streak_timer <= 0.0:
		_streak_timer = STREAK_EVERY
		_spawn_afterimage()

func hint() -> String:
	return "Super speed: hold Shift  (Ctrl dashes far)"

## A phantom copy of the runner, frozen in this frame's pose, left where they
## just were and fading out. Each of the runner's skeletons (body, cape) gets a
## frozen twin; the meshes are the runner's own, drawn with a glow shader.
func _spawn_afterimage() -> void:
	var skel := player.get_skeleton()
	if skel == null:
		return
	var ghost := Node3D.new()
	ghost.name = "SpeedAfterimage"
	ghost.add_to_group("afterimage")
	HitEffects.parent_for(player).add_child(ghost)
	var mat := ShaderMaterial.new()
	mat.shader = AFTERIMAGE_SHADER
	mat.set_shader_parameter("color", STREAK_COLOR)
	var frozen := {} # the runner's Skeleton3D -> its posed copy
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var src := n as MeshInstance3D
		if src.mesh == null or not src.is_visible_in_tree():
			continue # e.g. hitbox debug shapes
		var copy := MeshInstance3D.new()
		copy.mesh = src.mesh
		copy.material_override = mat
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var src_skel := src.get_node_or_null(src.skeleton) as Skeleton3D
		if src_skel:
			# Skinned (body, cape): same mesh and skin on a copy of its skeleton
			if not frozen.has(src_skel):
				frozen[src_skel] = _freeze(src_skel, ghost)
			var twin: Skeleton3D = frozen[src_skel]
			twin.add_child(copy)
			copy.skin = src.skin
			copy.transform = src_skel.global_transform.affine_inverse() * src.global_transform
		else:
			# Rigid gear pinned to a bone (boots, visor)
			ghost.add_child(copy)
			copy.global_transform = src.global_transform
	var tw := ghost.create_tween()
	tw.tween_method(func(a: float): mat.set_shader_parameter("fade", a), 1.0, 0.0, STREAK_LIFE)
	tw.tween_callback(ghost.queue_free)

## A skeleton holding `src`'s current pose, placed where `src` is.
static func _freeze(src: Skeleton3D, parent: Node3D) -> Skeleton3D:
	var s := Skeleton3D.new()
	for b in src.get_bone_count():
		s.add_bone(src.get_bone_name(b))
	for b in src.get_bone_count():
		s.set_bone_parent(b, src.get_bone_parent(b))
		s.set_bone_rest(b, src.get_bone_rest(b))
		s.set_bone_pose_position(b, src.get_bone_pose_position(b))
		s.set_bone_pose_rotation(b, src.get_bone_pose_rotation(b))
		s.set_bone_pose_scale(b, src.get_bone_pose_scale(b))
	parent.add_child(s)
	s.global_transform = src.global_transform
	return s
