extends Node
class_name Equipment
## Worn items by slot (cape, helmet, ...). Stores each slot's ItemData together
## with the WearableItem node attached to the skeleton, so the item is never
## reconstructed from the node. Hand <-> slot moves go through Player
## (equip_from_hand / unequip_to_hand), which also enforces the hand rules.

signal item_equipped(slot: int, item: ItemData)
signal item_unequipped(slot: int, item: ItemData)

var _skeleton: Skeleton3D = null
var _items: Dictionary = {} # slot -> ItemData
var _wearables: Dictionary = {} # slot -> WearableItem

func get_skeleton() -> Skeleton3D:
	if _skeleton == null or not is_instance_valid(_skeleton):
		_skeleton = RagdollController._find_first(get_parent(), "Skeleton3D") as Skeleton3D
	return _skeleton

## Wears `item` in its slot. The slot must be empty (unequip first).
func equip(item: ItemData) -> WearableItem:
	var slot: int = item.slot
	if has_equipped(slot):
		push_warning("[Equipment] Slot %d is occupied — unequip first" % slot)
		return null
	var skel := get_skeleton()
	if skel == null or item.scene == null:
		return null
	var wearable := item.scene.instantiate() as WearableItem
	if wearable == null:
		push_warning("[Equipment] '%s' scene is not a WearableItem" % item.display_name)
		return null
	if not wearable.equip(skel, item.bone_name):
		wearable.queue_free()
		return null
	wearable.set_color(item.preview_color)
	_items[slot] = item
	_wearables[slot] = wearable
	item_equipped.emit(slot, item)
	return wearable

## Takes off whatever is in `slot` and returns its ItemData (null if empty).
func unequip(slot: int) -> ItemData:
	if not has_equipped(slot):
		return null
	var item: ItemData = _items[slot]
	var wearable: WearableItem = _wearables[slot]
	_items.erase(slot)
	_wearables.erase(slot)
	item_unequipped.emit(slot, item)
	if is_instance_valid(wearable):
		wearable.queue_free()
	return item

func has_equipped(slot: int) -> bool:
	return _items.has(slot)

func get_item(slot: int) -> ItemData:
	return _items.get(slot, null)

func get_wearable(slot: int) -> WearableItem:
	return _wearables.get(slot, null)

## slot -> ItemData for every worn item.
func list_items() -> Dictionary:
	return _items.duplicate()

## True when a worn item grants the power (e.g. the cape grants "fly").
func has_power(power_id: String) -> bool:
	for slot in _items:
		if (_items[slot] as ItemData).power_id == power_id:
			return true
	return false
