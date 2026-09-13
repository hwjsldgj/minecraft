# 职责：水面缺陷回归测试（相邻水块内侧面 / 水色发灰）
# 路径：res://tests/water_face_probe.gd
# 说明：在受控区块里手工摆放方块，逐面核对剔除结果与水色：
#       1) 两块相邻【水】：它们之间不得有内侧面（共享平面 x=9 上不得有顶点）
#       2) 两块相邻【固体】：同样只出外表面（固体行为不变）
#       3) 固体紧邻水：固体朝水的面仍应生成（否则潜水会看穿固体）——既有约定
#       4) water_still 是灰度贴图，故必须靠 albedo_color 叠加蓝色才是 MC 水色
extends Node

const CW := GlobalConfig.BLOCK_WATER
const CS := GlobalConfig.BLOCK_STONE
const CA := GlobalConfig.BLOCK_AIR

var _fail := 0
var _world: WorldManager
var _cb := Vector3i(0, 0, 0)


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_test_adjacent_water()
	_test_adjacent_solid()
	_test_solid_next_to_water()
	_test_water_color()
	_test_type_change_no_ghost()
	_test_unloaded_neighbor()
	_test_air_rule()
	print("[WaterFaceProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterFaceProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterFaceProbe] FAIL  ", label)


# 清空区块 (0,0,0) 并按坐标表摆放方块，然后重建网格
func _setup(cells: Array) -> void:
	var c: SubChunk = _world.world_data[_cb]
	for i in range(c.blocks.size()):
		c.blocks[i] = CA
	for cell in cells:
		c.blocks[c.get_index(int(cell[0]), int(cell[1]), int(cell[2]))] = int(cell[3])
	c.dirty = true
	_world.rebuild_chunk(_cb)


# 取某通道的顶点数（无网格返回 0）
func _verts(channel: String) -> int:
	var mi = _world.render_cache.get(_cb, {}).get(channel)
	if mi == null or mi.mesh == null:
		return 0
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return 0
	return (am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


# 统计"整面都落在某平面"的三角形数（真正贴在平面上的面）
# 注意：只有 4 个角点全在该平面上才算——顶面等合法面只有 2 个角点在共享平面上。
func _faces_fully_on_plane(channel: String, px: float, y0: float, y1: float, z0: float, z1: float) -> int:
	var mi = _world.render_cache.get(_cb, {}).get(channel)
	if mi == null or mi.mesh == null:
		return 0
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return 0
	var vs: PackedVector3Array = am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var count := 0
	# 每 3 个顶点一个三角形
	var i := 0
	while i + 2 < vs.size():
		var ok := true
		for k in range(3):
			var v: Vector3 = vs[i + k]
			if absf(v.x - px) > 0.001 or v.y < y0 - 0.001 or v.y > y1 + 0.001 \
				or v.z < z0 - 0.001 or v.z > z1 + 0.001:
				ok = false
		if ok:
			count += 1
		i += 3
	return count


# T1 两块相邻的水（8,5,8）与（9,5,8）：总面数应为 5+5=10（每块少一个内侧面）
func _test_adjacent_water() -> void:
	_setup([[8, 5, 8, CW], [9, 5, 8, CW]])
	var v := _verts("water")
	_check(v == 60, "T1 两块相邻水应只有 10 个面（外表面），实测 %d 个面" % (v / 6))
	_check(_faces_fully_on_plane("water", 9.0, 4.9, 6.1, 7.9, 9.1) == 0,
		"T1 两块相邻水之间不得有内侧面（共享平面 x=9 上无完整面）")
	# 三块连成一排：两端各 5 面 + 中间 4 面 = 14 面
	_setup([[8, 5, 8, CW], [9, 5, 8, CW], [10, 5, 8, CW]])
	_check(_verts("water") == 84, "T1 三块相邻水应为 14 个面，实测 %d" % (_verts("water") / 6))
	# 单块水作对照：应为 6 个面
	_setup([[8, 5, 8, CW]])
	_check(_verts("water") == 36, "T1 对照：孤立水块应为 6 个面，实测 %d" % (_verts("water") / 6))


# T2 两块相邻固体：同样只出外表面（固体行为不变）
func _test_adjacent_solid() -> void:
	_setup([[8, 5, 8, CS], [9, 5, 8, CS]])
	var v := _verts("solid")
	_check(v == 60, "T2 两块相邻固体应只有 10 个面，实测 %d 个面" % (v / 6))
	_check(_faces_fully_on_plane("solid", 9.0, 4.9, 6.1, 7.9, 9.1) == 0,
		"T2 两块相邻固体之间不得有内侧面")


# T3 固体紧邻水：固体朝水的面仍生成（潜水不穿视）；水朝固体的面被剔除
func _test_solid_next_to_water() -> void:
	_setup([[8, 5, 8, CS], [9, 5, 8, CW]])
	_check(_verts("solid") == 36, "T3 固体朝水的面应保留（固体 6 个面），实测 %d" % (_verts("solid") / 6))
	_check(_verts("water") == 30, "T3 水朝固体的面应剔除（水 5 个面），实测 %d" % (_verts("water") / 6))


# T4 水色：water_still 为灰度贴图 → 必须靠 albedo_color 叠蓝，否则显示灰色
func _test_water_color() -> void:
	var src := TextureManager.get_texture_by_key(TextureManager.water_texture_key).get_image()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var gray_px := 0
	var total := 0
	for y in range(8):
		for x in range(8):
			var p := src.get_pixel(x, y)
			total += 1
			if absf(p.r - p.g) < 0.02 and absf(p.g - p.b) < 0.02:
				gray_px += 1
	_check(gray_px == total, "T4 前置：%s 确为灰度贴图（%d/%d 像素三通道相等）" % [TextureManager.water_texture_key, gray_px, total])

	var mat: StandardMaterial3D = TextureManager.get_water_material()
	var tint := mat.albedo_color
	_check(tint.b > tint.r + 0.20, "T4 水材质 albedo_color 应为蓝色叠加（实测 %.2f,%.2f,%.2f）" % [tint.r, tint.g, tint.b])
	# 灰度贴图 × 蓝色叠加 = 呈现 MC 水色（蓝通道显著高于红）
	var sum := Vector3.ZERO
	var n := 0
	for y in range(8):
		for x in range(8):
			var p := src.get_pixel(x, y)
			sum += Vector3(p.r * tint.r, p.g * tint.g, p.b * tint.b)
			n += 1
	var mean := sum / float(n)
	_check(mean.z > mean.x + 0.15, "T4 实际呈现色应偏蓝而非灰（%.3f,%.3f,%.3f）" % [mean.x, mean.y, mean.z])
	_check(is_equal_approx(tint.a, 0.55), "T4 透明度应保持 0.55")


# T5 方块类型改变时不得残留"幽灵面"（石→水 后固体网格里不得再留有该格的面）
func _test_type_change_no_ghost() -> void:
	_setup([[8, 5, 8, CS]])
	_check(_verts("solid") == 36, "T5 前置：单块石头应为 6 个面，实测 %d" % (_verts("solid") / 6))
	# 把同一格改成水（走 set_block → patch_block 的局部重建路径）
	_world.set_block(8, 5, 8, CW)
	_world.flush_build_queue()
	_check(_verts("solid") == 0, "T5 石→水 后固体网格不得残留幽灵面，实测 %d 个面" % (_verts("solid") / 6))
	_check(_verts("water") == 36, "T5 石→水 后水网格应为 6 个面，实测 %d" % (_verts("water") / 6))
	# 再改回空气：水网格也不得残留
	_world.set_block(8, 5, 8, CA)
	_world.flush_build_queue()
	_check(_verts("water") == 0, "T5 水→空气 后水网格不得残留幽灵面，实测 %d 个面" % (_verts("water") / 6))


# T6 水↔未加载(-1)：不渲染（剔除规则表四项之一）
func _test_unloaded_neighbor() -> void:
	# 卸载 -X 邻块，使 lx=0 的水块其 -X 邻居为"未加载"
	_world.unload_chunk(Vector3i(-1, 0, 0))
	_setup([[0, 5, 8, CW]])
	_check(_verts("water") == 30,
		"T6 水↔未加载(-1) 不渲染该面（应 5 个面），实测 %d" % (_verts("water") / 6))
	_check(_faces_fully_on_plane("water", 0.0, 4.9, 6.1, 7.9, 9.1) == 0,
		"T6 x=0 平面（朝未加载块）不得有完整面")
	_world.load_chunk(Vector3i(-1, 0, 0))
	_world.flush_build_queue()


# T7 剔除规则表逐项确认：水↔空气=渲染（其余三种=不渲染，见 T1/T3/T6）
func _test_air_rule() -> void:
	_setup([[8, 5, 8, CW]])
	_check(_verts("water") == 36, "T7 水四周皆为空气时应渲染 6 个面，实测 %d" % (_verts("water") / 6))
	_setup([[8, 5, 8, CW], [8, 6, 8, CW]])
	_check(_verts("water") == 60,
		"T7 竖直相邻两块水应为 10 个面（水↔水不渲染），实测 %d" % (_verts("water") / 6))
