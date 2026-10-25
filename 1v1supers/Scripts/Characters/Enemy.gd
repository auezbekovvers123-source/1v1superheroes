extends Node
class_name Enemy
## Makes its parent fighter a villain: computer-controlled (give it an
## AIPlayerInput as its Input), tinted, with a name and health bar overhead and
## starting gear. Villains are an offline thing: online they remove themselves.

@export var display_name: String = "VILLAIN"
## Multiplies the model's colours: an evil twin of the hero.
@export var tint: Color = Color(0.9, 0.36, 0.34)
## Worn from the start (each takes its slot).
@export var loadout: Array[ItemData] = []

var fighter: Player

func _ready() -> void:
	fighter = get_parent() as Player
	fighter.add_to_group("enemy")
	var net := get_node_or_null("/root/Net")
	if net:
		if net.is_online():
			fighter.queue_free() # a session is two humans; nobody would own the villain
			return
		net.session_started.connect(fighter.queue_free) # a session starting without reloading the level
	# Children are ready before their parent: finish once the fighter has its components
	fighter.ready.connect(_setup, CONNECT_ONE_SHOT)

func _setup() -> void:
	for item in loadout:
		if item:
			fighter.take_from_world(item)
	_tint()
	var bar := OverheadHealthBar.new()
	bar.name = "OverheadHealthBar"
	fighter.add_child(bar)
	bar.setup(fighter.health, display_name)

func _tint() -> void:
	var skel := fighter.get_skeleton()
	if skel == null:
		return
	var done := {} # original material -> tinted copy, shared between meshes
	for n in skel.get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as BaseMaterial3D
			if mat == null:
				continue
			if not done.has(mat):
				var copy := mat.duplicate() as BaseMaterial3D
				copy.albedo_color = mat.albedo_color * tint
				done[mat] = copy
			mi.set_surface_override_material(s, done[mat])
