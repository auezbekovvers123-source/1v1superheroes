extends Resource
class_name ItemData
## ItemData.gd — Data definition for items (wearable, consumable, etc.)

enum ItemType { WEARABLE, WEAPON, CONSUMABLE, MISC }
enum EquipSlot { NONE, CAPE, HELMET, ARMOR, BOOTS, ACCESSORY }

@export var id: String = ""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var type: ItemType = ItemType.WEARABLE
@export var slot: EquipSlot = EquipSlot.CAPE
@export var icon: Texture2D
@export var scene: PackedScene
@export var mesh: Mesh
@export var material: Material
@export var bone_name: String = "spine_03.x"
@export var preview_color: Color = Color(0.78, 0.12, 0.12, 1)

func is_wearable() -> bool:
	return type == ItemType.WEARABLE
