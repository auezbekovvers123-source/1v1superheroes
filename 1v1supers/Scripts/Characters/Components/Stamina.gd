extends Node
class_name Stamina
## Stamina pool with regen delay. All stamina tuning (costs included) lives here.

signal changed(value: float, max_value: float)

@export var max_value: float = 100.0
@export var regen_per_sec: float = 18.0
@export var regen_delay: float = 0.45 # seconds after spending before regen starts
@export_group("Costs")
@export var cost_dash: float = 25.0
@export var cost_punch: float = 8.0
@export var cost_kick: float = 14.0
@export var run_drain_per_sec: float = 8.0

var value: float = 100.0
var _regen_timer: float = 0.0

func _ready() -> void:
	value = max_value

func has(amount: float) -> bool:
	return value >= amount

## Spends `amount` if there is enough. Returns false (and spends nothing) otherwise.
func use(amount: float) -> bool:
	if value < amount:
		return false
	value = maxf(value - amount, 0.0)
	_regen_timer = regen_delay
	changed.emit(value, max_value)
	return true

func refill() -> void:
	value = max_value
	_regen_timer = 0.0
	changed.emit(value, max_value)

func tick(delta: float) -> void:
	if value >= max_value:
		value = max_value
		_regen_timer = regen_delay
		return
	if _regen_timer > 0.0:
		_regen_timer -= delta
		return
	value = minf(value + regen_per_sec * delta, max_value)
	changed.emit(value, max_value)
