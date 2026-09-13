# 职责：集中管理全局常量（区块尺寸、世界边界、方块 ID、面索引定义）
# 路径：res://scripts/core/GlobalConfig.gd
# 说明：本类不产生任何实例逻辑，仅作为常量仓库供其余模块引用，
#       避免代码中硬编码魔法数字。具体方块"属性"未来将由配置文件驱动。
class_name GlobalConfig
extends RefCounted

# ===== 区块尺寸 =====
const CHUNK_SIZE := 16

# ===== 世界边界（当前测试范围，未来可放宽/移除限制）=====
# 世界在 X/Z 平面为 64×64 的有限区域，Y 为高度 0~15。
# 区块坐标范围：x,z ∈ [-2, 1]，y = 0（见 WorldManager._ready）
const WORLD_MIN_X := -32
const WORLD_MAX_X := 31
const WORLD_MIN_Z := -32
const WORLD_MAX_Z := 31
const WORLD_MIN_Y := 0
const WORLD_MAX_Y := 15

# ===== 渲染/加载调度 =====
# 玩家周围加载区块半径（区块数）；用于 WorldManager.update_chunk_loading。
const RENDER_DISTANCE := 3

# ===== 方块 ID（仅定义数值；模块内部禁止按具体 ID 做 if 判断）=====
const BLOCK_AIR := 0
const BLOCK_STONE := 1
const BLOCK_GRASS := 2
const BLOCK_WATER := 3          # 水源（永久存在，水位 0）
const BLOCK_FLOWING_WATER := 4  # 流动水（水位 1~7；具体水位存于 WaterSimulator）


# 是否属于"水"这一类（水源或流动水）。渲染/物理/碰撞统一走这里，
# 避免各处分别判断 BLOCK_WATER 而漏掉 BLOCK_FLOWING_WATER。
static func is_water(id: int) -> bool:
	return id == BLOCK_WATER or id == BLOCK_FLOWING_WATER

# ===== 六个面索引（与法线方向对齐，0~5）=====
# 世界方位约定：X 右为 +X（东）、左为 -X（西）；
#               Y 上为 +Y、下为 -Y；
#               Z 前方为 -Z（北）、南方为 +Z。
const FACE_BOTTOM := 0  # 法线 (0, -1, 0) 底面
const FACE_TOP := 1     # 法线 (0,  1, 0) 顶面
const FACE_BACK := 2    # 法线 (0,  0,-1) 北面（后方，-Z）
const FACE_FRONT := 3   # 法线 (0,  0, 1) 南面（前方，+Z）
const FACE_LEFT := 4    # 法线 (-1, 0, 0) 西面（左方，-X）
const FACE_RIGHT := 5   # 法线 ( 1, 0, 0) 东面（右方，+X）
