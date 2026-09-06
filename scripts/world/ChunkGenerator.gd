# 职责：为 SubChunk 填充方块数据（当前为"草顶高原 + 中央下陷坑 + 最外水沟"测试地形）
# 路径：res://scripts/world/ChunkGenerator.gd
# 说明：静态类。当前实现仅为占位测试地形，未来替换为噪声生成时，只需保持方法
#       签名不变，WorldManager 无需任何修改（高内聚低耦合）。
#       刻意加入中央下陷坑，制造高度落差，使方块侧壁/体积在 F5 可见（非网格缺陷，
#       纯为验证场景可读性）。
# 约束：本模块只负责"填什么值"，绝不针对具体方块 ID 做 if 判断分支。
#       具体方块选择由坐标区域决定后写入常量数值，ID 本身不被当条件使用。
class_name ChunkGenerator
extends RefCounted

# 中央坑的范围（世界坐标，供纯坐标区域判断）
const PIT_MIN := -6
const PIT_MAX := 6
# 坑底地表高度(不含方块自身外的更高层)；低于平原使坑壁露石头
const PIT_FLOOR := 2


# 填充一个子区块的地形。
# 布局：内部(非坑)= 0~4 石头 + 5 草（平原草顶）；
#       中央坑 |x|,|z|<=PIT_MAX = 0~2 石头（坑底），使四周露 3 格石头侧壁；
#       最外一圈(世界边界) = 0~5 水（1 宽水沟）。
static func generate(_world: WorldManager, chunk: SubChunk) -> void:
	var size := GlobalConfig.CHUNK_SIZE
	var cx := chunk.position.x
	var cz := chunk.position.z
	var blocks := chunk.blocks

	for lz in range(size):
		var gz: int = cz * size + lz
		for lx in range(size):
			var gx: int = cx * size + lx
			var is_moat: bool = (
				gx == GlobalConfig.WORLD_MIN_X or gx == GlobalConfig.WORLD_MAX_X
				or gz == GlobalConfig.WORLD_MIN_Z or gz == GlobalConfig.WORLD_MAX_Z
			)
			var in_pit: bool = (
				gx >= PIT_MIN and gx <= PIT_MAX
				and gz >= PIT_MIN and gz <= PIT_MAX
			)

			if is_moat:
				# 最外一圈 = 1 宽水沟：0~5 水，6~15 空气
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= 5:
						id = GlobalConfig.BLOCK_WATER
					blocks[chunk.get_index(lx, gy, lz)] = id
			elif in_pit:
				# 中央下陷坑：0~PIT_FLOOR 石头，其上空气（坑壁露石头）
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= PIT_FLOOR:
						id = GlobalConfig.BLOCK_STONE
					blocks[chunk.get_index(lx, gy, lz)] = id
			else:
				# 内部草顶高原：0~4 石头，5 草，6~15 空气
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= 4:
						id = GlobalConfig.BLOCK_STONE
					elif gy == 5:
						id = GlobalConfig.BLOCK_GRASS
					blocks[chunk.get_index(lx, gy, lz)] = id
