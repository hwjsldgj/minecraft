# 职责：端到端验证「HUD 存在时鼠标左/右键交互仍生效」（5.1 回归）
# 路径：res://tests/interaction_with_hud_probe.gd
# 说明：经 Input.parse_input_event 走真实输入管线（含 GUI 命中测试），
#       若 HUD 控件吞掉鼠标事件则本测试会失败。
extends Node

var _fail := 0
var _world: WorldManager
var _player: PlayerController
var _cam: Camera3D
var _hud: HUD


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()

	_player = PlayerController.new()
	_player.name = "Player"
	add_child(_player)
	_player.require_mouse_capture = false  # 无头无捕获，仍走完整 _unhandled_input 链路
	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_player.add_child(_cam)

	_hud = HUD.new()
	_hud.name = "HUD"
	add_child(_hud)
	_run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[InterHUD] PASS  ", label)
	else:
		_fail += 1
		printerr("[InterHUD] FAIL  ", label)


func _click(index: int) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = index
	e.pressed = true
	e.position = get_viewport().get_visible_rect().size * 0.5
	Input.parse_input_event(e)


func _aim(eye: Vector3, dir: Vector3) -> void:
	_player.global_position = eye
	_cam.global_position = eye
	var dn := dir.normalized()
	var up := Vector3.UP if absf(dn.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	_cam.look_at(eye + dn, up)


func _run() -> void:
	_check(_hud.slot_texture_rects.size() == 9 and _hud.crosshair_nodes.size() == 2, "HUD 正常(9格+准星)")

	# 左键破坏：(8,5,10) 草块
	_aim(Vector3(8.5, 7.5, 10.5), Vector3(0, -1, 0))
	_check(_world.get_block(8, 5, 10) != GlobalConfig.BLOCK_AIR, "破坏前 (8,5,10) 应为固体")
	_click(MOUSE_BUTTON_LEFT)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_world.get_block(8, 5, 10) == GlobalConfig.BLOCK_AIR, "左键应破坏 (8,5,10)")

	# 右键放置：坑内朝 +X 命中 (7,4,0) → 放置到 (6,4,0)
	_aim(Vector3(5.5, 4.5, 0.5), Vector3(1, 0, 0))
	_check(_player.current_block_id == GlobalConfig.BLOCK_STONE, "当前槽应为石头")
	_click(MOUSE_BUTTON_RIGHT)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_world.get_block(6, 4, 0) == GlobalConfig.BLOCK_STONE, "右键应放置石头到 (6,4,0)")

	# 数字键切换仍正常
	_check(_player.handle_hotbar_key(KEY_2) and _player.current_block_id == GlobalConfig.BLOCK_GRASS, "数字键2应切到草")
	_hud.refresh()
	_check(_hud.selected_index == 1, "HUD 高亮应跟随到槽1")

	print("[InterHUD] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
