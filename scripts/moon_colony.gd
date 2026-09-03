class_name MoonColony
extends RefCounted
## Authority-owned colony cargo. This ledger never accepts backpack items or
## client-authored quantities, timers, balances, upgrade levels or rewards.

const SAVE_VERSION := 1
const PLOT_COUNT := 6
const GROW_SECONDS := 45.0
const TEND_SECONDS := 12.0
const AGE_SECONDS := 50.0
const HELPER_SECONDS := 8.0
const MAX_AGING_BATCHES := 3
const MAX_CARGO := 9999
const MAX_BALANCE := 1000000000
const UPGRADE_KEYS := ["yield", "growth", "plots", "helper"]
const UPGRADE_NAMES := ["Richer cultures", "Quick cultures", "Extra farm plot", "Farm helper"]
const UPGRADE_COSTS := [[12, 24], [10, 20], [12, 18], [24]]
const LANDMARK_NAMES := ["Earthrise Observatory", "Far-side Relay", "Crystal Garden"]
const LANDMARK_REWARDS := [6, 8, 10]
const CONTRACTS := [
	{"fresh": 4, "aged": 0, "reward": 12, "name": "First lunar delivery"},
	{"fresh": 6, "aged": 2, "reward": 30, "name": "School lunch shipment"},
	{"fresh": 8, "aged": 6, "reward": 70, "name": "Earth festival order"},
]
const ACTIONS := ["plant", "tend", "harvest", "sell_fresh", "sell_aged", "age",
	"upgrade", "contract", "discover", "refill"]

var seed := 0
var plots: Array[Dictionary] = []
var cargo := {"fresh": 0, "aged": 0}
var upgrades := {"yield": 0, "growth": 0, "plots": 0, "helper": 0}
var aging: Array[float] = []
var contracts: Array[bool] = [false, false, false]
var discoveries: Array[bool] = [false, false, false]
var stats := {"harvested": 0, "earned": 0, "spent": 0, "tended": 0}
var helper_remaining := HELPER_SECONDS
var helper_cursor := 0
var helper_target := -1
var restored_balance := 0


func _init(seed_value: int = 0) -> void:
	seed = seed_value
	for index in range(PLOT_COUNT):
		plots.append({"planted": index < 2, "grown": GROW_SECONDS if index < 2 else 0.0,
			"tended": false})


static func facility_direction(id: StringName) -> Vector3:
	var offset := Vector2.ZERO
	match id:
		&"farm": offset = Vector2(42.0, -9.0)
		&"aging": offset = Vector2(94.0, -58.0)
		&"market": offset = Vector2(112.0, -74.0)
		&"observatory": offset = Vector2(180.0, -120.0)
		&"relay": offset = Vector2(-160.0, -70.0)
		&"crystal_garden": offset = Vector2(30.0, 210.0)
	return Vector3(offset.x, MoonWorld.PLAYABLE_RADIUS_METERS, offset.y).normalized()


static func plot_direction(index: int) -> Vector3:
	var bounded := clampi(index, 0, PLOT_COUNT - 1)
	var offset := Vector2(42.0 + float(bounded % 3 - 1) * 6.0,
		-20.0 + (float(bounded / 3) - 0.5) * 7.0)
	return Vector3(offset.x, MoonWorld.PLAYABLE_RADIUS_METERS, offset.y).normalized()


static func landmark_direction(index: int) -> Vector3:
	return facility_direction([&"observatory", &"relay", &"crystal_garden"][clampi(index, 0, 2)])


static func action_direction(action: String, target: int = 0) -> Vector3:
	match action:
		"plant", "tend", "harvest": return plot_direction(target)
		"discover": return landmark_direction(target)
		"age": return facility_direction(&"aging")
		"upgrade": return facility_direction(&"market")
		"refill": return facility_direction([&"farm", &"market", &"observatory", &"relay"][clampi(target, 0, 3)])
	return facility_direction(&"market")


static func valid_action(action: String, target: int) -> bool:
	if not ACTIONS.has(action):
		return false
	match action:
		"plant", "tend", "harvest": return target >= 0 and target < PLOT_COUNT
		"discover", "contract": return target >= 0 and target < 3
		"upgrade", "refill": return target >= 0 and target < 4
		"sell_fresh", "sell_aged": return target >= 0 and target <= MAX_CARGO
	return target == 0


func growth_seconds() -> float:
	return GROW_SECONDS * (1.0 - 0.15 * int(upgrades.growth)) \
		* (0.9 if discoveries.count(true) == 3 else 1.0)


func harvest_yield() -> int:
	return 3 + int(upgrades["yield"])


func plot_unlocked(index: int) -> bool:
	return index >= 0 and index < 4 + int(upgrades.plots)


func plot_ready(index: int) -> bool:
	return plot_unlocked(index) and bool(plots[index].planted) \
		and float(plots[index].grown) >= growth_seconds()


## Advance only active simulation time. Event-sized helper steps keep both
## long deterministic test steps and frame-sized updates equivalent and bounded.
func advance(delta: float) -> bool:
	if not is_finite(delta) or delta <= 0.0 or delta > 3600.0:
		return false
	var remaining := delta
	var changed := false
	while remaining > 0.000001:
		var step := minf(remaining, helper_remaining) if int(upgrades.helper) > 0 else remaining
		var duration := growth_seconds()
		for index in range(PLOT_COUNT):
			if plot_unlocked(index) and bool(plots[index].planted) \
					and float(plots[index].grown) < duration:
				plots[index].grown = minf(float(plots[index].grown) + step, duration)
				changed = true
		for index in range(aging.size() - 1, -1, -1):
			aging[index] = maxf(aging[index] - step, 0.0)
			changed = true
			if aging[index] <= 0.0 and int(cargo.aged) <= MAX_CARGO - 2:
				cargo.aged = int(cargo.aged) + 2
				aging.remove_at(index)
		remaining -= step
		if int(upgrades.helper) > 0:
			changed = true
			helper_remaining -= step
			if helper_remaining <= 0.000001:
				helper_remaining = HELPER_SECONDS
				changed = _helper_work() or changed
	return changed


func _helper_work() -> bool:
	helper_target = -1
	for offset in range(PLOT_COUNT):
		var index := (helper_cursor + offset) % PLOT_COUNT
		if not plot_unlocked(index):
			continue
		if plot_ready(index):
			if int(cargo.fresh) > MAX_CARGO - harvest_yield():
				continue
			_harvest(index)
			plots[index].planted = true
		elif not bool(plots[index].planted):
			plots[index] = {"planted": true, "grown": 0.0, "tended": false}
		elif not bool(plots[index].tended):
			_tend(index)
		else:
			continue
		helper_target = index
		helper_cursor = (index + 1) % PLOT_COUNT
		return true
	return false


func _tend(index: int) -> void:
	plots[index].tended = true
	plots[index].grown = minf(float(plots[index].grown) + TEND_SECONDS, growth_seconds())
	stats.tended = mini(int(stats.tended) + 1, MAX_BALANCE)


func _harvest(index: int) -> void:
	cargo.fresh = int(cargo.fresh) + harvest_yield()
	stats.harvested = mini(int(stats.harvested) + harvest_yield(), MAX_BALANCE)
	plots[index] = {"planted": false, "grown": 0.0, "tended": false}


func _result(ok: bool, reason: String, balance: int, changed: bool = false) -> Dictionary:
	return {"ok": ok, "reason": reason, "balance": balance, "changed": changed}


func perform(action: String, target: int, balance: int) -> Dictionary:
	if not valid_action(action, target) or balance < 0 or balance > MAX_BALANCE:
		return _result(false, "Invalid colony request.", balance)
	var earned := 0
	var spent := 0
	var message := ""
	match action:
		"plant", "tend", "harvest":
			if not plot_unlocked(target):
				return _result(false, "Unlock this farm plot at Muenster's counter.", balance)
			var plot: Dictionary = plots[target]
			if action == "plant":
				if bool(plot.planted): return _result(false, "This plot is already planted.", balance)
				plots[target] = {"planted": true, "grown": 0.0, "tended": false}
				message = "Free cheese culture planted."
			elif action == "tend":
				if not bool(plot.planted) or plot_ready(target):
					return _result(false, "Tend a growing culture.", balance)
				if bool(plot.tended): return _result(false, "This culture has already been tended.", balance)
				_tend(target)
				message = "Culture tended: 12 seconds of growth added."
			else:
				if not plot_ready(target): return _result(false, "This culture is not ripe yet.", balance)
				if int(cargo.fresh) > MAX_CARGO - harvest_yield():
					return _result(false, "Colony cargo is full. Sell or age some fresh cheese.", balance)
				_harvest(target)
				message = "%d fresh wedges added to colony cargo." % harvest_yield()
		"sell_fresh", "sell_aged":
			var key := "fresh" if action == "sell_fresh" else "aged"
			var quantity := int(cargo[key]) if target == 0 else target
			if quantity <= 0 or quantity > int(cargo[key]):
				return _result(false, "There is not enough %s cheese in colony cargo." % key, balance)
			earned = quantity * (2 if key == "fresh" else 6)
			if balance > MAX_BALANCE - earned: return _result(false, "Banana balance is full.", balance)
			cargo[key] = int(cargo[key]) - quantity
			message = "Sold %d %s wedges for %d bananas." % [quantity, key, earned]
		"age":
			if aging.size() >= MAX_AGING_BATCHES: return _result(false, "All three aging shelves are busy.", balance)
			if int(cargo.fresh) < 3: return _result(false, "Aging needs 3 fresh wedges from colony cargo.", balance)
			if int(cargo.aged) + aging.size() * 2 > MAX_CARGO - 2:
				return _result(false, "Aged-cheese storage is full.", balance)
			cargo.fresh = int(cargo.fresh) - 3
			aging.append(AGE_SECONDS)
			message = "Aging 3 fresh wedges into 2 aged wedges: 50 seconds."
		"upgrade":
			var key: String = UPGRADE_KEYS[target]
			var level := int(upgrades[key])
			var costs: Array = UPGRADE_COSTS[target]
			if level >= costs.size(): return _result(false, "This upgrade is complete.", balance)
			spent = int(costs[level])
			if balance < spent: return _result(false, "Not enough bananas for this upgrade.", balance)
			upgrades[key] = level + 1
			message = "%s upgraded." % UPGRADE_NAMES[target]
		"contract":
			if contracts[target]: return _result(false, "This delivery is already complete.", balance)
			if target > 0 and not contracts[target - 1]:
				return _result(false, "Complete the previous delivery first.", balance)
			var order: Dictionary = CONTRACTS[target]
			if int(cargo.fresh) < int(order.fresh) or int(cargo.aged) < int(order.aged):
				return _result(false, "The delivery needs more colony cargo.", balance)
			earned = int(order.reward)
			if balance > MAX_BALANCE - earned: return _result(false, "Banana balance is full.", balance)
			cargo.fresh = int(cargo.fresh) - int(order.fresh)
			cargo.aged = int(cargo.aged) - int(order.aged)
			contracts[target] = true
			message = "Delivery complete: +%d bananas." % earned
		"discover":
			if discoveries[target]: return _result(false, "This landmark is already surveyed.", balance)
			earned = int(LANDMARK_REWARDS[target])
			if balance > MAX_BALANCE - earned: return _result(false, "Banana balance is full.", balance)
			discoveries[target] = true
			message = "%s surveyed: +%d bananas." % [LANDMARK_NAMES[target], earned]
			if discoveries.count(true) == 3: message += " All cultures now grow 10% faster."
		"refill":
			if (target == 2 and not discoveries[0]) or (target == 3 and not discoveries[1]):
				return _result(false, "Survey this outpost to activate its oxygen station.", balance)
			return _result(true, "Suit oxygen refilled.", balance)
	stats.earned = mini(int(stats.earned) + earned, MAX_BALANCE)
	stats.spent = mini(int(stats.spent) + spent, MAX_BALANCE)
	return _result(true, message, balance + earned - spent, true)


func snapshot(balance: int = 0) -> Dictionary:
	var display_plots: Array = []
	var duration := growth_seconds()
	for index in range(PLOT_COUNT):
		var planted := bool(plots[index].planted)
		display_plots.append({"id": index, "unlocked": plot_unlocked(index),
			"planted": planted, "ready": plot_ready(index), "duration": duration,
			"remaining": maxf(duration - float(plots[index].grown), 0.0) if planted else 0.0,
			"progress": clampf(float(plots[index].grown) / duration, 0.0, 1.0) if planted else 0.0,
			"tended": bool(plots[index].tended)})
	var offers: Array = []
	for index in range(UPGRADE_KEYS.size()):
		var level := int(upgrades[UPGRADE_KEYS[index]])
		offers.append({"id": index, "key": UPGRADE_KEYS[index], "name": UPGRADE_NAMES[index],
			"level": level, "max_level": UPGRADE_COSTS[index].size(),
			"cost": int(UPGRADE_COSTS[index][level]) if level < UPGRADE_COSTS[index].size() else 0})
	var orders: Array = []
	var landmarks: Array = []
	for index in range(3):
		var order: Dictionary = CONTRACTS[index].duplicate()
		order.merge({"id": index, "done": contracts[index],
			"available": not contracts[index] and (index == 0 or contracts[index - 1])})
		orders.append(order)
		landmarks.append({"id": index, "name": LANDMARK_NAMES[index],
			"discovered": discoveries[index], "reward": LANDMARK_REWARDS[index]})
	return {"version": SAVE_VERSION, "seed": seed, "balance": balance,
		"cargo": cargo.duplicate(), "plots": display_plots, "upgrades": upgrades.duplicate(),
		"upgrade_offers": offers, "aging": {"batches": aging.duplicate(),
			"remaining": aging.min() if not aging.is_empty() else 0.0},
		"contracts": orders, "landmarks": landmarks, "stats": stats.duplicate(),
		"helper": {"target": helper_target, "working": int(upgrades.helper) > 0 and helper_target >= 0},
		"survey_perk": discoveries.count(true) == 3, "growth_seconds": duration,
		"harvest_yield": harvest_yield()}


func serialize(balance: int) -> Dictionary:
	return {"version": SAVE_VERSION, "seed": seed, "balance": balance,
		"plots": plots.duplicate(true), "cargo": cargo.duplicate(),
		"upgrades": upgrades.duplicate(), "aging": aging.duplicate(),
		"contracts": contracts.duplicate(), "discoveries": discoveries.duplicate(),
		"stats": stats.duplicate(), "helper_remaining": helper_remaining,
		"helper_cursor": helper_cursor, "helper_target": helper_target}


static func _number(value: Variant, minimum: float, maximum: float, integer: bool = false) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= minimum and float(value) <= maximum \
		and (not integer or floorf(float(value)) == float(value))


func restore(record: Dictionary) -> bool:
	# Validate the complete record before assigning anything. JSON numbers may
	# arrive as floats, but integer ledger values must still be exact integers.
	if record.size() != 13 or not _number(record.get("version"), SAVE_VERSION, SAVE_VERSION, true) \
			or not _number(record.get("seed"), seed, seed, true) \
			or not _number(record.get("balance"), 0, MAX_BALANCE, true):
		return false
	for key in ["cargo", "upgrades", "stats"]:
		if not record.get(key) is Dictionary: return false
	if record.cargo.size() != 2 or record.upgrades.size() != 4 or record.stats.size() != 4:
		return false
	for key in ["fresh", "aged"]:
		if not _number(record.cargo.get(key), 0, MAX_CARGO, true): return false
	for index in range(4):
		if not _number(record.upgrades.get(UPGRADE_KEYS[index]), 0, UPGRADE_COSTS[index].size(), true): return false
	for key in ["harvested", "earned", "spent", "tended"]:
		if not _number(record.stats.get(key), 0, MAX_BALANCE, true): return false
	for key in ["plots", "aging", "contracts", "discoveries"]:
		if not record.get(key) is Array: return false
	if record.plots.size() != PLOT_COUNT or record.aging.size() > MAX_AGING_BATCHES \
			or record.contracts.size() != 3 or record.discoveries.size() != 3:
		return false
	for index in range(PLOT_COUNT):
		var plot: Variant = record.plots[index]
		if not plot is Dictionary or plot.size() != 3 or not plot.get("planted") is bool \
				or not plot.get("tended") is bool or not _number(plot.get("grown"), 0, GROW_SECONDS):
			return false
		if (not plot.planted and (float(plot.grown) != 0.0 or plot.tended)) \
				or (index >= 4 + int(record.upgrades.plots) and plot.planted): return false
	for value in record.aging:
		if not _number(value, 0, AGE_SECONDS): return false
	for key in ["contracts", "discoveries"]:
		for value in record[key]:
			if not value is bool: return false
	if (record.contracts[1] and not record.contracts[0]) \
			or (record.contracts[2] and not record.contracts[1]): return false
	if not _number(record.get("helper_remaining"), 0.000001, HELPER_SECONDS) \
			or not _number(record.get("helper_cursor"), 0, PLOT_COUNT - 1, true) \
			or not _number(record.get("helper_target"), -1, PLOT_COUNT - 1, true): return false
	plots.assign(record.plots.duplicate(true))
	cargo = {"fresh": int(record.cargo.fresh), "aged": int(record.cargo.aged)}
	for key in UPGRADE_KEYS: upgrades[key] = int(record.upgrades[key])
	aging.assign(record.aging)
	contracts.assign(record.contracts)
	discoveries.assign(record.discoveries)
	for key in stats: stats[key] = int(record.stats[key])
	helper_remaining = float(record.helper_remaining)
	helper_cursor = int(record.helper_cursor)
	helper_target = int(record.helper_target)
	restored_balance = int(record.balance)
	return true
