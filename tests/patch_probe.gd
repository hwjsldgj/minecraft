# 职责：方块修改【局部面重建】回归测试（只重算 3×3×3，不整块重建）
# 路径：res://tests/patch_probe.gd
# 说明：构建真实 WorldManager，直接调用 set_block 走局部修复路径，断言：
#       1) 内部方块：重算方块数 ≤ 27、重算顶点数 < 整块重建的 5%；
#       2) 结果与 build_chunk 整块重建【逐顶点一致】；
#       3) 区块边界：相邻区块的对应面同步更新；
#       4) 碰撞体按列增删（非整块重建）；
#       5) 未构建的区块仍走整块构建（首次加载路径不变）。
extends Node

var _fail := 0
var _world: WorldManager

const CHUNK_00 := Vector3i(0, 0, 0)
const CHUNK_NX := Vector3i(-1, 0, 0)


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_run()
	print("[PatchProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PatchProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[PatchProbe] FAIL  ", label)


# 某区块固体网格的顶点数（未构建返回 -1）
func _solid_verts(cb: Vector3i) -> int:
	var mi = _world.render_cache.get(cb, {}).get("solid")
	if mi == null or mi.mesh == null:
		return -1
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return 0
	return am.surface_get_array_len(0)


# 某区块固体网格的顶点数组（用于与整块重建结果逐顶点比对）
func _solid_arrays(cb: Vector3i) -> Array:
	var mi = _world.render_cache.get(cb, {}).get("solid")
	if mi == null:
		return []
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return []
	return am.surface_get_arrays(0)


# 该区块该列的碰撞盒数量
func _col_shapes(cb: Vector3i, lx: int, lz: int) -> int:
	var body = _world.render_cache.get(cb, {}).get("collision")
	if body == null:
		return 0
	var n := 0
	for c in body.get_children():
		if c is CollisionShape3D:
			var p: Vector3 = c.position
			if absf(p.x - (float(lx) + 0.5)) < 0.01 and absf(p.z - (float(lz) + 0.5)) < 0.01:
				n += 1
	return n


# 该列碰撞是否覆盖世界高度 y（方块 (x,y,z) 所在那一层）
func _col_covers_y(cb: Vector3i, lx: int, lz: int, y: int) -> bool:
	var body = _world.render_cache.get(cb, {}).get("collision")
	if body == null:
		return false
	for c in body.get_children():
		if c is CollisionShape3D:
			var p: Vector3 = c.position
			if absf(p.x - (float(lx) + 0.5)) > 0.01 or absf(p.z - (float(lz) + 0.5)) > 0.01:
				continue
			var half: float = (c.shape as BoxShape3D).size.y * 0.5
			if absf(p.y - (float(y) + 0.5)) < half - 0.01:
				return true
	return false


func _run() -> void:
	_test_interior_patch()
	_test_matches_full_rebuild()
	_test_boundary_neighbor()
	_test_collision_patch()
	_test_unbuilt_fallback()
	_test_patch_is_faster()


# T1 内部方块：只重算 3×3×3，重算顶点数远小于整块
func _test_interior_patch() -> void:
	_check(_world.get_block(9, 3, 10) == GlobalConfig.BLOCK_STONE, "T1 前置：(9,3,10) 应为石头(内部)")
	var full_verts := _solid_verts(CHUNK_00)
	_world.set_block(9, 3, 10, GlobalConfig.BLOCK_AIR)
	var cells: int = MeshBuilder.last_patch_cells
	var patch_verts: int = MeshBuilder.last_patch_verts
	_check(cells == 27, "T1 应只重算 3×3×3 = 27 个方块，实测 %d" % cells)
	_check(cells <= 4096 * 5 / 100, "T1 重算方块数 %d ≤ 整块的 5%%(%d)" % [cells, 4096 * 5 / 100])
	_check(patch_verts * 20 < full_verts, "T1 重算顶点 %d < 整块重建 %d 的 5%%" % [patch_verts, full_verts])
	_check(_world.get_block(9, 3, 10) == GlobalConfig.BLOCK_AIR, "T1 数据应已改为空气")
	_check(_solid_verts(CHUNK_00) != full_verts, "T1 本区块网格应已刷新")


# T2 局部修复结果 == 整块重建结果（逐顶点一致）
func _test_matches_full_rebuild() -> void:
	var patched := _solid_arrays(CHUNK_00)
	_world.rebuild_chunk(CHUNK_00)
	var full := _solid_arrays(CHUNK_00)
	_check(patched.size() > 0 and full.size() > 0, "T2 两侧数组均应非空")
	var same_verts: bool = patched[Mesh.ARRAY_VERTEX] == full[Mesh.ARRAY_VERTEX]
	var same_uv: bool = patched[Mesh.ARRAY_TEX_UV] == full[Mesh.ARRAY_TEX_UV]
	var same_col: bool = patched[Mesh.ARRAY_COLOR] == full[Mesh.ARRAY_COLOR]
	var same_nrm: bool = patched[Mesh.ARRAY_NORMAL] == full[Mesh.ARRAY_NORMAL]
	_check(same_verts, "T2 局部修复与整块重建的顶点应完全一致")
	_check(same_uv, "T2 局部修复与整块重建的 UV 应完全一致")
	_check(same_col, "T2 局部修复与整块重建的顶点色应完全一致")
	_check(same_nrm, "T2 局部修复与整块重建的法线应完全一致")


# T3 区块边界：改 lx=0 的方块，相邻区块的对应面也要更新
func _test_boundary_neighbor() -> void:
	_check(_world.get_block(0, 5, 10) == GlobalConfig.BLOCK_GRASS, "T3 前置：(0,5,10) 应为草方块")
	_check(_world.get_block(-1, 5, 10) == GlobalConfig.BLOCK_GRASS, "T3 前置：(-1,5,10) 应为草方块")
	var nb_before := _solid_verts(CHUNK_NX)
	var own_before := _solid_verts(CHUNK_00)
	_world.set_block(0, 5, 10, GlobalConfig.BLOCK_AIR)
	var nb_after := _solid_verts(CHUNK_NX)
	_check(nb_after == nb_before + 6, "T3 相邻区块应新增 1 个面(+6 顶点)：%d → %d" % [nb_before, nb_after])
	_check(_solid_verts(CHUNK_00) != own_before, "T3 本区块网格也应刷新")


# T4 碰撞体：按列增删，不整块重建
func _test_collision_patch() -> void:
	_check(_world.get_block(11, 3, 10) == GlobalConfig.BLOCK_STONE, "T4 前置：(11,3,10) 应为石头")
	_check(_col_shapes(CHUNK_00, 11, 10) == 1, "T4 破坏前该列应为 1 个合并碰撞盒")
	_check(_col_covers_y(CHUNK_00, 11, 10, 3), "T4 破坏前该列应覆盖 y=3")
	_world.set_block(11, 3, 10, GlobalConfig.BLOCK_AIR)
	_check(_col_shapes(CHUNK_00, 11, 10) == 2, "T4 破坏后该列应拆成 2 个碰撞盒(下方+上方)")
	_check(not _col_covers_y(CHUNK_00, 11, 10, 3), "T4 破坏后该列不应再覆盖 y=3")


# T5 未构建的区块：set_block 仍走整块构建（首次加载路径不变）
func _test_unbuilt_fallback() -> void:
	var nc := Vector3i(2, 0, 2)
	_world.load_chunk(nc)
	_check(not _world.render_cache.has(nc), "T5 新加载区块应尚未构建")
	_world.set_block(35, 5, 35, GlobalConfig.BLOCK_AIR)
	_check(_world.build_queue.has(nc), "T5 改动未构建区块应入队整块构建")
	_world.flush_build_queue()
	_check(_world.render_cache.has(nc) and _solid_verts(nc) > 0, "T5 整块构建后应有网格")


# T6 性能：局部修复应显著快于整块重建
func _test_patch_is_faster() -> void:
	var reps := 50
	var t0 := Time.get_ticks_usec()
	for i in range(reps):
		_world.set_block(9, 3, 10, GlobalConfig.BLOCK_AIR)
		_world.set_block(9, 3, 10, GlobalConfig.BLOCK_STONE)
	var patch_us := (Time.get_ticks_usec() - t0) / (reps * 2)
	var t1 := Time.get_ticks_usec()
	for i in range(5):
		_world.rebuild_chunk(CHUNK_00)
	var full_us := (Time.get_ticks_usec() - t1) / 5
	print("[PatchProbe] 局部修复 %d us/次，整块重建 %d us/次" % [patch_us, full_us])
	_check(patch_us < full_us, "T6 局部修复(%dus) 应快于整块重建(%dus)" % [patch_us, full_us])
