@tool
extends EditorPlugin

var dock: Control
var _citymaker_script: Script

func _enter_tree():
	add_tool_menu_item("CityBuilder: Bake City (citymaker.gd)", _run_citymaker)
	add_tool_menu_item("CityBuilder: Clear Preview", _clear_preview)
	# Create dock
	dock = _build_dock()
	add_control_to_dock(DOCK_SLOT_LEFT_UL, dock)
	_citymaker_script = load("res://addons/CityBuilderCG/citymaker.gd")

func _exit_tree():
	remove_tool_menu_item("CityBuilder: Bake City (citymaker.gd)")
	remove_tool_menu_item("CityBuilder: Clear Preview")
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

func _build_dock() -> Control:
	var panel = PanelContainer.new()
	panel.name = "CityBuilderCG"
	var v = VBoxContainer.new()
	v.custom_minimum_size = Vector2(220, 0)
	panel.add_child(v)

	var title = Label.new()
	title.text = "CityBuilderCG (FIXED)"
	title.add_theme_font_size_override("font_size", 14)
	v.add_child(title)

	var info = Label.new()
	info.text = "FIXED v2: grid-aligned, no overlaps\nheight 0.01, mesh-aware scale"
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(info)

	var sep = HSeparator.new()
	v.add_child(sep)

	var btn_bake = Button.new()
	btn_bake.text = " Bake Scene → generated_city.tscn"
	btn_bake.tooltip_text = "Runs addons/CityBuilderCG/citymaker.gd (EditorScript). Edit vars at top of that file."
	btn_bake.pressed.connect(_run_citymaker)
	v.add_child(btn_bake)

	var btn_gen = Button.new()
	btn_gen.text = " Generate Selected CityGenerator"
	btn_gen.tooltip_text = "Finds a CityGenerator node in the edited scene and calls generate_city()"
	btn_gen.pressed.connect(_generate_selected)
	v.add_child(btn_gen)

	var btn_clear = Button.new()
	btn_clear.text = " Clear Selected / Bake"
	btn_clear.pressed.connect(_clear_selected)
	v.add_child(btn_clear)

	var btn_rand = Button.new()
	btn_rand.text = " Randomize Seed + Generate"
	btn_rand.pressed.connect(_randomize_selected)
	v.add_child(btn_rand)

	var hint = Label.new()
	hint.text = "Tip: Select a CityGenerator node in city.tscn or prototype's CityTest to use Generate. For baked scene, tweak citymaker.gd vars then Bake."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.8,0.8,0.8,1)
	v.add_child(hint)

	# Quick presets
	var h = HBoxContainer.new()
	v.add_child(h)
	var lbl = Label.new(); lbl.text = "Grid"; h.add_child(lbl)
	var btn20 = Button.new(); btn20.text="20"; btn20.pressed.connect(func(): _apply_preset(20,2,2)); h.add_child(btn20)
	var btn30 = Button.new(); btn30.text="30"; btn30.pressed.connect(func(): _apply_preset(30,3,2)); h.add_child(btn30)
	var btn32 = Button.new(); btn32.text="32"; btn32.pressed.connect(func(): _apply_preset(32,4,4)); h.add_child(btn32)

	return panel

func _find_city_generator() -> Node:
	var edited = get_editor_interface().get_edited_scene_root()
	if not edited: return null
	# check if current edited has CityGenerator directly
	var found = _find_recursive(edited, "CityGenerator")
	return found

func _find_recursive(node: Node, cls: String) -> Node:
	if node.get_script():
		var sc = node.get_script()
		if sc and sc.get_global_name() == cls:
			return node
		# Also check class_name via is_class? fallback by name
		if node is CityGenerator:
			return node
	for c in node.get_children():
		var r = _find_recursive(c, cls)
		if r: return r
	return null

func _generate_selected():
	var gen = _find_city_generator()
	if not gen:
		push_warning("[CityBuilderCG] No CityGenerator found in edited scene. Open city.tscn or prototype.tscn and select CityGenerator node.")
		return
	if gen.has_method("generate_city"):
		gen.generate_city()
		print("[CityBuilderCG] generate_city() called on %s" % gen.get_path())

func _clear_selected():
	var gen = _find_city_generator()
	if gen and gen.has_method("clear_city"):
		gen.clear_city()
		print("[CityBuilderCG] clear_city() called")
	else:
		_clear_preview()

func _clear_preview():
	var edited = get_editor_interface().get_edited_scene_root()
	if not edited: return
	# Try to clear GeneratedCity child if present
	for c in edited.get_children():
		if c.name == "GeneratedCity":
			c.queue_free()
			print("[CityBuilderCG] cleared baked preview from edited root")

func _randomize_selected():
	var gen = _find_city_generator()
	if not gen: return
	gen.random_seed = randi() % 999999
	if gen.has_method("generate_city"):
		gen.generate_city()

func _apply_preset(grid: int, lx: int, ly: int):
	var gen = _find_city_generator()
	if not gen:
		push_warning("[CityBuilderCG] No CityGenerator selected for preset")
		return
	gen.grid_size_tiles = Vector2i(grid, grid)
	gen.lanes_x = lx
	gen.lanes_y = ly
	# sensible defaults from fixed generator (grid-aligned)
	gen.building_spacing_tiles = 0
	gen.building_density_multiplier = 1.4
	gen.height_offset = 0.01
	if gen.has_method("generate_city"):
		gen.generate_city()

func _run_citymaker():
	var script = load("res://addons/CityBuilderCG/citymaker.gd")
	if not script:
		push_error("[CityBuilderCG] citymaker.gd not found")
		return
	var instance = script.new()
	# EditorScript needs editor interface? _run will use get_editor_interface internally
	instance._run()
