extends Node
class_name Equipment
## Equipment.gd — Manages wearable slots for a CharacterBody3D
## Usage: attach as child of Player/Dummy, or call via _setup_equipment() in Player.gd
## Handles equip/unequip by slot, prevents duplicates, emits signals.

signal item_equipped(slot: int, item: WearableItem)
signal item_unequipped(slot: int, item: WearableItem)

@export var skeleton_path: NodePath = NodePath("../Mesh/C11/root/Skeleton3D")
@export var auto_discover_skeleton: bool = true

var _skeleton: Skeleton3D = null
var _slots: Dictionary = {} # EquipSlot -> WearableItem
var _owner_body: Node = null

func _ready() -> void:
	_owner_body = get_parent()
	if auto_discover_skeleton:
		_skeleton = _find_skeleton()
	else:
		_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if _skeleton == null:
		push_warning("[Equipment] Skeleton not found at: %s" % skeleton_path)

func _find_skeleton() -> Skeleton3D:
	if _owner_body == null:
		_owner_body = get_parent()
	if _owner_body:
		var result: Skeleton3D = _search_skeleton(_owner_body)
		if result:
			return result
	return get_node_or_null(skeleton_path) as Skeleton3D

func _search_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var r: Skeleton3D = _search_skeleton(c)
		if r:
			return r
	return null

func get_skeleton() -> Skeleton3D:
	if _skeleton == null or not is_instance_valid(_skeleton):
		_skeleton = _find_skeleton()
	return _skeleton

func equip_wearable(packed: PackedScene, slot: int = ItemData.EquipSlot.CAPE, bone: String = "") -> WearableItem:
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		push_warning("[Equipment] Cannot equip: no skeleton")
		return null
	if packed == null:
		push_warning("[Equipment] Cannot equip: packed scene is null")
		return null
	# Unequip existing in slot
	if _slots.has(slot) and _slots[slot] != null:
		unequip_slot(slot)
	var inst: Node = packed.instantiate()
	if inst is WearableItem:
		var wearable: WearableItem = inst as WearableItem
		var bname: String = bone if bone != "" else wearable.bone_name
		if wearable.equip(skel, bname):
			_slots[slot] = wearable
			item_equipped.emit(slot, wearable)
			return wearable
		else:
			wearable.queue_free()
			return null
	elif inst is BoneAttachment3D:
		var ba: BoneAttachment3D = inst as BoneAttachment3D
		var bname: String = bone if bone != "" else ba.bone_name
		var idx: int = skel.find_bone(bname)
		if idx == -1:
			push_warning("[Equipment] Bone not found: %s" % bname)
			inst.queue_free()
			return null
		ba.bone_name = bname
		skel.add_child(ba)
		_slots[slot] = ba as WearableItem
		item_equipped.emit(slot, ba as WearableItem)
		return ba as WearableItem
	else:
		# Generic Node3D — wrap in BoneAttachment
		var ba := BoneAttachment3D.new()
		ba.bone_name = bone if bone != "" else "spine_03.x"
		skel.add_child(ba)
		ba.add_child(inst)
		_slots[slot] = ba as WearableItem
		item_equipped.emit(slot, ba as WearableItem)
		return ba as WearableItem

func equip_existing(wearable: WearableItem, slot: int = ItemData.EquipSlot.CAPE) -> bool:
	var skel: Skeleton3D = get_skeleton()
	if skel == null or wearable == null:
		return false
	if _slots.has(slot) and _slots[slot] != null:
		unequip_slot(slot)
	if wearable.equip(skel):
		_slots[slot] = wearable
		item_equipped.emit(slot, wearable)
		return true
	return false

func unequip_slot(slot: int) -> void:
	if not _slots.has(slot):
		return
	var item: WearableItem = _slots[slot] as WearableItem
	if item and is_instance_valid(item):
		item.unequip()
		# Keep in tree but invisible, or free depending on preference
		# For persistence, we hide; for demo, we keep hidden
		item.visible = false
	item_unequipped.emit(slot, item)
	_slots.erase(slot)

func get_equipped(slot: int) -> WearableItem:
	return _slots.get(slot, null)

func has_equipped(slot: int) -> bool:
	return _slots.has(slot) and _slots[slot] != null and is_instance_valid(_slots[slot])

func list_equipped() -> Dictionary:
	return _slots.duplicate()

func unequip_all() -> void:
	for slot in _slots.keys():
		unequip_slot(slot)
