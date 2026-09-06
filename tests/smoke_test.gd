# 职责：数据层 + 纹理管道 + 网格构建的冒烟自检（无头可运行，回归基线）
# 路径：res://tests/smoke_test.gd
# 说明：以真实场景运行方式加载全局类缓存，验证：
#   1) WorldManager._ready 加载 16 个区块
#   2) 超平坦地形取样正确（内部=草/水/石头，边界=石头，越界未加载=-1）
#   3) set_block 修改与脏标记时序
#   4) TextureManager 扫描缓存 / get_uv 语义不变 / get_atlas_uv 图集 / 材质 / 占位
#   5) WorldManager.render_cache 网格句柄与 AABB（水/固分离）
extends Node

var _failures: int = 0
var _world: WorldManager = null

func _ready() -> void:
	print("[SmokeTest] === 冒烟自检开始 ===")
	_test_world()
	_test_textures()
	_test_meshes()
	print("[SmokeTest] === 完成： %d 处断言失败 ===" % _failures)
	# 无头运行后退出
	get_tree().quit(_failures)

func _check(cond: bool, label: String) -> void:
	if cond:
		print("[SmokeTest] PASS  %s" % label)
	else:
		_failures += 1
		printerr("[SmokeTest] FAIL  %s" % label)

func _test_world() -> void:
	_world = WorldManager.new()
	var world := _world
	# _ready 会执行：WorldManager 需加入场景树才会触发 _ready
	add_child(world)
	_check(world.world_data.size() == 16, "WorldManager 应加载 16 个区块 (实际 %d)" % world.world_data.size())

	# 内部区域取样：(gx, gy, gz) —— 草顶高原
	_check(world.get_block(0, 0, 0) == GlobalConfig.BLOCK_STONE, "内部 y0 应为石头")
	_check(world.get_block(0, 5, 0) == GlobalConfig.BLOCK_GRASS, "内部 y5 应为草")
	_check(world.get_block(0, 6, 0) == GlobalConfig.BLOCK_AIR, "内部 y6 应为空气(草顶为地表)")
	# 最外一圈水沟取样（世界边界 -32 与 31）
	_check(world.get_block(-32, 0, 0) == GlobalConfig.BLOCK_WATER, "水沟 x=-32 y0 应为水")
	_check(world.get_block(-32, 5, 0) == GlobalConfig.BLOCK_WATER, "水沟 x=-32 y5 应为水")
	_check(world.get_block(-32, 6, 0) == GlobalConfig.BLOCK_AIR, "水沟 x=-32 y6 应为空气")
	_check(world.get_block(31, 0, 31) == GlobalConfig.BLOCK_WATER, "水沟 x=31,z=31 y0 应为水")
	_check(world.get_block(0, 5, 31) == GlobalConfig.BLOCK_WATER, "水沟 z=31 y5 应为水")
	# 负数安全取模：-1 应落在区块 -1 的本地坐标 15
	_check(world.get_block(-1, 5, 0) == GlobalConfig.BLOCK_GRASS, "x=-1 y5 应为草(负坐标取模正确)")
	# 未加载区块（x=5,y=1 之外）→ -1
	_check(world.get_block(100, 5, 100) == -1, "越界未加载应返回 -1")
	# set_block：加载/建网格后 dirty 已被复位为 false；写入后应重新置 true
	var chunk_a: SubChunk = world.world_data[Vector3i(0, 0, 0)]
	var dirty_after_build: bool = chunk_a.dirty
	world.set_block(0, 6, 0, GlobalConfig.BLOCK_STONE)
	_check(world.get_block(0, 6, 0) == GlobalConfig.BLOCK_STONE, "set_block 后内部 y6 应变为石头")
	_check(chunk_a.dirty == true and dirty_after_build == false, "构建后 dirty=false，set_block 后应变 true")

func _test_textures() -> void:
	_check(TextureManager.texture_cache.size() > 0, "TextureManager 应缓存 >0 张纹理 (实际 %d)" % TextureManager.texture_cache.size())
	_check(TextureManager.texture_cache.has("stone"), "应缓存 stone 键")
	_check(TextureManager.texture_cache.has("grass_block_side"), "应缓存 grass_block_side 键")
	_check(TextureManager.get_texture_by_key("stone") != null, "get_texture_by_key(stone) 应非空")
	# 面索引：草方块 [底=泥土,顶=草面,四侧=草皮]
	_check(TextureManager.BLOCK_TEXTURE_KEYS[GlobalConfig.BLOCK_GRASS].size() == 6, "草方块配置应为 6 面")
	# 接口隔离：get_uv() 保持"整张图"语义不变
	_check(TextureManager.get_uv(GlobalConfig.BLOCK_GRASS, GlobalConfig.FACE_TOP) == Rect2(0, 0, 1, 1), "get_uv 顶面应返回整张图 Rect2(0,0,1,1)")
	# 图集专用 get_atlas_uv：返回归一化合法子矩形，且不同方块不同
	var grass_top_uv := TextureManager.get_atlas_uv(GlobalConfig.BLOCK_GRASS, GlobalConfig.FACE_TOP)
	_check(grass_top_uv.size.x > 0.0 and grass_top_uv.size.y > 0.0 and grass_top_uv.size.x <= 1.0 and grass_top_uv.size.y <= 1.0, "get_atlas_uv(草,顶) 应返回合法归一化矩形 %s" % grass_top_uv)
	var stone_uv := TextureManager.get_atlas_uv(GlobalConfig.BLOCK_STONE, GlobalConfig.FACE_TOP)
	_check(stone_uv != grass_top_uv, "草顶面与石头顶面 UV 应不同")
	_check(TextureManager.get_shared_material() != null, "get_shared_material() 应非空")
	_check(TextureManager.get_water_material() != null, "get_water_material() 应非空")
	# 缺失键 → 品红占位图（不应崩溃）
	var missing := TextureManager.get_texture_by_key("__no_such_key__")
	_check(missing != null, "缺失键应返回非空占位图")

func _test_meshes() -> void:
	# 网格句柄应登记在 WorldManager.render_cache（而非 SubChunk）
	_check(_world.render_cache.size() == 16, "render_cache 应有 16 个区块条目 (实际 %d)" % _world.render_cache.size())
	var solid_count := 0
	var water_count := 0
	for v3 in _world.render_cache:
		var entry: Dictionary = _world.render_cache[v3]
		var solid: MeshInstance3D = entry.get("solid")
		if solid != null:
			solid_count += 1
			var ab := solid.mesh.get_aabb()
			_check(ab.size.x > 0.0 and ab.size.y > 0.0 and ab.size.z > 0.0, "区块 %s 固体网格 AABB 应非退化" % v3)
		var water: MeshInstance3D = entry.get("water")
		if water != null:
			water_count += 1
	_check(solid_count == 16, "每个区块都应有固体网格 (实际 %d)" % solid_count)
	# 纯内部区块无外围水沟 → 无水网格；(含最外一圈的区块) 应有水网格
	var interior_entry: Dictionary = _world.render_cache[Vector3i(0, 0, 0)]
	_check(interior_entry.get("water") == null, "纯内部区块(0,0,0) 不应有水网格")
	var moat_entry: Dictionary = _world.render_cache[Vector3i(-2, 0, -2)]
	_check(moat_entry.get("water") != null, "含水沟区块(-2,0,-2) 应有水网格")
	# 非"薄片"体积：内部区块固体网格应覆盖 ~6 层高度(石头0~4+草5)，而非单层薄壳
	var ab0: AABB = interior_entry.get("solid").mesh.get_aabb()
	_check(ab0.size.y > 3.0 and ab0.size.y < 7.0, "内部区块固体网格 AABB 高度应≈6层 (实际 %.1f)" % ab0.size.y)
