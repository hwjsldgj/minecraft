# 职责：9 格物品栏（当前仅存方块 ID，为未来数量/耐久/NBT 预留结构）
# 路径：res://scripts/player/Inventory.gd
class_name Inventory
extends RefCounted

const SLOT_COUNT := 9

var slots: Array[int] = []
var selected_slot: int = 0


func _init() -> void:
	slots.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		slots[i] = -1
	slots[0] = GlobalConfig.BLOCK_STONE
	slots[1] = GlobalConfig.BLOCK_GRASS


# 只读接口：越界返回 -1
func get_slot(i: int) -> int:
	if i < 0 or i >= slots.size():
		return -1
	return slots[i]


func get_selected() -> int:
	return selected_slot


func get_current() -> int:
	return get_slot(selected_slot)


func select_slot(i: int) -> bool:
	if i < 0 or i >= slots.size():
		return false
	selected_slot = i
	return true
