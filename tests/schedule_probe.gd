# 职责：区块分帧构建调度回归测试（优化 3）
# 路径：res://tests/schedule_probe.gd
# 说明：逐帧观察 WorldManager._process 的构建节流与优先级：
#       1) 一次入队 5 个区块，每帧最多 N 个 → 3 个构建帧内完成；
#       2) 每帧构建数不超过 max_builds_per_frame（N=2 与 N=1 各验一次）；
#       3) 队列为空时 _process 零额外开销（远小于一次区块构建）；
#       4) 玩家周围区块优先，其余按距离由近到远（用直接调用 _process 精确驱动）；
#       5) 分帧不改变视觉结果（最终网格与整块重建一致）。
# 注：SceneTree.process_frame 在 _process 之前发出，故每次 await 后读到的是
#     "本帧 _process 尚未执行"的状态——采样时多取一帧并统计"构建帧数"即可。
extends Node

var _fail := 0
var _world: WorldManager


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()   # 初始 16 区块先同步就绪
	await _test_frames_budget()
	_test_distance_priority()
	_test_empty_queue_cost()
	_test_same_visual_result()
	print("[ScheduleProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[ScheduleProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[ScheduleProbe] FAIL  ", label)


func _solid_verts(cb: Vector3i) -> int:
	var mi = _world.render_cache.get(cb, {}).get("solid")
	if mi == null or mi.mesh == null:
		return -1
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return 0
	return am.surface_get_array_len(0)


# 采样若干帧，返回每帧"渲染缓存增长量"（= 该帧构建的区块数）
func _sample_builds(frames: int) -> Array:
	var deltas: Array = []
	var prev := _world.render_cache.size()
	for i in range(frames):
		await get_tree().process_frame
		var now := _world.render_cache.size()
		deltas.append(now - prev)
		prev = now
	return deltas


# 统计采样中"真正发生构建的帧数"与是否越过 N
func _summarize(deltas: Array, n: int) -> Array:
	var build_frames := 0
	var over := false
	for d in deltas:
		if d > 0:
			build_frames += 1
		if d > n:
			over = true
	return [build_frames, over]


const FIVE := [
	Vector3i(20, 0, 20), Vector3i(21, 0, 20), Vector3i(20, 0, 21),
	Vector3i(21, 0, 21), Vector3i(22, 0, 20),
]


# T1/T2 每帧最多 N 个；5 个区块 3 个构建帧内完成
func _test_frames_budget() -> void:
	_world.limit_to_world_bounds = false
	_world.max_builds_per_frame = 2
	_world.build_queue.clear()
	# 这 5 个区块此前未加载：load_chunk = 生成数据 + 入队渲染（不立即构建）
	for v3 in FIVE:
		_world.load_chunk(v3)
	_check(_world.build_queue.size() == 5, "T1 入队后队列应有 5 个区块，实测 %d" % _world.build_queue.size())

	var deltas: Array = await _sample_builds(4)
	var s2: Array = _summarize(deltas, 2)
	var built := 0
	for v3 in FIVE:
		if _world.render_cache.has(v3):
			built += 1
	_check(_world.build_queue.is_empty(), "T1 队列应已排空（剩余 %d）" % _world.build_queue.size())
	_check(built == 5, "T1 5 个区块应全部构建完成，实测 %d" % built)
	_check(s2[0] <= 3, "T1 5 个区块应在 3 个构建帧内完成，实测 %d 帧" % s2[0])
	_check(not s2[1], "T2 每帧构建数不得超过 N=2，实测各帧 %s" % str(deltas))

	# N=1：同样 5 个区块，每帧只能 1 个
	_world.max_builds_per_frame = 1
	_world.build_queue.clear()
	for v3 in FIVE:
		_world.render_cache.erase(v3)
		_world.mesh_cache.erase(v3)
		_world.world_data[v3].dirty = true
		_world.build_queue.append(v3)
	deltas = await _sample_builds(6)
	var s1: Array = _summarize(deltas, 1)
	_check(_world.build_queue.is_empty(), "T2 N=1 时 5 个区块应已排空（剩余 %d）" % _world.build_queue.size())
	_check(s1[0] <= 5, "T2 N=1 时 5 个区块应在 5 个构建帧内完成，实测 %d 帧" % s1[0])
	_check(not s1[1], "T2 每帧构建数不得超过 N=1，实测各帧 %s" % str(deltas))


# T4 玩家周围优先，其余按距离由近到远（直接驱动 _process，避免帧时序歧义）
func _test_distance_priority() -> void:
	_world.max_builds_per_frame = 1
	_world.limit_to_world_bounds = true
	_world.load_distance = 0
	# 把"玩家所在区块"设为 (10,10)（load_distance=0 不会额外加载区块）
	_world.update_chunk_loading(Vector3(10 * 16 + 8, 8.0, 10 * 16 + 8))
	_world.build_queue.clear()
	var near := Vector3i(11, 0, 10)    # 距离 1
	var mid := Vector3i(13, 0, 10)     # 距离 3
	var far := Vector3i(16, 0, 10)     # 距离 6
	# 故意乱序入队，验证调度按距离而非入队顺序取用
	for v3 in [far, mid, near]:
		_world.load_chunk(v3)
	_check(_world.build_queue.size() == 3, "T4 入队后队列应有 3 个区块，实测 %d" % _world.build_queue.size())

	_world._process(0.016)
	_check(_world.render_cache.has(near), "T4 第 1 帧应构建最近的区块 %s" % str(near))
	_check(not _world.render_cache.has(mid) and not _world.render_cache.has(far), "T4 第 1 帧不应构建较远区块")
	_world._process(0.016)
	_check(_world.render_cache.has(mid), "T4 第 2 帧应构建次近的区块 %s" % str(mid))
	_check(not _world.render_cache.has(far), "T4 第 2 帧不应跳到最远区块")
	_world._process(0.016)
	_check(_world.render_cache.has(far), "T4 第 3 帧应构建最远区块 %s" % str(far))


# T3 队列为空时 _process 无额外开销
func _test_empty_queue_cost() -> void:
	_world.build_queue.clear()
	var before := _world.render_cache.size()
	var t0 := Time.get_ticks_usec()
	for i in range(1000):
		_world._process(0.016)
	var empty_us := Time.get_ticks_usec() - t0
	_check(_world.render_cache.size() == before, "T3 空队列时 _process 不得改变渲染缓存")
	_check(_world.build_queue.is_empty(), "T3 空队列时 _process 不得改变队列")
	# 一次区块构建约 45ms；1000 次空转应远小于它
	_check(empty_us < 45000, "T3 1000 次空队列 _process 耗时 %d us，应远小于一次区块构建" % empty_us)
	print("[ScheduleProbe] 空队列 1000 次 _process = %d us" % empty_us)


# T5 分帧不改变视觉结果
func _test_same_visual_result() -> void:
	var cb := Vector3i(11, 0, 10)
	var staged := _solid_verts(cb)
	_world.rebuild_chunk(cb)
	var direct := _solid_verts(cb)
	_check(staged > 0, "T5 分帧构建后该区块应有网格（顶点 %d）" % staged)
	_check(staged == direct, "T5 分帧结果应与整块重建一致（%d vs %d）" % [staged, direct])
