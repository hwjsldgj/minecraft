# ============================================================================
# 文件:    DDA.gd
# 路径:    res://scripts/player/DDA.gd
# 职责:    体素射线步进（Amanatides & Woo），用于方块选取（破坏/放置）
# 说明:    纯数学实现，【不依赖物理引擎】，也不触碰任何网格节点；
#          只通过 WorldManager.get_block 读取体素。
#          返回 { hit: bool, block_pos: Vector3i, normal: Vector3i, t: float }
#          - normal = 进入命中格时所穿过的面法线（如自上方进入 → (0,1,0)），
#            为未来"方块朝向/放置朝向"预留。
#          - 起始格已是非空气时：命中该格，normal = (0,0,0)。
#          - 邻居返回 -1（未加载）视为未知区域：终止步进且不命中。
# ============================================================================
class_name DDA
extends RefCounted

const MISS := { "hit": false, "block_pos": Vector3i.ZERO, "normal": Vector3i.ZERO, "t": 0.0 }


# 从 origin 沿 direction 步进最多 max_dist 距离，返回首个非空气方块的命中信息。
static func raycast(world: WorldManager, origin: Vector3, direction: Vector3, max_dist: float) -> Dictionary:
	if world == null:
		return MISS
	var dir := direction.normalized()
	if dir.length_squared() < 1e-12:
		return MISS

	# 逐轴状态：cell 为当前格整数坐标；t_max 为到达下一格边界所需距离；t_delta 为跨一格距离
	var cell := [int(floor(origin.x)), int(floor(origin.y)), int(floor(origin.z))]
	var o := [origin.x, origin.y, origin.z]
	var d := [dir.x, dir.y, dir.z]
	var step := [0, 0, 0]
	var t_max := [INF, INF, INF]
	var t_delta := [INF, INF, INF]

	# 起始格判定
	var id0 := world.get_block(cell[0], cell[1], cell[2])
	# 起始格是水时不命中：眼睛泡在水里（很常见）也要能继续往前打到固体，
	# 否则会返回 normal=ZERO 的"起始格命中"，导致水中无法放置方块。
	if id0 != GlobalConfig.BLOCK_AIR and id0 != -1 and not GlobalConfig.is_water(id0):
		return { "hit": true, "block_pos": Vector3i(cell[0], cell[1], cell[2]), "normal": Vector3i.ZERO, "t": 0.0 }

	for axis in 3:
		if absf(d[axis]) < 1e-8:
			continue
		step[axis] = 1 if d[axis] > 0.0 else -1
		var boundary := float(cell[axis] + (1 if d[axis] > 0.0 else 0))
		t_max[axis] = (boundary - o[axis]) / d[axis]
		t_delta[axis] = absf(1.0 / d[axis])

	var t := 0.0
	while true:
		# 取最小 t_max 的轴（下一格跨轴）
		var axis := 0
		if t_max[1] < t_max[axis]:
			axis = 1
		if t_max[2] < t_max[axis]:
			axis = 2
		if t_max[axis] == INF:
			break
		t = t_max[axis]
		if t > max_dist:
			break
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
		var id := world.get_block(cell[0], cell[1], cell[2])
		if id == -1:
			break  # 未加载：未知区域，终止且不命中
		if id != GlobalConfig.BLOCK_AIR and not GlobalConfig.is_water(id):
			# 水【不可命中】：射线直接穿过水，命中水后面的固体
			# （因此水不会被破坏；在水中放置也只能依附于固体面）
			var normal := Vector3i.ZERO
			if axis == 0:
				normal = Vector3i(-step[0], 0, 0)
			elif axis == 1:
				normal = Vector3i(0, -step[1], 0)
			else:
				normal = Vector3i(0, 0, -step[2])
			return { "hit": true, "block_pos": Vector3i(cell[0], cell[1], cell[2]), "normal": normal, "t": t }
	return MISS
