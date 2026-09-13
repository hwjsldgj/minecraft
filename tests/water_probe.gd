# 职责：水下可见性回归测试（几何级，无头可跑）
# 路径：res://tests/water_probe.gd
# 说明：验证"透明感知剔除"——固体面若邻居是水也必须生成，
#       否则摄像机浸入水中会看穿固体、只见内壁。
#   检查点：区块 (-2,0,0) 内 gx=-31（局部 lx=1）应存在朝 -X 的固体面（其邻居 gx=-32 为水）。
extends Node

var _fail := 0
var _world: WorldManager


func _ready() -> void:
	_world = WorldManager.new()
	add_child(_world)
	_world.flush_build_queue()

	var entry: Dictionary = _world.render_cache.get(Vector3i(-2, 0, 0), {})
	var solid: MeshInstance3D = entry.get("solid")
	var water: MeshInstance3D = entry.get("water")

	_check(solid != null, "区块(-2,0,0) 应有固体网格")
	_check(water != null, "区块(-2,0,0) 应含水网格")

	if solid != null:
		var stats := _face_stats(solid.mesh, 1.0, Vector3(-1, 0, 0))
		_check(stats.y > 0, "朝向水的固体面应存在 (lx=1 平面、法线-X 的三角形数=%d)" % stats.y)
		_check(stats.x < 6000, "固体三角形总数未爆炸 (=%d)" % stats.x)

	print("[WaterProbe] === 完成： %d 处断言失败 ===" % _fail)
	get_tree().quit(_fail)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[WaterProbe] PASS  ", label)
	else:
		_fail += 1
		printerr("[WaterProbe] FAIL  ", label)


# 统计：返回 (三角形总数, 满足"全部顶点 x≈plane 且法线≈dir"的三角形数)
func _face_stats(mesh: Mesh, plane_x: float, dir: Vector3) -> Vector2i:
	var arr: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var total := 0
	var hit := 0
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null and (idx as PackedInt32Array).size() > 0:
		var ii: PackedInt32Array = idx
		total = ii.size() / 3
		for t in total:
			if _matches(verts, norms, ii[t * 3], ii[t * 3 + 1], ii[t * 3 + 2], plane_x, dir):
				hit += 1
	else:
		total = verts.size() / 3
		for t in total:
			if _matches(verts, norms, t * 3, t * 3 + 1, t * 3 + 2, plane_x, dir):
				hit += 1
	return Vector2i(total, hit)


func _matches(verts: PackedVector3Array, norms: PackedVector3Array, a: int, b: int, c: int, plane_x: float, dir: Vector3) -> bool:
	for i in [a, b, c]:
		if absf(verts[i].x - plane_x) > 0.01:
			return false
		if norms[i].dot(dir) < 0.9:
			return false
	return true
