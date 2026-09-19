# 职责：水在永久虚空邻接处的渲染回归测试
# 路径：res://tests/water_void_probe.gd
# 说明：世界 ±32 之外 / y<0 之下的 -1 是"永久虚空"（永远不会被流式加载），
#       水面向它们必须照常渲染；而世界范围内未加载区块的 -1 仍要剔除以省面。
extends Node

var _fail := 0
var _world: WorldManager
var _cb := Vector3i(0, 0, 0)
var _chunk: SubChunk


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_test_void_helper()
	_test_moat_outer_wall_and_floor()
	_test_streamed_unloaded_still_culled()
	print("[WaterVoidProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterVoidProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterVoidProbe] FAIL  ", label)


func _test_void_helper() -> void:
	_check(MeshBuilder._is_permanent_void(32, 3, 5), "T1 x=32 应为永久虚空")
	_check(MeshBuilder._is_permanent_void(-33, 3, 5), "T1 x=-33 应为永久虚空")
	_check(MeshBuilder._is_permanent_void(5, -1, 5), "T1 y=-1 应为永久虚空")
	_check(not MeshBuilder._is_permanent_void(5, 3, 5), "T1 世界内坐标不应是永久虚空")
	_check(not MeshBuilder._is_permanent_void(-1, 3, 5), "T1 世界范围内未加载区不应是永久虚空")


# 水沟在 x=31（水 gy 0..5）：应能看到 +X 外壁与 y=0 水底
func _test_moat_outer_wall_and_floor() -> void:
	var cb := Vector3i(1, 0, 0)   # 覆盖 x=31 的区块
	var mi = _world.render_cache.get(cb, {}).get("water")
	_check(mi != null, "T2 区块 (1,0,0) 应有水网格")
	if mi == null:
		return
	var vs: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# 顶点是【区块本地坐标】：区块 (1,0,0) 覆盖世界 x=16..31，
	# 世界 x=32（+X 方向永久虚空）对应本地 x=16；世界 y=0 对应本地 y=0。
	var wall := 0
	var floor_v := 0
	for v in vs:
		if absf(v.x - 16.0) < 0.001:
			wall += 1
		if absf(v.y - 0.0) < 0.001 and v.x >= 14.9:
			floor_v += 1
	_check(wall > 0, "T2 水沟应渲染朝永久虚空(+X)的外壁（本地 x=16 顶点 %d）" % wall)
	_check(floor_v > 0, "T2 水沟应渲染水底面（本地 y=0 顶点 %d）" % floor_v)


# 世界范围内未加载区块的 -1 仍应剔除（不影响流式省面）
func _test_streamed_unloaded_still_culled() -> void:
	_world.unload_chunk(Vector3i(-1, 0, 0))
	_chunk = _world.world_data[_cb]
	for i in range(_chunk.blocks.size()):
		_chunk.blocks[i] = GlobalConfig.BLOCK_AIR
	_chunk.blocks[_chunk.get_index(0, 5, 8)] = GlobalConfig.BLOCK_WATER
	_chunk.dirty = true
	_world.rebuild_chunk(_cb)
	var mi = _world.render_cache[_cb]["water"]
	var n := 0
	if mi != null and mi.mesh.get_surface_count() > 0:
		n = (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 6
	_check(n == 5, "T3 世界内未加载邻块(-X)仍应剔除该面（应 5 个面，实测 %d）" % n)
	_world.load_chunk(Vector3i(-1, 0, 0))
	_world.flush_build_queue()
