# 职责：管理所有已加载的子区块，提供按世界坐标查询/修改方块的服务
# 路径：res://scripts/world/WorldManager.gd
# 说明：持有 world_data 字典（键 Vector3i 区块索引，值 SubChunk）。
#       本类只做"读写方块数值"的数据层工作，不对任何具体方块 ID 做判断——
#       具体方块语义、遮挡、网格重建等均属后续阶段/其它模块。
class_name WorldManager
extends Node3D

# 已加载子区块：键 = Vector3i（区块网格索引），值 = SubChunk
var world_data: Dictionary = {}


# 按世界坐标查询方块 ID。
# 若所在区块未加载/不存在，返回 -1（代表"未加载/未知"，供后续邻接遮挡判断）。
func get_block(gx: int, gy: int, gz: int) -> int:
	var chunk := _chunk_at(gx, gy, gz)
	if chunk == null:
		return -1
	var lx := _local_coord(gx)
	var ly := _local_coord(gy)
	var lz := _local_coord(gz)
	return chunk.blocks[chunk.get_index(lx, ly, lz)]


# 按世界坐标写入方块 ID。
# 若所在区块不存在则静默忽略（不误建区块）；写入后标记该区块脏以便重建。
func set_block(gx: int, gy: int, gz: int, id: int) -> void:
	var chunk := _chunk_at(gx, gy, gz)
	if chunk == null:
		return
	var lx := _local_coord(gx)
	var ly := _local_coord(gy)
	var lz := _local_coord(gz)
	chunk.blocks[chunk.get_index(lx, ly, lz)] = id
	chunk.dirty = true


# 加载（若缺失）并返回指定区块索引的子区块。
# 新建的区块交由 ChunkGenerator.generate() 填充地形，实现数据层与生成逻辑解耦。
func load_chunk(v3: Vector3i) -> SubChunk:
	if world_data.has(v3):
		return world_data[v3]
	var chunk := SubChunk.new()
	chunk.position = v3
	ChunkGenerator.generate(self, chunk)
	world_data[v3] = chunk
	return chunk


# 根据世界坐标返回其所属区块；不存在时返回 null。
func _chunk_at(gx: int, gy: int, gz: int) -> SubChunk:
	var chunk_x := int(floor(gx / float(GlobalConfig.CHUNK_SIZE)))
	var chunk_y := int(floor(gy / float(GlobalConfig.CHUNK_SIZE)))
	var chunk_z := int(floor(gz / float(GlobalConfig.CHUNK_SIZE)))
	return world_data.get(Vector3i(chunk_x, chunk_y, chunk_z))


# 世界坐标 → 区块内本地坐标（0~15），使用安全取模处理负数。
func _local_coord(v: int) -> int:
	return ((v % GlobalConfig.CHUNK_SIZE) + GlobalConfig.CHUNK_SIZE) % GlobalConfig.CHUNK_SIZE


# 测试初始化：加载覆盖世界边界所需范围的 16 个区块（x,z ∈ -2..1，y = 0）。
func _ready() -> void:
	for cx in range(-2, 2):
		for cz in range(-2, 2):
			load_chunk(Vector3i(cx, 0, cz))
			print("[WorldManager] 加载区块： (%d, %d, %d)" % [cx, 0, cz])
