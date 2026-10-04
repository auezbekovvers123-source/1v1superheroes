extends CanvasLayer
class_name NetMenu
## F1: host or join an online game (Steam or direct IP) and see who is
## connected. A small status line stays in the corner while online.

var net: Node # the Net autoload, our parent
var _panel: PanelContainer
var _status: Label
var _corner: Label
var _name_edit: LineEdit
var _addr_edit: LineEdit
var _lobby_edit: LineEdit
var _lobby_list: ItemList
var _steam_note: Label
var _steam_buttons: Array[Button] = []
var _invite_button: Button
var _copy_button: Button
var _leave_button: Button
var _peers_label: Label
var _lobbies: Array = []
var _disabled_input: PlayerInput = null

func _ready() -> void:
	net = get_parent()
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_panel.visible = false
	net.status_changed.connect(func(_t: String): _refresh())
	net.peers_changed.connect(_refresh)
	net.steam.lobbies_found.connect(_on_lobbies_found)
	_refresh()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("net_menu"):
		toggle()
		get_viewport().set_input_as_handled()

func is_open() -> bool:
	return _panel.visible

func toggle() -> void:
	if is_open():
		close()
	else:
		open()

func open() -> void:
	_panel.visible = true
	_name_edit.text = net.player_name
	_hold_focus()
	_refresh()

func close() -> void:
	_panel.visible = false
	_apply_name()
	if _disabled_input and is_instance_valid(_disabled_input):
		_disabled_input.enabled = true
	_disabled_input = null
	if get_tree().get_first_node_in_group("local_player"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _process(_delta: float) -> void:
	if net.is_online():
		var ping := ""
		for peer in net.pings:
			ping = " · %d ms" % net.pings[peer]
		_corner.text = "ONLINE (%s) · %d/%d players%s · F1" % [net.transport_name(), net.fighters().size(), net.MAX_PLAYERS, ping]
	else:
		_corner.text = "F1: multiplayer"
	if is_open():
		_refresh_peers()
		_hold_focus()

## While open the menu keeps the mouse and our fighter stands still, also after
## a session start reloads the level (the new fighter grabs the mouse on spawn).
func _hold_focus() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var me := get_tree().get_first_node_in_group("local_player") as Player
	if me and me.input.enabled:
		me.input.enabled = false
		_disabled_input = me.input

# --- Actions -------------------------------------------------------------------------

func _apply_name() -> void:
	var n := _name_edit.text.strip_edges()
	if n != "":
		net.player_name = n.left(24)

func _on_host_steam() -> void:
	_apply_name()
	net.host_steam()

func _on_join_lobby_id() -> void:
	var t := _lobby_edit.text.strip_edges()
	if not t.is_valid_int():
		net.set_status("Paste the host's lobby ID (a long number).")
		return
	_apply_name()
	net.join_steam(int(t))

func _on_join_selected() -> void:
	var sel := _lobby_list.get_selected_items()
	if sel.is_empty():
		return
	_apply_name()
	net.join_steam(int(_lobbies[sel[0]].id))

func _on_lobbies_found(lobbies: Array) -> void:
	_lobbies = lobbies
	_lobby_list.clear()
	for l in lobbies:
		_lobby_list.add_item("%s  (%d/%d)" % [l.name if l.name != "" else "Lobby %d" % l.id, l.members, net.MAX_PLAYERS])
	if lobbies.is_empty():
		net.set_status("No open games found. Ask your friend to host, or use an invite.")

func _on_host_direct() -> void:
	_apply_name()
	var port: int = _parse_addr().port
	net.host_direct(port)

func _on_join_direct() -> void:
	_apply_name()
	var a := _parse_addr()
	net.join_direct(a.host, a.port)

func _parse_addr() -> Dictionary:
	var t := _addr_edit.text.strip_edges()
	var host := t
	var port: int = net.DEFAULT_PORT
	if t.contains(":"):
		host = t.get_slice(":", 0)
		if t.get_slice(":", 1).is_valid_int():
			port = int(t.get_slice(":", 1))
	return {"host": host if host != "" else "127.0.0.1", "port": port}

# --- View ------------------------------------------------------------------------------

func _refresh() -> void:
	if _status == null:
		return
	_status.text = net.status
	var steam_ok: bool = net.steam.available
	_steam_note.text = "Steam: signed in as %s" % net.steam.persona if steam_ok else "Steam unavailable: %s" % net.steam.unavailable_reason
	for b in _steam_buttons:
		b.disabled = not steam_ok
	var in_lobby: bool = net.transport_name() == "Steam" and net.steam.lobby_id != 0
	_invite_button.disabled = not in_lobby
	_copy_button.disabled = not in_lobby
	_leave_button.disabled = not net.is_online()
	_refresh_peers()

func _refresh_peers() -> void:
	if not net.is_online():
		_peers_label.text = ""
		return
	var lines: Array[String] = ["You (%s)%s" % [net.player_name, " · host" if net.is_host() else ""]]
	for peer in net.names:
		var ms: String = " · ping %d ms" % net.pings[peer] if net.pings.has(peer) else ""
		lines.append("%s%s%s%s" % [net.names[peer], " · host" if peer == 1 else "", ms, _link_stats(peer)])
	_peers_label.text = "\n".join(lines)

## How smoothly their fighter replays here: input delay, lost packets, drift.
func _link_stats(peer: int) -> String:
	var f: Player = net.fighter(peer)
	if f == null or not f.input is NetworkPlayerInput or not f.has_node("NetSync"):
		return ""
	var ni := f.input as NetworkPlayerInput
	var sync := f.get_node("NetSync") as NetSync
	return "\n    replay delay %d ms · lost %d · ran dry %d · drift %d cm" % [
		roundi(ni.target_delay * 1000.0 / Engine.physics_ticks_per_second), ni.holes_filled, ni.ran_dry,
		roundi(sync.correction_error * 100.0)]

func _build() -> void:
	_corner = Label.new()
	_corner.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_corner.position = Vector2(-330, 12)
	_corner.size = Vector2(318, 20)
	_corner.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_corner.add_theme_font_size_override("font_size", 13)
	_corner.modulate = Color(1, 1, 1, 0.75)
	_corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_corner)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(440, 0)
	_panel.position = Vector2(-220, -300)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.94)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)

	_heading(box, "Multiplayer", 22)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(400, 0)
	_status.modulate = Color(1, 0.9, 0.5)
	box.add_child(_status)
	var name_row := HBoxContainer.new()
	box.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "Your name"
	name_row.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)

	box.add_child(HSeparator.new())
	_heading(box, "Steam", 16)
	_steam_note = Label.new()
	_steam_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_steam_note.custom_minimum_size = Vector2(400, 0)
	_steam_note.add_theme_font_size_override("font_size", 12)
	box.add_child(_steam_note)
	var steam_row := HBoxContainer.new()
	box.add_child(steam_row)
	_steam_buttons.append(_button(steam_row, "Host game", _on_host_steam))
	_invite_button = _button(steam_row, "Invite friend", func(): net.steam.invite_friends())
	_copy_button = _button(steam_row, "Copy lobby ID", func(): DisplayServer.clipboard_set(str(net.steam.lobby_id)))
	var find_row := HBoxContainer.new()
	box.add_child(find_row)
	_steam_buttons.append(_button(find_row, "Find games", func(): net.steam.find_lobbies()))
	_steam_buttons.append(_button(find_row, "Join selected", _on_join_selected))
	_lobby_list = ItemList.new()
	_lobby_list.custom_minimum_size = Vector2(400, 70)
	box.add_child(_lobby_list)
	var id_row := HBoxContainer.new()
	box.add_child(id_row)
	_lobby_edit = LineEdit.new()
	_lobby_edit.placeholder_text = "lobby ID"
	_lobby_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_row.add_child(_lobby_edit)
	_steam_buttons.append(_button(id_row, "Join ID", _on_join_lobby_id))

	box.add_child(HSeparator.new())
	_heading(box, "Direct (LAN / IP / same PC)", 16)
	var addr_row := HBoxContainer.new()
	box.add_child(addr_row)
	_addr_edit = LineEdit.new()
	_addr_edit.text = "127.0.0.1:%d" % net.DEFAULT_PORT
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_row.add_child(_addr_edit)
	_button(addr_row, "Host", _on_host_direct)
	_button(addr_row, "Join", _on_join_direct)

	box.add_child(HSeparator.new())
	_peers_label = Label.new()
	box.add_child(_peers_label)
	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	_leave_button = _button(bottom, "Leave game", func(): net.leave("You left the game."))
	_button(bottom, "Close (F1)", close)

func _heading(parent: Control, text: String, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)

func _button(parent: Control, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b
