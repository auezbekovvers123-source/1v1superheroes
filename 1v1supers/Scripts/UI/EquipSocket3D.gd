extends Node3D
class_name EquipSocket3D
## EquipSocket3D.gd — Circular equip slot rendered DIRECTLY IN WORLD SPACE.
## A glowing ring (procedural SDF shader on a camera-facing quad) attached to a
## bone anchor on the character model. Screen-space values (screen_position /
## screen_radius / visible_on_screen) are updated every frame by InventoryUI so
## drag & drop can hit-test the rings with the mouse.

const RING_SHADER_CODE := "
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, cull_disabled;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float ring_alpha : hint_range(0.0, 1.0) = 0.35;
uniform float fill_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float glow : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	// Camera-facing billboard: keep only the model's translation, take the
	// orientation from the camera (standard spatial-shader billboard trick).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	// crisp ring band around r = 0.78
	float ring = smoothstep(0.09, 0.015, abs(r - 0.78));
	// filled disc when an item is equipped
	float disc = (1.0 - smoothstep(0.68, 0.76, r)) * fill_alpha;
	// soft outer halo for hover / valid-target feedback
	float halo = exp(-max(r - 0.80, 0.0) * 7.0) * glow;
	vec3 col = ring_color.rgb;
	float a = ring * (0.82 + 0.18 * pulse);
	a += disc;
	a += halo * 0.8;
	// hot white shimmer on the ring while pulsing
	col = mix(col, vec3(1.0), pulse * 0.5);
	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 1.0) * ring_alpha;
}
"

const ACCENT := Color(0.3, 0.85, 1.0)

var slot: int = ItemData.EquipSlot.NONE
var radius: float = 0.10 # world-space radius of the ring in meters

var equipped_item: ItemData = null
var anchor: Node3D = null

# Screen-space cache (updated by InventoryUI each frame while open)
var screen_position: Vector2 = Vector2.ZERO
var screen_radius: float = 0.0
var visible_on_screen: bool = false

var _mat: ShaderMaterial = null
var _pulse_time: float = 0.0
var _fill: float = 0.0
var _glow: float = 0.0
var _pulse: float = 0.0
var _alpha: float = 0.35

func _init(p_slot: int = 0, p_radius: float = 0.10) -> void:
	slot = p_slot
	radius = p_radius

func _ready() -> void:
	# Quad with procedural ring shader, billboarded by the shader itself.
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * radius * 2.0 * 1.7 # extra room for the halo
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = RING_SHADER_CODE
	_mat.shader = sh
	_mat.set_shader_parameter("ring_color", Color(1, 1, 1))
	_mat.set_shader_parameter("ring_alpha", 0.35)
	_mat.render_priority = 10 # transparent: draw after the character mesh
	mi.material_override = _mat
	add_child(mi)

func set_equipped(item: ItemData) -> void:
	equipped_item = item

func clear_equipped() -> void:
	equipped_item = null

## Per-frame visual state machine. drag_item/drag_source describe the
## active world-socket drag (null when idle); InventoryUI supplies screen data.
## drag_source is the EquipSocket3D the drag started from, or null if none.
func update_state(delta: float, mouse: Vector2, drag_item: ItemData, drag_source) -> void:
	var hover := visible_on_screen and mouse.distance_to(screen_position) <= maxf(screen_radius * 1.3, 26.0)
	# Support legacy bool (old call passes bool) — treat true as "dragging" without source info
	var drag_source_sock: EquipSocket3D = null
	var is_dragging := false
	if drag_source is EquipSocket3D:
		drag_source_sock = drag_source as EquipSocket3D
		is_dragging = drag_item != null
	elif drag_source is bool:
		is_dragging = (drag_source as bool) and drag_item != null

	var valid_target := false
	if is_dragging and drag_source_sock != null and drag_source_sock != self:
		if drag_source_sock.slot == ItemData.EquipSlot.HAND and slot == drag_item.slot and slot != ItemData.EquipSlot.HAND:
			# HAND -> equip ring (equip)
			valid_target = true
		elif drag_source_sock.slot != ItemData.EquipSlot.HAND and slot == ItemData.EquipSlot.HAND:
			# equip ring -> HAND (unequip)
			valid_target = true
	elif is_dragging and drag_source_sock == null and drag_item != null:
		# Fallback for old tray->ring drag (kept for compat if called without source)
		if slot == drag_item.slot and slot != ItemData.EquipSlot.HAND and not (equipped_item != null and equipped_item == drag_item):
			valid_target = true

	var target_fill := 0.0
	var target_glow := 0.0
	var target_pulse := 0.0
	var target_alpha := 0.35
	var col := Color(1, 1, 1)

	if equipped_item != null:
		target_fill = 0.85
		target_alpha = 0.95
		col = equipped_item.preview_color.lerp(Color.WHITE, 0.25)

	if valid_target:
		target_glow = 0.85
		target_alpha = 0.95
		col = ACCENT
		if hover:
			target_pulse = 1.0
			_pulse_time += delta * 6.0
	elif is_dragging:
		# Something is being dragged between world sockets — dim the non-targets
		target_alpha = 0.15

	if hover and equipped_item != null and drag_item == null:
		target_glow = maxf(target_glow, 0.45)
		target_pulse = maxf(target_pulse, 0.35)
		_pulse_time += delta * 4.0

	_fill = lerpf(_fill, target_fill, clampf(delta * 14.0, 0.0, 1.0))
	_glow = lerpf(_glow, target_glow, clampf(delta * 14.0, 0.0, 1.0))
	_pulse = lerpf(_pulse, target_pulse, clampf(delta * 14.0, 0.0, 1.0))
	_alpha = lerpf(_alpha, target_alpha, clampf(delta * 14.0, 0.0, 1.0))

	if _mat:
		_mat.set_shader_parameter("fill_alpha", _fill)
		_mat.set_shader_parameter("glow", _glow)
		_mat.set_shader_parameter("pulse", _pulse)
		_mat.set_shader_parameter("ring_alpha", _alpha)
		_mat.set_shader_parameter("ring_color", col)

func reset_visual_state() -> void:
	_fill = 0.0
	_glow = 0.0
	_pulse = 0.0
	_alpha = 0.35
	_pulse_time = 0.0
	if _mat:
		_mat.set_shader_parameter("fill_alpha", 0.0)
		_mat.set_shader_parameter("glow", 0.0)
		_mat.set_shader_parameter("pulse", 0.0)
		_mat.set_shader_parameter("ring_alpha", 0.35)

## True when the given screen-space mouse position is over this ring.
func hit_test(mouse: Vector2) -> bool:
	if not visible_on_screen:
		return false
	return mouse.distance_to(screen_position) <= maxf(screen_radius * 1.3, 26.0)
