extends Node
class_name Inventory
## Inventory.gd — Single HAND slot inventory (holds 1 item in right hand).
## Previous multi-slot bag has been replaced with a single HAND slot as requested.
## The held item is visualized attached to the right hand bone and drives
## UpperBody_ITEMHOLD (looped, filtered) while held.

signal item_added(item: ItemData)
signal item_removed(item: ItemData)
signal inventory_changed()
signal held_item_changed(item: ItemData)

const MAX_HAND_ITEMS: int = 1

var _items: Array[ItemData] = []

## --- HAND logic helpers ---
func get_held_item() -> ItemData:
	if _items.size() > 0:
		return _items[0]
	return null

func is_hand_full() -> bool:
	return _items.size() >= MAX_HAND_ITEMS

func is_hand_empty() -> bool:
	return _items.is_empty()

func can_pickup() -> bool:
	return _items.size() < MAX_HAND_ITEMS

func add_item(item: ItemData) -> void:
	if item == null:
		push_warning("[Inventory] Cannot add null item")
		return
	if is_hand_full():
		push_warning("[Inventory] HAND full — can hold only one item (have '%s', tried '%s')" % [get_held_item().display_name if get_held_item() else "?", item.display_name])
		return
	# Force HAND slot semantics: ensure item knows it's hand item
	if item.slot != ItemData.EquipSlot.HAND and not item.is_hand_item():
		# legacy wearable cloaks stay cape — but hand items should be HAND
		pass
	_items.append(item)
	item_added.emit(item)
	held_item_changed.emit(item)
	inventory_changed.emit()
	print("[Inventory] Held '%s' in HAND (total: %d)" % [item.display_name, _items.size()])

func remove_item(item: ItemData) -> bool:
	var idx := _items.find(item)
	if idx == -1:
		return false
	_items.remove_at(idx)
	item_removed.emit(item)
	held_item_changed.emit(get_held_item())
	inventory_changed.emit()
	print("[Inventory] Removed '%s' from HAND (total: %d)" % [item.display_name, _items.size()])
	return true

func pop_held_item() -> ItemData:
	if _items.is_empty():
		return null
	var it: ItemData = _items[0]
	remove_item(it)
	return it

func get_items() -> Array[ItemData]:
	return _items.duplicate()

func has_item(item: ItemData) -> bool:
	return _items.has(item)

func item_count() -> int:
	return _items.size()

func clear() -> void:
	_items.clear()
	held_item_changed.emit(null)
	inventory_changed.emit()
