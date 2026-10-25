extends Node
class_name Powers
## The fighter's superpowers, one per worn item that declares a power_id. Kept
## in step with Equipment: put an item on and its power appears, take it off
## and it is gone. Player calls the hooks once per frame.

signal changed()

## power_id (ItemData.power_id) -> the Power script. A new item power = a new
## Power script + a line here.
const REGISTRY := {
	"fly": "res://Scripts/Characters/Powers/FlightPower.gd",
	"speed": "res://Scripts/Characters/Powers/SuperSpeedPower.gd",
	"laser": "res://Scripts/Characters/Powers/LaserEyesPower.gd",
}

var player: Player
var _active: Dictionary = {} # power_id -> Power

func setup(p_player: Player) -> void:
	player = p_player
	player.equipment.item_equipped.connect(func(_s: int, _i: ItemData): _sync())
	player.equipment.item_unequipped.connect(func(_s: int, _i: ItemData): _sync())
	_sync()

func has(power_id: String) -> bool:
	return _active.has(power_id)

func get_power(power_id: String) -> Power:
	return _active.get(power_id)

func list() -> Array:
	return _active.values()

func handle_intent(i: PlayerInput.Intent) -> void:
	for p: Power in _active.values():
		p.handle_intent(i)

func physics_update(delta: float) -> void:
	for p: Power in _active.values():
		p.physics_update(delta)

## Fastest sprint any worn power gives (0 = the normal run).
func run_speed() -> float:
	var best := 0.0
	for p: Power in _active.values():
		best = maxf(best, p.run_speed())
	return best

func dash_scale() -> float:
	var best := 1.0
	for p: Power in _active.values():
		best = maxf(best, p.dash_scale())
	return best

## Lets every worn power boost a melee swing; returns the knockback multiplier.
func boost_strike(hit: HitInfo) -> float:
	var k := 1.0
	for p: Power in _active.values():
		k *= p.boost_strike(hit)
	return k

func hints() -> PackedStringArray:
	var out := PackedStringArray()
	for p: Power in _active.values():
		if p.hint() != "":
			out.append(p.hint())
	return out

func _sync() -> void:
	var wanted := {}
	var items := player.equipment.list_items()
	for slot in items:
		var item: ItemData = items[slot]
		if item.power_id != "" and REGISTRY.has(item.power_id):
			wanted[item.power_id] = true
	var any := false
	for power_id in _active.keys():
		if not wanted.has(power_id):
			(_active[power_id] as Power).removed()
			_active.erase(power_id)
			any = true
	for power_id in wanted:
		if not _active.has(power_id):
			var p: Power = (load(REGISTRY[power_id]) as GDScript).new(player, power_id)
			_active[power_id] = p
			p.added()
			any = true
	if any:
		changed.emit()

func _exit_tree() -> void:
	for p: Power in _active.values():
		p.removed()
	_active.clear()
