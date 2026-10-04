extends SkeletonModifier3D
class_name UpperBodyTwist
## Twists the upper spine (and a little of the neck) around the bones' own Y axis,
## ON TOP of whatever the AnimationTree posed this frame. Skeleton modifiers run
## after animation and their result is discarded every frame, so the twist never
## fights the animation and never accumulates.

@export var spine_bone: String = "spine_03.x"
@export var neck_bone: String = "neck.x"
@export var neck_share: float = 0.35 # fraction of the twist applied to the neck

## Current twist in radians (set by the owner every physics frame).
var twist: float = 0.0

var _spine_idx: int = -1
var _neck_idx: int = -1
var _resolved: bool = false

func _process_modification_with_delta(_delta: float) -> void:
	if is_zero_approx(twist):
		return
	var skel := get_skeleton()
	if skel == null:
		return
	if not _resolved:
		_spine_idx = skel.find_bone(spine_bone)
		_neck_idx = skel.find_bone(neck_bone)
		_resolved = true
	if _spine_idx >= 0:
		skel.set_bone_pose_rotation(_spine_idx, skel.get_bone_pose_rotation(_spine_idx) * Quaternion(Vector3.UP, twist))
	if _neck_idx >= 0:
		skel.set_bone_pose_rotation(_neck_idx, skel.get_bone_pose_rotation(_neck_idx) * Quaternion(Vector3.UP, twist * neck_share))
