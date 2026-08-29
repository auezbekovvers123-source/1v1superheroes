extends Node
class_name Inventory
## Inventory.gd — Holds the player's bag of collected items (not yet equipped)
## Items picked up in the world land here first. The player then drags them
## onto equipment sockets via InventoryUI to equip.

signal item_added(item: ItemData)
signal item_removed(item: ItemData)
signal inventory_changed()

var _items: Array[ItemData] = []

func add_item(item: ItemData) -> void:
	if item == null:
		push_warning("[Inventory] Cannot add null item")
		return
	_items.append(item)
	item_added.emit(item)
	inventory_changed.emit()
	print("[Inventory] Added '%s' (total: %d)" % [item.display_name, _items.size()])

func remove_item(item: ItemData) -> bool:
	var idx := _items.find(item)
	if idx == -1:
		return false
	_items.remove_at(idx)
	item_removed.emit(item)
	inventory_changed.emit()
	print("[Inventory] Removed '%s' (total: %d)" % [item.display_name, _items.size()])
	return true

func get_items() -> Array[ItemData]:
	return _items.duplicate()

func has_item(item: ItemData) -> bool:
	return _items.has(item)

func item_count() -> int:
	return _items.size()

func clear() -> void:
	_items.clear()
	inventory_changed.emit()
