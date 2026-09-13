# 职责：水下表现回归测试（水面顶部从水下可见 / 水下滤镜生效）
# 路径：res://tests/underwater_probe.gd
# 说明：
#   问题1：水面顶面（face=1）的环绕是"从外侧(=上方)看为正面"，从水下看到的是它的背面。
#          材质若只渲染正面（CULL_BACK），潜水抬头就看不到水面贴图 → 必须双面。
#   问题2：WaterEffectController 找相机时曾把兄弟节点当子节点查（"Camera3D"），
#          永远拿到 null 直接 return → 滤镜从未生效。本探针按 main.tscn 的层级复刻
#          （World / WorldEnvironment / Player{Camera3D, WaterEffectController}）来验证。
extends Node

var _fail := 0
var _world: WorldManager
var _player: PlayerController
var _cam: Camera3D
var _fx: WaterEffectController
var _env: Environment


func _ready() -> void:
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()

	_env = Environment.new()
	_env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = _env
	add_child(we)

	_player = PlayerController.new()
	_player.name = "Player"
	add_child(_player)
	_player.set_physics_process(false)   # 本探针只改相机位置，避免物理干扰

	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_cam.position = Vector3(0.0, 1.6, 0.0)
	_player.add_child(_cam)

	_fx = WaterEffectController.new()
	_fx.name = "WaterEffectController"
	_player.add_child(_fx)

	_test_top_face_visible_from_below()
	await _test_underwater_filter()
	print("[UnderwaterProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[UnderwaterProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[UnderwaterProbe] FAIL  ", label)


# T1 水面顶面：网格里确实存在朝上的顶面，且材质双面渲染（水下能看到其背面）
func _test_top_face_visible_from_below() -> void:
	var found_top := false
	var upward_winding := false
	for v3 in _world.render_cache.keys():
		var e: Dictionary = _world.render_cache[v3]
		if e.get("water") == null:
			continue
		var am: ArrayMesh = e["water"].mesh
		if am.get_surface_count() == 0:
			continue
		var vs: PackedVector3Array = am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var i := 0
		while i + 2 < vs.size():
			var n := (vs[i + 1] - vs[i]).cross(vs[i + 2] - vs[i])
			if absf(n.y) > 0.9 and absf(n.x) < 0.01 and absf(n.z) < 0.01:
				found_top = true
				if absf(vs[i].y - roundf(vs[i].y)) < 0.01:
					upward_winding = true
			i += 3
	_check(found_top, "T1 水网格里应存在水平顶面（face=1）")
	_check(upward_winding, "T1 顶面环绕应为水平朝向（正面朝上，背面朝下→水下看到的是背面）")
	var mat: StandardMaterial3D = TextureManager.get_water_material()
	_check(mat.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"T1 水材质应双面渲染（CULL_DISABLED），否则从水下看不到水面顶部贴图")


# T2 水下滤镜：相机进水方块 → 雾效开；出水 → 恢复
func _test_underwater_filter() -> void:
	# 水沟在 x=-32 / x=31 / z=-32 / z=31（水 gy 0..5）
	_cam.global_position = Vector3(31.5, 3.0, 5.5)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var eye := _cam.global_position
	var bid := _world.get_block(int(floor(eye.x)), int(floor(eye.y)), int(floor(eye.z)))
	_check(bid == GlobalConfig.BLOCK_WATER, "T2 前置：相机所在方块应为水（实测 %d）" % bid)
	_check(_env.fog_enabled, "T2 相机浸入水方块时应开启水下滤镜")
	_check(is_equal_approx(_env.fog_density, _fx.fog_density),
		"T2 滤镜浓度应生效（%.3f）" % _env.fog_density)
	_check(_env.fog_light_color.b > _env.fog_light_color.r + 0.15,
		"T2 滤镜应为偏蓝/青蓝（%.2f,%.2f,%.2f）" % [_env.fog_light_color.r, _env.fog_light_color.g, _env.fog_light_color.b])

	_cam.global_position = Vector3(12.0, 8.0, 12.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(not _env.fog_enabled, "T2 相机出水后应恢复（滤镜关闭）")

	# 再入水一次，确认可反复切换
	_cam.global_position = Vector3(-31.5, 2.0, 10.5)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_env.fog_enabled, "T2 再次入水应重新开启滤镜")
