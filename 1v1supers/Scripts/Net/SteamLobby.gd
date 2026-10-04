extends Node
class_name SteamLobby
## Steam lobbies + SteamMultiplayerPeer through the GodotSteam addon.
##
## GodotSteam is called dynamically (Engine.get_singleton / ClassDB), so the
## game still runs, with Steam greyed out, when the addon is not installed.
## Flow: the host creates a lobby and a SteamMultiplayerPeer host; a friend
## joins the lobby (Steam invite, "Join Game" in the friends list, the lobby
## browser or the lobby ID) and connects a client peer to the lobby owner.
## Steam relays the traffic: no IP addresses, no port forwarding.

signal lobby_ready(peer: MultiplayerPeer, is_host: bool)
signal failed(reason: String)
signal status(text: String)
signal lobbies_found(lobbies: Array) # [{id, name, members}]
## A friend's invite was accepted in the Steam overlay / friends list.
signal invite_accepted(lobby_id: int)
## Steam is up (available is true from now on).
signal started()

## 480 = Spacewar, Valve's shared test app: fine for development and play
## tests. Put the game's own App ID here once it has a Steam page.
const APP_ID := 480
## Lobby tag so the lobby browser only lists this game among everything on 480.
const GAME_KEY := "1v1superheroes"

# Steamworks enum values used below
const LOBBY_TYPE_PUBLIC := 2
const RESULT_OK := 1
const CHAT_ROOM_ENTER_SUCCESS := 1
const LOBBY_COMPARISON_EQUAL := 0
const LOBBY_DISTANCE_WORLDWIDE := 3

var available := false
var unavailable_reason := "GodotSteam addon not installed (see README)"
var lobby_id: int = 0
var steam_id: int = 0
var persona: String = ""

var _steam: Object = null
var _new_peer: Callable

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Engine.has_singleton("Steam"):
		use_steam(Engine.get_singleton("Steam"))

## Starts Steam through `steam_api` (the GodotSteam singleton). `new_peer`
## makes the multiplayer peer; tests pass a stand-in for both.
func use_steam(steam_api: Object, new_peer: Callable = Callable()) -> void:
	_steam = steam_api
	_new_peer = new_peer
	# Tells the Steam client which app this is (no steam_appid.txt needed)
	OS.set_environment("SteamAppId", str(APP_ID))
	OS.set_environment("SteamGameId", str(APP_ID))
	var init_method := "steamInitEx" if _steam.has_method("steamInitEx") else "steamInit"
	var result: Variant = call_flexible(_steam, init_method, {"app_id": APP_ID, "embed_callbacks": false, "retrieve_stats": false})
	steam_id = int(_steam.call("getSteamID"))
	if steam_id == 0:
		var verbal: String = str(result.get("verbal", result)) if result is Dictionary else str(result)
		unavailable_reason = "Steam is not running or refused to start (%s)" % verbal
		_steam = null
		return
	if not _new_peer.is_valid():
		if not ClassDB.class_exists("SteamMultiplayerPeer"):
			unavailable_reason = "this GodotSteam build has no SteamMultiplayerPeer (use GodotSteam 4.14 or newer)"
			_steam = null
			return
		_new_peer = func() -> MultiplayerPeer: return ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer
	persona = str(_steam.call("getPersonaName"))
	if _steam.has_method("initRelayNetworkAccess"):
		_steam.call("initRelayNetworkAccess") # warm up the relay network before the first connection
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	_steam.connect("lobby_match_list", _on_lobby_match_list)
	_steam.connect("join_requested", _on_join_requested)
	available = true
	unavailable_reason = ""
	started.emit()

## Lets go of the Steam API (leaves the lobby first).
func stop() -> void:
	leave_lobby()
	if _steam:
		for sig in ["lobby_created", "lobby_joined", "lobby_match_list", "join_requested"]:
			for c in _steam.get_signal_connection_list(sig):
				if c.callable.get_object() == self:
					_steam.disconnect(sig, c.callable)
	_steam = null
	_new_peer = Callable()
	available = false
	unavailable_reason = "Steam stopped"

func _process(_delta: float) -> void:
	if _steam:
		_steam.call("run_callbacks")

## Lobby ID from "+connect_lobby <id>" (Steam passes it when an invite starts the game).
func command_line_lobby() -> int:
	var args := OS.get_cmdline_args()
	var i := args.find("+connect_lobby")
	if i >= 0 and i + 1 < args.size() and args[i + 1].is_valid_int():
		return int(args[i + 1])
	return 0

func create_lobby(max_members: int) -> void:
	if not available:
		failed.emit(unavailable_reason)
		return
	leave_lobby()
	status.emit("Creating a Steam lobby...")
	_steam.call("createLobby", LOBBY_TYPE_PUBLIC, max_members)

func join_lobby(id: int) -> void:
	if not available:
		failed.emit(unavailable_reason)
		return
	leave_lobby()
	status.emit("Joining Steam lobby %d..." % id)
	_steam.call("joinLobby", id)

func leave_lobby() -> void:
	if _steam and lobby_id != 0:
		_steam.call("leaveLobby", lobby_id)
		if _steam.has_method("clearRichPresence"):
			_steam.call("clearRichPresence")
	lobby_id = 0

## Opens the Steam overlay's invite dialog for the current lobby.
func invite_friends() -> void:
	if _steam and lobby_id != 0:
		_steam.call("activateGameOverlayInviteDialog", lobby_id)

## Searches open lobbies of this game; answers with lobbies_found.
func find_lobbies() -> void:
	if not available:
		failed.emit(unavailable_reason)
		return
	_steam.call("addRequestLobbyListStringFilter", "game", GAME_KEY, LOBBY_COMPARISON_EQUAL)
	_steam.call("addRequestLobbyListDistanceFilter", LOBBY_DISTANCE_WORLDWIDE)
	_steam.call("requestLobbyList")

func friend_name(id: int) -> String:
	return str(_steam.call("getFriendPersonaName", id)) if _steam else ""

func _on_lobby_created(result: int, id: int) -> void:
	if result != RESULT_OK:
		failed.emit("Steam could not create a lobby (result %d)" % result)
		return
	lobby_id = id
	_steam.call("setLobbyJoinable", id, true)
	_steam.call("setLobbyData", id, "game", GAME_KEY)
	_steam.call("setLobbyData", id, "name", "%s's game" % persona)
	# Lets friends press "Join Game" on us in the Steam friends list
	if _steam.has_method("setRichPresence"):
		_steam.call("setRichPresence", "connect", "+connect_lobby %d" % id)
	var peer := _make_peer(true, 0)
	if peer:
		lobby_ready.emit(peer, true)

func _on_lobby_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != CHAT_ROOM_ENTER_SUCCESS:
		failed.emit("Could not join the Steam lobby (response %d)" % response)
		return
	lobby_id = id
	var owner_id := int(_steam.call("getLobbyOwner", id))
	if owner_id == steam_id:
		return # our own lobby: lobby_created already set the host up
	status.emit("Connecting to %s through Steam..." % friend_name(owner_id))
	var peer := _make_peer(false, owner_id)
	if peer:
		lobby_ready.emit(peer, false)

func _on_lobby_match_list(lobbies: Array, _count: int = 0) -> void:
	var out: Array = []
	for id in lobbies:
		out.append({
			"id": int(id),
			"name": str(_steam.call("getLobbyData", id, "name")),
			"members": int(_steam.call("getNumLobbyMembers", id)),
		})
	lobbies_found.emit(out)

func _on_join_requested(id: int, _friend_id: int) -> void:
	invite_accepted.emit(id)

## The peer for the current lobby. Newer GodotSteam versions can follow the
## lobby's members themselves (host_with_lobby / connect_to_lobby); older ones
## connect straight to the lobby owner.
func _make_peer(hosting: bool, owner_steam_id: int) -> MultiplayerPeer:
	var peer: MultiplayerPeer = _new_peer.call()
	if "no_nagle" in peer:
		peer.set("no_nagle", true) # send every tick's packet at once instead of batching
	var err: Variant
	var opts := {"virtual_port": 0, "port": 0, "options": []}
	if hosting:
		err = peer.call("host_with_lobby", lobby_id) if peer.has_method("host_with_lobby") else call_flexible(peer, "create_host", opts)
	else:
		err = peer.call("connect_to_lobby", lobby_id) if peer.has_method("connect_to_lobby") \
			else call_flexible(peer, "create_client", opts, [owner_steam_id])
	if err != OK:
		failed.emit("SteamMultiplayerPeer could not start (error %s)" % str(err))
		leave_lobby()
		return null
	return peer

## Calls `method` filling its parameters by name from `named` (after the
## positional `leading` ones), so small signature differences between GodotSteam
## versions (an extra options parameter, a renamed port) don't break the call.
static func call_flexible(obj: Object, method: String, named: Dictionary, leading: Array = []) -> Variant:
	for m in obj.get_method_list():
		if m.name != method:
			continue
		var args: Array = m.args
		var defaults: Array = m.default_args
		var first_default := args.size() - defaults.size()
		var values: Array = []
		for i in args.size():
			var arg_name: String = args[i].name
			if i < leading.size():
				values.append(leading[i])
			elif named.has(arg_name) and _fits(named[arg_name], args[i].type):
				values.append(named[arg_name])
			elif i >= first_default:
				values.append(defaults[i - first_default])
			else:
				values.append(type_convert(null, args[i].type))
		return obj.callv(method, values)
	return obj.call(method) if obj.has_method(method) else null

static func _fits(value: Variant, type: int) -> bool:
	return type == TYPE_NIL or typeof(value) == type or (type == TYPE_FLOAT and value is int)
