extends CanvasLayer
class_name CombatHUD
## Minimal HUD for the local player: HP, stamina, combo counter, aim reticle.

var player: Player = null

var _hp_bar: ProgressBar
var _hp_label: Label
var _stamina_bar: ProgressBar
var _stamina_label: Label
var _combo_label: Label
var _cross: Label

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Reticle (only while aiming), centred
	_cross = Label.new()
	_cross.text = "·"
	_cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cross.add_theme_font_size_override("font_size", 36)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.visible = false
	root.add_child(_cross)

	_hp_bar = _make_bar(root, Vector2(18, 18), Vector2(260, 18), Color(0.2, 0.95, 0.4))
	_hp_label = _make_label(root, Vector2(22, 20), 12, Color.WHITE)
	_stamina_bar = _make_bar(root, Vector2(18, 42), Vector2(260, 12), Color(0.32, 0.78, 1.0))
	_stamina_label = _make_label(root, Vector2(22, 40), 10, Color.WHITE)
	_combo_label = _make_label(root, Vector2(18, 60), 22, Color(1, 0.92, 0.28))

	var title := _make_label(root, Vector2.ZERO, 22, Color.WHITE)
	title.text = "GOOF - prototype"
	title.modulate = Color(1, 1, 1, 0.78)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position.y = 18

	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("local_player") as Player
	if player:
		player.health.health_changed.connect(_on_hp)
		_on_hp(player.health.current, player.health.max_health)

func _make_bar(parent: Control, pos: Vector2, size: Vector2, fill: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.position = pos
	bar.size = size
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.08, 0.85)
	bg.set_corner_radius_all(4)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)
	parent.add_child(bar)
	return bar

func _make_label(parent: Control, pos: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

## Green above 50%, yellow above 25%, red below.
func _set_fill(bar: ProgressBar, pct: float, high: Color) -> void:
	var sb := bar.get_theme_stylebox("fill") as StyleBoxFlat
	if sb:
		sb.bg_color = high if pct > 0.5 else (Color(1.0, 0.82, 0.15) if pct > 0.25 else Color(1.0, 0.22, 0.22))

func _on_hp(cur: float, maxv: float) -> void:
	_hp_bar.max_value = maxv
	_hp_bar.value = cur
	_set_fill(_hp_bar, cur / maxv, Color(0.2, 0.95, 0.4))
	_hp_label.text = "HP %d / %d" % [int(cur), int(maxv)]

func _process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_cross.visible = player.is_aiming
	var st := player.stamina
	_stamina_bar.max_value = st.max_value
	_stamina_bar.value = st.value
	_set_fill(_stamina_bar, st.value / maxf(st.max_value, 1.0), Color(0.32, 0.78, 1.0))
	_stamina_label.text = "ST %d / %d" % [int(st.value), int(st.max_value)]
	var combat := player.combat
	var total: int = MeleeCombat.COMBO_ANIMS.size()
	if player.is_attacking():
		_combo_label.text = "COMBO %d / %d %s" % [combat.combo_index + 1, total, "✓" if combat.has_hit_this_swing else ""]
		_combo_label.modulate = Color(1, 0.95, 0.3) if combat.has_hit_this_swing else Color.WHITE
		_combo_label.visible = true
	else:
		# Keep showing the chain briefly after a partial combo
		_combo_label.visible = combat.combo_reset_timer > 0.02 and combat.combo_index != 0
		if _combo_label.visible:
			_combo_label.text = "COMBO %d/%d (%.1fs)" % [combat.combo_index + 1, total, combat.combo_reset_timer]
			_combo_label.modulate = Color(1, 1, 1, 0.82)
