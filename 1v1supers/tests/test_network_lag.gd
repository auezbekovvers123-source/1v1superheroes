extends "res://tests/test_network.gd"
## test_network.gd over a bad connection: every message each machine receives is
## 70-110 ms late (round trip ~140-220 ms) and 5% of the unreliable packets are lost.

func _port() -> int:
	return 24712

func _netsim() -> Array:
	return [70, 40, 5]
