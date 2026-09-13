# 职责：管理所有已加载的子区块，提供按世界坐标查询/修改方块的服务
# 路径：res://scripts/world/WorldManager.gd
# 说明：持有 world_data 字典（键 Vector3i 区块索引，值 SubChunk）。
#       本类只做"读写方块数值"的数据层工作，不对任何具体方块 ID 做判断——
#       具体方块语义、遮挡、网格重建等均属后续阶段/其它模块。
#       网格渲染句柄不入 SubChunk（保持数据/渲染分离），而归属本类 render_cache。
class_name WorldManager
extends Node3D

# 已加载子区块：键 = Vector3i（区块网格索引），值 = SubChunk
var world_data: Dictionary = {}

# 区块渲染句柄：键 = Vector3i（区块网格索引），值 = { solid: MeshInstance3D|null, water: MeshInstance3D|null, collision: StaticBody3D|null }
# 网格是 WorldManager 的子节点；此缓存用于重建前释放与遍历。SubChunk 不感知渲染。
var render_cache: Dictionary = {}

# 顶点包缓存：键 = Vector3i（区块网格索引），值 = MeshBuilder.new_cache() 结构。
# 保存每个方块分片的顶点包与每列的碰撞形状，供 set_block 走【局部面重建】。
# 完整构建（build_chunk）时全量建立，之后由 patch_block 局部刷新。
var mesh_cache: Dictionary = {}

# ===== 分帧构建调度（避免跨区块瞬间卡帧）=====
# 待构建区块队列（存区块索引 Vector3i）
var build_queue: Array = []
# 每帧最多构建的区块数
@export var max_builds_per_frame: int = 2

# ===== 启动时序：数据先行 → 渲染后置 → 物理最后 =====
# 阶段1：所有初始区块的方块数据同步生成完毕（data_ready）
# 阶段2：数据就绪后才统一对网格+碰撞体入队，由 _process 分帧构建
# 阶段3：构建队列排空（render_ready）时发出 world_ready，玩家此前禁止物理模拟
var data_ready := false
var render_ready := false
signal world_ready

# 初始加载的区块范围（x,z ∈ MIN..MAX，y = 0）
const INITIAL_CHUNK_MIN := -2
const INITIAL_CHUNK_MAX := 1

# 动态加载/卸载距离（区块数；本轮仅搭框架，暂不自动调用）
const UNLOAD_DISTANCE := 5

# 六邻接方向（用于跨区块边界重建）
const NEIGHBOR_OFFSETS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


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
	# 数据层职责：写入后立即让受影响的网格刷新。
	# 调用方只管写数据，不必自己算区块索引——曾因调用方误把"方块坐标"
	# 当作"区块索引"传入重建接口，导致数据已变而画面不变。
	# 已构建过的区块走【局部面重建】（只重算改动点周围 3×3×3）；
	# 尚未构建的区块仍入队等整块构建。
	if mesh_cache.has(chunk.position) and render_cache.has(chunk.position):
		_patch_around(gx, gy, gz)
	else:
		_enqueue_rebuild(chunk.position)


# 局部重建受改动影响的面：本区块以被改方块为中心重算，边界处再补相邻区块。
func _patch_around(gx: int, gy: int, gz: int) -> void:
	var chunk := _chunk_at(gx, gy, gz)
	if chunk == null:
		return
	MeshBuilder.patch_block(self, chunk, _local_coord(gx), _local_coord(gy), _local_coord(gz))
	for d in NEIGHBOR_OFFSETS:
		var dv: Vector3i = d
		var nx: int = gx + dv.x
		var ny: int = gy + dv.y
		var nz: int = gz + dv.z
		var nb := _chunk_at(nx, ny, nz)
		if nb != null and nb.position != chunk.position:
			MeshBuilder.patch_block(self, nb, _local_coord(nx), _local_coord(ny), _local_coord(nz))


# 将区块加入重建队列（去重；仅在区块已加载时）。
func _enqueue_rebuild(v3: Vector3i) -> void:
	if world_data.has(v3) and not build_queue.has(v3):
		build_queue.append(v3)


# 该区块是否需要构建：尚未构建过，或数据已变更（dirty）。
func _needs_build(v3: Vector3i) -> bool:
	if not render_cache.has(v3):
		return true
	return world_data[v3].dirty


# 只生成区块【数据】（blocks 数组），不触发任何渲染构建 —— "数据先行"的核心入口。
# 为将来噪声地形 / 无限世界预留：数据可在任意时刻先行生成，渲染随后按需构建。
func generate_chunk_data(v3: Vector3i) -> SubChunk:
	if world_data.has(v3):
		return world_data[v3]
	var chunk := SubChunk.new()
	chunk.position = v3
	ChunkGenerator.generate(self, chunk)
	world_data[v3] = chunk
	return chunk


# 加载区块 = 先生成数据，再入队渲染构建（对外保持"加载即会用"的语义）。
# 生成逻辑(ChunkGenerator)与网格逻辑(MeshBuilder)解耦：替换任一无需改动另一。
func load_chunk(v3: Vector3i) -> SubChunk:
	var existed := world_data.has(v3)
	var chunk := generate_chunk_data(v3)
	if not existed and not build_queue.has(v3):
		build_queue.append(v3)
	return chunk


# 重建某区块的网格：已构建则立即重建；尚未构建则入队。
func rebuild_chunk(v3: Vector3i) -> void:
	if not world_data.has(v3):
		return
	if render_cache.has(v3):
		MeshBuilder.build_chunk(self, world_data[v3])
	elif not build_queue.has(v3):
		build_queue.append(v3)


# 分帧构建：每帧最多构建 max_builds_per_frame 个待建区块。
func _process(_delta: float) -> void:
	var built := 0
	while build_queue.size() > 0 and built < max_builds_per_frame:
		var v3 = build_queue.pop_front()
		if world_data.has(v3) and _needs_build(v3):
			MeshBuilder.build_chunk(self, world_data[v3])
			built += 1
	_check_render_ready()


# 立即清空构建队列（供测试/需要同步就绪时调用）。
func flush_build_queue() -> void:
	while build_queue.size() > 0:
		var v3 = build_queue.pop_front()
		if world_data.has(v3) and _needs_build(v3):
			MeshBuilder.build_chunk(self, world_data[v3])
	_check_render_ready()


# 初始构建队列排空 → 渲染就绪。物理必须等这一刻才能开始（见 PlayerController）。
func _check_render_ready() -> void:
	if render_ready or not data_ready or not build_queue.is_empty():
		return
	render_ready = true
	world_ready.emit()


# 物理模拟是否可以开始：数据与初始渲染都已就绪。
func is_physics_ready() -> bool:
	return data_ready and render_ready


# 卸载区块：释放其渲染句柄与数据（供动态加载/卸载使用）。
func unload_chunk(v3: Vector3i) -> void:
	clear_render(v3)
	build_queue.erase(v3)
	world_data.erase(v3)


# 依据玩家位置动态加载/卸载区块（本轮仅提供接口，暂不在 _process 中自动调用，
# 以免当前 64×64 有限世界被卸载或越界生成；第 4 阶段取消空气墙后接入）。
func update_chunk_loading(player_pos: Vector3) -> void:
	var center := Vector3i(
		int(floor(player_pos.x / float(GlobalConfig.CHUNK_SIZE))),
		0,
		int(floor(player_pos.z / float(GlobalConfig.CHUNK_SIZE)))
	)
	var load_distance: int = GlobalConfig.RENDER_DISTANCE
	for dx in range(-load_distance, load_distance + 1):
		for dz in range(-load_distance, load_distance + 1):
			var v3 := Vector3i(center.x + dx, 0, center.z + dz)
			if not world_data.has(v3):
				load_chunk(v3)
	for v3 in world_data.keys():
		var dist: int = max(absi(v3.x - center.x), absi(v3.z - center.z))
		if dist > UNLOAD_DISTANCE:
			unload_chunk(v3)


# 释放某区块在 render_cache 中的旧网格实例（存在则 queue_free 并移除缓存键），
# 同时丢弃其顶点包/碰撞列缓存。
func clear_render(v3: Vector3i) -> void:
	mesh_cache.erase(v3)
	if not render_cache.has(v3):
		return
	var entry: Dictionary = render_cache[v3]
	if entry.get("solid") is MeshInstance3D:
		entry["solid"].queue_free()
	if entry.get("water") is MeshInstance3D:
		entry["water"].queue_free()
	if entry.get("collision") is StaticBody3D:
		entry["collision"].queue_free()
	render_cache.erase(v3)


# 根据世界坐标返回其所属区块；不存在时返回 null。
func _chunk_at(gx: int, gy: int, gz: int) -> SubChunk:
	var chunk_x := int(floor(gx / float(GlobalConfig.CHUNK_SIZE)))
	var chunk_y := int(floor(gy / float(GlobalConfig.CHUNK_SIZE)))
	var chunk_z := int(floor(gz / float(GlobalConfig.CHUNK_SIZE)))
	return world_data.get(Vector3i(chunk_x, chunk_y, chunk_z))


# 世界坐标 → 区块内本地坐标（0~15），使用安全取模处理负数。
func _local_coord(v: int) -> int:
	return ((v % GlobalConfig.CHUNK_SIZE) + GlobalConfig.CHUNK_SIZE) % GlobalConfig.CHUNK_SIZE


# 启动流程（数据先行 · 渲染后置 · 物理最后）：
#   阶段1  同步生成全部初始区块的【数据】（不触发任何渲染）；此时 get_block 全可用。
#   阶段2  数据全部就绪后，才把渲染构建统一入队，由 _process 分帧构建网格与碰撞体。
#   阶段3  队列排空时发出 world_ready，玩家控制器在此之前冻结物理，
#          避免出生点碰撞体尚未生成就下坠穿地（曾表现为"掉入方块内部"）。
func _ready() -> void:
	_prepare_initial_data()
	var initial := _initial_chunk_list()
	for v3 in initial:
		_enqueue_rebuild(v3)


# 阶段1：数据先行
func _prepare_initial_data() -> void:
	var count := 0
	for cx in range(INITIAL_CHUNK_MIN, INITIAL_CHUNK_MAX + 1):
		for cz in range(INITIAL_CHUNK_MIN, INITIAL_CHUNK_MAX + 1):
			generate_chunk_data(Vector3i(cx, 0, cz))
			count += 1
	data_ready = true
	print("[WorldManager] 数据生成完成：%d 个区块（渲染待入队）" % count)


# 初始区块列表（与 _prepare_initial_data 的范围一致）
func _initial_chunk_list() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for cx in range(INITIAL_CHUNK_MIN, INITIAL_CHUNK_MAX + 1):
		for cz in range(INITIAL_CHUNK_MIN, INITIAL_CHUNK_MAX + 1):
			out.append(Vector3i(cx, 0, cz))
	return out
