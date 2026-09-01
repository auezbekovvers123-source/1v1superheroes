extends CanvasLayer
## CombatHUD.gd — minimal HUD: player HP, combo, reticle, instructions

var player: CharacterBody3D
var player_health: Node
var combo_label: Label
var hp_bar: ProgressBar
var hp_label: Label
var stamina_bar: ProgressBar
var stamina_label: Label
var instruction: Label
var hit_marker: Control
var cross: Label

func _ready() -> void:
	# Build UI programmatically (no scene needed)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Crosshair / reticle (only visible while aiming)
	cross = Label.new()
	cross.text = "·"
	cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cross.position = get_viewport().get_visible_rect().size / 2 - Vector2(8, 12)
	cross.add_theme_font_size_override("font_size", 36)
	cross.modulate = Color(1,1,1,1)
	cross.visible = false
	root.add_child(cross)

	# HP bar
	hp_bar = ProgressBar.new()
	hp_bar.position = Vector2(18, 18)
	hp_bar.size = Vector2(260, 18)
	hp_bar.max_value = 100
	hp_bar.value = 100
	hp_bar.show_percentage = false
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = Color(0.08,0.08,0.08,0.85)
	sb_bg.corner_radius_top_left = 4
	sb_bg.corner_radius_top_right = 4
	sb_bg.corner_radius_bottom_left = 4
	sb_bg.corner_radius_bottom_right = 4
	var sb_fg := StyleBoxFlat.new()
	sb_fg.bg_color = Color(0.2, 0.95, 0.4)
	sb_fg.corner_radius_top_left = 4
	sb_fg.corner_radius_top_right = 4
	sb_fg.corner_radius_bottom_left = 4
	sb_fg.corner_radius_bottom_right = 4
	hp_bar.add_theme_stylebox_override("background", sb_bg)
	hp_bar.add_theme_stylebox_override("fill", sb_fg)
	root.add_child(hp_bar)

	hp_label = Label.new()
	hp_label.position = Vector2(22, 20)
	hp_label.text = "HP 100 / 100"
	hp_label.add_theme_font_size_override("font_size", 12)
	hp_label.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(hp_label)

	# Stamina bar (under HP)
	stamina_bar = ProgressBar.new()
	stamina_bar.position = Vector2(18, 42)
	stamina_bar.size = Vector2(260, 12)
	stamina_bar.max_value = 100
	stamina_bar.value = 100
	stamina_bar.show_percentage = false
	var sb_stam_bg := StyleBoxFlat.new()
	sb_stam_bg.bg_color = Color(0.08, 0.08, 0.08, 0.85)
	sb_stam_bg.corner_radius_top_left = 4
	sb_stam_bg.corner_radius_top_right = 4
	sb_stam_bg.corner_radius_bottom_left = 4
	sb_stam_bg.corner_radius_bottom_right = 4
	var sb_stam_fg := StyleBoxFlat.new()
	sb_stam_fg.bg_color = Color(0.32, 0.78, 1.0)
	sb_stam_fg.corner_radius_top_left = 4
	sb_stam_fg.corner_radius_top_right = 4
	sb_stam_fg.corner_radius_bottom_left = 4
	sb_stam_fg.corner_radius_bottom_right = 4
	stamina_bar.add_theme_stylebox_override("background", sb_stam_bg)
	stamina_bar.add_theme_stylebox_override("fill", sb_stam_fg)
	root.add_child(stamina_bar)

	stamina_label = Label.new()
	stamina_label.position = Vector2(22, 40)
	stamina_label.text = "ST 100 / 100"
	stamina_label.add_theme_font_size_override("font_size", 10)
	stamina_label.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(stamina_label)

	# Combo label
	combo_label = Label.new()
	combo_label.position = Vector2(18, 46)
	combo_label.text = ""
	combo_label.add_theme_font_size_override("font_size", 22)
	combo_label.add_theme_color_override("font_color", Color(1,0.92,0.28))
	root.add_child(combo_label)

	# Prototype title (centered, large)
	instruction = Label.new()
	instruction.text = "GOOF - prototype"
	instruction.add_theme_font_size_override("font_size", 22)
	instruction.modulate = Color(1,1,1,0.78)
	instruction.set_anchors_preset(Control.PRESET_CENTER_TOP)
	instruction.position = Vector2(get_viewport().get_visible_rect().size.x / 2 - 90, 18)
	instruction.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(instruction)

	# Hit marker (center flash)
	hit_marker = Control.new()
	hit_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hit_marker)

	# Find player deferred
	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("fighter") as CharacterBody3D
	# Prefer Player named
	var pl = get_tree().current_scene.get_node_or_null("Prototype/Player")
	if pl:
		player = pl as CharacterBody3D
	if player:
		player_health = player.get_node_or_null("Health")
		if player_health:
			player_health.health_changed.connect(_on_hp)
			_on_hp(player_health.get("current"), player_health.get("max_health"))

func _on_hp(cur: float, maxv: float) -> void:
	if hp_bar:
		hp_bar.max_value = maxv
		hp_bar.value = cur
		var pct: float = cur / maxv
		var sb = hp_bar.get_theme_stylebox("fill")
		if sb is StyleBoxFlat:
			if pct > 0.5:
				(sb as StyleBoxFlat).bg_color = Color(0.2, 0.95, 0.4)
			elif pct > 0.25:
				(sb as StyleBoxFlat).bg_color = Color(1.0, 0.82, 0.15)
			else:
				(sb as StyleBoxFlat).bg_color = Color(1.0, 0.22, 0.22)
	if hp_label:
		hp_label.text = "HP %d / %d" % [int(cur), int(maxv)]

func _process(_delta: float) -> void:
	if player == null:
		return
	# Crosshair appears only while aiming
	var aiming: bool = player.get("is_aiming") if player.get("is_aiming") != null else false
	if cross:
		cross.visible = aiming
	# Stamina bar — driven by player.stamina / player.max_stamina
	if stamina_bar:
		var cur_stam: float = player.get("stamina") if player.get("stamina") != null else 100.0
		var max_stam: float = player.get("max_stamina") if player.get("max_stamina") != null else 100.0
		stamina_bar.max_value = max_stam
		stamina_bar.value = cur_stam
		var pct_stam: float = cur_stam / maxf(max_stam, 1.0)
		var sb_s = stamina_bar.get_theme_stylebox("fill")
		if sb_s is StyleBoxFlat:
			if pct_stam > 0.5:
				(sb_s as StyleBoxFlat).bg_color = Color(0.32, 0.78, 1.0)
			elif pct_stam > 0.25:
				(sb_s as StyleBoxFlat).bg_color = Color(1.0, 0.82, 0.15)
			else:
				(sb_s as StyleBoxFlat).bg_color = Color(1.0, 0.22, 0.22)
	if stamina_label:
		var cs2: float = player.get("stamina") if player.get("stamina") != null else 100.0
		var ms2: float = player.get("max_stamina") if player.get("max_stamina") != null else 100.0
		stamina_label.text = "ST %d / %d" % [int(cs2), int(ms2)]
	# Combo display
	var idx: int = player.get("combo_index") if player.get("combo_index") != null else 0
	var attacking: bool = player.get("is_attacking") if player.get("is_attacking") != null else false
	var has_hit: bool = player.get("_has_hit_this_swing") if player.get("_has_hit_this_swing") != null else false
	if attacking:
		var total: int = 4
		combo_label.text = "COMBO %d / %d %s" % [idx+1, total, "✓" if has_hit else ""]
		combo_label.modulate = Color(1, 0.95, 0.3) if has_hit else Color.WHITE
		combo_label.visible = true
	else:
		# fade quickly after
		if combo_label.visible:
			# keep for 0.9s via timer done implicitly
			pass
		# auto hide after a bit — we just keep last visible briefly
		var timer_val: float = player.get("combo_reset_timer") if player.get("combo_reset_timer") != null else 0.0
		combo_label.visible = timer_val > 0.02 and idx != 0
		if combo_label.visible:
			combo_label.text = "COMBO %d/4 (%.1fs)" % [idx+1, timer_val]
			combo_label.modulate = Color(1,1,1,0.82)

func flash_hit(is_crit: bool) -> void:
	if hit_marker == null:
		return
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.color = Color(1,0.22,0.22,0.18) if not is_crit else Color(1,0.88,0.22,0.22)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hit_marker.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, 0.14 if not is_crit else 0.22)
	tw.tween_callback(func(): if is_instance_valid(rect): rect.queue_free())
	# Scale hit text
	combo_label.scale = Vector2(1.18, 1.18)
	var tw2 := create_tween()
	tw2.tween_property(combo_label, "scale", Vector2.ONE, 0.18)
