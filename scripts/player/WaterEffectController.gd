# ============================================================================
# 文件:    WaterEffectController.gd
# 路径:    res://scripts/player/WaterEffectController.gd
# 职责:    水下表现：相机浸入水方块时开启蓝色雾效，出水还原（纯表现层，无着色器）
# 说明:    挂在 Player 下；通过 WorldEnvironment 动态切换 Environment 雾。
#          - 水下：fog_enabled=true, fog_light_color=(0.05,0.15,0.3), fog_density=0.08
#          - 陆地：还原为初始雾设置（默认关闭）
#          体素判定（相机所在方块==BLOCK_WATER）与玩家物理判定相互独立，低耦合。
# ============================================================================
extends Node3D
class_name WaterEffectController

@export var fog_color: Color = Color(0.05, 0.15, 0.3)
@export var fog_density: float = 0.08

var _env: Environment = null
var _fog_enabled_default: bool = false

@onready var _world: WorldManager = get_node_or_null("../World") as WorldManager
@onready var _camera: Camera3D = get_node_or_null("Camera3D") as Camera3D


func _ready() -> void:
	var we := get_node_or_null("../WorldEnvironment")
	if we is WorldEnvironment and (we as WorldEnvironment).environment != null:
		_env = (we as WorldEnvironment).environment
		_fog_enabled_default = _env.fog_enabled


func _physics_process(_delta: float) -> void:
	if _env == null or _camera == null or _world == null:
		return
	var eye := _camera.global_position
	var id := _world.get_block(int(floor(eye.x)), int(floor(eye.y)), int(floor(eye.z)))
	var underwater := id == GlobalConfig.BLOCK_WATER
	if underwater:
		_env.fog_enabled = true
		_env.fog_light_color = fog_color
		_env.fog_density = fog_density
	else:
		_env.fog_enabled = _fog_enabled_default
