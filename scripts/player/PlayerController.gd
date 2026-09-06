# ============================================================================
# 文件:    PlayerController.gd
# 路径:    res://scripts/player/PlayerController.gd
# 职责:    第一人称玩家的移动 / 跳跃 / 重力 / 水中判定 / 世界边界空气墙
# 说明:    继承 CharacterBody3D（依赖地形 StaticBody 提供地面碰撞）。
#          - 水中判定：身体中心（global_position.y + 0.9）没入水面 WATER_LEVEL 即入水。
#          - 水中：低重力、低移速、低跳。
#          - 空气墙：用 position clamp 硬钳世界边界 ±32 与高度 0~15。
#          面向(yaw)由 CameraController 转向本节点，使 WASD 相对视线方向。
# ============================================================================
extends CharacterBody3D
class_name PlayerController

# 陆地参数
const LAND_SPEED := 5.0
const LAND_JUMP_VELOCITY := 6.5
const LAND_GRAVITY := -20.0

# 水中参数（身体中心没入水面时触发）
const WATER_SPEED := 2.0
const WATER_JUMP_VELOCITY := 2.5
const WATER_GRAVITY := -8.0
# 水面高度：当前地形外围 1 宽水沟，水到 gy5 → 水面≈世界 y6
const WATER_LEVEL := 6.0
# 身体中心相对原点偏移（身高约 1.8，脚底在 origin-0.9 → 中心在 origin+0.9）
const BODY_CENTER_OFFSET := 0.9
# 世界边界半宽（空气墙留出胶囊半径）
const WORLD_HALF := 0.4
const WORLD_MIN := -32
const WORLD_MAX := 31


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	# 1) 入水判定
	var in_water := global_position.y + BODY_CENTER_OFFSET < WATER_LEVEL

	# 2) 重力
	var gravity := WATER_GRAVITY if in_water else LAND_GRAVITY
	velocity.y += gravity * delta

	# 3) 跳跃（仅在地面）
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = WATER_JUMP_VELOCITY if in_water else LAND_JUMP_VELOCITY

	# 4) 水平移动（方向投影到本节点局部坐标系，跟随相机转向）
	var speed := WATER_SPEED if in_water else LAND_SPEED
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	if direction.length() > 0.001:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()

	# 5) 世界边界硬碰撞（空气墙）
	position.x = clampf(position.x, float(WORLD_MIN) + WORLD_HALF, float(WORLD_MAX) - WORLD_HALF)
	position.z = clampf(position.z, float(WORLD_MIN) + WORLD_HALF, float(WORLD_MAX) - WORLD_HALF)
	position.y = clampf(position.y, 0.0, 15.0)
