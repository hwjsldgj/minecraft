# ============================================================================
# 文件:    PlayerController.gd
# 路径:    res://scripts/player/PlayerController.gd
# 职责:    第一人称玩家的移动 / 跳跃(连跳) / 重力 / 体素入水判定 / 水中操控 / 空气墙
# 说明:    继承 CharacterBody3D（依赖地形 StaticBody 提供地面碰撞）。
#          - 入水判定【基于体素】：查询脚部/身体中心所在方块是否为 BLOCK_WATER，
#            不再用 Y 高度（避免中央干坑被误判为水中）。
#          - 水中：空格上浮、Shift 下沉、无按键自然缓沉；不使用陆地跳跃。
#          - 陆地：按住空格 + is_on_floor → 触发跳跃（MC 风格连跳）。
#          - 空气墙：用 GlobalConfig 的世界边界常量 ± 胶囊半径。
#          面向(yaw)由 CameraController 转向本节点，使 WASD 相对视线方向。
# ============================================================================
extends CharacterBody3D
class_name PlayerController

# ===== 可调参数（检查器中可编辑）=====
@export var land_speed: float = 5.0
@export var land_jump_velocity: float = 6.5
@export var land_gravity: float = -20.0
@export var water_speed: float = 2.0
@export var swim_up_speed: float = 3.0
@export var sink_speed: float = 3.0
@export var water_sink_accel: float = 0.5
# 身体中心相对原点偏移（脚底在原点，身高约 1.8 → 中心在 +0.9）
@export var body_center_offset: float = 0.9
# 世界边界留边（胶囊半径）
@export var world_half_width: float = 0.4

# 当前是否处于水中（供其它表现模块读取；判定基于体素）
var in_water := false

@onready var _world: WorldManager = get_node_or_null("../World") as WorldManager


func _ready() -> void:
	# 与地形 StaticBody3D 同层，确保陆地与水中均正常碰撞（不穿模）
	collision_layer = 1
	collision_mask = 1
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# 世界坐标处是否为水方块（体素检测；无世界引用时视为非水）
func is_water_at(world_pos: Vector3) -> bool:
	if _world == null:
		return false
	var id := _world.get_block(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	return id == GlobalConfig.BLOCK_WATER


func _physics_process(delta: float) -> void:
	# 1) 体素入水判定：脚部或身体中心所在方块为水
	var feet := global_position
	var center := global_position + Vector3(0.0, body_center_offset, 0.0)
	in_water = is_water_at(feet) or is_water_at(center)

	var speed := water_speed if in_water else land_speed

	# 2) 垂直运动
	if in_water:
		# 水中：空格上浮 / Shift 下沉 / 无按键自然缓沉（禁用陆地跳跃）
		if Input.is_action_pressed("jump"):
			velocity.y = swim_up_speed
		elif Input.is_action_pressed("sneak"):
			velocity.y = -sink_speed
		else:
			velocity.y -= water_sink_accel * delta
	else:
		velocity.y += land_gravity * delta
		# MC 风格连跳：按住空格落地即起跳
		if Input.is_action_pressed("jump") and is_on_floor():
			velocity.y = land_jump_velocity

	# 3) 水平移动（方向投影到本节点局部坐标系，跟随相机转向）
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	if direction.length() > 0.001:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()

	# 4) 世界边界硬碰撞（空气墙，与 GlobalConfig 严格一致，仅留胶囊半径）
	position.x = clampf(position.x, float(GlobalConfig.WORLD_MIN_X) + world_half_width, float(GlobalConfig.WORLD_MAX_X) - world_half_width)
	position.z = clampf(position.z, float(GlobalConfig.WORLD_MIN_Z) + world_half_width, float(GlobalConfig.WORLD_MAX_Z) - world_half_width)
	position.y = clampf(position.y, float(GlobalConfig.WORLD_MIN_Y), float(GlobalConfig.WORLD_MAX_Y))
