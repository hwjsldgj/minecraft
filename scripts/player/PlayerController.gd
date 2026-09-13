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

# ===== 陆地参数（可调）=====
@export var land_speed: float = 5.0
@export var land_jump_velocity: float = 6.5
@export var land_gravity: float = -20.0

# ===== 液体参数（MC Wiki 手感触感参考值；与陆地分离，便于扩展其它液体）=====
@export_group("Liquid")
@export var liquid_swim_speed: float = 2.20        # 水面/完全浸没水平游速 (MC 2.20)
@export var liquid_partial_speed: float = 1.97     # 部分浸入(浅水)水平速度 (MC 1.97)
@export var liquid_down_speed: float = 1.81        # 完全水下向下游 (MC 1.81)
@export var liquid_up_speed: float = 0.39          # 完全水下向上游 (MC 0.39)
@export var liquid_surface_up_speed: float = 2.00  # 未完全浸没时上浮/出水
@export var liquid_idle_sink_speed: float = 0.80   # 无输入时自然下沉速度
@export var liquid_sink_accel: float = 4.0         # 垂直速度趋近率
@export var liquid_drag: float = 0.8               # MC drag_factor（每游戏刻 20Hz）
@export_group("")

# MC 游戏刻频率（用于把每刻阻力换算到帧）
const LIQUID_TICK_RATE := 20.0

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
	# 1) 体素判定：脚部进水=接触水；身体中心进水=完全浸没
	var feet := global_position
	var center := global_position + Vector3(0.0, body_center_offset, 0.0)
	var feet_in_water := is_water_at(feet)
	var submerged := is_water_at(center)
	in_water = feet_in_water or submerged

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var has_input := direction.length() > 0.001

	if in_water:
		# 2) 水中水平：完全浸没=游泳速度；仅部分浸入=浅水速度（MC 2.20 / 1.97）
		var h_speed := liquid_swim_speed if submerged else liquid_partial_speed
		if has_input:
			velocity.x = direction.x * h_speed
			velocity.z = direction.z * h_speed
		else:
			# 无输入：按 MC drag_factor（每游戏刻 20Hz）衰减
			var drag := pow(liquid_drag, delta * LIQUID_TICK_RATE)
			velocity.x *= drag
			velocity.z *= drag
		# 3) 水中垂直：空格上浮(水下 0.39/水面 2.0) / Shift 下沉(1.81) / 无输入缓沉
		if Input.is_action_pressed("jump"):
			velocity.y = liquid_up_speed if submerged else liquid_surface_up_speed
		elif Input.is_action_pressed("sneak"):
			velocity.y = -liquid_down_speed
		else:
			velocity.y = move_toward(velocity.y, -liquid_idle_sink_speed, liquid_sink_accel * delta)
	else:
		# 4) 陆地：重力 + 连跳 + 水平移动（与液体参数完全分离）
		velocity.y += land_gravity * delta
		if Input.is_action_pressed("jump") and is_on_floor():
			velocity.y = land_jump_velocity
		if has_input:
			velocity.x = direction.x * land_speed
			velocity.z = direction.z * land_speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, land_speed)
			velocity.z = move_toward(velocity.z, 0.0, land_speed)

	move_and_slide()

	# 5) 世界边界硬碰撞（空气墙，与 GlobalConfig 严格一致，仅留胶囊半径）
	position.x = clampf(position.x, float(GlobalConfig.WORLD_MIN_X) + world_half_width, float(GlobalConfig.WORLD_MAX_X) - world_half_width)
	position.z = clampf(position.z, float(GlobalConfig.WORLD_MIN_Z) + world_half_width, float(GlobalConfig.WORLD_MAX_Z) - world_half_width)
	position.y = clampf(position.y, float(GlobalConfig.WORLD_MIN_Y), float(GlobalConfig.WORLD_MAX_Y))
