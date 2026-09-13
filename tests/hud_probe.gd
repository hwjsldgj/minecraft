# 职责：子任务 5.1 HUD 回归测试（准星 / 9 格物品栏缩略图 / 选中高亮跟随）
# 路径：res://tests/hud_probe.gd
extends Node

var _fail := 0
var _world: WorldManager
var _player: PlayerController
var _hud: HUD


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()

	_player = PlayerController.new()
	_player.name = "Player"
	add_child(_player)

	_hud = HUD.new()
	_hud.name = "HUD"
	add_child(_hud)
	_run()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[HudProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[HudProbe] FAIL  ", label)


func _run() -> void:
	_check(_hud.crosshair_nodes.size() == 2, "准星应为两条线")
	if _hud.crosshair_nodes.size() == 2:
		_check(_hud.crosshair_nodes[0].size.x > _hud.crosshair_nodes[0].size.y, "准星横线应为横向 2px 线")
		_check(_hud.crosshair_nodes[1].size.y > _hud.crosshair_nodes[1].size.x, "准星竖线应为纵向 2px 线")

	_check(_hud.slot_texture_rects.size() == 9, "物品栏应为 9 格")
	_check(_hud.slot_highlights.size() == 9, "9 格均应有高亮框")

	# 槽0 石头 / 槽1 草应有图集缩略图；槽8 空槽无贴图
	_check(_hud.slot_texture_rects[0].texture != null, "槽0 应有纹理缩略图")
	_check(_hud.slot_texture_rects[1].texture != null, "槽1 应有纹理缩略图")
	_check(_hud.slot_texture_rects[8].texture == null, "空槽8 不应有纹理")

	var at := _hud.slot_texture_rects[0].texture as AtlasTexture
	_check(at != null and at.atlas != null and at.region.size.x > 0.0, "缩略图应为图集 AtlasTexture 且区域有效")
	_check(at != null and at.atlas == TextureManager.get_atlas_texture(), "缩略图应复用现有图集(不重复加载)")

	# 选中高亮跟随按键切换
	_check(_hud.slot_highlights[0].visible and not _hud.slot_highlights[1].visible, "默认高亮应在槽0")
	_player.handle_hotbar_key(KEY_2)
	_hud._process(0.0)
	_check(_hud.selected_index == 1, "按2后 selected_index 应为 1")
	_check(_hud.slot_highlights[1].visible and not _hud.slot_highlights[0].visible, "高亮应跟随到槽1")

	print("[HudProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)
