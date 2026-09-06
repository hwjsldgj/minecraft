# 职责：第一阶段数据层 + 纹理管道的冒烟自检（无头可运行，回归基线）
# 路径：res://tests/smoke_test.gd
# 说明：以真实场景运行方式加载全局类缓存，验证：
#   1) WorldManager._ready 加载 16 个区块
#   2) 超平坦地形取样正确（内部=草/水/石头，边界=石头，越界未加载=-1）
#   3) set_block 修改与脏标记
#   4) TextureManager 自动扫描缓存、get_texture_by_key / get_uv / 缺失占位
extends Node

var _failures: int = 0

func _ready() -> void:
	print("[SmokeTest] === 冒烟自检开始 ===")
	_test_world()
	_test_textures()
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
	var world := WorldManager.new()
	# _ready 会执行：WorldManager 需加入场景树才会触发 _ready
	add_child(world)
	_check(world.world_data.size() == 16, "WorldManager 应加载 16 个区块 (实际 %d)" % world.world_data.size())

	# 内部区域取样：(gx, gy, gz)
	_check(world.get_block(0, 0, 0) == GlobalConfig.BLOCK_STONE, "内部 y0 应为石头")
	_check(world.get_block(0, 5, 0) == GlobalConfig.BLOCK_GRASS, "内部 y5 应为草")
	_check(world.get_block(0, 6, 0) == GlobalConfig.BLOCK_WATER, "内部 y6 应为水")
	_check(world.get_block(0, 7, 0) == GlobalConfig.BLOCK_AIR, "内部 y7 应为空气")
	# 边界石墙取样（世界边界 -32 与 31）
	_check(world.get_block(-32, 0, 0) == GlobalConfig.BLOCK_STONE, "边界墙 x=-32 y0 应为石头")
	_check(world.get_block(-32, 5, 0) == GlobalConfig.BLOCK_STONE, "边界墙 x=-32 y5 应为石头")
	_check(world.get_block(-32, 6, 0) == GlobalConfig.BLOCK_AIR, "边界墙 x=-32 y6 应为空气")
	_check(world.get_block(31, 0, 31) == GlobalConfig.BLOCK_STONE, "边界墙 x=31,z=31 y0 应为石头")
	_check(world.get_block(0, 5, 31) == GlobalConfig.BLOCK_STONE, "边界墙 z=31 y5 应为石头")
	# 负数安全取模：-1 应落在区块 -1 的本地坐标 15
	_check(world.get_block(-1, 5, 0) == GlobalConfig.BLOCK_GRASS, "x=-1 y5 应为草(负坐标取模正确)")
	# 未加载区块（x=5,y=1 之外）→ -1
	_check(world.get_block(100, 5, 100) == -1, "越界未加载应返回 -1")
	# set_block：先查脏标记再改
	var chunk_a: SubChunk = world.world_data[Vector3i(0, 0, 0)]
	var dirty_before: bool = chunk_a.dirty
	world.set_block(0, 6, 0, GlobalConfig.BLOCK_STONE)
	_check(world.get_block(0, 6, 0) == GlobalConfig.BLOCK_STONE, "set_block 后 y6 应变为石头")
	_check(chunk_a.dirty == true and dirty_before == true, "set_block 后区块应保持 dirty")

func _test_textures() -> void:
	_check(TextureManager.texture_cache.size() > 0, "TextureManager 应缓存 >0 张纹理 (实际 %d)" % TextureManager.texture_cache.size())
	_check(TextureManager.texture_cache.has("stone"), "应缓存 stone 键")
	_check(TextureManager.texture_cache.has("grass_block_side"), "应缓存 grass_block_side 键")
	_check(TextureManager.get_texture_by_key("stone") != null, "get_texture_by_key(stone) 应非空")
	# 面索引：草方块 [底=泥土,顶=草面,四侧=草皮]
	_check(TextureManager.BLOCK_TEXTURE_KEYS[GlobalConfig.BLOCK_GRASS].size() == 6, "草方块配置应为 6 面")
	_check(TextureManager.get_uv(GlobalConfig.BLOCK_GRASS, GlobalConfig.FACE_TOP) == Rect2(0, 0, 1, 1), "get_uv 顶面应返回整张图 Rect2(0,0,1,1)")
	# 缺失键 → 品红占位图（不应崩溃）
	var missing := TextureManager.get_texture_by_key("__no_such_key__")
	_check(missing != null, "缺失键应返回非空占位图")
