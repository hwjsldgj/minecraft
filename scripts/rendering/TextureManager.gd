# 职责：自动扫描并缓存所有方块贴图，提供按纹理键名 / 按(方块, 面)查询的服务
# 路径：res://scripts/rendering/TextureManager.gd
# 说明：启动时扫描 res://block/ 目录，将文件名(去后缀)作为键缓存所有 16×16 PNG，
#       无需手工配置数百个文件路径，天然支持未来上千种方块。
#       block_id → 长度为 6 的键名数组，顺序严格对应面索引 [0底,1顶,2北,3南,4西,5东]。
# 建议：在 Project Settings 中将其设为自动加载单例（AutoLoad）。
# 注意：本脚本作为自动加载单例使用，因此【不声明 class_name】——
#       单例全局名 TextureManager 即为其全局访问器；若再声明同名 class_name
#       会与自动加载单例冲突（Godot 报 "hides an autoload singleton"）。
extends Node

# 贴图目录（游戏打包时随 res:// 一并导出）
const TEXTURE_DIR := "res://block/"
# 图集缓存放盘路径（user://，不入版本库）
const CACHE_PATH := "user://atlas_cache.res"
# 缓存资源脚本（用 preload 而非全局类名，避免依赖 class_name 缓存）
const AtlasCacheScript := preload("res://scripts/rendering/AtlasCache.gd")

# 纯色占位尺寸（与原版贴图一致）
const PLACEHOLDER_SIZE := 16

# 需对着色层/叠加着色的源纹理：MC 的 grass_block_top 是灰度图，绿靠草地色叠加。
# 在拼入图集前按给定颜色着色，使草顶呈现正常草绿而非灰白(观感"覆雪")。
const _SOURCE_TINT := {
	"grass_block_top": Color(0.42, 0.78, 0.35),
}

# 方块纹理配置：键 = 方块 ID，值 = 长度 6 键名数组
# 顺序： [0=底, 1=顶, 2=北, 3=南, 4=西, 5=东]
const BLOCK_TEXTURE_KEYS := {
	# 石头：六面同图
	GlobalConfig.BLOCK_STONE: ["stone", "stone", "stone", "stone", "stone", "stone"],
	# 草方块：底泥土，顶草面，四周草皮
	GlobalConfig.BLOCK_GRASS: [
		"dirt",
		"grass_block_top",
		"grass_block_side",
		"grass_block_side",
		"grass_block_side",
		"grass_block_side"
	],
	# 水：静止水面六面同图
	GlobalConfig.BLOCK_WATER: ["water_still", "water_still", "water_still", "water_still", "water_still", "water_still"],
}

# 纹理缓存：键 = 纹理键名，值 = Texture2D
var texture_cache: Dictionary = {}
# 品红占位图缓存（避免对每个缺失键都重复生成 + 重复告警）
var _placeholder: Texture2D = null

# ===== 第二阶段：运行时图集与共享材质 =====
# 说明：为使"多个方块共享一块 StandardMaterial3D 而各显其纹理"，把
#       BLOCK_TEXTURE_KEYS 中出现的去重纹理拼成一张图集。get_uv() 的
#       "整张图"语义保持不变；图集查询走独立的 get_atlas_uv()，接口隔离。
var _atlas_texture: ImageTexture = null
# 键 = 纹理键名，值 = 该键在图集中的归一化 UV 子矩形（Rect2, 0~1）
var _atlas_uv: Dictionary = {}
var _shared_material: StandardMaterial3D = null
var _water_material: StandardMaterial3D = null


func _ready() -> void:
	# 优化4：优先进程内缓存（图集 + UV + 目录指纹），命中则跳过 928 张 PNG 的扫描与拼图。
	if _load_from_cache():
		return
	_scan_textures()
	_ensure_atlas()
	_save_cache()


# ===== 图集缓存（user://atlas_cache.res）=====

# 目录指纹（廉价版）：对 928 个文件逐个 stat 需要 ~145ms，会抵消缓存收益，故改为
#   1) block/ 目录自身的修改时间 —— 替换/改名会更新；
#   2) block/ 下 .png 的【数量】—— 增删文件（目录 mtime 只有秒级精度，同秒内增删测不出）；
#   3) 图集【实际引用到的】贴图（BLOCK_TEXTURE_KEYS 去重后，通常个位数）各自的最新修改时间
#      —— 覆盖"原地改写某张贴图"的情况。未被任何方块引用的贴图不影响图集，无需纳入。
func _get_dir_mtime() -> int:
	var fp := FileAccess.get_modified_time(TEXTURE_DIR)
	fp = fp * 31 + _count_png_files()
	for k in _referenced_keys():
		fp = fp * 31 + FileAccess.get_modified_time(TEXTURE_DIR + k + ".png")
	return fp


# block/ 下 .png 数量（只做一次目录枚举，不做逐文件 stat）
func _count_png_files() -> int:
	var dir := DirAccess.open(TEXTURE_DIR)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".png"):
			count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return count


# 图集引用到的去重纹理键（排序，保证拼图布局与指纹都稳定）
func _referenced_keys() -> Array:
	var keys: Array = []
	for block_id in BLOCK_TEXTURE_KEYS:
		for k in BLOCK_TEXTURE_KEYS[block_id]:
			if not keys.has(k):
				keys.append(k)
	keys.sort()
	return keys


# 尝试从缓存加载图集。命中返回 true；无缓存 / 损坏 / 目录已变 均返回 false（走重建）。
func _load_from_cache() -> bool:
	if not ResourceLoader.exists(CACHE_PATH):
		return false
	var res: Resource = ResourceLoader.load(CACHE_PATH)
	if res == null:
		push_warning("[TextureManager] 图集缓存无法解析，已忽略并重建： %s" % CACHE_PATH)
		return false
	var atlas = res.get("atlas")
	var uv = res.get("atlas_uv")
	var mtime = res.get("dir_mtime")
	if atlas == null or not (uv is Dictionary) or (uv as Dictionary).is_empty():
		push_warning("[TextureManager] 图集缓存内容不完整，已忽略并重建： %s" % CACHE_PATH)
		return false
	if int(mtime) != _get_dir_mtime():
		print("[TextureManager] block/ 已变化，图集缓存失效，重新构建。")
		return false
	_atlas_texture = atlas
	_atlas_uv = uv
	# 命中时不再全量扫描：只按需加载 BLOCK_TEXTURE_KEYS 实际引用的少数贴图，
	# 保证 get_texture_by_key()/texture_cache 与无缓存时行为一致。
	_preload_block_textures()
	print("[TextureManager] 图集缓存命中： %s（%d 张去重纹理）" % [CACHE_PATH, _atlas_uv.size()])
	return true


# 把缓存写盘（首次构建或将重建后）。失败仅告警，不影响本次运行。
func _save_cache() -> void:
	var res: Resource = AtlasCacheScript.new()
	res.set("atlas", _atlas_texture)
	res.set("atlas_uv", _atlas_uv)
	res.set("dir_mtime", _get_dir_mtime())
	var err := ResourceSaver.save(res, CACHE_PATH)
	if err != OK:
		push_warning("[TextureManager] 图集缓存写入失败（err=%d）： %s" % [err, CACHE_PATH])
	else:
		print("[TextureManager] 图集缓存已保存： %s" % CACHE_PATH)


# 只加载 BLOCK_TEXTURE_KEYS 引用到的贴图（缓存命中时使用，通常仅个位数）
func _preload_block_textures() -> void:
	for block_id in BLOCK_TEXTURE_KEYS:
		for k in BLOCK_TEXTURE_KEYS[block_id]:
			get_texture_by_key(k)


# 扫描并缓存 TEXTURE_DIR 下所有 .png。
# 目录不存在时不崩溃，仅建立空缓存并告警。
func _scan_textures() -> void:
	var dir := DirAccess.open(TEXTURE_DIR)
	if dir == null:
		push_warning("[TextureManager] 警告： 贴图目录不存在 (%s)" % TEXTURE_DIR)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".png"):
			var key := file_name.get_basename()
			var tex := load(TEXTURE_DIR + file_name) as Texture2D
			if tex != null:
				texture_cache[key] = tex
				print("[TextureManager] 缓存纹理： %s" % key)
			else:
				push_warning("[TextureManager] 警告： 无法加载纹理 %s" % file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	print("[TextureManager] 纹理扫描完成，共缓存 %d 张贴图。" % texture_cache.size())


# 按键名查询纹理；缺失时返回(并缓存)一张品红纯色占位图。
func get_texture_by_key(key: String) -> Texture2D:
	if texture_cache.has(key):
		return texture_cache[key]
	# 延迟加载：图集缓存命中时不再全量扫描目录，按键按需从磁盘加载
	var path := TEXTURE_DIR + key + ".png"
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			texture_cache[key] = tex
			return tex
	# 生成品红占位图并缓存，避免对同一缺失键重复告警
	if _placeholder == null:
		# Godot 4：Image.new() 为空图，需用 create_empty 分配尺寸与格式
		var img := Image.create_empty(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(Color.MAGENTA)
		_placeholder = ImageTexture.create_from_image(img)
	texture_cache[key] = _placeholder
	push_warning('[TextureManager] 警告： 未找到纹理键名 "%s"' % key)
	return _placeholder


# 返回某方块某面所用的 UV 区域。face 取值 0~5（见 GlobalConfig.FACE_*）。
# 当前简化实现：所有贴图为 16×16 整张图，故直接返回整张图 UV Rect2(0,0,1,1)。
# 未来升级为 Texture2DArray / 图集后，本方法将依据键名返回对应图层/子图的 UV，
# 此接口保持不变，调用方无需改动。
func get_uv(block_id: int, face: int) -> Rect2:
	if face < 0 or face > 5:
		push_warning("[TextureManager] 非法面索引： %d（应为 0~5），回退为整张图。" % face)
		return Rect2(0, 0, 1, 1)

	if not BLOCK_TEXTURE_KEYS.has(block_id):
		push_warning("[TextureManager] 未配置方块 ID=%d 的纹理。" % block_id)
		return Rect2(0, 0, 1, 1)

	var key: String = BLOCK_TEXTURE_KEYS[block_id][face]
	get_texture_by_key(key)  # 预取缓存/占位，保证资源可用（返回值暂未使用）
	return Rect2(0, 0, 1, 1)


# ===== 图集：单张共享材质支撑多方块贴图 =====

# 懒构建运行时图集：把 BLOCK_TEXTURE_KEYS 用到的去重纹理按网格拼到一张 ImageTexture，
# 并回填 _atlas_uv（texture_key -> 归一化子矩形）。缺键纹理走品红占位，永不崩溃。
func _ensure_atlas() -> void:
	if _atlas_texture != null:
		return

	# 收集所有被引用的去重纹理键（排序保证布局稳定）
	var keys := _referenced_keys()

	var count := keys.size()
	if count == 0:
		push_warning("[TextureManager] 未配置任何方块纹理，图集为空。")
		return

	# 方块贴图通常为 16×16 正方形；MC 动画贴图（水/岩浆/火等）为垂直条
	# （宽 w × 高 n*w），此处统一取【首帧】作为该键在静态方块上的贴图，
	# 以免整条被拼入图集。若正方形用整张。帧边长即其宽度。
	var tile := 16
	var frame_rect: Dictionary = {}  # key -> 该键在图集来源中要截取的源区域
	for k in keys:
		var t := get_texture_by_key(k)
		var w := t.get_width()
		var h := t.get_height()
		var rect_src := Rect2i(0, 0, w, h)
		if h > w and h % w == 0:
			rect_src = Rect2i(0, 0, w, w)  # 动画条：仅取第一帧 w×w
		frame_rect[k] = rect_src
		tile = max(tile, w)

	# 排布成尽量接近方形的网格，再补齐到 2 的幂（兼容老 GL 对 NPOT 的顾虑）
	var cols := int(ceil(sqrt(float(count))))
	var rows := int(ceil(float(count) / float(cols)))
	var need_w := cols * tile
	var need_h := rows * tile
	var pw := 1
	while pw < need_w:
		pw *= 2
	var ph := 1
	while ph < need_h:
		ph *= 2

	var atlas_img := Image.create_empty(pw, ph, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color(0, 0, 0, 1))  # 透明黑底（未被占用区不会用于采样）

	for i in count:
		var key: String = keys[i]
		var tex := get_texture_by_key(key)
		var sub := tex.get_image()
		if sub == null:
			continue
		# 统一转 RGBA8 以便 blit_rect
		if sub.get_format() != Image.FORMAT_RGBA8:
			sub.convert(Image.FORMAT_RGBA8)
		# 需要草地绿着色的源（grass_block_top 为灰度，着色后为草绿顶）
		if _SOURCE_TINT.has(key):
			var tint: Color = _SOURCE_TINT[key]
			var sw := sub.get_width()
			var sh := sub.get_height()
			for py in range(sh):
				for px in range(sw):
					var p := sub.get_pixel(px, py)
					sub.set_pixel(px, py, Color(p.r * tint.r, p.g * tint.g, p.b * tint.b, p.a))
		var src: Rect2i = frame_rect[key]
		var col := i % cols
		var row := i / cols
		atlas_img.blit_rect(sub, src, Vector2i(col * tile, row * tile))
		var uv := Rect2(float(col * tile) / float(pw), float(row * tile) / float(ph), float(tile) / float(pw), float(tile) / float(ph))
		_atlas_uv[key] = uv

	_atlas_texture = ImageTexture.create_from_image(atlas_img)
	print("[TextureManager] 构建运行时图集： %d 张去重纹理(单元%d×%d) → %d×%d" % [count, tile, tile, pw, ph])


# 只读访问运行时图集（UI 缩略图等复用，避免重复加载纹理）
func get_atlas_texture() -> Texture2D:
	_ensure_atlas()
	return _atlas_texture


# 返回某方块某面在图集中的归一化 UV 子矩形（供共享材质网格采样）。
# 独立于 get_uv()——get_uv 保持"整张图"语义不变，本方法专供图集材质使用。
func get_atlas_uv(block_id: int, face: int) -> Rect2:
	if not BLOCK_TEXTURE_KEYS.has(block_id):
		push_warning("[TextureManager] 未配置方块 ID=%d 的纹理。" % block_id)
		return Rect2(0, 0, 1, 1)
	if face < 0 or face > 5:
		push_warning("[TextureManager] 非法面索引： %d（应为 0~5）。" % face)
		return Rect2(0, 0, 1, 1)

	_ensure_atlas()
	var key: String = BLOCK_TEXTURE_KEYS[block_id][face]
	if _atlas_uv.has(key):
		return _atlas_uv[key]
	# 图集未命中（理论上不会）回退整张图
	return Rect2(0, 0, 1, 1)


# 返回共享的固体材质：单张图集 + 顶点色作反照率 + unshaded（少 DrawCall、适配老核显）。
func get_shared_material() -> StandardMaterial3D:
	if _shared_material == null:
		_ensure_atlas()
		_shared_material = StandardMaterial3D.new()
		_shared_material.albedo_texture = _atlas_texture
		_shared_material.vertex_color_use_as_albedo = true
		_shared_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# 近邻过滤：保像素风、防图集相邻格边缘渗色
		_shared_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return _shared_material


# 液体材质参数（集中配置，便于未来扩展其它液体：岩浆/蜂蜜等）
const LIQUID_ALBEDO := Color(0.2, 0.5, 0.8, 0.55)
const LIQUID_RENDER_PRIORITY := 1


# 返回共享的水材质：半透明蓝色（可透过水体看到环境；水下另有雾效补强）。
# 双面渲染：置身影内/水中均可见水面。不使用自定义着色器，适配老核显。
func get_water_material() -> StandardMaterial3D:
	if _water_material == null:
		_water_material = StandardMaterial3D.new()
		_water_material.albedo_color = LIQUID_ALBEDO
		_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_water_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_water_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		_water_material.render_priority = LIQUID_RENDER_PRIORITY
		_water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _water_material
