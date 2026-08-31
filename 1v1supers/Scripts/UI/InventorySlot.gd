extends Control
class_name InventorySlot
## InventorySlot.gd — Minimalist item box for inventory tray matching the sketch.
## Drag to drop onto 3D character sockets.

signal drag_started(item: ItemData)
signal drag_ended()
signal item_right_clicked(item: ItemData)

var item_data: ItemData = null
var _slot_size: Vector2 = Vector2(86, 92)
var _is_hovered: bool = false
var _hover_blend: float = 0.0

func _ready() -> void:
	custom_minimum_size = _slot_size
	size = _slot_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func(): _is_hovered = true)
	mouse_exited.connect(func(): _is_hovered = false)

func setup(item: ItemData, slot_size: Vector2 = Vector2(86, 92)) -> void:
	item_data = item
	_slot_size = slot_size
	custom_minimum_size = _slot_size
	size = _slot_size
	queue_redraw()

func _process(delta: float) -> void:
	var target := 1.0 if _is_hovered else 0.0
	if abs(_hover_blend - target) > 0.01:
		_hover_blend = lerp(_hover_blend, target, delta * 14.0)
		queue_redraw()

func _draw() -> void:
	if item_data == null:
		return

	var font := get_theme_default_font()
	var r_rect := Rect2(Vector2.ZERO, size)
	var accent: Color = item_data.preview_color
	
	# Background card
	var bg_col := Color(0.08, 0.09, 0.12, 0.85).lerp(Color(0.14, 0.16, 0.22, 0.95), _hover_blend)
	draw_rect(r_rect, bg_col, true)

	# Clean white / neon border matching sketch
	var border_col := Color(1, 1, 1, 0.6).lerp(Color(1, 1, 1, 0.95), _hover_blend)
	var border_w := 2.0 + _hover_blend * 1.0
	draw_rect(r_rect, border_col, false, border_w)

	# Center item circular swatch
	var icon_center := Vector2(size.x / 2.0, 42)
	var icon_rad := 20.0 + _hover_blend * 2.0
	
	# Outer soft glow
	draw_circle(icon_center, icon_rad + 4.0, Color(accent.r, accent.g, accent.b, 0.2 + _hover_blend * 0.25))
	# Main color circle
	draw_circle(icon_center, icon_rad, accent)
	# White ring border
	draw_arc(icon_center, icon_rad, 0, TAU, 32, Color.WHITE, 1.5)
	
	# Inner highlight
	draw_circle(icon_center + Vector2(-icon_rad * 0.3, -icon_rad * 0.3), icon_rad * 0.25, Color(1, 1, 1, 0.6))

	# Simple Label (e.g. "ITEM" or short name)
	var name_text := item_data.display_name.to_upper()
	if name_text.length() > 9:
		name_text = name_text.substr(0, 8) + ".."
	var text_w := font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 10).x
	var text_col := Color(1, 1, 1, 0.85).lerp(Color.WHITE, _hover_blend)
	draw_string(font, Vector2((size.x - text_w) / 2.0, size.y - 12), name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, text_col)

# --- Drag source (custom drag owned by InventoryUI — bridges 2D tray ↔ 3D sockets) ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and item_data != null:
			# Hand off to InventoryUI's cross-surface drag (works over the 3D rings too)
			modulate = Color(1, 1, 1, 0.35)
			drag_started.emit(item_data)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and item_data != null:
			item_right_clicked.emit(item_data)
			accept_event()
