# 职责：为 SubChunk 填充方块数据（当前为超平坦测试地形）
# 路径：res://scripts/world/ChunkGenerator.gd
# 说明：静态类。当前实现仅为占位的"超平坦 + 边界石墙"逻辑，
#       未来替换为噪声生成时，只需保持方法签名不变，
#       WorldManager 无需任何修改（高内聚低耦合）。
# 约束：本模块只负责"填什么值"，绝不针对具体方块 ID 做 if 判断分支。
#       具体方块选择由坐标区域决定后写入常量数值，ID 本身不被当条件使用。
class_name ChunkGenerator
extends RefCounted


# 填充一个子区块的地形。
static func generate(world: WorldManager, chunk: SubChunk) -> void:
	var size := GlobalConfig.CHUNK_SIZE
	var cx := chunk.position.x
	var cz := chunk.position.z
	var blocks := chunk.blocks

	# 遍历本地 (lx, lz)，由区块坐标反算全局世界坐标，以判断是否在世界边界。
	for lz in range(size):
		var gz: int = cz * size + lz
		for lx in range(size):
			var gx: int = cx * size + lx
			# 判断该列是否位于世界边界（超平坦世界的石墙），
			# 这是纯坐标判断，不涉及方块 ID 分支。
			var is_wall: bool = (
				gx == GlobalConfig.WORLD_MIN_X or gx == GlobalConfig.WORLD_MAX_X
				or gz == GlobalConfig.WORLD_MIN_Z or gz == GlobalConfig.WORLD_MAX_Z
			)

			if is_wall:
				# 边界墙：0~5 石头，6~15 空气
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= 5:
						id = GlobalConfig.BLOCK_STONE
					blocks[chunk.get_index(lx, gy, lz)] = id
			else:
				# 内部区域：0~4 石头，5 草，6 水，7~15 空气
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= 4:
						id = GlobalConfig.BLOCK_STONE
					elif gy == 5:
						id = GlobalConfig.BLOCK_GRASS
					elif gy == 6:
						id = GlobalConfig.BLOCK_WATER
					blocks[chunk.get_index(lx, gy, lz)] = id
