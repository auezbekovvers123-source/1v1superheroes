extends GearWearable
class_name LaserVisorWearable
## Laser visor (power "laser"): a dark band round the head with a glowing red
## lens across the eyes.

func _ready() -> void:
	super._ready()
	var p := make_pivot(bone_name)
	_main_material = solid(Color(0.12, 0.12, 0.16), 0.6, 0.35)
	var y := Player.EYE_HEIGHT
	var band := MeshInstance3D.new()
	var ring := CylinderMesh.new()
	ring.top_radius = 0.225 # the head is 0.216 round
	ring.bottom_radius = 0.225
	ring.height = 0.06
	ring.radial_segments = 24
	band.mesh = ring
	band.material_override = _main_material
	band.position = Vector3(0, y, 0)
	p.add_child(band)
	# The eyes stand out of the head, so the lens sits well forward of the band
	var lens_z := Player.EYE_FORWARD - 0.02
	box(p, Vector3(0.44, 0.16, 0.04), Vector3(0, y, lens_z), glow(Color(1.0, 0.1, 0.06), 3.0))
	for side in [1.0, -1.0]:
		box(p, Vector3(0.035, 0.07, 0.17), Vector3(0.215 * side, y, lens_z - 0.09), _main_material)
	box(p, Vector3(0.46, 0.025, 0.05), Vector3(0, y + 0.085, lens_z), _main_material) # brow rim
