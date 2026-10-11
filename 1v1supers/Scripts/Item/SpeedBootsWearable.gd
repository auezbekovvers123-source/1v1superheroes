extends GearWearable
class_name SpeedBootsWearable
## Speed boots (power "speed"): a red boot with a gold wing on each foot.

func _ready() -> void:
	super._ready()
	_main_material = solid(Color(0.85, 0.12, 0.1))
	var wing := glow(Color(1.0, 0.8, 0.2), 1.6)
	var sole := solid(Color(0.15, 0.12, 0.12), 0.1, 0.8)
	# Around the foot mesh: the ankle bone is 0.10 above the sole, the foot
	# runs from 0.07 behind it to 0.24 in front
	for side in [["foot.l", 1.0], ["foot.r", -1.0]]:
		var p := make_pivot(side[0])
		var out: float = side[1] # outward = +X for the left foot
		box(p, Vector3(0.2, 0.11, 0.33), Vector3(0, -0.045, 0.085), _main_material)
		box(p, Vector3(0.14, 0.13, 0.15), Vector3(0, 0.04, 0.0), _main_material) # shaft round the ankle
		box(p, Vector3(0.205, 0.025, 0.335), Vector3(0, -0.09, 0.085), sole)
		box(p, Vector3(0.02, 0.1, 0.17), Vector3(0.08 * out, 0.08, -0.04), wing, Vector3(0, 0, -20.0 * out))
