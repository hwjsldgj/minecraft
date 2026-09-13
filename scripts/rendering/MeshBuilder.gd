# ============================================================================
# 文件:    MeshBuilder.gd
# 路径:    res://scripts/rendering/MeshBuilder.gd
# 职责:    构建 / 局部修复区块的 ArrayMesh，实现邻接面剔除与顶点颜色（MC 风明暗）
# 版本:    v0.3.0
# 说明:    - 顶点使用区块本地连续坐标(方块占 [lx,lx+1]×...)，MeshInstance3D
#            position = chunk.position*16，二者叠加即世界坐标。
#          - 网格句柄归属 WorldManager.render_cache（Vector3i->{solid,water,collision}），
#            本类通过 world 增删/登记；SubChunk 不感知渲染，保持数据/渲染分离。
#          - 【顶点包缓存】每个区块在 WorldManager.mesh_cache 里按方块索引保存顶点包：
#            首次 build_chunk 全量生成一次；之后 set_block 走 patch_block，
#            只重算被改方块周围 3×3×3 的方块面，再从缓存重组顶点数组。
#            这样避免了每次改动都遍历 4096 方块 × 6 邻居查询（此前整块重建的卡顿来源）。
#          - 【面生成只有 _make_pack 一处实现】，完整构建与局部修复共用，二者结果完全一致。
#          - 面剔除: 固体面朝向 空气/未加载/水 时生成；水面只朝向 空气/未加载 生成。
#          - 每个面 6 个顶点（两三角形 0,1,2 + 0,2,3）；材质 UNSHADED，
#            明暗由顶点色 FACE_BRIGHTNESS 决定，故不使用光照法线。
#          - 碰撞体按【列(lx,lz)】缓存 BoxShape3D：局部修复时只重建受影响的那几列。
# ============================================================================
class_name MeshBuilder
extends RefCounted

# 面法线（顺序与 GlobalConfig.FACE_BOTTOM~RIGHT = 0..5 对齐）
const FACE_NORMALS := [
	Vector3(0, -1, 0),   # 0 FACE_BOTTOM 底面
	Vector3(0, 1, 0),    # 1 FACE_TOP    顶面
	Vector3(0, 0, -1),   # 2 FACE_BACK   北面(-Z)
	Vector3(0, 0, 1),    # 3 FACE_FRONT  南面(+Z)
	Vector3(-1, 0, 0),   # 4 FACE_LEFT   西面(-X)
	Vector3(1, 0, 0),    # 5 FACE_RIGHT  东面(+X)
]

# 每个面：4 个角点 [位置偏移(方块内0..1), UV(该面0..1)]。
# 环绕方向说明：Godot 默认 cull_back，其"正面"是从外侧看为【顺时针】的环绕。
# 故此处的角点顺序为【顺时针(从外侧看)】：从方块外看是正面，从方块内看是背面，
# 这样 cull_back 会显示外表面、剔除内壁。UV 随角点成对绑定；
# 侧面/顶面 uv.y=0 在方块顶边(贴图顶行=草皮条)、uv.y=1 在底边。
const FACE_QUADS := [
	# 0 BOTTOM 底面(泥土)，法线 (0,-1,0)，面朝下(从外侧=下方看为正面)
	[
		[Vector3(0, 0, 1), Vector2(0, 1)],
		[Vector3(1, 0, 1), Vector2(1, 1)],
		[Vector3(1, 0, 0), Vector2(1, 0)],
		[Vector3(0, 0, 0), Vector2(0, 0)],
	],
	# 1 TOP 顶面(草面)，法线 (0,1,0)，面朝上(从外侧=上方看为正面)
	[
		[Vector3(1, 1, 0), Vector2(0, 1)],
		[Vector3(1, 1, 1), Vector2(1, 1)],
		[Vector3(0, 1, 1), Vector2(1, 0)],
		[Vector3(0, 1, 0), Vector2(0, 0)],
	],
	# 2 BACK 北面(-Z)，草皮条朝上，法线 (0,0,-1)
	[
		[Vector3(0, 0, 0), Vector2(0, 1)],
		[Vector3(1, 0, 0), Vector2(1, 1)],
		[Vector3(1, 1, 0), Vector2(1, 0)],
		[Vector3(0, 1, 0), Vector2(0, 0)],
	],
	# 3 FRONT 南面(+Z)，草皮条朝上，法线 (0,0,1)
	[
		[Vector3(1, 0, 1), Vector2(1, 1)],
		[Vector3(0, 0, 1), Vector2(0, 1)],
		[Vector3(0, 1, 1), Vector2(0, 0)],
		[Vector3(1, 1, 1), Vector2(1, 0)],
	],
	# 4 LEFT 西面(-X)，草皮条朝上，法线 (-1,0,0)
	[
		[Vector3(0, 0, 1), Vector2(1, 1)],
		[Vector3(0, 0, 0), Vector2(0, 1)],
		[Vector3(0, 1, 0), Vector2(0, 0)],
		[Vector3(0, 1, 1), Vector2(1, 0)],
	],
	# 5 RIGHT 东面(+X)，草皮条朝上，法线 (1,0,0)
	[
		[Vector3(1, 0, 0), Vector2(0, 1)],
		[Vector3(1, 0, 1), Vector2(1, 1)],
		[Vector3(1, 1, 1), Vector2(1, 0)],
		[Vector3(1, 1, 0), Vector2(0, 0)],
	],
]

# 面亮度（顶点颜色乘数，MC 风明暗）。索引对齐 face 0..5。
const FACE_BRIGHTNESS := {
	0: Color(0.6, 0.6, 0.6),   # BOTTOM 底 最暗
	1: Color(1.0, 1.0, 1.0),   # TOP    顶 最亮
	2: Color(0.8, 0.8, 0.8),   # BACK
	3: Color(0.8, 0.8, 0.8),   # FRONT
	4: Color(0.8, 0.8, 0.8),   # LEFT
	5: Color(0.8, 0.8, 0.8),   # RIGHT
}

static var _face_checked := false

# ===== 局部修复统计（供测试断言"只重算了很小一部分"）=====
# 上一次 patch_block 重算的方块数与其中生成的顶点数
static var last_patch_cells := 0
static var last_patch_verts := 0

# ===== 完整构建 =====

# 全量构建单区块：遍历 4096 个方块生成顶点包 → 组装网格与碰撞 → 登记缓存。
# 只在区块首次加载时调用；之后的方块改动走 patch_block。
static func build_chunk(world: WorldManager, chunk: SubChunk) -> void:
	var origin_v3 := chunk.position
	# 1) 释放旧网格（render_cache 中该区块已有的 MeshInstance3D）与旧缓存
	world.clear_render(origin_v3)

	# 首次构建前自检面数据：每面叉积=外法线 且 角点在[0,1]/UV在[0,1]
	if not _face_checked:
		_face_checked = true
		_face_self_check()

	var size := GlobalConfig.CHUNK_SIZE
	var cache := new_cache()
	for ly in range(size):
		for lz in range(size):
			for lx in range(size):
				_store_pack(cache, world, chunk, lx, ly, lz)

	var entry := { "solid": null, "water": null, "collision": null }
	world.mesh_cache[origin_v3] = cache
	world.render_cache[origin_v3] = entry

	_refresh_meshes(world, origin_v3, cache, entry)
	_build_collider_all(world, chunk, cache, entry)
	chunk.dirty = false


# 新建一个区块的顶点包缓存。
static func new_cache() -> Dictionary:
	return {
		"packs": {},    # 固体：方块索引 -> 顶点包
		"wpacks": {},   # 水：方块索引 -> 顶点包
		"cols": {},     # 碰撞：列键(lx*16+lz) -> CollisionShape3D[]
	}


# ===== 局部修复 =====

# 只重建 (lx,ly,lz) 周围 3×3×3 范围内的方块面，再从缓存重组该区块的
# 网格数组与受影响列的碰撞体。区块尚未构建时返回 false（由调用方入队整块构建）。
static func patch_block(world: WorldManager, chunk: SubChunk, lx: int, ly: int, lz: int) -> bool:
	var origin_v3 := chunk.position
	if not world.mesh_cache.has(origin_v3) or not world.render_cache.has(origin_v3):
		return false

	var cache: Dictionary = world.mesh_cache[origin_v3]
	var entry: Dictionary = world.render_cache[origin_v3]
	var size := GlobalConfig.CHUNK_SIZE

	# 1) 只重算 3×3×3 邻域（裁剪到本区块范围内）的方块面
	var cells := 0
	var verts := 0
	for dy in range(-1, 2):
		var y := ly + dy
		if y < 0 or y >= size:
			continue
		for dz in range(-1, 2):
			var z := lz + dz
			if z < 0 or z >= size:
				continue
			for dx in range(-1, 2):
				var x := lx + dx
				if x < 0 or x >= size:
					continue
				_store_pack(cache, world, chunk, x, y, z)
				cells += 1
				verts += _pack_verts(cache, chunk.get_index(x, y, z))
	last_patch_cells = cells
	last_patch_verts = verts

	# 2) 碰撞体：只更新受影响的列（本列 + 四邻列）
	_refresh_columns(world, chunk, cache, entry, lx, lz)

	# 3) 从缓存重组顶点数组，就地更新已有网格实例
	_refresh_meshes(world, origin_v3, cache, entry)
	chunk.dirty = false
	return true


# ===== 面生成（完整构建与局部修复共用的唯一实现）=====

# 生成某方块的可见面顶点包；无可见面（空气或六面全被遮挡）时返回 null。
# 包 = { "pos": PackedVector3Array, "nrm": ..., "col": PackedColorArray, "uv": ... }
static func _make_pack(world: WorldManager, chunk: SubChunk, lx: int, ly: int, lz: int, id: int) -> Variant:
	if id == GlobalConfig.BLOCK_AIR:
		return null
	var size := GlobalConfig.CHUNK_SIZE
	var origin := chunk.position
	var gx := origin.x * size + lx
	var gy := origin.y * size + ly
	var gz := origin.z * size + lz
	var block_origin := Vector3(lx, ly, lz)
	var is_water_block := GlobalConfig.is_water(id)

	# 局部 Packed 数组在追加期间引用计数为 1 → 原地追加，无写时复制开销
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()

	for face in range(6):
		var n: Vector3 = FACE_NORMALS[face]
		# 邻接剔除（透明感知）：
		#   - 水：仅当邻居为【空气】时才渲染该面。
		#     水↔水 / 水↔固体 / 水↔未加载(-1) 一律不渲染 —— 否则会看到水体内部
		#     或外壳的侧面（相邻水块之间的内侧面本应被剔除）。
		#   - 固体：水【不遮挡】，凡邻居为空气/未加载/水 都生成该面。
		#     否则朝向水的固体面会被剔除 → 浸入水中会看穿固体、只见内壁。
		var nb: int = world.get_block(gx + int(n.x), gy + int(n.y), gz + int(n.z))
		if is_water_block:
			if nb != GlobalConfig.BLOCK_AIR:
				continue
		else:
			var nb_air := nb == GlobalConfig.BLOCK_AIR or nb == -1
			if not (nb_air or GlobalConfig.is_water(nb)):
				continue

		var rect := TextureManager.get_atlas_uv(id, face)
		var quads: Array = FACE_QUADS[face]
		var brightness: Color = FACE_BRIGHTNESS[face]
		var c0 := block_origin + (quads[0][0] as Vector3)
		var c1 := block_origin + (quads[1][0] as Vector3)
		var c2 := block_origin + (quads[2][0] as Vector3)
		var c3 := block_origin + (quads[3][0] as Vector3)
		var u0 := rect.position + (quads[0][1] as Vector2) * rect.size
		var u1 := rect.position + (quads[1][1] as Vector2) * rect.size
		var u2 := rect.position + (quads[2][1] as Vector2) * rect.size
		var u3 := rect.position + (quads[3][1] as Vector2) * rect.size
		# 面法线：取该面的外法线（与 FACE_NORMALS 一致，即原 SurfaceTool.generate_normals 的结果）
		var fn: Vector3 = n
		# 两三角形 0,1,2 + 0,2,3（角点顺序已保证从外侧看为顺时针）
		pos.append_array(PackedVector3Array([c0, c1, c2, c0, c2, c3]))
		nrm.append_array(PackedVector3Array([fn, fn, fn, fn, fn, fn]))
		col.append_array(PackedColorArray([brightness, brightness, brightness, brightness, brightness, brightness]))
		uv.append_array(PackedVector2Array([u0, u1, u2, u0, u2, u3]))

	if pos.is_empty():
		return null
	return { "pos": pos, "nrm": nrm, "col": col, "uv": uv }


# 重新生成单个方块的顶点包并写入缓存（无面则从缓存移除）。
static func _store_pack(cache: Dictionary, world: WorldManager, chunk: SubChunk, lx: int, ly: int, lz: int) -> void:
	var idx := chunk.get_index(lx, ly, lz)
	var id: int = chunk.blocks[idx]
	var pack: Variant = _make_pack(world, chunk, lx, ly, lz, id)
	# 必须【双向清理】：方块类型发生变化时（石→水、水→空气…），旧类型字典里的过期
	# 顶点包若不删除，会残留在网格里形成"幽灵面"——表现为相邻水块之间多出侧面。
	var solid_packs: Dictionary = cache["packs"]
	var water_packs: Dictionary = cache["wpacks"]
	if GlobalConfig.is_water(id):
		solid_packs.erase(idx)
		if pack == null:
			water_packs.erase(idx)
		else:
			water_packs[idx] = pack
	else:
		water_packs.erase(idx)
		if pack == null:
			solid_packs.erase(idx)
		else:
			solid_packs[idx] = pack


# 缓存中某方块顶点包的顶点数（无包为 0）。
static func _pack_verts(cache: Dictionary, idx: int) -> int:
	var packs: Dictionary = cache["packs"]
	if packs.has(idx):
		return (packs[idx]["pos"] as PackedVector3Array).size()
	var wpacks: Dictionary = cache["wpacks"]
	if wpacks.has(idx):
		return (wpacks[idx]["pos"] as PackedVector3Array).size()
	return 0


# ===== 顶点数组组装 =====

# 按方块索引升序把各顶点包拼成 ArrayMesh 所需的数组；无顶点时返回 []。
# 索引升序保证结果与"整块重建"逐顶点一致（可被测试直接比对）。
static func _assemble(packs: Dictionary) -> Array:
	if packs.is_empty():
		return []
	var keys: Array = packs.keys()
	keys.sort()
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	for k in keys:
		var p: Dictionary = packs[k]
		pos.append_array(p["pos"])
		nrm.append_array(p["nrm"])
		col.append_array(p["col"])
		uv.append_array(p["uv"])
	if pos.is_empty():
		return []
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_TEX_UV] = uv
	return arrays


# 用缓存重组该区块的固体/水网格；已有实例则就地更新其 ArrayMesh，避免节点反复创建。
static func _refresh_meshes(world: WorldManager, chunk_pos: Vector3i, cache: Dictionary, entry: Dictionary) -> void:
	_apply_mesh(world, chunk_pos, entry, "solid", cache["packs"], TextureManager.get_shared_material())
	_apply_mesh(world, chunk_pos, entry, "water", cache["wpacks"], TextureManager.get_water_material())


static func _apply_mesh(world: WorldManager, chunk_pos: Vector3i, entry: Dictionary, key: String, packs: Dictionary, material: Material) -> void:
	var arrays := _assemble(packs)
	var mi = entry.get(key)
	if arrays.is_empty():
		if mi is MeshInstance3D:
			mi.queue_free()
			entry[key] = null
		return
	if mi is MeshInstance3D:
		var am: ArrayMesh = mi.mesh
		am.clear_surfaces()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	else:
		var am2 := ArrayMesh.new()
		am2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi2 := _make_instance(am2, chunk_pos, material)
		world.add_child(mi2)
		entry[key] = mi2


# 创建 MeshInstance3D：position = chunk.position*16（区块本地→世界平移）。
static func _make_instance(mesh: Mesh, chunk_pos: Vector3i, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = Vector3(chunk_pos) * float(GlobalConfig.CHUNK_SIZE)
	return mi


# ===== 碰撞体 =====

# 未来更激进合并（二维/三维贪心合并）的开关：true=竖向游程合并；false=每方块一盒。
# 两种模式都保证【固体体积内处处有碰撞】，不跳过内部方块。
static var merge_vertical_runs := true


# 全量构建碰撞体：覆盖【全部】非空气/非水方块（含内部），合并到同一个 StaticBody3D。
# 逐列生成并缓存每列的 CollisionShape3D 列表，供之后局部更新。
static func _build_collider_all(world: WorldManager, chunk: SubChunk, cache: Dictionary, entry: Dictionary) -> void:
	var chunk_pos := chunk.position
	var size := GlobalConfig.CHUNK_SIZE
	var body := _new_body(chunk_pos)
	var cols: Dictionary = cache["cols"]
	for lz in range(size):
		for lx in range(size):
			var shapes := _column_shapes(body, chunk, lx, lz)
			if shapes.size() > 0:
				cols[_col_key(lx, lz)] = shapes
	if cols.is_empty():
		body.free()
		return
	world.add_child(body)
	entry["collision"] = body


# 局部更新碰撞：只重建 (lx,lz) 及其四邻列的形状（增删 BoxShape3D）。
static func _refresh_columns(world: WorldManager, chunk: SubChunk, cache: Dictionary, entry: Dictionary, lx: int, lz: int) -> void:
	var size := GlobalConfig.CHUNK_SIZE
	var cols: Dictionary = cache["cols"]
	var body = entry.get("collision")
	if body == null:
		body = _new_body(chunk.position)
		world.add_child(body)
		entry["collision"] = body
	var neigh := [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]
	for d in neigh:
		var x: int = lx + int(d[0])
		var z: int = lz + int(d[1])
		if x < 0 or x >= size or z < 0 or z >= size:
			continue
		var key := _col_key(x, z)
		# 移除该列旧形状（立即释放，保证本帧物理状态正确）
		if cols.has(key):
			for cs in cols[key]:
				if is_instance_valid(cs):
					if cs.get_parent() != null:
						cs.get_parent().remove_child(cs)
					cs.free()
			cols.erase(key)
		var shapes := _column_shapes(body, chunk, x, z)
		if shapes.size() > 0:
			cols[key] = shapes
	# 区块内已无任何碰撞盒时释放本体
	if cols.is_empty():
		if body.get_parent() != null:
			body.get_parent().remove_child(body)
		body.free()
		entry["collision"] = null


static func _new_body(chunk_pos: Vector3i) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(chunk_pos) * float(GlobalConfig.CHUNK_SIZE)
	body.collision_layer = 1
	body.collision_mask = 1
	return body


# 生成 (lx,lz) 这一列的全部碰撞盒并按竖向游程合并；返回新建的 CollisionShape3D 列表。
static func _column_shapes(body: StaticBody3D, chunk: SubChunk, lx: int, lz: int) -> Array:
	var out: Array = []
	var size := GlobalConfig.CHUNK_SIZE
	var ly := 0
	while ly < size:
		var id: int = chunk.blocks[chunk.get_index(lx, ly, lz)]
		if id == GlobalConfig.BLOCK_AIR or GlobalConfig.is_water(id):
			ly += 1
			continue
		var run := 1
		if merge_vertical_runs:
			while ly + run < size:
				var nid: int = chunk.blocks[chunk.get_index(lx, ly + run, lz)]
				if nid == GlobalConfig.BLOCK_AIR or GlobalConfig.is_water(nid):
					break
				run += 1
		out.append(_add_box(body, lx, ly, lz, run))
		ly += run
	return out


# 追加一个碰撞盒，覆盖柱段 (lx, ly..ly+run-1, lz)，返回该 CollisionShape3D。
static func _add_box(body: StaticBody3D, lx: int, ly: int, lz: int, run: int) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, float(run), 1.0)
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = Vector3(float(lx) + 0.5, float(ly) + float(run) * 0.5, float(lz) + 0.5)
	body.add_child(cs)
	return cs


# 列键：把 (lx,lz) 压成一个整数，作为碰撞列缓存的字典键。
static func _col_key(lx: int, lz: int) -> int:
	return lx * GlobalConfig.CHUNK_SIZE + lz


# ===== 自检 =====

# 自检：每个面的 (v1-v0)×(v2-v0) 应 == 该面外法线，角点在[0,1]、UV在[0,1]。
static func _face_self_check() -> void:
	for face in range(6):
		var q: Array = FACE_QUADS[face]
		var p0: Vector3 = q[0][0]
		var p1: Vector3 = q[1][0]
		var p2: Vector3 = q[2][0]
		var n: Vector3 = (p1 - p0).cross(p2 - p0).normalized()
		var want: Vector3 = FACE_NORMALS[face]
		# 环绕方向只要与法线轴对齐即可（正负代表该面对应哪一侧朝外）；
		# 依 Godot cull_back 正面约定，存的是"从外侧看为顺时针"，故右手法线指向法线反侧。
		if absf(n.dot(want)) < 0.999:
			push_warning("[MeshBuilder] FACE %d 法线错误： got %s want(axis) %s" % [face, n, want])
		for corner in q:
			var pos: Vector3 = corner[0]
			var tuv: Vector2 = corner[1]
			if pos.x < 0.0 or pos.y < 0.0 or pos.z < 0.0 or pos.x > 1.0 or pos.y > 1.0 or pos.z > 1.0:
				push_warning("[MeshBuilder] FACE %d 角点越界： %s" % [face, pos])
			if tuv.x < 0.0 or tuv.y < 0.0 or tuv.x > 1.0 or tuv.y > 1.0:
				push_warning("[MeshBuilder] FACE %d UV 越界： %s" % [face, tuv])
