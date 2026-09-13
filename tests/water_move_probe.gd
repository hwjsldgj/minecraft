# 职责：水中移动回归测试（MC 手感触感参数；驱动真实 PlayerController）
# 路径：res://tests/water_move_probe.gd
# 说明：在真实物理帧中模拟按键，验证 MC 参考速度：
#   完全浸没水平 2.20 / 部分浸入水平 1.97 / 下沉 1.81 / 水下上浮 0.39
#   水面出水上浮 2.00 / 无输入阻力衰减 / 无输入缓沉 0.80 / 陆地回归(5.0 + 重力)
extends Node

var _fail := 0
var _world: WorldManager
var _player: PlayerController


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

	await _run()


func _release_all() -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right", "jump", "sneak"]:
		if Input.is_action_pressed(a):
			Input.action_release(a)


func _place(p: Vector3) -> void:
	_player.velocity = Vector3.ZERO
	_player.global_position = p


func _step(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterMoveProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterMoveProbe] FAIL  ", label)


func _run() -> void:
	_release_all()

	# T1 完全浸没：水平游速 = 2.20
	_place(Vector3(-31.5, 3.0, 0.5))
	await _step(2)
	_check(_player.in_water, "T1 应判定为水中")
	Input.action_press("move_forward")
	await _step(20)
	var vh := Vector2(_player.velocity.x, _player.velocity.z).length()
	_check(absf(vh - 2.20) < 0.06, "T1 完全浸没水平游速≈2.20 (实测 %.2f)" % vh)

	# T2 无输入：水中阻力衰减
	Input.action_release("move_forward")
	var before := vh
	await _step(20)
	var after := Vector2(_player.velocity.x, _player.velocity.z).length()
	_check(after < before * 0.5, "T2 无输入水中阻力衰减 %.2f → %.2f" % [before, after])

	# T3 Shift 下沉 = 1.81
	Input.action_press("sneak")
	await _step(5)
	_check(absf(_player.velocity.y + 1.81) < 0.06, "T3 水下下沉≈1.81 (实测 %.2f)" % _player.velocity.y)
	Input.action_release("sneak")

	# T4 空格上浮（完全浸没）= 0.39
	Input.action_press("jump")
	await _step(5)
	_check(absf(_player.velocity.y - 0.39) < 0.06, "T4 水下上浮≈0.39 (实测 %.2f)" % _player.velocity.y)
	# T4b 水中不得沿用陆地跳跃初速度（land_jump 默认 6.5）
	_check(absf(_player.velocity.y - _player.land_jump) > 1.0,
		"T4b 水中应禁用陆地跳跃（vy=%.2f, land_jump=%.2f）" % [_player.velocity.y, _player.land_jump])
	Input.action_release("jump")

	# T5 无输入竖直：趋近自然缓沉 0.80
	await _step(30)
	_check(absf(_player.velocity.y + 0.80) < 0.10, "T5 无输入缓沉≈0.80 (实测 %.2f)" % _player.velocity.y)

	# T6 部分浸入（脚在水中、头在水面之上）：水平 = 1.97
	_release_all()
	_place(Vector3(-31.5, 5.5, 0.5))
	await _step(2)
	_check(_player.in_water, "T6 脚部应接触水")
	Input.action_press("move_forward")
	await _step(2)
	var vh2 := Vector2(_player.velocity.x, _player.velocity.z).length()
	_check(absf(vh2 - 1.97) < 0.06, "T6 部分浸入水平速度≈1.97 (实测 %.2f)" % vh2)
	Input.action_release("move_forward")

	# T7 部分浸入时上浮/出水 = 2.00
	Input.action_press("jump")
	await _step(3)
	_check(absf(_player.velocity.y - 2.00) < 0.06, "T7 水面出水上浮≈2.00 (实测 %.2f)" % _player.velocity.y)
	_release_all()

	# T8 陆地回归：非水中 + 水平 5.0 + 重力生效
	_place(Vector3(10.0, 9.0, 10.0))
	await _step(2)
	_check(not _player.in_water, "T8 陆地不应判定为水中")
	Input.action_press("move_forward")
	await _step(10)
	var vh3 := Vector2(_player.velocity.x, _player.velocity.z).length()
	_check(absf(vh3 - 5.0) < 0.06, "T8 陆地水平速度≈5.0 (实测 %.2f)" % vh3)
	_check(_player.velocity.y < -1.0, "T8 陆地重力生效 (vy=%.2f)" % _player.velocity.y)
	_release_all()

	print("[WaterMoveProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
