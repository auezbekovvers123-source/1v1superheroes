extends Area3D
class_name ItemPickup
## World item: bobs and spins until a player picks it up into their hand
## (the player's "interact" action calls try_interact), or on touch when
## auto_pickup is on.

signal picked_up(picker: Node, item_id: String)

@export_group("Item")
@export var item_data: ItemData ## The item this pickup gives. Preferred over the fields below.
@export var item_name: String = "Cloak"
@export var item_id: String = "cloak_01"
@export var wearable_scene: PackedScene
@export var equip_slot: int = 1 # ItemData.EquipSlot.CAPE
@export var bone_name: String = "spine_03.x"
@export var pickup_color: Color = Color(0.78, 0.12, 0.12, 1)

@export_group("Pickup")
@export var auto_pickup: bool = false
@export var require_interact: bool = true
@export var respawn_time: float = 0.0 # 0 = no respawn, freed after pickup
@export var pickup_radius: float = 2.0
@export var bob_amplitude: float = 0.18
@export var bob_speed: float = 1.6
@export var rotation_speed: float = 45.0 # degrees per second
@export var pickup_scale: Vector3 = Vector3(0.145, 0.145, 0.145) # world display scale

var _mesh: MeshInstance3D = null
var _base_y: float = 0.0
var _time: float = 0.0
var _picked: bool = false

func _ready() -> void:
	monitoring = true
	monitorable = true
	collision_layer = 0
	collision_mask = 1 # fighters are on layer 1
	_mesh = find_child("PickupMesh", true, false) as MeshInstance3D
	if _mesh == null:
		_mesh = RagdollController._find_first(self, "MeshInstance3D") as MeshInstance3D
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape == null:
		col_shape = CollisionShape3D.new()
		col_shape.name = "CollisionShape3D"
		col_shape.shape = SphereShape3D.new()
		add_child(col_shape)
	if col_shape.shape is SphereShape3D:
		(col_shape.shape as SphereShape3D).radius = pickup_radius
	if _mesh:
		_base_y = _mesh.position.y
		_mesh.scale = pickup_scale
		var mat := _mesh.material_override as ShaderMaterial
		if mat and mat.shader and mat.shader.get_shader_uniform_list().any(func(u): return u.name == "color"):
			mat.set_shader_parameter("color", pickup_color)
	body_entered.connect(_on_body_entered)
	add_to_group("pickup")

func _process(delta: float) -> void:
	if _picked or _mesh == null:
		return
	_time += delta
	_mesh.position.y = _base_y + sin(_time * bob_speed) * bob_amplitude
	_mesh.rotation.y += deg_to_rad(rotation_speed) * delta

func _on_body_entered(body: Node3D) -> void:
	if auto_pickup and not require_interact and body is Player:
		try_interact(body)

func is_pickable() -> bool:
	return not _picked and visible

## The item this pickup represents (built from the export fields if item_data is unset).
func get_item_data() -> ItemData:
	if item_data == null:
		var data := ItemData.new()
		data.id = item_id
		data.display_name = item_name
		data.slot = equip_slot as ItemData.EquipSlot
		data.scene = wearable_scene
		data.bone_name = bone_name
		data.preview_color = pickup_color
		if equip_slot == ItemData.EquipSlot.HAND or wearable_scene == null:
			data.is_holdable = true
			data.slot = ItemData.EquipSlot.HAND
			data.type = ItemData.ItemType.HOLDABLE
			data.is_usable = item_id.begins_with("usable")
		item_data = data
	return item_data

## Puts the item into `picker`'s hand. Wearables (the cape) also go to the hand
## first; they are worn by dragging them onto a slot in the inventory (TAB).
func try_interact(picker: Player) -> bool:
	if _picked:
		return false
	if not picker.hand.pick_up(get_item_data()):
		return false
	_picked = true
	picked_up.emit(picker, item_id)
	set_deferred("monitoring", false)
	if _mesh:
		var tw := create_tween()
		tw.tween_property(_mesh, "scale", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(_mesh, "position:y", _mesh.position.y + 1.0, 0.25)
	if respawn_time > 0.0:
		get_tree().create_timer(0.25).timeout.connect(func(): visible = false)
		get_tree().create_timer(respawn_time).timeout.connect(_respawn)
	else:
		get_tree().create_timer(0.35).timeout.connect(queue_free)
	return true

func _respawn() -> void:
	_picked = false
	visible = true
	set_deferred("monitoring", true)
	if _mesh:
		_mesh.scale = pickup_scale
		_mesh.position.y = _base_y
