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

# ===== 陆地参数（编辑器内按组显示；默认值与既有手感一致）=====
@export_group("Land")
@export var land_speed: float = 5.0          # 陆地水平速度
@export var land_jump: float = 6.5           # 起跳初速度
@export var land_gravity: float = -20.0      # 重力加速度

# ===== 液体参数（MC Wiki 数据；与陆地完全分离，为未来其它液体留扩展位）=====
@export_group("Liquid")
@export var water_speed: float = 2.20          # 水面/完全浸没水平游速 (MC 2.20)
@export var water_partial_speed: float = 1.97  # 部分浸入(浅水)水平速度 (MC 1.97)
@export var water_down: float = 1.81           # 完全水下向下游 (MC 1.81)
@export var water_up: float = 0.39             # 完全水下向上游 (MC 0.39)
@export var water_surface_up: float = 2.00     # 未完全浸没时上浮/出水
@export var water_idle_sink: float = 0.80      # 无输入时自然下沉速度
@export var water_sink_accel: float = 4.0      # 垂直速度趋近率
@export var water_drag: float = 0.8            # MC drag_factor（每游戏刻 20Hz）

# MC 游戏刻频率（用于把每刻阻力换算到帧）
const LIQUID_TICK_RATE := 20.0

# ===== 交互（子任务 4.1/4.2：DDA 破坏/放置 + 物品栏）=====
@export_group("Interaction")
@export var interact_reach: float = 4.0
# 是否要求鼠标处于捕获状态才响应交互（无头测试可关闭以驱动输入链路）
@export var require_mouse_capture: bool = true

# ===== 碰撞体（胶囊：脚底在原点，身高 body_height，中心在 +body_center_offset）=====
@export_group("Physics")
@export var body_height: float = 1.8
@export var body_radius: float = 0.4         # 胶囊半径（兼作世界边界留边）
@export var body_center_offset: float = 0.9
# 物品栏（9 格，数字键 1~9 切换；空槽 = -1）
var inventory: Inventory = Inventory.new()
# 当前待放置方块 ID：来自物品栏当前槽（只读，UI 与放置共用）
var current_block_id: int:
	get:
		return inventory.get_current()

var _camera: Camera3D = null

# 当前是否处于水中（供其它表现模块读取；判定基于体素）
var in_water := false

@onready var _world: WorldManager = get_node_or_null("../World") as WorldManager


func _ready() -> void:
	# 与地形 StaticBody3D 同层，确保陆地与水中均正常碰撞（不穿模）
	collision_layer = 1
	collision_mask = 1
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 世界渲染（网格+碰撞体）就绪前冻结物理：否则出生于空中时会先下坠，
	# 而出生点所在区块的碰撞体尚未生成 → 穿过地面卡在方块内部。
	if _world != null and not _world.is_physics_ready():
		velocity = Vector3.ZERO
		set_physics_process(false)
		_world.world_ready.connect(_on_world_ready)


# 世界就绪回调：恢复物理模拟
func _on_world_ready() -> void:
	set_physics_process(true)


# 世界坐标处是否为水方块（体素检测；无世界引用时视为非水）
func is_water_at(world_pos: Vector3) -> bool:
	if _world == null:
		return false
	var id := _world.get_block(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	return id == GlobalConfig.BLOCK_WATER


# 惰性获取相机（相机子节点可能晚于本节点进入场景树）
func _camera_node() -> Camera3D:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_node_or_null("Camera3D") as Camera3D
	return _camera


# 从摄像机中心沿视线方向做 DDA 射线，返回命中信息（未命中 hit=false）
func aim() -> Dictionary:
	var cam := _camera_node()
	if cam == null or _world == null:
		return { "hit": false, "block_pos": Vector3i.ZERO, "normal": Vector3i.ZERO, "t": 0.0 }
	var origin := cam.global_position
	var direction := -cam.global_transform.basis.z
	return DDA.raycast(_world, origin, direction, interact_reach)


# 左键：破坏命中的方块（只走 WorldManager API，不直接操作网格节点）
func try_break() -> bool:
	var r := aim()
	if not r.get("hit", false):
		return false
	var p: Vector3i = r["block_pos"]
	# 只写数据：网格失效与重建由 WorldManager.set_block 统一负责
	# （曾在此误传"方块坐标"给 rebuild_chunk（它要的是"区块索引"），
	#   查表失败静默返回，导致数据已变而画面不变——F5 点击"无反应"的根因。）
	_world.set_block(p.x, p.y, p.z, GlobalConfig.BLOCK_AIR)
	return true


# 放置合法性：边界内 + 目标为空 + 不与玩家 AABB 重叠
func can_place_at(target: Vector3i) -> bool:
	if _world == null:
		return false
	if target.x < GlobalConfig.WORLD_MIN_X or target.x > GlobalConfig.WORLD_MAX_X:
		return false
	if target.z < GlobalConfig.WORLD_MIN_Z or target.z > GlobalConfig.WORLD_MAX_Z:
		return false
	if target.y < GlobalConfig.WORLD_MIN_Y or target.y > GlobalConfig.WORLD_MAX_Y:
		return false
	if _world.get_block(target.x, target.y, target.z) != GlobalConfig.BLOCK_AIR:
		return false  # 已占用（含未加载 -1）
	# 玩家 AABB 与目标方块 AABB 相交检测
	var r := body_radius
	var pmin := global_position - Vector3(r, 0.0, r)
	var pmax := global_position + Vector3(r, body_height, r)
	var bmin := Vector3(target)
	var bmax := bmin + Vector3.ONE
	var overlap := pmin.x < bmax.x and pmax.x > bmin.x \
		and pmin.y < bmax.y and pmax.y > bmin.y \
		and pmin.z < bmax.z and pmax.z > bmin.z
	return not overlap


# 右键：在命中面法线方向放置 current_block_id
func try_place() -> bool:
	if current_block_id < 0:
		return false  # 空槽位：拒绝放置
	var r := aim()
	if not r.get("hit", false):
		return false
	var n: Vector3i = r["normal"]
	if n == Vector3i.ZERO:
		return false  # 视线起点已在方块内，方向不明确
	var hit_pos: Vector3i = r["block_pos"]
	var target := hit_pos + n
	if not can_place_at(target):
		return false
	_world.set_block(target.x, target.y, target.z, current_block_id)
	return true


# 数字键 1~9 → 选中槽位 0~8（返回是否处理）
func handle_hotbar_key(keycode: int) -> bool:
	if keycode < KEY_1 or keycode > KEY_9:
		return false
	return inventory.select_slot(keycode - KEY_1)


# 鼠标左键破坏 / 右键放置；数字键切换物品栏（仅在鼠标被捕获时响应）
func _unhandled_input(event: InputEvent) -> void:
	if require_mouse_capture and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			try_break()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			try_place()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			handle_hotbar_key(k.keycode)


func _physics_process(delta: float) -> void:
	# 0) 依据玩家位置动态加载/卸载区块（无限世界框架：数据先行 + 分帧渲染）
	if _world != null:
		_world.update_chunk_loading(global_position)

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
		var h_speed := water_speed if submerged else water_partial_speed
		if has_input:
			velocity.x = direction.x * h_speed
			velocity.z = direction.z * h_speed
		else:
			# 无输入：按 MC drag_factor（每游戏刻 20Hz）衰减
			var drag := pow(water_drag, delta * LIQUID_TICK_RATE)
			velocity.x *= drag
			velocity.z *= drag
		# 3) 水中垂直：空格上浮(水下 0.39/水面 2.0) / Shift 下沉(1.81) / 无输入缓沉
		if Input.is_action_pressed("jump"):
			velocity.y = water_up if submerged else water_surface_up
		elif Input.is_action_pressed("sneak"):
			velocity.y = -water_down
		else:
			velocity.y = move_toward(velocity.y, -water_idle_sink, water_sink_accel * delta)
	else:
		# 4) 陆地：重力 + 连跳 + 水平移动（与液体参数完全分离）
		velocity.y += land_gravity * delta
		if Input.is_action_pressed("jump") and is_on_floor():
			velocity.y = land_jump
		if has_input:
			velocity.x = direction.x * land_speed
			velocity.z = direction.z * land_speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, land_speed)
			velocity.z = move_toward(velocity.z, 0.0, land_speed)

	move_and_slide()

	# 5) 世界边界硬碰撞（空气墙，与 GlobalConfig 严格一致，仅留胶囊半径）
	position.x = clampf(position.x, float(GlobalConfig.WORLD_MIN_X) + body_radius, float(GlobalConfig.WORLD_MAX_X) - body_radius)
	position.z = clampf(position.z, float(GlobalConfig.WORLD_MIN_Z) + body_radius, float(GlobalConfig.WORLD_MAX_Z) - body_radius)
	position.y = clampf(position.y, float(GlobalConfig.WORLD_MIN_Y), float(GlobalConfig.WORLD_MAX_Y))
