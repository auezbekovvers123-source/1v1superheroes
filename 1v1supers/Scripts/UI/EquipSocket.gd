extends Control
class_name EquipSocket
## EquipSocket.gd — Minimalist Glowing Socket Circle directly tracked to 3D body parts.
## NO TEXT. Pure glowing circles matching the original hand-drawn concept.
## Smoothly fades in and glows when the cursor / dragged item is near.

signal socket_equipped(slot: int, item: ItemData)
signal socket_unequipped(slot: int, item: ItemData)

var slot: int = ItemData.EquipSlot.NONE
var socket_radius: float = 24.0
var hover_activation_distance: float = 120.0

var equipped_item: ItemData = null
var is_drag_hover: bool = false
var is_drag_active_globally: bool = false
var is_valid_drag_target: bool = false

# Visual state
var _proximity_alpha: float = 0.15
var _target_alpha: float = 0.15
var _pulse_time: float = 0.0
var _current_scale: float = 1.0
var _target_scale: float = 1.0

# Accent color for drag glow
var accent_color: Color = Color(0.3, 0.85, 1.0)

func _init(p_slot: int = 0, p_radius: float = 24.0) -> void:
	slot = p_slot
	socket_radius = p_radius

func _ready() -> void:
	var d := socket_radius * 2.5
	custom_minimum_size = Vector2(d, d)
	size = Vector2(d, d)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func update_proximity(mouse_pos: Vector2, delta: float) -> void:
	var center := global_position + size / 2.0
	var dist := center.distance_to(mouse_pos)
	
	if is_drag_active_globally:
		if is_valid_drag_target:
			if dist < hover_activation_distance:
				_target_alpha = 1.0
				_target_scale = 1.25
			else:
				_target_alpha = 0.75
				_target_scale = 1.05
		else:
			_target_alpha = 0.1
			_target_scale = 0.9
	elif equipped_item != null:
		if dist < hover_activation_distance:
			_target_alpha = 1.0
			_target_scale = 1.15
		else:
			_target_alpha = 0.9
			_target_scale = 1.0
	else:
		if dist < hover_activation_distance:
			var t := 1.0 - (dist / hover_activation_distance)
			_target_alpha = lerpf(0.18, 1.0, t * t)
			_target_scale = lerpf(0.9, 1.15, t)
		else:
			_target_alpha = 0.18 # Subtle ghost ring
			_target_scale = 0.95

	_proximity_alpha = lerp(_proximity_alpha, _target_alpha, delta * 14.0)
	_current_scale = lerp(_current_scale, _target_scale, delta * 14.0)
	
	if is_drag_hover or (is_drag_active_globally and is_valid_drag_target):
		_pulse_time += delta * 6.0
	
	queue_redraw()

func _draw() -> void:
	if _proximity_alpha <= 0.02:
		return

	var center := size / 2.0
	var r := socket_radius * _current_scale
	var pulse := 0.5 + 0.5 * sin(_pulse_time)
	
	if equipped_item:
		var item_col: Color = equipped_item.preview_color
		# Outer soft glow aura
		draw_circle(center, r + 8.0, Color(item_col.r, item_col.g, item_col.b, 0.22 * _proximity_alpha))
		draw_circle(center, r + 4.0, Color(item_col.r, item_col.g, item_col.b, 0.45 * _proximity_alpha))
		
		# Filled vibrant core
		draw_circle(center, r, Color(item_col.r, item_col.g, item_col.b, 0.95 * _proximity_alpha))
		
		# Crisp white sketch ring
		draw_arc(center, r, 0, TAU, 48, Color(1, 1, 1, 0.95 * _proximity_alpha), 2.5)
		draw_arc(center, r + 2.0, 0, TAU, 48, Color(1, 1, 1, 0.35 * _proximity_alpha), 1.2)
		
		# Inner highlight glint
		draw_circle(center + Vector2(-r * 0.3, -r * 0.3), r * 0.28, Color(1, 1, 1, 0.65 * _proximity_alpha))
	elif is_drag_hover:
		# Drag hover drop target — intense pulse glow
		var glow_col := accent_color.lerp(Color.WHITE, 0.3)
		draw_circle(center, r + 12.0, Color(glow_col.r, glow_col.g, glow_col.b, 0.3 * pulse * _proximity_alpha))
		draw_circle(center, r + 6.0, Color(glow_col.r, glow_col.g, glow_col.b, 0.5 * _proximity_alpha))
		draw_circle(center, r, Color(glow_col.r, glow_col.g, glow_col.b, 0.25 * _proximity_alpha))
		
		draw_arc(center, r, 0, TAU, 48, Color(1, 1, 1, 1.0 * _proximity_alpha), 3.0)
		draw_arc(center, r + 4.0 + pulse * 3.0, 0, TAU, 48, glow_col * (0.8 * _proximity_alpha), 2.0)
	elif is_drag_active_globally and is_valid_drag_target:
		# Valid target while dragging
		draw_circle(center, r + 6.0, Color(accent_color.r, accent_color.g, accent_color.b, 0.25 * _proximity_alpha))
		draw_arc(center, r, 0, TAU, 48, Color(accent_color.r, accent_color.g, accent_color.b, 0.85 * _proximity_alpha), 2.2)
		draw_arc(center, r + 3.0, 0, TAU, 48, Color(1, 1, 1, 0.4 * _proximity_alpha), 1.2)
	else:
		# Empty state — soft glowing white ring matching sketch
		draw_circle(center, r + 8.0, Color(1, 1, 1, 0.08 * _proximity_alpha))
		draw_circle(center, r + 4.0, Color(1, 1, 1, 0.16 * _proximity_alpha))
		
		# White ring outline
		draw_arc(center, r, 0, TAU, 48, Color(1, 1, 1, 0.85 * _proximity_alpha), 2.2)
		draw_arc(center, r + 2.0, 0, TAU, 48, Color(1, 1, 1, 0.3 * _proximity_alpha), 1.0)
		
		# Inner soft dot
		draw_circle(center, 3.5, Color(1, 1, 1, 0.6 * _proximity_alpha))

# --- Drag & Drop ---

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is Dictionary and data.has("item_data"):
		var item: ItemData = data["item_data"]
		var valid := (item.slot == slot)
		if is_drag_hover != valid:
			is_drag_hover = valid
			_pulse_time = 0.0
			queue_redraw()
		return valid
	if is_drag_hover:
		is_drag_hover = false
		queue_redraw()
	return false

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.has("item_data"):
		var item: ItemData = data["item_data"]
		is_drag_hover = false
		queue_redraw()
		socket_equipped.emit(slot, item)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		is_drag_hover = false
		is_drag_active_globally = false
		queue_redraw()

# --- Click to unequip ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and equipped_item:
			var item := equipped_item
			equipped_item = null
			queue_redraw()
			socket_unequipped.emit(slot, item)
			accept_event()

func set_equipped(item: ItemData) -> void:
	equipped_item = item
	queue_redraw()

func clear_equipped() -> void:
	equipped_item = null
	queue_redraw()
