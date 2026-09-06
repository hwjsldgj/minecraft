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

# 纯色占位尺寸（与原版贴图一致）
const PLACEHOLDER_SIZE := 16

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


func _ready() -> void:
	_scan_textures()


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
