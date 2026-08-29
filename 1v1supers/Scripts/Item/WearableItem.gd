extends BoneAttachment3D
class_name WearableItem
## WearableItem.gd — Base class for wearable equipment (cloak, armor, etc.)
## Attached to a Skeleton3D bone via BoneAttachment3D. Provides equip/unequip API
## and slot handling. Attach this node under a Skeleton3D to follow the bone.

@export_group("Wearable")
@export var item_name: String = "Wearable"
@export var item_id: String = "wearable_generic"
@export var use_bone_attachment: bool = true
@export var mesh_offset: Vector3 = Vector3.ZERO
@export var mesh_rotation_deg: Vector3 = Vector3.ZERO
@export var mesh_scale: Vector3 = Vector3.ONE
@export var auto_find_skeleton: bool = true

var _mesh_instance: MeshInstance3D = null
var _is_equipped: bool = false

func _ready() -> void:
	# Ensure default bone if not set (inherited from BoneAttachment3D)
	if use_bone_attachment and (bone_name == null or bone_name == ""):
		bone_name = "spine_03.x"
	if auto_find_skeleton and get_parent() is not Skeleton3D:
		# Delay one frame to let parent skeleton be ready, then warn if not attached correctly
		pass
	_mesh_instance = _find_mesh_instance()
	if _mesh_instance:
		_mesh_instance.position = mesh_offset
		_mesh_instance.rotation_degrees = mesh_rotation_deg
		_mesh_instance.scale = mesh_scale
	_is_equipped = true

func _find_mesh_instance() -> MeshInstance3D:
	# Search by type, not name (CloakMesh vs MeshInstance3D)
	var stack: Array[Node] = [self]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n != self:
			return n as MeshInstance3D
		for c in n.get_children():
			stack.append(c)
	return null

func get_mesh_instance() -> MeshInstance3D:
	if _mesh_instance and is_instance_valid(_mesh_instance):
		return _mesh_instance
	_mesh_instance = _find_mesh_instance()
	return _mesh_instance

func equip(to_skeleton: Skeleton3D, target_bone: String = "") -> bool:
	if to_skeleton == null:
		push_warning("[WearableItem] equip failed: skeleton is null")
		return false
	var bname: String = target_bone if target_bone != "" else bone_name
	var bone_idx: int = to_skeleton.find_bone(bname)
	if bone_idx == -1:
		push_warning("[WearableItem] bone '%s' not found on skeleton. Available: %d bones" % [bname, to_skeleton.get_bone_count()])
		return false
	# Reparent under skeleton if needed
	if get_parent() != to_skeleton:
		var prev_parent = get_parent()
		if prev_parent:
			prev_parent.remove_child(self)
		to_skeleton.add_child(self)
		owner = to_skeleton.owner if to_skeleton.owner else to_skeleton
	bone_name = bname
	_is_equipped = true
	visible = true
	print("[WearableItem] Equipped '%s' on bone '%s' (%d)" % [item_name, bname, bone_idx])
	return true

func unequip() -> void:
	visible = false
	_is_equipped = false
	print("[WearableItem] Unequipped '%s'" % item_name)

func is_equipped() -> bool:
	return _is_equipped and visible

func set_color(col: Color) -> void:
	var mi = get_mesh_instance()
	if mi and mi.material_override is ShaderMaterial:
		(mi.material_override as ShaderMaterial).set_shader_parameter("color", col)
	elif mi and mi.get_surface_override_material(0) is ShaderMaterial:
		(mi.get_surface_override_material(0) as ShaderMaterial).set_shader_parameter("color", col)
