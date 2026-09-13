# 职责：水面贴图修正回归测试（不做 Shader / 不做动画）
# 路径：res://tests/water_mat_probe.gd
# 说明：验证水面材质确实是"water_still 贴图 + 半透明"，而不是纯色：
#       1) 水材质为 StandardMaterial3D（非 ShaderMaterial），albedo_texture 已绑定；
#       2) 水网格 UV 取自 get_atlas_uv(BLOCK_WATER, face)，是图集子矩形且【非整张图】；
#       3) 该 UV 子矩形在图集里的像素 == water_still.png 首帧像素（逐像素平均误差极小），
#          即"水面显示的就是 water_still 贴图"；
#       4) 该单元不是纯色（有明暗变化），证明不是被压成单色；
#       5) 透明模式仍为 TRANSPARENCY_ALPHA，alpha 仍为 0.55。
extends Node


var _fail := 0
var _world: WorldManager


func _ready() -> void:
	_test_water_material()
	_test_water_mesh_uv()
	_test_atlas_tile_matches_texture()
	print("[WaterMatProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterMatProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterMatProbe] FAIL  ", label)


func _test_water_material() -> void:
	var mat: StandardMaterial3D = TextureManager.get_water_material()
	_check(mat != null, "T1 水材质应非空")
	_check(mat is StandardMaterial3D, "T1 水材质应为 StandardMaterial3D（非 ShaderMaterial）")
	_check(mat.albedo_texture != null, "T1 水材质 albedo_texture 应已绑定（不再是纯色材质）")
	_check(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "T1 透明模式应保持 TRANSPARENCY_ALPHA")
	_check(is_equal_approx(mat.albedo_color.a, 0.55), "T1 透明度应保持 0.55（实测 %.2f）" % mat.albedo_color.a)
	_check(mat.albedo_color.b > mat.albedo_color.r + 0.20,
		"T1 albedo 应为蓝色叠加（water_still 是灰度图，颜色靠叠加色给出）")
	_check(mat.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"T1 水材质应双面渲染（CULL_DISABLED），保证从水下也能看到水面顶部")


# T2 水网格 UV：来自 get_atlas_uv(BLOCK_WATER, face)，必须是图集子矩形
func _test_water_mesh_uv() -> void:
	var uv := TextureManager.get_atlas_uv(GlobalConfig.BLOCK_WATER, GlobalConfig.FACE_TOP)
	_check(uv.size.x > 0.0 and uv.size.x < 1.0 and uv.size.y > 0.0 and uv.size.y < 1.0,
		"T2 水面 UV 应为图集子矩形（非整张图）：%s" % str(uv))
	# 构造水网格，确认其 UV 落在该子矩形内
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	var found := false
	for v3 in _world.render_cache.keys():
		var e: Dictionary = _world.render_cache[v3]
		if e.get("water") == null:
			continue
		var am: ArrayMesh = e["water"].mesh
		if am.get_surface_count() == 0:
			continue
		var uvs: PackedVector2Array = am.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		for p in uvs:
			if p.x >= uv.position.x - 0.001 and p.x <= uv.end.x + 0.001 \
				and p.y >= uv.position.y - 0.001 and p.y <= uv.end.y + 0.001:
				found = true
				break
		if found:
			break
	_check(found, "T2 水网格顶点的 UV 应落在 water 单元的子矩形内（与材质图集对齐）")


# T3/T4 图集里 water 单元 == water_still.png 首帧像素；且该单元不是纯色
func _test_atlas_tile_matches_texture() -> void:
	var atlas_tex := TextureManager.get_atlas_texture()
	_check(atlas_tex != null, "T3 图集应可用")
	var atlas := atlas_tex.get_image()
	atlas.convert(Image.FORMAT_RGBA8)

	var src_tex := TextureManager.get_texture_by_key(TextureManager.water_texture_key)
	_check(src_tex != null, "T3 应能取得 %s 贴图" % TextureManager.water_texture_key)
	var src := src_tex.get_image()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)

	var uv := TextureManager.get_atlas_uv(GlobalConfig.BLOCK_WATER, GlobalConfig.FACE_TOP)
	var tile := 16
	var x0 := int(round(uv.position.x * atlas.get_width()))
	var y0 := int(round(uv.position.y * atlas.get_height()))

	var diff := 0.0
	var min_l := 2.0
	var max_l := -1.0
	for py in range(tile):
		for px in range(tile):
			var a := atlas.get_pixel(x0 + px, y0 + py)
			var b := src.get_pixel(px, py)   # 动画条首帧（左上 16×16）
			diff += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			var l := (a.r + a.g + a.b) / 3.0
			min_l = minf(min_l, l)
			max_l = maxf(max_l, l)
	var mean := diff / float(tile * tile)
	_check(mean < 0.02, "T3 图集 water 单元应等于 water_still 首帧像素（平均误差 %.4f）" % mean)
	_check(max_l - min_l > 0.03, "T4 water 单元应非纯色（亮度范围 %.3f~%.3f）" % [min_l, max_l])
