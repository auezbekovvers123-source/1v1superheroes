extends Area3D
class_name Hurtbox3D
## Hurtbox3D — receives hits, forwards to Health. Attach to character body.

var health_node: Node

func _ready() -> void:
	add_to_group("hurtbox")
	collision_layer = 4  # hurtbox layer
	collision_mask = 0
	monitoring = false
	monitorable = true
	health_node = get_parent().get_node_or_null("Health")
	if health_node == null:
		# search parent chain
		var p := get_parent()
		while p:
			var h = p.get_node_or_null("Health")
			if h:
				health_node = h
				break
			p = p.get_parent()
	if get_child_count() == 0:
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.48
		capsule.height = 1.82
		shape.shape = capsule
		add_child(shape)
	# Debug: green wire for hurtbox (always visible in editor, hidden in game unless you enable)
	var dbg = get_node_or_null("HurtDBG")
	if dbg == null:
		var mi = MeshInstance3D.new()
		mi.name = "HurtDBG"
		var capm = CapsuleMesh.new()
		capm.radius = 0.48
		capm.height = 1.82
		capm.radial_segments = 12
		mi.mesh = capm
		var dmat = StandardMaterial3D.new()
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dmat.albedo_color = Color(0.2,1,0.3,0.10)
		dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = dmat
		# Hide by default - set visible true to debug
		mi.visible = false
		add_child(mi)
