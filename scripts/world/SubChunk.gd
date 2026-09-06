# 职责：管理单个 16×16×16 子区块（SubChunk）的数据存储
# 路径：res://scripts/world/SubChunk.gd
# 说明：仅持有方块数据与脏标记，不感知世界/网格/纹理，保持高内聚低耦合。
#       索引布局：blocks[lx + lz*16 + ly*256]，Y 为最外层索引，
#       便于按高度层快速遍历（地形填充/光照/水面处理会受益）。
class_name SubChunk
extends RefCounted

# 一个子区块的体积 = 16^3 = 4096 个方块
const VOLUME := GlobalConfig.CHUNK_SIZE * GlobalConfig.CHUNK_SIZE * GlobalConfig.CHUNK_SIZE

# 方块数据（扁平一维数组，初始全部填充空气）
var blocks: PackedInt32Array = PackedInt32Array()
# 脏标记：该子区块是否需要重建网格（后续网格阶段使用）
var dirty: bool = true
# 区块在三维网格中的索引坐标（Vector3i，注意非世界坐标）
var position: Vector3i = Vector3i.ZERO

func _init() -> void:
	# 初始化定长数组并全部填充空气（默认空气 = 0）
	blocks.resize(VOLUME)
	blocks.fill(GlobalConfig.BLOCK_AIR)


# 将本地坐标 (0~15) 映射为扁平数组下标。
# 布局约定：index = lx + lz * 16 + ly * 256（Y 为最外层索引）。
func get_index(lx: int, ly: int, lz: int) -> int:
	return lx + lz * GlobalConfig.CHUNK_SIZE + ly * GlobalConfig.CHUNK_SIZE * GlobalConfig.CHUNK_SIZE
