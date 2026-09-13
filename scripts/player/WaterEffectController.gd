# ============================================================================
# 文件:    WaterEffectController.gd
# 路径:    res://scripts/player/WaterEffectController.gd
# 职责:    水下表现：相机浸入水方块时开启青蓝色雾效，出水还原（纯表现层，无着色器）
# 说明:    本节点挂在 Player 下，而 World / WorldEnvironment 与 Player 平级（都挂在 Main 下），
#          故相对路径是 ../../World 与 ../../WorldEnvironment，不是 ../World。
#          早先这三处路径都按"自己是 Main 的子节点"书写，结果 _world / _env 恒为 null、
#          相机也找不到 → _physics_process 每次都在开头 return，水下滤镜从未生效。
#          现改为【沿祖先逐级查找】，层级调整或改名都不会再静默失效。
#          - 水下：fog_enabled=true, fog_light_color, fog_density（MC 风格青蓝滤镜）
#          - 出水：还原为初始雾设置（默认关闭）
#          体素判定（相机所在方块==BLOCK_WATER）与玩家物理判定相互独立，低耦合。
# ============================================================================
extends Node3D
class_name WaterEffectController

@export var fog_color: Color = Color(0.05, 0.15, 0.3)
@export var fog_density: float = 0.08

var _env: Environment = null
var _world: WorldManager = null
var _camera: Camera3D = null
var _fog_enabled_default: bool = false


func _ready() -> void:
	_world = _find_on_ancestors("World") as WorldManager
	var we := _find_on_ancestors("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
		_fog_enabled_default = _env.fog_enabled
	if _world == null or _env == null:
		push_warning("[WaterEffectController] 缺少 World / WorldEnvironment，水下滤镜不可用。")


# 沿祖先逐级向上查找名为 node_name 的节点（先看当前祖先的子节点，再上升一层）。
# 用于取到与 Player 平级的 World / WorldEnvironment。
func _find_on_ancestors(node_name: String) -> Node:
	var node := get_parent()
	while node != null:
		var found := node.get_node_or_null(node_name)
		if found != null:
			return found
		node = node.get_parent()
	return null


# 惰性解析相机：它是本节点的兄弟（../Camera3D）；取不到时回退到视口当前相机。
func _camera_node() -> Camera3D:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_node_or_null("../Camera3D") as Camera3D
	if _camera == null:
		var vp := get_viewport()
		if vp != null:
			_camera = vp.get_camera_3d()
	return _camera


func _physics_process(_delta: float) -> void:
	if _env == null or _world == null:
		return
	var cam := _camera_node()
	if cam == null:
		return
	var eye := cam.global_position
	var id := _world.get_block(int(floor(eye.x)), int(floor(eye.y)), int(floor(eye.z)))
	var underwater := id == GlobalConfig.BLOCK_WATER
	if underwater:
		_env.fog_enabled = true
		_env.fog_light_color = fog_color
		_env.fog_density = fog_density
	else:
		_env.fog_enabled = _fog_enabled_default
