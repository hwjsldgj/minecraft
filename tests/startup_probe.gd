# 职责：启动时序回归测试（数据先行 → 渲染后置 → 物理最后）
# 路径：res://tests/startup_probe.gd
# 说明：实例化真实的 scenes/main.tscn，逐物理帧观察：
#       1) 启动当帧 16 区块【数据】就已齐全（get_block 全可用）；
#       2) 渲染（网格+碰撞体）就绪前玩家物理被冻结，禁止下坠；
#       3) 就绪后玩家落到地面，全程不得穿入实心方块；
#       4) 16 区块网格与碰撞体全部生成；
#       5) 运行时破坏/放置仍走局部修复（不回归优化1）。
extends Node

var _fail := 0
var _main: Node
var _world: WorldManager
var _player: CharacterBody3D
var _spawn_y := 0.0
var _frames := 0
var _froze_ok := true
var _never_in_solid := true
var _finished := false


func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	_world = _main.get_node("World")
	_player = _main.get_node("Player")
	_spawn_y = _player.global_position.y
	_check(_world.world_data.size() == 16, "T1 启动当帧应有 16 个区块数据，实测 %d" % _world.world_data.size())
	_check(_world.data_ready, "T1 data_ready 应为 true")
	var data_ok := true
	for v3 in _world.world_data.keys():
		var c: SubChunk = _world.world_data[v3]
		var solid := 0
		for i in range(c.blocks.size()):
			if c.blocks[i] != GlobalConfig.BLOCK_AIR:
				solid += 1
		if c.blocks.size() != 4096 or solid == 0:
			data_ok = false
	_check(data_ok, "T1 每个区块的 blocks 都应是完整地形（4096 且非空）")
	_check(_world.get_block(12, 5, 12) == GlobalConfig.BLOCK_GRASS, "T1 出生点下方数据应已就绪（草方块）")
	_check(not _world.render_ready, "T2 启动当帧渲染应尚未就绪")
	_check(not _player.is_physics_processing(), "T2 渲染就绪前玩家物理应被冻结")


func _physics_process(_delta: float) -> void:
	if _finished:
		return
	_frames += 1
	var y := _player.global_position.y
	if not _world.is_physics_ready():
		if absf(y - _spawn_y) > 0.001:
			_froze_ok = false
	elif _in_solid():
		_never_in_solid = false
	if _world.is_physics_ready() and _player.is_on_floor():
		_finish()
	elif _frames > 600:
		_finish()


# 玩家胶囊（脚底在原点，高 1.8）是否与实心方块重叠
func _in_solid() -> bool:
	var p := _player.global_position
	for dy in [0.2, 0.9, 1.6]:
		for dx in [-0.3, 0.3]:
			for dz in [-0.3, 0.3]:
				var id := _world.get_block(
					int(floor(p.x + dx)), int(floor(p.y + dy)), int(floor(p.z + dz)))
				if id != GlobalConfig.BLOCK_AIR and id != GlobalConfig.BLOCK_WATER and id != -1:
					return true
	return false


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[StartupProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[StartupProbe] FAIL  ", label)


func _solid_verts(cb: Vector3i) -> int:
	var mi = _world.render_cache.get(cb, {}).get("solid")
	if mi == null or mi.mesh == null:
		return -1
	var am: ArrayMesh = mi.mesh
	if am.get_surface_count() == 0:
		return 0
	return am.surface_get_array_len(0)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_check(_froze_ok, "T2 渲染就绪前玩家不得下坠（应被冻结）")
	_check(_never_in_solid, "T3 就绪后玩家不得穿入实心方块")
	var y := _player.global_position.y
	_check(absf(y - 6.0) < 0.2, "T3 玩家应站在地面上 y≈6.0，实测 %.3f" % y)

	var missing_mesh := 0
	var missing_col := 0
	for v3 in _world.world_data.keys():
		var e: Dictionary = _world.render_cache.get(v3, {})
		if e.get("solid") == null:
			missing_mesh += 1
		if e.get("collision") == null:
			missing_col += 1
	_check(missing_mesh == 0, "T4 16 个区块都应有固体网格（缺失 %d）" % missing_mesh)
	_check(missing_col == 0, "T4 16 个区块都应有碰撞体（缺失 %d）" % missing_col)

	var before := _solid_verts(Vector3i(0, 0, 0))
	_world.set_block(9, 3, 10, GlobalConfig.BLOCK_AIR)
	_check(MeshBuilder.last_patch_cells == 27,
		"T5 运行时改动仍应走局部修复(27 个方块)，实测 %d" % MeshBuilder.last_patch_cells)
	_check(_solid_verts(Vector3i(0, 0, 0)) != before, "T5 局部修复后网格应已刷新")

	print("[StartupProbe] === 完成： %d 处断言失败（物理帧 %d）===" % [_fail, _frames])
	get_tree().quit(_fail)
