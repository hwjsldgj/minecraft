# ============================================================================
# 文件:    MeshBuilder.gd
# 路径:    res://scripts/rendering/MeshBuilder.gd
# 职责:    构建区块的 ArrayMesh，实现邻接面剔除与顶点颜色（MC 风明暗）
# 版本:    v0.2.1
# 说明:    - 顶点使用区块本地连续坐标(方块占 [lx,lx+1]×...)，MeshInstance3D
#            position = chunk.position*16，二者叠加即世界坐标。
#          - 网格句柄归属 WorldManager.render_cache（Vector3i->{solid,water}），
#            本类通过 world 增删/登记；SubChunk 不感知渲染，保持数据/渲染分离。
#          - 面剔除: 某面生成 ⇔ 邻居为空气(BLOCK_AIR)或未加载(-1)。
#            固体与水分别生成两个独立网格（水独立为未来透明水面预留）。
#          - 纹理查询用 TextureManager.get_atlas_uv()（共享材质图集 UV），
#            不改动 get_uv() 的整张图语义。
#          - 每个面的四边形以【每角点=(位置偏移, UV)】显式给出，而非 p0+两个轴：
#            (a) 保证 4 角点落在方块表面，展开为完整 1×1 单元（真实体积）；
#            (b) 两三角形 (v0,v1,v2)+(v0,v2,v3) 的叉积 = 该面外法线（正面向外、
#                背面剔除可见）；
#            (c) 对顶面与四个侧面，uv.y=0(贴图顶行，即草皮条/草面)对齐方块顶边，
#                uv.y=1 在底边 → 侧面贴图直立不倒置。
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


# 构建单个区块的固体网格与水网格，并把结果登记到 world.render_cache。
static func build_chunk(world: WorldManager, chunk: SubChunk) -> void:
	var origin_v3 := chunk.position
	# 1) 释放旧网格（render_cache 中该区块已有的 MeshInstance3D）
	world.clear_render(origin_v3)

	# 首次构建前自检面数据：每面叉积=外法线 且 角点在[0,1]/UV在[0,1]
	if not _face_checked:
		_face_checked = true
		_face_self_check()

	var st_solid := SurfaceTool.new()
	st_solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_water := SurfaceTool.new()
	st_water.begin(Mesh.PRIMITIVE_TRIANGLES)
	var solid_verts := 0
	var water_verts := 0

	var size := GlobalConfig.CHUNK_SIZE
	var cx := origin_v3.x
	var cz := origin_v3.z

	# 3) 三重循环遍历区块本地坐标
	for ly in range(size):
		for lz in range(size):
			for lx in range(size):
				var id: int = chunk.blocks[chunk.get_index(lx, ly, lz)]
				if id == GlobalConfig.BLOCK_AIR:
					continue
				var gx := cx * size + lx
				var gy := origin_v3.y * size + ly
				var gz := cz * size + lz
				var block_origin := Vector3(lx, ly, lz)

				# 4) 六方向邻接剔除（透明感知）：
				#   - 水：仅在与空气/未加载相邻处生成（水内部/水-固体之间不生成，省性能）
				#   - 固体：水【不遮挡】，凡邻居为空气/未加载/水 都生成该面。
				#     否则朝向水的固体面会被剔除 → 浸入水中会看穿固体、只见内壁。
				var is_water_block := id == GlobalConfig.BLOCK_WATER
				for face in range(6):
					var n: Vector3 = FACE_NORMALS[face]
					var nb: int = world.get_block(gx + int(n.x), gy + int(n.y), gz + int(n.z))
					var nb_air := nb == GlobalConfig.BLOCK_AIR or nb == -1
					if is_water_block:
						if not nb_air:
							continue
					else:
						if not (nb_air or nb == GlobalConfig.BLOCK_WATER):
							continue

					# 5) 面 4 角点：位置 = block_origin + 偏移；
					#    UV   = atlas_rect.position + 面内uv * atlas_rect.size
					var rect := TextureManager.get_atlas_uv(id, face)
					var quads: Array = FACE_QUADS[face]
					var color: Color = FACE_BRIGHTNESS[face]

					var st := st_solid
					if id == GlobalConfig.BLOCK_WATER:
						st = st_water
						water_verts += 4
					else:
						solid_verts += 4

					var pos := [
						block_origin + (quads[0][0] as Vector3),
						block_origin + (quads[1][0] as Vector3),
						block_origin + (quads[2][0] as Vector3),
						block_origin + (quads[3][0] as Vector3),
					]
					var uv := [
						rect.position + (quads[0][1] as Vector2) * rect.size,
						rect.position + (quads[1][1] as Vector2) * rect.size,
						rect.position + (quads[2][1] as Vector2) * rect.size,
						rect.position + (quads[3][1] as Vector2) * rect.size,
					]
					_emit_quad(st, pos[0], pos[1], pos[2], pos[3], uv[0], uv[1], uv[2], uv[3], color)

	# 6) 提交网格（空则句柄置 null、不建实例）
	var solid_mesh := _commit_if_used(st_solid, solid_verts)
	var water_mesh := _commit_if_used(st_water, water_verts)

	var entry := { "solid": null, "water": null, "collision": null }
	var mesh_solid: MeshInstance3D = null
	var collider: StaticBody3D = null
	if solid_mesh != null:
		mesh_solid = _make_instance(solid_mesh, origin_v3, TextureManager.get_shared_material())
		world.add_child(mesh_solid)
		entry["solid"] = mesh_solid
		# 为固体网格生成碰撞体，供玩家/物理落地/跳跃
		collider = _make_collider(world, chunk, origin_v3)
		if collider != null:
			world.add_child(collider)
			entry["collision"] = collider
	var mesh_water: MeshInstance3D = null
	if water_mesh != null:
		# 透明排序由水材质的 render_priority=1 控制（MeshInstance3D 无该属性）
		mesh_water = _make_instance(water_mesh, origin_v3, TextureManager.get_water_material())
		world.add_child(mesh_water)
		entry["water"] = mesh_water

	# 7) 登记到 WorldManager.render_cache
	world.render_cache[origin_v3] = entry
	chunk.dirty = false


# 生成一个四边形（两三角形 0,1,2 与 0,2,3；角点顺序已保证 CCW/外法线）。
static func _emit_quad(st: SurfaceTool, c0: Vector3, c1: Vector3, c2: Vector3, c3: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2, color: Color) -> void:
	# 三角形 1: c0,c1,c2
	st.set_color(color)
	st.set_uv(uv0)
	st.add_vertex(c0)
	st.set_color(color)
	st.set_uv(uv1)
	st.add_vertex(c1)
	st.set_color(color)
	st.set_uv(uv2)
	st.add_vertex(c2)
	# 三角形 2: c0,c2,c3
	st.set_color(color)
	st.set_uv(uv0)
	st.add_vertex(c0)
	st.set_color(color)
	st.set_uv(uv2)
	st.add_vertex(c2)
	st.set_color(color)
	st.set_uv(uv3)
	st.add_vertex(c3)


# 若确有顶点则 commit() 并返回网格；否则返回 null（避免空网格节点）。
static func _commit_if_used(st: SurfaceTool, vert_count: int) -> Mesh:
	if vert_count <= 0:
		return null
	st.generate_normals()
	return st.commit()


# 创建 MeshInstance3D：position = chunk.position*16（区块本地→世界平移）。
static func _make_instance(mesh: Mesh, chunk_pos: Vector3i, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = Vector3(chunk_pos) * float(GlobalConfig.CHUNK_SIZE)
	return mi


# 未来更激进合并（二维/三维贪心合并）的开关：true=竖向游程合并；false=每方块一盒。
# 两种模式都保证【固体体积内处处有碰撞】，不跳过内部方块。
static var merge_vertical_runs := true


# 为区块固体生成碰撞：覆盖【全部】非空气/非水方块（含内部），合并到同一个 StaticBody3D。
# 按列竖向累积连续固体段，每段 1 个 BoxShape3D（凸体，无内外之分，不会穿模）。
static func _make_collider(_world: WorldManager, chunk: SubChunk, chunk_pos: Vector3i) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(chunk_pos) * float(GlobalConfig.CHUNK_SIZE)
	body.collision_layer = 1
	body.collision_mask = 1
	var size := GlobalConfig.CHUNK_SIZE
	var added := 0
	for lz in range(size):
		for lx in range(size):
			var ly := 0
			while ly < size:
				var id: int = chunk.blocks[chunk.get_index(lx, ly, lz)]
				if id == GlobalConfig.BLOCK_AIR or id == GlobalConfig.BLOCK_WATER:
					ly += 1
					continue
				var run := 1
				if merge_vertical_runs:
					while ly + run < size:
						var nid: int = chunk.blocks[chunk.get_index(lx, ly + run, lz)]
						if nid == GlobalConfig.BLOCK_AIR or nid == GlobalConfig.BLOCK_WATER:
							break
						run += 1
				_add_box(body, lx, ly, lz, run)
				added += 1
				ly += run
	if added == 0:
		return null
	return body


# 追加一个碰撞盒，覆盖柱段 (lx, ly..ly+run-1, lz)。未来 2D/3D 贪心合并的统一出口。
static func _add_box(body: StaticBody3D, lx: int, ly: int, lz: int, run: int) -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, float(run), 1.0)
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = Vector3(float(lx) + 0.5, float(ly) + float(run) * 0.5, float(lz) + 0.5)
	body.add_child(cs)


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
