# 职责：为 SubChunk 填充方块数据（当前为"草顶高原 + 最外一圈水沟"的测试地形）
# 路径：res://scripts/world/ChunkGenerator.gd
# 说明：静态类。当前实现仅为占位测试地形，未来替换为噪声生成时，只需保持方法
#       签名不变，WorldManager 无需任何修改（高内聚低耦合）。
# 约束：本模块只负责"填什么值"，绝不针对具体方块 ID 做 if 判断分支。
#       具体方块选择由坐标区域决定后写入常量数值，ID 本身不被当条件使用。
class_name ChunkGenerator
extends RefCounted


# 填充一个子区块的地形。
# 布局：内部 = 0~4 石头 + 5 草（草顶为可见地表）；
#       最外一圈（世界边界） = 0~5 水（1 宽水沟），使分层/立体可被肉眼看到。
static func generate(_world: WorldManager, chunk: SubChunk) -> void:
	var size := GlobalConfig.CHUNK_SIZE
	var cx := chunk.position.x
	var cz := chunk.position.z
	var blocks := chunk.blocks

	# 遍历本地 (lx, lz)，由区块坐标反算全局世界坐标，以判断是否在世界边界(水沟)。
	for lz in range(size):
		var gz: int = cz * size + lz
		for lx in range(size):
			var gx: int = cx * size + lx
			var is_moat: bool = (
				gx == GlobalConfig.WORLD_MIN_X or gx == GlobalConfig.WORLD_MAX_X
				or gz == GlobalConfig.WORLD_MIN_Z or gz == GlobalConfig.WORLD_MAX_Z
			)

			if is_moat:
				# 最外一圈 = 1 宽水沟：0~5 水，6~15 空气
				for gy in range(size):
					var id := GlobalConfig.BLOCK_AIR
					if gy <= 5:
						id = GlobalConfig.BLOCK_WATER
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
