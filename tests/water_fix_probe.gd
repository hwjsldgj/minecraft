# 职责：流动水 4 项缺陷回归测试
# 路径：res://tests/water_fix_probe.gd
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
	_test_break_water()
	_test_place_into_water()
	_test_level_joint()
	_test_block_above_keeps_level()
	_test_source_removed_dries()
	print("[WaterFixProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterFixProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterFixProbe] FAIL  ", label)


func _reset_empty() -> void:
	_sim.levels.clear()
	_sim._queue.clear()
	_sim._pending.clear()
	_chunk = _world.world_data[_cb]
	for i in range(_chunk.blocks.size()):
		_chunk.blocks[i] = CA
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)


func _count_water() -> int:
	var n := 0
	for i in range(_chunk.blocks.size()):
		if GlobalConfig.is_water(_chunk.blocks[i]):
			n += 1
	return n


func _prepare_flat() -> void:
	_reset_empty()
	for lz in range(16):
		for lx in range(16):
			_chunk.blocks[_chunk.get_index(lx, 5, lz)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)


# 问题2：切断水源后，水流应逐级干涸并最终全部消失
func _test_source_removed_dries() -> void:
	_prepare_flat()
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	var before := _count_water()
	_check(before > 10, "P5 前置：扩散后应有多格水（实测 %d）" % before)
	_world.set_block(8, 6, 8, CA)   # 切断水源
	_check(_sim.has_pending(), "P5 移除水源后应唤醒周围的水重新评估")
	for i in range(40):
		_sim.flush()
		if _count_water() == 0:
			break
	_check(_count_water() == 0, "P5 切断水源后水流应全部干涸（剩余 %d 格）" % _count_water())
	_check(not _sim.has_pending(), "P5 干涸完成后队列应为空（剩余 %d）" % _sim.pending_count())
	# P5b 反向：水源仍在时，已扩散的水流不得被误判为断供而自行消失
	_prepare_flat()
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	var n0 := _count_water()
	for i in range(20):
		_sim.flush()
	_check(_count_water() == n0,
		"P5b 水源仍连通时水流不应自行消失（%d → %d）" % [n0, _count_water()])


func _count_x9(vs: PackedVector3Array) -> int:
	var n := 0
	for v in vs:
		if absf(v.x - 9.0) < 0.001:
			n += 1
	return n


# 取指定方块范围内水网格的最高顶点
func _water_top_at(cx: int, ly0: float, ly1: float, cz: int) -> float:
	var mi = _world.render_cache.get(_cb, {}).get("water")
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return -100.0
	var top := -100.0
	for v in (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		if v.x >= float(cx) - 0.01 and v.x <= float(cx) + 1.01 \
			and v.z >= float(cz) - 0.01 and v.z <= float(cz) + 1.01 \
			and v.y >= ly0 - 0.01 and v.y <= ly1 + 0.01 and v.y > top:
			top = v.y
	return top


func _water_top(ly0: float, ly1: float) -> float:
	var mi = _world.render_cache.get(_cb, {}).get("water")
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return -100.0
	var top := -100.0
	for v in (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		if v.y >= ly0 - 0.001 and v.y <= ly1 + 0.001 and v.y > top:
			top = v.y
	return top


# 问题1：水不可破坏，射线应穿过水打到后面的固体
func _test_break_water() -> void:
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.blocks[_chunk.get_index(10, 5, 8)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var r := DDA.raycast(_world, Vector3(4.5, 5.5, 8.5), Vector3(1, 0, 0), 20.0)
	_check(bool(r.get("hit", false)) and r.get("block_pos") == Vector3i(10, 5, 8),
		"P1 射线应穿过水命中后方固体 (10,5,8)，实测 %s" % str(r.get("block_pos")))
	var before := _world.get_block(8, 5, 8)
	_check(GlobalConfig.is_water(before), "P1 水方块应仍在（未被射线命中/破坏）")


# 问题2：水中可放置（目标格为水时应判定为"可放置"，放置后替换水）
func _test_place_into_water() -> void:
	_reset_empty()
	var target := Vector3i(8, 5, 8)
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.blocks[_chunk.get_index(8, 4, 8)] = CS   # 辅助方块：目标格下方有实心
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var p := PlayerController.new()
	p.name = "Player"
	add_child(p)
	p.global_position = Vector3(20.0, 20.0, 20.0)   # 远离目标格，排除 AABB 重叠
	var allowed: bool = p.can_place_at(target)
	_check(allowed, "P2 目标格是水时应可放置（替换水）")
	_check(not p.can_place_at(Vector3i(8, 4, 8)), "P2 目标格是固体时仍应拒绝")
	p.free()


# 问题3：相邻不同水位之间应补上竖直连接面（无缝隙）
func _test_level_joint() -> void:
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CF
	_chunk.blocks[_chunk.get_index(9, 5, 8)] = CF
	_sim.levels[Vector3i(8, 5, 8)] = 1     # 高水位方块
	_sim.levels[Vector3i(9, 5, 8)] = 5     # 低水位方块
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var hi := _sim.surface_height(Vector3i(8, 5, 8))
	var lo := _sim.surface_height(Vector3i(9, 5, 8))
	var mi = _world.render_cache[_cb]["water"]
	var vs: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# 边界平面 x=9 上必须存在一块【竖直连接面】：法线为 ±X，且三个顶点都在 x=9、
	# y 介于 [lo, hi] 之间（只有顶面角点的那种情况会被排除）
	var joint := 0
	var i := 0
	while i + 2 < vs.size():
		var a: Vector3 = vs[i]
		var b: Vector3 = vs[i + 1]
		var c: Vector3 = vs[i + 2]
		if absf(a.x - 9.0) < 0.001 and absf(b.x - 9.0) < 0.001 and absf(c.x - 9.0) < 0.001:
			var n := (b - a).cross(c - a).normalized()
			if absf(n.y) < 0.1 and absf(n.x) > 0.9:
				var ymin: float = minf(minf(a.y, b.y), c.y)
				var ymax: float = maxf(maxf(a.y, b.y), c.y)
				if ymin >= 5.0 + lo - 0.01 and ymax <= 5.0 + hi + 0.01:
					joint += 1
		i += 3
	_check(joint > 0,
		"P3 水位 1/5 相邻处应有竖直连接面（x=9 上 y∈[%.3f,%.3f] 的三角面数=%d，水网格顶点 %d，x≈9 顶点 %d）" % [
			5.0 + lo, 5.0 + hi, joint, vs.size(), _count_x9(vs)])


# 问题4：在水位!=0 的水方块上方放方块后，仍保持原水位高度
func _test_block_above_keeps_level() -> void:
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CF
	_sim.levels[Vector3i(8, 5, 8)] = 3     # 水位 3
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var h := _sim.surface_height(Vector3i(8, 5, 8))
	_check(absf(_water_top(5.0, 6.0) - (5.0 + h)) < 0.01,
		"P4 前置：水位 3 的薄层高度应为 %.3f" % (5.0 + h))
	# 在其上方放置固体（走 set_block → patch_block 局部重建）
	_world.set_block(8, 6, 8, CS)
	_world.flush_build_queue()
	var h2 := _sim.surface_height(Vector3i(8, 5, 8))
	_check(absf(h2 - h) < 0.001, "P4 上方放方块后水位高度不应变化（%.3f → %.3f）" % [h, h2])
	var top := _water_top(5.0, 6.0)
	_check(absf(top - (5.0 + h)) < 0.01,
		"P4 上方放方块后网格高度应仍为水位高度 %.3f（实测 %.3f，满格为 6.0）" % [5.0 + h, top])

	# P4b 真实水流：放水源 → 跑完全流程 → 远处流动水必须【当场】就渲染成自己的水位高度
	# （_place 若在写方块之后才登记水位，网格会先按"水源 0.875/1.0"渲染，即"满格"假象）
	_reset_empty()
	for lz in range(16):
		for lx in range(16):
			_chunk.blocks[_chunk.get_index(lx, 5, lz)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	_world.set_block(8, 6, 8, CW)
	_sim.flush()
	var far := Vector3i(11, 6, 8)   # 距水源 3 格 → 水位 3
	_check(_sim.get_level(far) == 3, "P4b 前置：(11,6,8) 水位应为 3（实测 %d）" % _sim.get_level(far))
	var expected := 6.0 + _sim.surface_height(far)
	# 直接在该格范围内查找"等于自身水位高度"的顶点（避免被邻居连接面的顶点干扰）
	var found := false
	var mi2 = _world.render_cache[_cb]["water"]
	for v in (mi2.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		if v.x >= 10.99 and v.x <= 12.01 and v.z >= 7.99 and v.z <= 9.01 and absf(v.y - expected) < 0.02:
			found = true
	_check(found,
		"P4b 流动水应渲染为自身水位高度 %.3f（按水源渲染会是 6.875）" % expected)
