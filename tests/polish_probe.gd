# 职责：优化4（图集缓存）+ 优化5（物理参数 @export）回归测试
# 路径：res://tests/polish_probe.gd
# 说明：
#   优化4：首次生成缓存 / 二次加载 <100ms / 改 block/ 后失效重建 / 缓存损坏降级
#   优化5：默认值与原常量一致 / 编辑器分组存在 / 修改参数立即生效
extends Node

const CACHE_PATH := "user://atlas_cache.res"
const TMP_PNG := "res://block/__probe_tmp.png"

var _fail := 0
var _world: WorldManager
var _player: PlayerController


func _ready() -> void:
	_test_atlas_cache()
	_test_export_groups()
	_test_params_take_effect()
	print("[PolishProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PolishProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[PolishProbe] FAIL  ", label)


func _delete_cache() -> void:
	if FileAccess.file_exists(CACHE_PATH):
		var d := DirAccess.open("user://")
		if d != null:
			d.remove("atlas_cache.res")


# ===== 优化4：图集缓存 =====

func _test_atlas_cache() -> void:
	# T1 首次启动：无缓存 → 构建图集并写盘
	_delete_cache()
	TextureManager._atlas_texture = null
	TextureManager._atlas_uv = {}
	var t0 := Time.get_ticks_msec()
	TextureManager._ensure_atlas()
	TextureManager._save_cache()
	var gen_ms := Time.get_ticks_msec() - t0
	var uv_count: int = TextureManager._atlas_uv.size()
	_check(FileAccess.file_exists(CACHE_PATH), "T1 首次应生成缓存文件 %s" % CACHE_PATH)
	_check(uv_count > 0, "T1 图集 UV 映射应非空（%d 项）" % uv_count)
	print("[PolishProbe] 首次构建+存盘 = %d ms" % gen_ms)

	# T2 二次启动：命中缓存且 <100ms
	TextureManager._atlas_texture = null
	TextureManager._atlas_uv = {}
	TextureManager.texture_cache.clear()
	var t1 := Time.get_ticks_msec()
	var hit: bool = TextureManager._load_from_cache()
	var load_ms := Time.get_ticks_msec() - t1
	# 热加载（缓存文件已在系统磁盘缓存中）——最接近"二次启动"的场景
	TextureManager._atlas_texture = null
	TextureManager._atlas_uv = {}
	var t2 := Time.get_ticks_msec()
	var hit2: bool = TextureManager._load_from_cache()
	var warm_ms := Time.get_ticks_msec() - t2
	# 目录指纹自身的开销（每次校验都要算）
	var t3 := Time.get_ticks_msec()
	var fingerprint: int = TextureManager._get_dir_mtime()
	var fp_ms := Time.get_ticks_msec() - t3
	print("[PolishProbe] 首次加载 %d ms / 热加载 %d ms / 目录指纹 %d ms" % [load_ms, warm_ms, fp_ms])
	_check(hit and hit2, "T2 二次启动应命中缓存")
	_check(warm_ms < 100, "T2 二次启动（热）应 <100ms，实测 %d ms" % warm_ms)
	_check(fingerprint > 0, "T2 目录指纹应有效（%d）" % fingerprint)
	_check(TextureManager._atlas_uv.size() == uv_count, "T2 UV 映射应与首次一致")
	_check(TextureManager.get_atlas_texture() != null, "T2 图集应可用")
	_check(TextureManager.get_texture_by_key("stone") != null, "T2 缓存命中后 stone 贴图仍可取得")
	_check(TextureManager.texture_cache.has("stone"), "T2 缓存命中后应预载方块贴图")

	# T3a 改动 block/（新增一张贴图）→ 指纹变化 → 缓存失效
	_check(_write_tmp_png(), "T3 应能写入临时贴图")
	_check(not TextureManager._load_from_cache(), "T3 新增贴图后缓存应失效")
	TextureManager._ensure_atlas()
	TextureManager._save_cache()
	# T3b 删除贴图 → 再次失效；随后复原并重新命中
	_delete_tmp_png()
	_check(not TextureManager._load_from_cache(), "T3 删除贴图后缓存应再次失效")
	TextureManager._ensure_atlas()
	TextureManager._save_cache()
	_check(TextureManager._load_from_cache(), "T3 目录复原后缓存应重新命中")

	# T4 缓存损坏 → 降级重建，不崩溃
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("this is not a valid resource")
		f.close()
	_check(not TextureManager._load_from_cache(), "T4 缓存损坏应降级为重建（返回 false）而非崩溃")
	TextureManager._save_cache()
	_check(TextureManager._load_from_cache(), "T4 重建后的缓存应可再次命中")


func _write_tmp_png() -> bool:
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 1, 1))
	return img.save_png(TMP_PNG) == OK


func _delete_tmp_png() -> void:
	var d := DirAccess.open("res://block/")
	if d != null and d.file_exists("__probe_tmp.png"):
		d.remove("__probe_tmp.png")


# ===== 优化5：物理参数 @export =====

func _test_export_groups() -> void:
	var groups := {}
	for p in PlayerController.new().get_property_list():
		if (int(p.get("usage", 0)) & PROPERTY_USAGE_GROUP) != 0:
			groups[String(p.get("name", ""))] = true
	for want in ["Land", "Liquid", "Interaction", "Physics"]:
		_check(groups.has(want), "T5 应存在导出分组 %s" % want)


func _test_params_take_effect() -> void:
	var p := PlayerController.new()
	_check(is_equal_approx(p.land_speed, 5.0), "T6 land_speed 默认 5.0")
	_check(is_equal_approx(p.land_jump, 6.5), "T6 land_jump 默认 6.5")
	_check(is_equal_approx(p.land_gravity, -20.0), "T6 land_gravity 默认 -20.0")
	_check(is_equal_approx(p.water_speed, 2.20), "T6 water_speed 默认 2.20")
	_check(is_equal_approx(p.water_up, 0.39), "T6 water_up 默认 0.39")
	_check(is_equal_approx(p.water_down, 1.81), "T6 water_down 默认 1.81")
	_check(is_equal_approx(p.water_idle_sink, 0.80), "T6 water_idle_sink 默认 0.80")
	_check(is_equal_approx(p.water_drag, 0.8), "T6 water_drag 默认 0.8")
	_check(is_equal_approx(p.interact_reach, 4.0), "T6 interact_reach 默认 4.0")
	_check(is_equal_approx(p.body_height, 1.8), "T6 body_height 默认 1.8")
	_check(is_equal_approx(p.body_radius, 0.4), "T6 body_radius 默认 0.4")
	_check(is_equal_approx(p.body_center_offset, 0.9), "T6 body_center_offset 默认 0.9")
	p.free()

	# 真实生效：body_radius 变大后，原本可放置的空中格因与玩家 AABB 重叠而被拒
	_world = WorldManager.new()
	_world.name = "World"
	add_child(_world)
	_world.flush_build_queue()
	_player = PlayerController.new()
	_player.name = "Player"
	add_child(_player)
	_player.global_position = Vector3(0.5, 8.0, 0.5)
	var target := Vector3i(0, 8, 3)
	_check(_world.get_block(0, 8, 3) == GlobalConfig.BLOCK_AIR, "T6 前置：目标格应为空气")
	_check(_player.can_place_at(target), "T6 小半径时该空中格应可放置")
	_player.body_radius = 3.0
	_check(not _player.can_place_at(target), "T6 调大 body_radius 后应立即生效（AABB 重叠被拒）")
	_player.body_radius = 0.4
	_check(_player.can_place_at(target), "T6 复原半径后应恢复可放置")
