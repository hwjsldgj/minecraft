# ============================================================================
# 文件:    MeshBuilder.gd
# 路径:    res://scripts/rendering/MeshBuilder.gd
# 职责:    构建区块的 ArrayMesh，实现邻接面剔除与顶点颜色（MC 风明暗）
# 版本:    v0.2.0
# 说明:    - 顶点使用区块本地连续坐标(方块占 [lx,lx+1]×...)，MeshInstance3D
#            position = chunk.position*16，二者叠加即世界坐标。
#          - 网格句柄归属 WorldManager.render_cache（Vector3i->{solid,water}），
#            本类通过 world 增删/登记；SubChunk 不感知渲染，保持数据/渲染分离。
#          - 面剔除: 某面生成 ⇔ 邻居为空气(BLOCK_AIR)或未加载(-1)。
#            固体与水分别生成两个独立网格（水独立为未来透明水面预留）。
#          - 纹理查询用 TextureManager.get_atlas_uv()（共享材质图集 UV），
#            不改动 get_uv() 的整张图语义。
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

# 每个面的四边形参数：p0=角点(所在面最小角)，u/v=两块内单位方向。
# 约定 u×v == 对应外法线，保证以逆时针(正面)面向观察者（背面剔除可见），
# 且 c0..c3 = p0, p0+u, p0+u+v, p0+v 全部落在该方块的 [0,1]^3 单元内。
const FACE_GEOM := {
	# face: 0 底,1 顶,2 北(-Z),3 南(+Z),4 西(-X),5 东(+X)
	0: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],  # BOTTOM
	1: [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],  # TOP
	2: [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0)],  # BACK (-Z)
	3: [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],  # FRONT (+Z)
	4: [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],  # LEFT (-X)
	5: [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],  # RIGHT (+X)
}

# 面亮度（顶点颜色乘数，MC 风明暗）。索引对齐 face 0..5。
const FACE_BRIGHTNESS := {
	0: Color(0.6, 0.6, 0.6),   # BOTTOM 底 最暗
	1: Color(1.0, 1.0, 1.0),   # TOP    顶 最亮
	2: Color(0.8, 0.8, 0.8),   # BACK
	3: Color(0.8, 0.8, 0.8),   # FRONT
	4: Color(0.8, 0.8, 0.8),   # LEFT
	5: Color(0.8, 0.8, 0.8),   # RIGHT
}


# 构建单个区块的固体网格与水网格，并把结果登记到 world.render_cache。
static func build_chunk(world: WorldManager, chunk: SubChunk) -> void:
	var origin_v3 := chunk.position
	# 1) 释放旧网格（render_cache 中该区块已有的 MeshInstance3D）
	world.clear_render(origin_v3)

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

				# 4) 六方向邻接剔除：仅当邻居为空气/未加载才生成该面
				for face in range(6):
					var n: Vector3 = FACE_NORMALS[face]
					var nb: int = world.get_block(gx + int(n.x), gy + int(n.y), gz + int(n.z))
					if not (nb == GlobalConfig.BLOCK_AIR or nb == -1):
						continue

					# 5) 四顶点 + UV（逆时针；见类头 u×v=外法线约定）
					var rect := TextureManager.get_atlas_uv(id, face)
					var geo: Array = FACE_GEOM[face]
					var p0: Vector3 = geo[0]
					var u: Vector3 = geo[1]
					var v: Vector3 = geo[2]
					var c0: Vector3 = block_origin + p0
					var c1: Vector3 = block_origin + p0 + u
					var c2: Vector3 = block_origin + p0 + u + v
					var c3: Vector3 = block_origin + p0 + v
					var uv0 := rect.position
					var uv1 := rect.position + Vector2(rect.size.x, 0.0)
					var uv2 := rect.position + Vector2(rect.size.x, rect.size.y)
					var uv3 := rect.position + Vector2(0.0, rect.size.y)

					# 6) 顶点颜色按面亮度
					var color: Color = FACE_BRIGHTNESS[face]

					var st := st_solid
					if id == GlobalConfig.BLOCK_WATER:
						st = st_water
						water_verts += 4
					else:
						solid_verts += 4

					_emit_quad(st, c0, c1, c2, c3, uv0, uv1, uv2, uv3, color)

	# 6) 提交网格（空则句柄置 null、不建实例）
	var solid_mesh := _commit_if_used(st_solid, solid_verts)
	var water_mesh := _commit_if_used(st_water, water_verts)

	var entry := { "solid": null, "water": null }
	var mesh_solid: MeshInstance3D = null
	if solid_mesh != null:
		mesh_solid = _make_instance(solid_mesh, origin_v3, TextureManager.get_shared_material())
		world.add_child(mesh_solid)
		entry["solid"] = mesh_solid
	var mesh_water: MeshInstance3D = null
	if water_mesh != null:
		mesh_water = _make_instance(water_mesh, origin_v3, TextureManager.get_water_material())
		world.add_child(mesh_water)
		entry["water"] = mesh_water

	# 7) 登记到 WorldManager.render_cache
	world.render_cache[origin_v3] = entry
	chunk.dirty = false


# 生成一个四边形（两三角形 0,1,2 与 0,2,3，逆时针）。顶点顺序由 c0..c3 保证。
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
