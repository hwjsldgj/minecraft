# 职责：玩家碰撞体尺寸"单一数据源"回归测试
# 路径：res://tests/collision_shape_probe.gd
# 说明：胶囊尺寸过去在 main.tscn 与 PlayerController 的 @export 各存一份，
#       改一处不同步。现由 _ready 用 @export 覆写场景胶囊，本探针验证：
#       1) 默认值下场景胶囊与 @export 完全一致（碰撞行为不变）；
#       2) 改 @export 后调用同步即可让碰撞体跟着变（无需改场景）；
#       3) 同步后几何关系正确（胶囊中心 = 脚底 + body_center_offset，顶/底自洽）。
extends Node

var _fail := 0
var _main: Node
var _player: PlayerController


func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	_player = _main.get_node("Player")
	_test_defaults_synced()
	_test_export_overrides_scene()
	print("[CollisionShapeProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[CollisionShapeProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[CollisionShapeProbe] FAIL  ", label)


func _cap() -> CapsuleShape3D:
	var cs := _player.get_node("CollisionShape3D") as CollisionShape3D
	return cs.shape as CapsuleShape3D


func _shape_node() -> CollisionShape3D:
	return _player.get_node("CollisionShape3D") as CollisionShape3D


# T1 默认值：场景胶囊已被 @export 覆写，两者一致（碰撞行为不变）
func _test_defaults_synced() -> void:
	var cap := _cap()
	_check(cap != null, "T1 CollisionShape3D 应有 CapsuleShape3D")
	_check(is_equal_approx(cap.radius, _player.body_radius),
		"T1 胶囊半径应等于 body_radius（%.3f vs %.3f）" % [cap.radius, _player.body_radius])
	_check(is_equal_approx(cap.height, _player.body_height),
		"T1 胶囊高度应等于 body_height（%.3f vs %.3f）" % [cap.height, _player.body_height])
	_check(is_equal_approx(_shape_node().position.y, _player.body_center_offset),
		"T1 胶囊中心 Y 应等于 body_center_offset（%.3f vs %.3f）" % [_shape_node().position.y, _player.body_center_offset])
	_check(is_equal_approx(cap.radius, 0.4) and is_equal_approx(cap.height, 1.8),
		"T1 默认尺寸仍应为 0.4 / 1.8（不改变既有碰撞行为）")


# T2 改 @export → 同步后碰撞体跟着变；再改回并恢复
func _test_export_overrides_scene() -> void:
	_player.body_height = 3.0
	_player.body_radius = 0.6
	_player.body_center_offset = 1.5
	_player._sync_collision_shape()
	var cap := _cap()
	_check(is_equal_approx(cap.height, 3.0), "T2 改 body_height 后胶囊高度应同步为 3.0（实测 %.3f）" % cap.height)
	_check(is_equal_approx(cap.radius, 0.6), "T2 改 body_radius 后胶囊半径应同步为 0.6（实测 %.3f）" % cap.radius)
	_check(is_equal_approx(_shape_node().position.y, 1.5), "T2 改 body_center_offset 后中心 Y 应同步为 1.5")
	# 复原默认，保证后续（含同进程其它检查）不受影响
	_player.body_height = 1.8
	_player.body_radius = 0.4
	_player.body_center_offset = 0.9
	_player._sync_collision_shape()
	_check(is_equal_approx(_cap().height, 1.8) and is_equal_approx(_cap().radius, 0.4),
		"T2 复原后胶囊应回到 0.4 / 1.8")
	# 同步使用的是副本，不污染场景子资源
	var res: Shape3D = _player.get_node("CollisionShape3D").shape
	_check(res != null and res.resource_path == "", "T2 胶囊应为运行时副本（不写回场景资源）")
