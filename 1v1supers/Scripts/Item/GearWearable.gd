extends WearableItem
class_name GearWearable
## Base for worn gear drawn from simple shapes (no art assets yet). Shapes are
## placed in character space - +Y up, +Z forward, metres from the bone - and
## follow the bone's motion.

var _twins: Array[Node] = []
var _main_material: StandardMaterial3D = null

## Holds shapes for `bone`: under this node for our own bone, or under a twin
## attachment for a second bone (a pair of boots).
func make_pivot(bone: String) -> Node3D:
	var skel := get_parent() as Skeleton3D
	var holder: Node3D = self
	if skel and bone != bone_name:
		var twin := BoneAttachment3D.new()
		twin.name = "%s_%s" % [name, bone.replace(".", "_")]
		twin.bone_name = bone
		skel.add_child(twin)
		_twins.append(twin)
		holder = twin
	var pivot := Node3D.new()
	pivot.name = "Gear"
	holder.add_child(pivot)
	if skel:
		var idx := skel.find_bone(bone)
		if idx >= 0:
			# Undo the bone's rest rotation: shapes are authored in character space
			pivot.basis = skel.get_bone_global_rest(idx).basis.orthonormalized().inverse()
	return pivot

func _exit_tree() -> void:
	for t in _twins:
		if is_instance_valid(t):
			t.queue_free()
	_twins.clear()

static func box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

static func solid(color: Color, metallic := 0.3, roughness := 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m

static func glow(color: Color, energy := 2.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

func set_color(col: Color) -> void:
	if _main_material:
		_main_material.albedo_color = col
