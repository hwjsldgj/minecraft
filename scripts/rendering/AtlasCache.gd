# 职责：运行时图集缓存资源（TextureManager 的持久化载体）
# 路径：res://scripts/rendering/AtlasCache.gd
# 说明：仅作数据容器，逻辑全部在 TextureManager。存盘到 user://atlas_cache.res，
#       含图集贴图、UV 映射与 res://block/ 目录指纹（用于判断是否需要重建）。
extends Resource

# 拼好的运行时图集（ImageTexture）
@export var atlas: Texture2D = null
# 纹理键 -> 图集内归一化 UV 子矩形
@export var atlas_uv: Dictionary = {}
# res://block/ 目录指纹（文件数 + 最新修改时间）——变化即缓存失效
@export var dir_mtime: int = 0
