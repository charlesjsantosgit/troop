class_name LunarInventory
extends RefCounted
## Compact, deterministic survival inventory. Storage is deliberately absent
## until a normal or space backpack is equipped; integrations may therefore
## keep one inventory on every monkey without accidentally granting free slots.

signal changed
signal backpack_changed(kind: int, slot_count: int)

enum Backpack { NONE, NORMAL, SPACE }

const NORMAL_SLOTS := 12
const SPACE_SLOTS := 18
const DEFAULT_MAX_STACK := 64
const ITEM_BANANA := &"banana"
const ITEM_MOON_CHEESE := &"moon_cheese"

var backpack_kind := Backpack.NONE
var _slots: Array[Dictionary] = []


func has_backpack() -> bool:
	return backpack_kind != Backpack.NONE


func slot_count() -> int:
	return _slots.size()


func slots_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in _slots:
		result.append(slot.duplicate(true))
	return result


func equip_backpack(kind: int) -> bool:
	kind = clampi(kind, Backpack.NONE, Backpack.SPACE)
	var capacity := capacity_for(kind)
	if capacity < _used_slot_count():
		return false
	var packed := _packed_nonempty_slots()
	_slots.clear()
	_slots.resize(capacity)
	for index in range(capacity):
		_slots[index] = _empty_slot()
	for index in range(packed.size()):
		_slots[index] = packed[index]
	backpack_kind = kind
	backpack_changed.emit(backpack_kind, capacity)
	changed.emit()
	return true


static func capacity_for(kind: int) -> int:
	match kind:
		Backpack.NORMAL:
			return NORMAL_SLOTS
		Backpack.SPACE:
			return SPACE_SLOTS
	return 0


func add_item(item_id: StringName, amount: int,
		max_stack := DEFAULT_MAX_STACK) -> int:
	if not has_backpack() or item_id == &"" or amount <= 0:
		return maxi(amount, 0)
	max_stack = maxi(max_stack, 1)
	var remaining := amount
	# Existing stacks are filled in display order before empty slots. This is
	# stable across peers and keeps the compact grid tidy without a sort pass.
	for index in range(_slots.size()):
		var slot: Dictionary = _slots[index]
		if StringName(slot.id) != item_id or int(slot.count) >= int(slot.max_stack):
			continue
		var room := int(slot.max_stack) - int(slot.count)
		var moved := mini(room, remaining)
		slot.count = int(slot.count) + moved
		_slots[index] = slot
		remaining -= moved
		if remaining == 0:
			changed.emit()
			return 0
	for index in range(_slots.size()):
		if not _slot_empty(_slots[index]):
			continue
		var moved := mini(max_stack, remaining)
		_slots[index] = {"id": item_id, "count": moved,
			"max_stack": max_stack}
		remaining -= moved
		if remaining == 0:
			changed.emit()
			return 0
	if remaining != amount:
		changed.emit()
	return remaining


func remove_item(item_id: StringName, amount: int) -> int:
	if amount <= 0 or not has_backpack():
		return 0
	var remaining := mini(amount, count_item(item_id))
	var removed := remaining
	# Remove from the last stack first so the first visible stack stays full.
	for index in range(_slots.size() - 1, -1, -1):
		var slot: Dictionary = _slots[index]
		if StringName(slot.id) != item_id:
			continue
		var moved := mini(int(slot.count), remaining)
		slot.count = int(slot.count) - moved
		remaining -= moved
		_slots[index] = _empty_slot() if int(slot.count) <= 0 else slot
		if remaining == 0:
			break
	if removed > 0:
		changed.emit()
	return removed


func count_item(item_id: StringName) -> int:
	var total := 0
	for slot in _slots:
		if StringName(slot.id) == item_id:
			total += int(slot.count)
	return total


func can_add(item_id: StringName, amount: int,
		max_stack := DEFAULT_MAX_STACK) -> bool:
	if not has_backpack() or item_id == &"" or amount < 0:
		return false
	var room := 0
	for slot in _slots:
		if _slot_empty(slot):
			room += maxi(max_stack, 1)
		elif StringName(slot.id) == item_id:
			room += int(slot.max_stack) - int(slot.count)
		if room >= amount:
			return true
	return amount == 0


func move_slot(from_index: int, to_index: int) -> bool:
	if from_index < 0 or from_index >= _slots.size() \
			or to_index < 0 or to_index >= _slots.size():
		return false
	if from_index == to_index:
		return true
	var held := _slots[from_index]
	_slots[from_index] = _slots[to_index]
	_slots[to_index] = held
	changed.emit()
	return true


func clear() -> void:
	for index in range(_slots.size()):
		_slots[index] = _empty_slot()
	changed.emit()


func _used_slot_count() -> int:
	var used := 0
	for slot in _slots:
		if not _slot_empty(slot):
			used += 1
	return used


func _packed_nonempty_slots() -> Array[Dictionary]:
	var packed: Array[Dictionary] = []
	for slot in _slots:
		if not _slot_empty(slot):
			packed.append(slot.duplicate(true))
	return packed


static func _empty_slot() -> Dictionary:
	return {"id": &"", "count": 0, "max_stack": DEFAULT_MAX_STACK}


static func _slot_empty(slot: Dictionary) -> bool:
	return StringName(slot.get("id", &"")) == &"" \
		or int(slot.get("count", 0)) <= 0
