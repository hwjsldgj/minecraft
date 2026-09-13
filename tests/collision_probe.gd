# 职责：碰撞穿模回归测试（无头物理仿真）
# 路径：res://tests/collision_probe.gd
# 说明：驱动一个 CharacterBody3D（Capsule r0.4 h1.8）在真实物理帧中移动，验证：
#   T1 水中向固体推 → 始终不进入固体（核心回归：不穿模）
#   T2 固体深处推向更深处 → 被阻挡或被排出，绝不"在固体内自由平移"
#   T3 陆地（空气中）向坑壁推 → 被阻挡
extends Node


class ProbeBody extends CharacterBody3D:
	var drive := Vector3.ZERO

	func _ready() -> void:
		collision_layer = 1
		collision_mask = 1
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.8
		cs.shape = cap
		add_child(cs)

	func _physics_process(_delta: float) -> void:
		velocity = drive
		move_and_slide()


var _fail := 0
var _world: WorldManager


func _ready() -> void:
	_world = WorldManager.new()
	add_child(_world)
	_world.flush_build_queue()
	await _run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[CollisionProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[CollisionProbe] FAIL  ", label)


func _is_solid(world_pos: Vector3) -> bool:
	var id := _world.get_block(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	return id != GlobalConfig.BLOCK_AIR and id != GlobalConfig.BLOCK_WATER and id != -1


func _make_body(pos: Vector3) -> ProbeBody:
	var b := ProbeBody.new()
	add_child(b)
	b.global_position = pos
	return b


func _step(frames: int) -> void:
	for _i in frames:
		await get_tree().physics_frame


func _run() -> void:
	# T1：水中（外圈水沟 gx=-32）向 +X 推向固体（gx=-31 起为实心）
	var b1 := _make_body(Vector3(-31.5, 4.0, 0.5))
	b1.drive = Vector3(5.0, 0.0, 0.0)
	await _step(90)
	_check(b1.global_position.x <= -31.35, "T1 水中撞墙被阻挡 x=%.2f (应<=-31.35)" % b1.global_position.x)
	_check(not _is_solid(b1.global_position), "T1 身体未进入固体")
	b1.queue_free()

	# T2：固体深处（gx=-30, y=3，四周/上下均被固体包裹）向 +X（更深）推
	var start := Vector3(-30.5, 3.0, 0.5)
	var b2 := _make_body(start)
	b2.drive = Vector3(5.0, 0.0, 0.0)
	await _step(90)
	var dx := absf(b2.global_position.x - start.x)
	var inside := _is_solid(b2.global_position)
	_check((not inside) or dx < 1.5, "T2 固体内部不被自由穿越 inside=%s dx=%.2f" % [inside, dx])
	b2.queue_free()

	# T3：陆地空气中（中央坑内 gx=5 为空气）向 +X 推向坑壁（gx=7 起为实心）
	var b3 := _make_body(Vector3(5.0, 4.0, 0.5))
	b3.drive = Vector3(8.0, 0.0, 0.0)
	await _step(90)
	_check(b3.global_position.x <= 6.7, "T3 陆地撞坑壁被阻挡 x=%.2f (应<=6.70)" % b3.global_position.x)
	_check(not _is_solid(b3.global_position), "T3 身体未进入固体")
	b3.queue_free()

	print("[CollisionProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
