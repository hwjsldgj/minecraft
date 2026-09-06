# ============================================================================
# 文件:    CameraController.gd
# 路径:    res://scripts/player/CameraController.gd
# 职责:    第一人称鼠标视角（挂到 Player 下的 Camera3D）
# 说明:    鼠标 X → 旋转父节点(Player)的 yaw，使 WASD 移动相对视线；
#          鼠标 Y → 旋转本相机 pitch（±89° 俯仰）。
#          ESC 释放鼠标；鼠标左键点击时重新捕获。
# ============================================================================
extends Node3D
class_name CameraController

@export var sensitivity: float = 0.002


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# yaw：转向父节点（Player），让 move 的方向跟随视线
		var parent := get_parent()
		if parent is Node3D:
			(parent as Node3D).rotate_y(-event.relative.x * sensitivity)
		# pitch：只俯仰本相机
		var rel: Vector2 = event.relative
		var pitch: float = rotation.x - rel.y * sensitivity
		rotation.x = clampf(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
