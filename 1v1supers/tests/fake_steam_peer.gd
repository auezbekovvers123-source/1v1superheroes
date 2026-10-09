extends ENetMultiplayerPeer
## Stand-in for GodotSteam's SteamMultiplayerPeer (tests only): its lobby
## helpers, carried over ENet on localhost.

const PORT := 24713

func host_with_lobby(_lobby_id: int) -> Error:
	return create_server(PORT, 1)

func connect_to_lobby(_lobby_id: int) -> Error:
	return create_client("127.0.0.1", PORT)
