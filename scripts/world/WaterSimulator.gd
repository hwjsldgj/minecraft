# ============================================================================
# 文件:    WaterSimulator.gd
# 路径:    res://scripts/world/WaterSimulator.gd
# 职责:    流动水第一阶段（基础扩散）：水源向水平方向扩散、向下优先、水位分级
# 说明:    - BFS 队列驱动（绝不递归）：每个待处理位置入队一次（_pending 去重），
#            由 _process 按 @export 的节奏与每帧上限消费；队列为空时直接 return，
#            流完后零开销。
#          - 扩散规则（MC Wiki 核实）：
#              * 水源 BLOCK_WATER（水位 0）永久存在，不会消失；
#              * 优先向下：下方为空气 → 直接落下（下落不衰减水位）；
#              * 下方为固体或水时 → 向四个水平方向扩散，水位 +1；
#              * 水位到达 7（最远）后停止继续扩散（最远 7 格）。
#          - 水位数据接口：get_level(pos) / levels 字典，供未来"水位分级渲染"读取
#            （水位 0=水源，1~7=流动水）。方块 ID 只区分 水源/流动水 两类。
#          - 本阶段不实现：两源成新源、水岩交互、水消退。
# ============================================================================
class_name WaterSimulator
extends Node

const SOURCE := GlobalConfig.BLOCK_WATER
const FLOWING := GlobalConfig.BLOCK_FLOWING_WATER
const MAX_LEVEL := 7

# 四个水平扩散方向
const SIDES := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
# 六邻接（用于方块变化后唤醒周围的水）
const NEIGHBORS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

# 每帧最多处理的方块数（节流，避免卡顿）
@export var max_updates_per_frame: int = 2
# 扩散节奏：每 5 游戏刻 = 0.25s 推进一格（即 4 方块/秒）
@export var step_interval: float = 0.25

# 待处理队列（BFS）与其去重表
var _queue: Array[Vector3i] = []
var _pending: Dictionary = {}
# 水位接口：位置 -> 0~7（0=水源）。供渲染/逻辑查询；非水位置不登记。
var levels: Dictionary = {}

var _accum := 0.0
var _world: WorldManager = null
# 自身写入期间置位：避免自己的 set_block 又回调 on_block_changed，
# 造成"自我唤醒 → 队列反复膨胀"的无效循环。
var _writing := false


func _ready() -> void:
	_world = get_parent() as WorldManager


# ===== 水位查询接口（未来水位分级渲染使用）=====

# 返回该位置水位 0~7；不是水（或未登记且非水源）返回 -1
func get_level(pos: Vector3i) -> int:
	if levels.has(pos):
		return levels[pos]
	if _world != null and _world.get_block(pos.x, pos.y, pos.z) == SOURCE:
		return 0
	return -1


func is_source(pos: Vector3i) -> bool:
	return _world != null and _world.get_block(pos.x, pos.y, pos.z) == SOURCE


# ===== 队列 =====

# 入队一个待处理位置（去重）
func enqueue(pos: Vector3i) -> void:
	if _pending.has(pos):
		return
	_pending[pos] = true
	_queue.append(pos)


func has_pending() -> bool:
	return not _queue.is_empty()


func pending_count() -> int:
	return _queue.size()


# 立即把队列处理完（供测试；游戏内由 _process 分帧消费）
func flush(max_steps: int = 100000) -> void:
	var steps := 0
	while not _queue.is_empty() and steps < max_steps:
		var pos: Vector3i = _queue.pop_front()
		_pending.erase(pos)
		_update_cell(pos)
		steps += 1


# 方块发生变化（WorldManager.set_block 调用）：
#   - 写入水 → 登记水位（水源固定为 0）并入队，同时唤醒周围的水重新判断；
#   - 写入非水 → 清掉水位记录，并唤醒周围的水（可能有了新的空间可流过去）。
func on_block_changed(pos: Vector3i, id: int) -> void:
	if _writing:
		return   # 自己写入的水由 _place 直接管理水位与入队，无需再回调
	if GlobalConfig.is_water(id):
		if id == SOURCE:
			levels[pos] = 0
		enqueue(pos)
	else:
		levels.erase(pos)
	for d in NEIGHBORS:
		var np: Vector3i = pos + d
		if _world != null and GlobalConfig.is_water(_world.get_block(np.x, np.y, np.z)):
			enqueue(np)


# ===== 分帧推进 =====

func _process(delta: float) -> void:
	if _queue.is_empty():
		return   # 流完即零开销
	_accum += delta
	if _accum < step_interval:
		return
	_accum = 0.0
	var n := 0
	while not _queue.is_empty() and n < max_updates_per_frame:
		var pos: Vector3i = _queue.pop_front()
		_pending.erase(pos)
		_update_cell(pos)
		n += 1


# ===== 扩散核心 =====

func _update_cell(pos: Vector3i) -> void:
	if _world == null:
		return
	var id := _world.get_block(pos.x, pos.y, pos.z)
	if not GlobalConfig.is_water(id):
		return
	var level := get_level(pos)
	if level < 0:
		level = MAX_LEVEL   # 未登记水位的旧水：当作最远水位，不主动扩散

	# 1) 向下优先：下方是空气 → 直接落下（下落不衰减水位）
	var below := pos + Vector3i(0, -1, 0)
	if _world.get_block(below.x, below.y, below.z) == GlobalConfig.BLOCK_AIR:
		_place(below, level)
		return

	# 2) 下方为固体或水 → 向水平四方向扩散，水位 +1；到 7 停止
	if level >= MAX_LEVEL:
		return
	for d in SIDES:
		var np: Vector3i = pos + d
		if _world.get_block(np.x, np.y, np.z) != GlobalConfig.BLOCK_AIR:
			continue
		_place(np, level + 1)


# 写入一格水并登记水位、入队继续扩散。
# 注意：模拟器写入的【永远是流动水】，绝不自造水源 —— 否则瀑布/落水会在坑里
# 生成永久水源，"水源永久存在"的语义就被破坏了（水源只能由玩家放置）。
func _place(pos: Vector3i, level: int) -> void:
	var id := FLOWING
	_writing = true
	_world.set_block(pos.x, pos.y, pos.z, id)
	_writing = false
	if _world.get_block(pos.x, pos.y, pos.z) != id:
		return   # 越界/区块未加载 → 未真正写入，不登记
	levels[pos] = level
	enqueue(pos)
