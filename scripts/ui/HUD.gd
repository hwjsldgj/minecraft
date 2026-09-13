# 职责：HUD —— 屏幕中心准星 + 底部 9 格物品栏（只读 Inventory，不修改数据）
# 路径：res://scripts/ui/HUD.gd
extends CanvasLayer
class_name HUD

const SLOT_SIZE := 60.0
const SLOT_GAP := 4.0
const BAR_MARGIN := 12.0
const ZOOM_PX := 8.0
const CROSS_LEN := 8.0
const CROSS_THICK := 1.0  # 半宽 → 2px 实线

var selected_index: int = 0
var slot_texture_rects: Array[TextureRect] = []
var slot_highlights: Array[ColorRect] = []
var crosshair_nodes: Array[ColorRect] = []

var _inventory: Inventory = null
var _count := 9
var _bar: Control = null


func _ready() -> void:
	_inventory = _find_inventory()
	_count = Inventory.SLOT_COUNT
	_build_crosshair()
	_build_bar()
	refresh()


# 只读获取物品栏（来自 Player）；找不到则为 null（UI 仍安全显示空槽）
func _find_inventory() -> Inventory:
	var p := get_node_or_null("../Player")
	if p is PlayerController:
		return (p as PlayerController).inventory
	return null


func _build_crosshair() -> void:
	var h := ColorRect.new()
	h.color = Color.WHITE
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 不允许 HUD 吞掉鼠标事件(否则视角无法转动)
	h.anchor_left = 0.5
	h.anchor_top = 0.5
	h.anchor_right = 0.5
	h.anchor_bottom = 0.5
	h.offset_left = -CROSS_LEN
	h.offset_right = CROSS_LEN
	h.offset_top = -CROSS_THICK
	h.offset_bottom = CROSS_THICK
	add_child(h)
	crosshair_nodes.append(h)

	var v := ColorRect.new()
	v.color = Color.WHITE
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.anchor_left = 0.5
	v.anchor_top = 0.5
	v.anchor_right = 0.5
	v.anchor_bottom = 0.5
	v.offset_left = -CROSS_THICK
	v.offset_right = CROSS_THICK
	v.offset_top = -CROSS_LEN
	v.offset_bottom = CROSS_LEN
	add_child(v)
	crosshair_nodes.append(v)


func _build_bar() -> void:
	var total := float(_count) * SLOT_SIZE + float(_count - 1) * SLOT_GAP
	_bar = Control.new()
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.anchor_left = 0.5
	_bar.anchor_right = 0.5
	_bar.anchor_top = 1.0
	_bar.anchor_bottom = 1.0
	_bar.offset_left = -total * 0.5
	_bar.offset_right = total * 0.5
	_bar.offset_top = -(SLOT_SIZE + BAR_MARGIN)
	_bar.offset_bottom = -BAR_MARGIN
	add_child(_bar)

	for i in _count:
		var x := float(i) * (SLOT_SIZE + SLOT_GAP)
		var hi := ColorRect.new()
		hi.color = Color.WHITE
		hi.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hi.position = Vector2(x - 2.0, -2.0)
		hi.size = Vector2(SLOT_SIZE + 4.0, SLOT_SIZE + 4.0)
		hi.visible = false
		_bar.add_child(hi)
		slot_highlights.append(hi)

		var bg := ColorRect.new()
		bg.color = Color(0.10, 0.10, 0.10, 0.85)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.position = Vector2(x, 0.0)
		bg.size = Vector2(SLOT_SIZE, SLOT_SIZE)
		_bar.add_child(bg)

		var tr := TextureRect.new()
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.position = Vector2(x + ZOOM_PX * 0.5, ZOOM_PX * 0.5)
		tr.size = Vector2(SLOT_SIZE - ZOOM_PX, SLOT_SIZE - ZOOM_PX)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_bar.add_child(tr)
		slot_texture_rects.append(tr)


# 依据 Inventory 刷新缩略图与选中高亮（只读）
func refresh() -> void:
	if _inventory != null:
		selected_index = _inventory.get_selected()
	var atlas := TextureManager.get_atlas_texture()
	var atlas_size := Vector2.ZERO
	if atlas != null:
		atlas_size = atlas.get_size()
	for i in _count:
		var id := -1 if _inventory == null else _inventory.get_slot(i)
		var tr := slot_texture_rects[i]
		if id < 0 or id == GlobalConfig.BLOCK_AIR or atlas == null:
			tr.texture = null
		else:
			# 从现有图集截取该方块顶面区域，不重复加载纹理
			var uv := TextureManager.get_atlas_uv(id, GlobalConfig.FACE_TOP)
			var at := AtlasTexture.new()
			at.atlas = atlas
			at.region = Rect2(uv.position * atlas_size, uv.size * atlas_size)
			tr.texture = at
		slot_highlights[i].visible = (i == selected_index)


func _process(_delta: float) -> void:
	if _inventory != null and _inventory.get_selected() != selected_index:
		refresh()
