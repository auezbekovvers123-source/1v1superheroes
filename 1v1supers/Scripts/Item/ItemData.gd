extends Resource
class_name ItemData
## ItemData.gd — Data definition for items (wearable, consumable, etc.)

enum ItemType { WEARABLE, WEAPON, CONSUMABLE, MISC, HOLDABLE }
enum EquipSlot { NONE, CAPE, HELMET, ARMOR, BOOTS, ACCESSORY, HAND }

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

# --- Hand-hold / Usable ---
@export var is_holdable: bool = false
@export var is_usable: bool = false
@export var use_anim: String = "UpperBody_ITEMUSE"
@export var hold_anim: String = "UpperBody_ITEMHOLD"
# right hand attachment tuning for held mesh
@export var hold_offset: Vector3 = Vector3(0.02, -0.02, 0.08)
@export var hold_rotation_deg: Vector3 = Vector3(0, 0, 0)
@export var hold_scale: Vector3 = Vector3.ONE

# --- Powers (worn-item abilities, activated with R / "power" action) ---
# Generic so future items (helmet, boots, ...) can declare their own power.
# Cape uses power_id = "fly".
@export var power_id: String = ""
@export var power_name: String = ""

func has_power() -> bool:
	return power_id != ""

func is_wearable() -> bool:
	return type == ItemType.WEARABLE

func is_hand_item() -> bool:
	return slot == EquipSlot.HAND or is_holdable or type == ItemType.HOLDABLE
