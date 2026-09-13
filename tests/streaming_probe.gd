# 职责：区块动态加载/卸载框架回归测试（优化 2）
# 路径：res://tests/streaming_probe.gd
# 说明：直接驱动 WorldManager.update_chunk_loading()，验证：
#       1) 距离参数可配置（load_distance / unload_distance）；
#       2) 玩家附近的区块被加载（数据 + 网格 + 碰撞体）；
#       3) 远离后超距区块被卸载，world_data / render_cache / mesh_cache 无残留，
#          且 MeshInstance3D / StaticBody3D / CollisionShape3D 已释放；
#       4) 空气墙（±32）内的区块受保护、永不卸载（不破坏初始 16 区块）；
#       5) 与优化1的局部修复路径不冲突。
extends Node

var _fail := 0
var _world: WorldManager

# 世界边界对应的区块范围（空气墙保护内的 16 个区块）
const BOUND_CHUNKS := [
	Vector3i(-2, 0, -2), Vector3i(-2, 0, -1), Vector3i(-2, 0, 0), Vector3i(-2, 0, 1),
	Vector3i(-1, 0, -2), Vector3i(-1, 0, -1), Vector3i(-1, 0, 0), Vector3i(-1, 0, 1),
	Vector3i(0, 0, -2), Vector3i(0, 0, -1), Vector3i(0, 0, 0), Vector3i(0, 0, 1),
	Vector3i(1, 0, -2), Vector3i(1, 0, -1), Vector3i(1, 0, 0), Vector3i(1, 0, 1),
]


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_run()
	print("[StreamingProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[StreamingProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[StreamingProbe] FAIL  ", label)


# 方块坐标 → 区块索引
func _cb(gx: int, gz: int) -> Vector3i:
	return Vector3i(int(floor(gx / 16.0)), 0, int(floor(gz / 16.0)))


# 该区块是否完整（数据 + 网格 + 碰撞体）
func _is_complete(v3: Vector3i) -> bool:
	if not _world.world_data.has(v3) or not _world.render_cache.has(v3):
		return false
	var e: Dictionary = _world.render_cache[v3]
	return e.get("solid") != null and e.get("collision") != null


func _run() -> void:
	_test_defaults_and_no_op()
	_test_load_nearby()
	_test_unload_far()
	_test_bound_protection()
	_test_patch_still_works()


# T1 默认参数 + 空气墙内调用不改变 16 区块
func _test_defaults_and_no_op() -> void:
	_check(_world.load_distance == 5, "T1 load_distance 默认应为 5，实测 %d" % _world.load_distance)
	_check(_world.unload_distance == 8, "T1 unload_distance 默认应为 8，实测 %d" % _world.unload_distance)
	_check(_world.world_data.size() == 16, "T1 初始应有 16 个区块")
	# 玩家在地图任意位置移动（空气墙内），既有 16 区块不得被卸载
	_world.update_chunk_loading(Vector3(-20.0, 8.0, 20.0))
	_world.update_chunk_loading(Vector3(28.0, 8.0, -28.0))
	var kept := 0
	for v3 in BOUND_CHUNKS:
		if _world.world_data.has(v3):
			kept += 1
	_check(kept == 16, "T1 玩家在空气墙内移动不得卸载既有区块（实测保留 %d/16）" % kept)


# T2 加载：玩家附近的区块被加载（数据 + 网格 + 碰撞体）
# 注：加载遵循"数据先行"——数据同步生成，渲染入队由 _process 分帧构建；
#     测试里用 flush_build_queue() 显式清空队列（与其它探针一致）。
func _test_load_nearby() -> void:
	_world.limit_to_world_bounds = false   # 关闭有限世界保护，验证框架本身
	_world.load_distance = 1
	_world.unload_distance = 2
	# 移动到远处区块 (10,10) 附近
	_world.update_chunk_loading(Vector3(10 * 16 + 8, 8.0, 10 * 16 + 8))
	_world.flush_build_queue()
	var expect := 0
	var complete := 0
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var v3 := Vector3i(10 + dx, 0, 10 + dz)
			expect += 1
			if _is_complete(v3):
				complete += 1
	_check(complete == expect, "T2 加载半径内 %d 个区块应全部就绪（数据+网格+碰撞），实测 %d" % [expect, complete])
	_check(_world.render_cache.size() == expect,
		"T2 卸载半径外的旧区块应被清理，render_cache 应剩 %d，实测 %d" % [expect, _world.render_cache.size()])


# T3 卸载：超距区块被卸载且无残留
func _test_unload_far() -> void:
	var far := Vector3i(0, 0, 0)
	_check(not _world.world_data.has(far), "T3 远处区块数据应已清理")
	# 记录一个当前区块的节点引用，再远离，验证节点被真正释放
	var cur := Vector3i(10, 0, 10)
	var e: Dictionary = _world.render_cache[cur]
	var mesh_node: MeshInstance3D = e["solid"]
	var body: StaticBody3D = e["collision"]
	var child: CollisionShape3D = body.get_child(0)
	_world.update_chunk_loading(Vector3(30 * 16 + 8, 8.0, 30 * 16 + 8))
	_world.flush_build_queue()
	_check(not _world.world_data.has(cur), "T3 远离后 world_data 不应有该区块")
	_check(not _world.render_cache.has(cur), "T3 远离后 render_cache 不应有该区块")
	_check(not _world.mesh_cache.has(cur), "T3 远离后 mesh_cache 不应有该区块")
	_check(not is_instance_valid(mesh_node), "T3 卸载应释放 MeshInstance3D")
	_check(not is_instance_valid(body), "T3 卸载应释放 StaticBody3D")
	_check(not is_instance_valid(child), "T3 卸载应释放 CollisionShape3D")


# T4 空气墙保护：边界内区块永不卸载
func _test_bound_protection() -> void:
	_world.limit_to_world_bounds = true
	_world.load_distance = 5
	_world.unload_distance = 1   # 故意设得极小，验证保护优先于距离
	# 先站回世界内，把 16 区块加载回来
	_world.update_chunk_loading(Vector3(8.0, 8.0, 8.0))
	_world.flush_build_queue()
	var kept := 0
	for v3 in BOUND_CHUNKS:
		if _is_complete(v3):
			kept += 1
	_check(kept == 16, "T4 世界内应重新加载 16 个区块（实测 %d）" % kept)
	# 再远离：unload_distance=1 也不会卸载空气墙内的区块
	_world.update_chunk_loading(Vector3(500.0, 8.0, 500.0))
	var kept2 := 0
	for v3 in BOUND_CHUNKS:
		if _world.world_data.has(v3) and _world.render_cache.has(v3):
			kept2 += 1
	_check(kept2 == 16, "T4 空气墙内区块受保护不得卸载（实测 %d/16）" % kept2)
	_check(not _world.world_data.has(Vector3i(31, 0, 31)), "T4 界外区块不应被加载（空气墙外不生成）")


# T5 与局部修复不冲突：加载区内的方块改动仍走 patch
func _test_patch_still_works() -> void:
	var cb := Vector3i(0, 0, 0)
	_check(_world.render_cache.has(cb), "T5 前置：区块 (0,0,0) 应已加载")
	var before := -1
	var mi = _world.render_cache[cb].get("solid")
	if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
		before = mi.mesh.surface_get_array_len(0)
	_world.set_block(9, 3, 10, GlobalConfig.BLOCK_AIR)
	_check(MeshBuilder.last_patch_cells == 27,
		"T5 动态加载后改动仍应走局部修复(27)，实测 %d" % MeshBuilder.last_patch_cells)
	var after := -1
	var mi2 = _world.render_cache[cb].get("solid")
	if mi2 != null and mi2.mesh != null and mi2.mesh.get_surface_count() > 0:
		after = mi2.mesh.surface_get_array_len(0)
	_check(before > 0 and after != before, "T5 局部修复后网格应刷新（顶点 %d → %d）" % [before, after])
