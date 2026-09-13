# 职责：子任务 4.2 物品栏回归测试（数字键切换 / 空槽拒绝 / 正常放置）
# 路径：res://tests/inventory_probe.gd
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
	cs.shape = CapsuleShape3D.new()
	_player.add_child(cs)
	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_player.add_child(_cam)
	_run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[InventoryProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[InventoryProbe] FAIL  ", label)


func _aim(eye: Vector3, dir: Vector3) -> void:
	_player.global_position = eye
	_cam.global_position = eye
	_cam.look_at(eye + dir.normalized(), Vector3.UP)


func _run() -> void:
	var inv := _player.inventory
	_check(inv.get_slot(0) == GlobalConfig.BLOCK_STONE, "槽0 应为石头")
	_check(inv.get_slot(1) == GlobalConfig.BLOCK_GRASS, "槽1 应为草")
	_check(inv.get_slot(8) == -1, "槽8 应为空(-1)")

	# 数字键 1~9
	_check(_player.handle_hotbar_key(KEY_1) and _player.current_block_id == GlobalConfig.BLOCK_STONE, "按1→石头")
	_check(_player.handle_hotbar_key(KEY_2) and _player.current_block_id == GlobalConfig.BLOCK_GRASS, "按2→草")
	_check(_player.handle_hotbar_key(KEY_3) and _player.current_block_id == -1, "按3→-1")
	_check(_player.handle_hotbar_key(KEY_9) and _player.current_block_id == -1, "按9→-1")
	_check(_player.inventory.get_selected() == 8, "get_selected 应为 8")
	_check(not _player.handle_hotbar_key(KEY_0), "非 1~9 键不处理")

	# 空槽位拒绝放置（瞄准坑壁 (7,4,0)，target=(6,4,0) 合法但槽为空）
	_aim(Vector3(5.5, 4.5, 0.5), Vector3(1.0, 0.0, 0.0))
	_check(not _player.try_place(), "空槽位 try_place 应返回 false")
	_check(_world.get_block(6, 4, 0) == GlobalConfig.BLOCK_AIR, "空槽位时不应放置")

	# 选中石头后正常放置
	_player.handle_hotbar_key(KEY_1)
	_check(_player.try_place(), "选中石头后 try_place 应成功")
	_check(_world.get_block(6, 4, 0) == GlobalConfig.BLOCK_STONE, "放置处应为石头")

	# 选中草后放置到下一位（换一列，避免与玩家 AABB 重叠）
	_player.handle_hotbar_key(KEY_2)
	_aim(Vector3(5.5, 5.5, 3.5), Vector3(1.0, 0.0, 0.0))
	_check(_player.try_place(), "选中草后 try_place 应成功")
	_check(_world.get_block(6, 5, 3) == GlobalConfig.BLOCK_GRASS, "放置处应为草")

	print("[InventoryProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
