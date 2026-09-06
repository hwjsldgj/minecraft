# ============================================================================
# 文件:    editor_camera.gd
# 路径:    res://scripts/rendering/editor_camera.gd
# 职责:    开发用观察相机：围绕目标点轨道旋转 / 缩放，便于浏览体素世界
# 说明:    纯编辑器/开发观察用途，不属玩家控制（玩家物理属后续阶段）。
#           操作：按住鼠标右键拖动=旋转视角；滚轮=缩放。
# ============================================================================
extends Camera3D

@export var target: Vector3 = Vector3(0, 6, 0)
@export var distance := 58.0
@export var yaw_deg := 45.0
@export var pitch_deg := 38.0

var _dragging := false
var _last_mouse := Vector2.ZERO


func _ready() -> void:
	_apply_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
			_last_mouse = event.position
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = max(distance * 0.85, 6.0)
			_apply_transform()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = min(distance * 1.18, 220.0)
			_apply_transform()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var delta: Vector2 = event.position - _last_mouse
		_last_mouse = event.position
		# 拖拽旋转：左右=偏航，上下=俯仰
		yaw_deg = fposmod(yaw_deg - delta.x * 0.25, 360.0)
		pitch_deg = clampf(pitch_deg + delta.y * 0.25, -85.0, 85.0)
		_apply_transform()
		get_viewport().set_input_as_handled()


func _apply_transform() -> void:
	var horiz := deg_to_rad(yaw_deg)
	var elev := deg_to_rad(pitch_deg)
	var offset := Vector3(
		cos(elev) * sin(horiz),
		sin(elev),
		cos(elev) * cos(horiz)
	) * distance
	global_position = target + offset
	look_at(target, Vector3.UP)
