extends Node3D
class_name OverheadHealthBar
## A camera-facing health bar with a name above it, floating over a fighter.
## Hidden while the fighter is down.

const HEALTH_BAR_SHADER := preload("res://Assets/Shaders/health_bar.gdshader")

@export var height: float = 2.35
@export var title: String = ""
@export var title_color: Color = Color(1.0, 0.35, 0.3)

var health: Health
var _mat: ShaderMaterial
var _bar: MeshInstance3D
var _label: Label3D

func setup(p_health: Health, p_title: String = "") -> void:
	health = p_health
	title = p_title
	if is_node_ready():
		_bind()

func _ready() -> void:
	position = Vector3(0, height, 0)
	_bar = MeshInstance3D.new()
	_bar.name = "Bar"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.1, 0.11)
	_bar.mesh = quad
	_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	_mat.shader = HEALTH_BAR_SHADER
	_bar.material_override = _mat
	add_child(_bar)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 40
	_label.outline_size = 10
	_label.pixel_size = 0.004
	_label.modulate = title_color
	_label.position = Vector3(0, 0.16, 0)
	add_child(_label)
	if health:
		_bind()

func _bind() -> void:
	_label.text = title
	if not health.health_changed.is_connected(_on_health):
		health.health_changed.connect(_on_health)
	_on_health(health.current, health.max_health)

func _on_health(current: float, max_health: float) -> void:
	var pct := clampf(current / maxf(max_health, 1.0), 0.0, 1.0)
	_mat.set_shader_parameter("fill", pct)
	var col := Color(1.0, 0.25, 0.22, 0.95)
	if pct > 0.55:
		col = Color(1.0, 0.45, 0.2, 0.95)
	_mat.set_shader_parameter("fill_color", col)
	visible = current > 0.0
