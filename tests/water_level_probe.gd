# 职责：流动水第二阶段回归测试（水位分级渲染：顶面/侧面按水位裁剪）
# 路径：res://tests/water_level_probe.gd
# 说明：MC 风格水面高度：水位 0=水源、1~7=流动水递减；上方为水时水源满格。
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
	_test_heights()
	_test_mesh_clipping()
	_test_top_face_rule()
	print("[WaterLevelProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterLevelProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterLevelProbe] FAIL  ", label)


func _reset_empty() -> void:
	_sim.levels.clear()
	_sim._queue.clear()
	_sim._pending.clear()
	_chunk = _world.world_data[_cb]
	for i in range(_chunk.blocks.size()):
		_chunk.blocks[i] = CA
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)


# 取水网格在某 y 范围内的最高顶点（区块本地坐标）
func _water_top(ly0: float, ly1: float) -> float:
	var mi = _world.render_cache.get(_cb, {}).get("water")
	if mi == null or mi.mesh == null:
		return -1.0
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return -1.0
	var top := -100.0
	for v in (am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		if v.y >= ly0 - 0.001 and v.y <= ly1 + 0.001 and v.y > top:
			top = v.y
	return top


# T1 高度函数：露天水源 0.875；被水包围水源 1.0；水位 1/7 递减
func _test_heights() -> void:
	_reset_empty()
	var p := Vector3i(8, 5, 8)
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	_check(absf(_sim.surface_height(p) - 0.875) < 0.001,
		"T1 露天/孤立水源高度应≈0.875（实测 %.3f）" % _sim.surface_height(p))
	# 上方再放一格水 → 下层被水包围，高度应为 1.0
	_chunk.blocks[_chunk.get_index(8, 6, 8)] = CW
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	_check(absf(_sim.surface_height(p) - 1.0) < 0.001,
		"T1 被水包围的水源高度应为 1.0（实测 %.3f）" % _sim.surface_height(p))
	# 流动水：直接登记水位验证递减
	_sim.levels[p] = 1
	_check(absf(_sim.surface_height(p) - 0.768) < 0.01,
		"T1 水位 1 高度应≈0.768（实测 %.3f）" % _sim.surface_height(p))
	_sim.levels[p] = 7
	_check(absf(_sim.surface_height(p) - 0.125) < 0.001,
		"T1 水位 7 薄层高度应为 0.125（实测 %.3f）" % _sim.surface_height(p))


# T2 网格裁剪：孤立水源的顶面与侧面都裁到 0.875
func _test_mesh_clipping() -> void:
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var top := _water_top(5.0, 6.0)
	_check(absf(top - 5.875) < 0.001, "T2 孤立水源网格最高点应为 5.875（实测 %.3f）" % top)
	# 侧面：四周网格顶点都不得超过水位高度
	var mi = _world.render_cache[_cb]["water"]
	var vs: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var over := 0
	for v in vs:
		if v.y > 5.875 + 0.001:
			over += 1
	_check(over == 0, "T2 不得有顶点超过水位高度（超出 %d 个）" % over)

	# 水位 7 的流动水：极薄
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CF
	_sim.levels[Vector3i(8, 5, 8)] = 7
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var top7 := _water_top(5.0, 6.0)
	_check(absf(top7 - 5.125) < 0.001, "T2 水位 7 薄层网格最高点应为 5.125（实测 %.3f）" % top7)


# T3 顶面规则：上方为固体/水时不出顶面；上方为空气才出
func _test_top_face_rule() -> void:
	# 上方是石头 → 无水顶面（水平面 y=6 上无水面）
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.blocks[_chunk.get_index(8, 6, 8)] = CS
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var mi = _world.render_cache[_cb]["water"]
	var vs: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var horiz := 0
	var i := 0
	while i + 2 < vs.size():
		var n := (vs[i + 1] - vs[i]).cross(vs[i + 2] - vs[i])
		if n.y < -0.9 and absf(n.x) < 0.01 and absf(n.z) < 0.01:
			horiz += 1
		i += 3
	_check(horiz == 0, "T3 上方为固体时不应渲染水面顶面（实测 %d 个水平面）" % horiz)
	# 上方是空气 → 有顶面
	_reset_empty()
	_chunk.blocks[_chunk.get_index(8, 5, 8)] = CW
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var mi2 = _world.render_cache[_cb]["water"]
	var vs2: PackedVector3Array = mi2.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var horiz2 := 0
	var j := 0
	while j + 2 < vs2.size():
		var n2 := (vs2[j + 1] - vs2[j]).cross(vs2[j + 2] - vs2[j])
		if n2.y < -0.9 and absf(n2.x) < 0.01 and absf(n2.z) < 0.01:
			horiz2 += 1
		j += 3
	_check(horiz2 > 0, "T3 上方为空气时应渲染水面顶面（实测 %d 个水平面）" % horiz2)
