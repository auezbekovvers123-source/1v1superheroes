extends RefCounted
## Stand-in for the GodotSteam singleton (tests only). Lobbies exist only in
## this process and the "Steam" connection is ENet on localhost
## (fake_steam_peer.gd). Lobby ids encode their owner: 1000 + owner's Steam id.

signal lobby_created(connect: int, lobby_id: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal join_requested(lobby_id: int, steam_id: int)

var steam_id: int
var persona: String
var lobby_data := {}
var calls: Array[String] = []

func _init(p_steam_id: int, p_persona: String) -> void:
	steam_id = p_steam_id
	persona = p_persona

# Newer GodotSteam signature; SteamLobby fills it by parameter name
func steamInitEx(app_id: int = 0, embed_callbacks: bool = false) -> Dictionary:
	calls.append("steamInitEx %d %s" % [app_id, embed_callbacks])
	return {"status": 0, "verbal": "Steamworks active."}

func run_callbacks() -> void:
	pass

func getSteamID() -> int:
	return steam_id

func getPersonaName() -> String:
	return persona

func getFriendPersonaName(id: int) -> String:
	return "Friend %d" % id

func createLobby(lobby_type: int, max_members: int) -> void:
	calls.append("createLobby %d %d" % [lobby_type, max_members])
	var id := 1000 + steam_id
	var answer := func():
		lobby_created.emit(1, id)
		lobby_joined.emit(id, 0, false, 1) # Steam also joins you to your own lobby
	answer.call_deferred()

func joinLobby(id: int) -> void:
	calls.append("joinLobby %d" % id)
	var answer := func(): lobby_joined.emit(id, 0, false, 1)
	answer.call_deferred()

func getLobbyOwner(id: int) -> int:
	return id - 1000

func setLobbyJoinable(_id: int, joinable: bool) -> bool:
	calls.append("setLobbyJoinable %s" % joinable)
	return true

func setLobbyData(_id: int, key: String, value: String) -> bool:
	lobby_data[key] = value
	return true

func getLobbyData(_id: int, key: String) -> String:
	return lobby_data.get(key, "")

func getNumLobbyMembers(_id: int) -> int:
	return 1

func setRichPresence(key: String, value: String) -> bool:
	calls.append("setRichPresence %s=%s" % [key, value])
	return true

func clearRichPresence() -> void:
	calls.append("clearRichPresence")

func leaveLobby(id: int) -> void:
	calls.append("leaveLobby %d" % id)

func activateGameOverlayInviteDialog(id: int) -> void:
	calls.append("invite %d" % id)

func addRequestLobbyListStringFilter(key: String, value: String, comparison: int) -> void:
	calls.append("filter %s=%s %d" % [key, value, comparison])

func addRequestLobbyListDistanceFilter(distance: int) -> void:
	calls.append("distance %d" % distance)

func requestLobbyList() -> void:
	var answer := func(): lobby_match_list.emit([1000 + steam_id])
	answer.call_deferred()
