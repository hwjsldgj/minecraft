# 职责：子任务 4.1 交互回归测试（DDA 命中 / 破坏 / 放置与三条拒绝规则）
# 路径：res://tests/interaction_probe.gd
# 说明：构建真实 WorldManager + PlayerController + Camera3D，直接调用公开方法
#       （DDA 与 set_block 均为同步纯逻辑，无需物理帧）。
extends Node

var _fail := 0
var _world: WorldManager
var _player: PlayerController
var _cam: Camera3D


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()

	_player = PlayerController.new()
	_player.name = "Player"
	add_child(_player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0.0, 0.9, 0.0)
	_player.add_child(cs)

	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_player.add_child(_cam)

	_run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[InteractionProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[InteractionProbe] FAIL  ", label)


func _place(pos: Vector3) -> void:
	_player.global_position = pos


func _look(eye: Vector3, dir: Vector3) -> void:
	_cam.global_position = eye
	var dn := dir.normalized()
	var up := Vector3.UP if absf(dn.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	_cam.look_at(eye + dn, up)


func _run() -> void:
	# T1a 朝下命中：(10.5,7.5,10.5) 向下 → 命中草方块 (10,5,10)，法线 (0,1,0)
	_place(Vector3(10.0, 6.0, 10.0))
	_look(Vector3(10.5, 7.5, 10.5), Vector3(0.0, -1.0, 0.0))
	var r1: Dictionary = _player.aim()
	_check(bool(r1["hit"]) and r1["block_pos"] == Vector3i(10, 5, 10) and r1["normal"] == Vector3i(0, 1, 0),
		"T1a 向下命中 (10,5,10)/法线(0,1,0) 实测 %s/%s" % [r1["block_pos"], r1["normal"]])

	# T1b 水平命中：坑内 (4.5,4.5,0.5) 朝 +X → 距坑壁 2.5 格(射程 4 内) → 命中 (7,4,0)，法线 (-1,0,0)
	_look(Vector3(4.5, 4.5, 0.5), Vector3(1.0, 0.0, 0.0))
	var r2: Dictionary = _player.aim()
	_check(bool(r2["hit"]) and r2["block_pos"] == Vector3i(7, 4, 0) and r2["normal"] == Vector3i(-1, 0, 0),
		"T1b 水平命中 (7,4,0)/法线(-1,0,0) 实测 %s/%s" % [r2["block_pos"], r2["normal"]])

	# T2 破坏：瞄准 (8,5,10) 左键 → 变为空气
	_place(Vector3(8.0, 6.0, 10.0))
	_look(Vector3(8.5, 7.5, 10.5), Vector3(0.0, -1.0, 0.0))
	var broke: bool = _player.try_break()
	_check(broke, "T2 try_break 应返回 true")
	_check(_world.get_block(8, 5, 10) == GlobalConfig.BLOCK_AIR, "T2 破坏后 (8,5,10) 应为空气")

	# T3 放置被拒（与玩家 AABB 重叠）：站在 (10,6,10) 朝下，target=(10,6,10) 为脚下
	_place(Vector3(10.0, 6.0, 10.0))
	_look(Vector3(10.5, 7.5, 10.5), Vector3(0.0, -1.0, 0.0))
	var placed_self: bool = _player.try_place()
	_check(not placed_self, "T3 脚下放置应被拒绝(AABB 重叠)")
	_check(_world.get_block(10, 6, 10) == GlobalConfig.BLOCK_AIR, "T3 目标格仍应为空气")

	# T4 放置被拒（越界）：在边界列 (x=-32,y=6) 造一个测试方块，从界内朝 -X 命中它
	_place(Vector3(-30.0, 6.0, 5.0))
	_world.set_block(-32, 6, 5, GlobalConfig.BLOCK_STONE)
	_look(Vector3(-30.5, 6.5, 5.5), Vector3(-1.0, 0.0, 0.0))
	var r4: Dictionary = _player.aim()
	_check(bool(r4["hit"]) and r4["block_pos"] == Vector3i(-32, 6, 5), "T4 应命中边界测试方块 %s" % r4["block_pos"])
	var placed_oob: bool = _player.try_place()
	_check(not placed_oob, "T4 越界放置应被拒绝")
	_check(_world.get_block(-33, 6, 5) == -1, "T4 界外应仍为未加载(-1)")

	# T5 放置规则直接校验
	_place(Vector3(0.0, 8.0, 0.0))
	_check(not _player.can_place_at(Vector3i(10, 3, 10)), "T5a 目标已占用应拒绝")
	_check(not _player.can_place_at(Vector3i(-33, 3, 0)), "T5b X 越界应拒绝")
	_check(not _player.can_place_at(Vector3i(0, 16, 0)), "T5c Y 越界应拒绝")
	_check(_player.can_place_at(Vector3i(0, 8, 3)), "T5d 空中合法点应允许")

	# T6 合法放置：坑内朝 +X 命中 (7,4,0)，target=(6,4,0) 为空气
	_place(Vector3(5.5, 4.5, 0.5))
	_look(Vector3(5.5, 4.5, 0.5), Vector3(1.0, 0.0, 0.0))
	var placed_ok: bool = _player.try_place()
	_check(placed_ok, "T6 合法放置应成功")
	_check(_world.get_block(6, 4, 0) == _player.current_block_id, "T6 放置处应为 current_block_id(%d)" % _player.current_block_id)

	print("[InteractionProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
