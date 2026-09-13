# 职责：流动水第一阶段回归测试（水源扩散 / 向下优先 / 水位 7 停止 / 障碍 / 队列排空 / 每帧上限）
# 路径：res://tests/water_sim_probe.gd
extends Node

const CW := GlobalConfig.BLOCK_WATER
const CF := GlobalConfig.BLOCK_FLOWING_WATER
const CS := GlobalConfig.BLOCK_STONE
const CA := GlobalConfig.BLOCK_AIR

var _fail := 0
var _world: WorldManager
var _sim: WaterSimulator
var _cb := Vector3i(0, 0, 0)
var _chunk: SubChunk


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_sim = _world.water_sim
	_check(_sim != null, "T0 WorldManager 应创建 WaterSimulator")
	_test_horizontal_spread()
	_test_down_priority()
	_test_obstacle_stops()
	_test_queue_drains()
	_test_frame_limit()
	print("[WaterSimProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterSimProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterSimProbe] FAIL  ", label)


func _block(gx: int, gy: int, gz: int) -> int:
	return _world.get_block(gx, gy, gz)


# 清空区块 (0,0,0)，并铺一层石头地板 y=5；同时清空水模拟状态
func _reset_flat() -> void:
	_sim.levels.clear()
	_sim._queue.clear()
	_sim._pending.clear()
	_chunk = _world.world_data[_cb]
	for i in range(_chunk.blocks.size()):
		_chunk.blocks[i] = CA
	for lz in range(16):
		for lx in range(16):
			_chunk.blocks[_chunk.get_index(lx, 5, lz)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)


# T1 水平扩散：地板 y=5 上放水源，四个方向最远 7 格
func _test_horizontal_spread() -> void:
	_reset_flat()
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	_check(_block(8, 6, 8) == CW, "T1 水源应保持 BLOCK_WATER（不消失）")
	_check(_sim.get_level(Vector3i(8, 6, 8)) == 0, "T1 水源水位应为 0")
	_check(_block(9, 6, 8) == CF and _sim.get_level(Vector3i(9, 6, 8)) == 1,
		"T1 相邻格应为流动水且水位 1（实测 %d / %d）" % [_block(9, 6, 8), _sim.get_level(Vector3i(9, 6, 8))])
	var reached := 0
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var far: Vector3i = Vector3i(8, 6, 8) + d * 7
		if _block(far.x, far.y, far.z) == CF and _sim.get_level(far) == 7:
			reached += 1
	_check(reached == 4, "T1 四个方向都应扩散到第 7 格且水位 7，实测 %d/4" % reached)
	_check(_block(16, 6, 8) == CA, "T1 第 8 格不应有水（最远 7 格）")


# T2 向下优先：地板开洞 → 先竖直下落，落到底部后再水平铺开
func _test_down_priority() -> void:
	_reset_flat()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CA   # 地板挖洞
	_chunk.blocks[_chunk.get_index(8, 0, 8)] = CS   # 洞底地板
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	_world.set_block(8, 6, 8, CW)
	# 只看"第一步"：每帧上限设 1，只处理水源这一格 → 必须向下，不得横向铺开
	_sim.max_updates_per_frame = 1
	_sim._process(1.0)
	_check(GlobalConfig.is_water(_block(8, 5, 8)), "T2 第一步应优先向下（(8,5,8) 已充水）")
	_check(_block(8, 6, 9) == CA and _block(9, 6, 8) == CA, "T2 第一步不得水平扩散")
	# 跑到收敛：应一路下落到洞底，并在底部铺开
	_sim.max_updates_per_frame = 64
	_sim.flush()
	_check(GlobalConfig.is_water(_block(8, 1, 8)), "T2 水应一路竖直下落到洞底 (8,1,8)")
	_check(GlobalConfig.is_water(_block(8, 3, 8)), "T2 下落路径 (8,3,8) 应为水")
	var spread := GlobalConfig.is_water(_block(9, 1, 8)) or GlobalConfig.is_water(_block(9, 0, 8))
	_check(spread, "T2 落到底部后应水平铺开")
	_check(_block(8, 1, 8) == CF, "T2 下落的水必须是流动水（不得自造永久水源）")


# T3 障碍停止：把 y=6 层除十字通道外全填石头，水只能停在通道内
func _test_obstacle_stops() -> void:
	_reset_flat()
	var cross := [Vector3i(8, 6, 8), Vector3i(9, 6, 8), Vector3i(7, 6, 8), Vector3i(8, 6, 9), Vector3i(8, 6, 7)]
	for lz in range(16):
		for lx in range(16):
			if not cross.has(Vector3i(lx, 6, lz)):
				_chunk.blocks[_chunk.get_index(lx, 6, lz)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	var wet := 0
	for v in cross:
		if GlobalConfig.is_water(_block(v.x, v.y, v.z)):
			wet += 1
	_check(wet == 5, "T3 十字通道 5 格应全部被水填充，实测 %d" % wet)
	_check(_block(10, 6, 8) == CS and _block(8, 6, 10) == CS, "T3 障碍方块不得被水替换")
	_check(_sim.get_level(Vector3i(9, 6, 8)) == 1 and _sim.get_level(Vector3i(7, 6, 8)) == 1,
		"T3 被围住时水位只到 1（水遇障碍停止）")
	_check(not _sim.has_pending(), "T3 被围住后队列应立即排空")


# T4 队列排空：流完后无待处理项；空队列时 _process 无副作用
func _test_queue_drains() -> void:
	_reset_flat()
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	_check(not _sim.has_pending(), "T4 水流完后队列应为空（剩余 %d）" % _sim.pending_count())
	var n0 := _sim.levels.size()
	var q0 := _sim.pending_count()
	_sim._process(1.0)
	_check(not _sim.has_pending() and _sim.pending_count() == q0 and _sim.levels.size() == n0,
		"T4 队列为空时 _process 不产生任何变化")


# T5 每帧上限：max_updates_per_frame=1 时，一次推进只处理 1 格（只放下源 + 4 个邻居）
func _test_frame_limit() -> void:
	_reset_flat()
	_world.set_block(8, 6, 8, CW)
	_check(_sim.pending_count() == 1, "T5 前置：仅水源在队列中（实测 %d）" % _sim.pending_count())
	_sim.max_updates_per_frame = 1
	_sim._process(1.0)
	_check(_sim.levels.size() == 5,
		"T5 每帧上限 N=1 时应只处理水源一格（水位表 5 项），实测 %d" % _sim.levels.size())
	_check(_sim.has_pending(), "T5 还有待处理项（水未一次流完）")
	_sim.max_updates_per_frame = 2
	_sim.flush()
	_check(not _sim.has_pending(), "T5 清空队列后应无残留")
