extends Area3D
class_name Hurtbox3D
## Where a fighter can be hit. Hitbox3D finds these with a shape query and
## forwards the hit to `health`.

const LAYER: int = 4 # physics layer 3 (bit value 4)

var health: Health = null

func _ready() -> void:
	add_to_group("hurtbox")
	collision_layer = LAYER
	collision_mask = 0
	monitoring = false
	monitorable = true
	health = get_parent().get_node_or_null("Health") as Health
	if get_child_count() == 0:
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.48
		capsule.height = 1.82
		shape.shape = capsule
		add_child(shape)

## The fighter this hurtbox belongs to.
func get_body() -> Node3D:
	return get_parent() as Node3D
