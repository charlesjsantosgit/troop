class_name ResidentLife
extends RefCounted

## Small persistent records for real players, advanced only while they are active.
## The city authority owns `state`; physical service context never comes from RPC payloads.
const MAX_RESIDENTS := 512
const MAX_ACTIVE_STEP := 5.0
const MIN_NEED := 20.0
const REST_SECONDS := 15.0
const BED_RANGE := 3.0
const CLINIC_RANGE := 18.0
const CLINIC_PRICE := 18
const CAREER_THRESHOLDS := [0, 3, 8, 16, 30]
const CAREERS := ["courier", "maintenance", "provisioning"]
const CONSUMABLES := {
	"banana": {"label":"Banana", "nutrition":18.0, "hydration":4.0},
	"plantain": {"label":"Plantain", "nutrition":20.0, "hydration":3.0},
	"meal": {"label":"Prepared meal", "nutrition":40.0, "hydration":10.0},
	"dried_food": {"label":"Dried food", "nutrition":28.0, "hydration":0.0},
	"carrot": {"label":"Carrot", "nutrition":12.0, "hydration":5.0},
	"tomato": {"label":"Tomato", "nutrition":10.0, "hydration":10.0},
	"cucumber": {"label":"Cucumber", "nutrition":8.0, "hydration":15.0},
	"strawberry": {"label":"Strawberry", "nutrition":12.0, "hydration":8.0},
	"water": {"label":"Water", "nutrition":0.0, "hydration":40.0},
}

var state: Dictionary = {}


static func new_state() -> Dictionary:
	return {}


static func migrate(candidate: Variant) -> Dictionary:
	# A missing field is the only older schema. Existing malformed data must fail validation.
	if candidate == null: return new_state()
	return candidate.duplicate(true) if candidate is Dictionary else {"invalid":true}


static func valid(candidate: Variant) -> bool:
	if not candidate is Dictionary or candidate.size() > MAX_RESIDENTS: return false
	for actor in candidate:
		if not actor is String or not _valid_actor(actor): return false
		var row: Variant = candidate[actor]
		if not row is Dictionary or row.size() != 11: return false
		for need in ["nutrition", "hydration", "rest"]:
			if not _number(row.get(need), MIN_NEED, 100.0): return false
		for key in ["active_seconds", "last_action_time", "rest_until"]:
			if not _number(row.get(key), 0.0, 1.0e12): return false
		if not _number(row.get("last_clinic_time"), -60.0, 1.0e12): return false
		if not _integer(row.get("last_job_serial"), 0, 1000000000): return false
		if not _integer(row.get("schema"), 1, 1): return false
		if not row.get("rest_building") is String or row.rest_building.length() > 80: return false
		if not row.get("careers") is Dictionary or row.careers.size() != CAREERS.size(): return false
		for career in CAREERS:
			if not _integer(row.careers.get(career), 0, 1000000000): return false
	return true


func import_state(candidate: Variant) -> bool:
	var migrated := migrate(candidate)
	if not valid(migrated): return false
	state = migrated
	return true


func view(actor: String) -> Dictionary:
	if not _valid_actor(actor): return {}
	var row: Dictionary = state.get(actor, _new_resident())
	var result: Dictionary = row.duplicate(true)
	var careers: Array = []
	for career in CAREERS:
		var completed := int(row.careers[career])
		var level := _level(completed)
		careers.append({"id":career, "label":career.capitalize(), "completed":completed,
			"level":level + 1, "bonus_percent":level * 5,
			"next_at":CAREER_THRESHOLDS[level + 1] if level < 4 else -1})
	result["career_rows"] = careers
	var lowest := minf(float(row.nutrition), minf(float(row.hydration), float(row.rest)))
	result["stamina_multiplier"] = lerpf(0.85, 1.0, clampf((lowest - MIN_NEED) / 15.0, 0.0, 1.0))
	result["condition"] = "Ready for the day" if lowest >= 35.0 else "A meal, water or rest will help"
	result["resting"] = not str(row.rest_building).is_empty()
	result["clinic_price"] = CLINIC_PRICE
	return result


func advance(actor: String, dt: float, position: Vector3, time: float, context: Dictionary = {}) -> bool:
	if not _valid_actor(actor) or not is_finite(dt) or dt <= 0.0 or not position.is_finite() \
			or not is_finite(time) or time < 0.0 or time > 1.0e12: return false
	if not state.has(actor) and state.size() >= MAX_RESIDENTS: return false
	var row: Dictionary = state.get(actor, _new_resident())
	var seconds := minf(dt, MAX_ACTIVE_STEP)
	row.active_seconds = minf(1.0e12, float(row.active_seconds) + seconds)
	row.nutrition = maxf(MIN_NEED, float(row.nutrition) - seconds / 60.0)
	row.hydration = maxf(MIN_NEED, float(row.hydration) - seconds / 40.0)
	row.rest = maxf(MIN_NEED, float(row.rest) - seconds / 80.0)
	if not str(row.rest_building).is_empty():
		if time <= float(row.rest_until) and _bed_matches(context, actor, str(row.rest_building), position):
			row.rest = minf(100.0, float(row.rest) + seconds * 4.0)
		else:
			row.rest_building = ""
			row.rest_until = 0.0
	state[actor] = row
	return true


func action(kind: String, payload: Dictionary, sim, actor: String, position: Vector3,
		time: float, context: Dictionary = {}) -> Dictionary:
	if not _valid_actor(actor) or not position.is_finite() or not is_finite(time) or time < 0.0 \
			or time > 1.0e12 or sim == null or not sim.state is Dictionary:
		return _result(false, "The resident's authority state is unavailable.")
	if absf(time - float(sim.state.get("time", time))) > 2.0:
		return _result(false, "This life action used an invalid authority time.")
	if not state.has(actor) and state.size() >= MAX_RESIDENTS:
		return _result(false, "The resident register is full.")
	var location := str(sim.inventory_location(actor, "earth"))
	if not sim.state.get("inventories", {}).has(location):
		return _result(false, "The resident's Earth backpack is unavailable.")
	var row: Dictionary = state.get(actor, _new_resident()).duplicate(true)
	if time < float(row.last_action_time):
		return _result(false, "This life action is older than the resident record.")
	var result: Dictionary
	match kind:
		"life_consume":
			var item := str(payload.get("item", ""))
			if not CONSUMABLES.has(item): return _result(false, "Choose food or water from your backpack.")
			if sim.stock(location, item) < 1: return _result(false, "That item is no longer in your backpack.")
			var food: Dictionary = CONSUMABLES[item]
			if (float(food.nutrition) <= 0.0 or float(row.nutrition) >= 100.0) \
					and (float(food.hydration) <= 0.0 or float(row.hydration) >= 100.0):
				return _result(false, "You do not need that item right now.")
			sim._consume(location, item, 1, "Resident food and drink")
			row.nutrition = minf(100.0, float(row.nutrition) + float(food.nutrition))
			row.hydration = minf(100.0, float(row.hydration) + float(food.hydration))
			result = _result(true, "%s consumed from your backpack." % str(food.label))
		"life_rest":
			var building := str(payload.get("building", ""))
			if not _bed_matches(context, actor, building, position):
				return _result(false, "Walk beside the bed in your own home to rest.")
			if float(row.rest) >= 99.0: return _result(false, "You are already well rested.")
			row.rest_building = building
			row.rest_until = time + REST_SECONDS
			result = _result(true, "Resting. Stay beside your bed for 15 seconds; moving away ends your rest.")
		"life_clinic":
			var building := str(payload.get("building", ""))
			if not _clinic_matches(context, building, position):
				return _result(false, "Visit a clinic entrance for treatment.")
			if time - float(row.last_clinic_time) < 30.0:
				return _result(false, "Your treatment is still taking effect.")
			if context.has("health") and float(row.nutrition) >= 70.0 and float(row.hydration) >= 70.0 \
					and float(row.rest) >= 70.0 and float(context.get("health", 100.0)) >= 100.0:
				return _result(false, "You are healthy and do not need treatment.")
			if int(sim.balance(actor)) < CLINIC_PRICE:
				return _result(false, "Clinic treatment costs %d credits." % CLINIC_PRICE)
			sim._transfer(actor, "treasury", CLINIC_PRICE, "Resident clinic treatment")
			for need in ["nutrition", "hydration", "rest"]: row[need] = maxf(70.0, float(row[need]))
			row.last_clinic_time = time
			result = _result(true, "Clinic treatment complete. Paid %d credits." % CLINIC_PRICE)
			result["heal_to"] = 100.0
		_:
			return _result(false, "That resident life action is unavailable.")
	row.last_action_time = time
	state[actor] = row
	result["resident_life"] = view(actor)
	return result


func record_job(actor: String, job_id: String, kind: String, base_reward: int, sim,
		time: float, reserved_payroll: int = 0) -> Dictionary:
	# Called by the authority only after the ordinary cargo/payment transaction succeeds.
	var serial_text := job_id.trim_prefix("city_job_")
	if not _valid_actor(actor) or not job_id.begins_with("city_job_") or not serial_text.is_valid_int() \
			or base_reward < 0 or base_reward > 1000000 or not is_finite(time) or time < 0.0 \
			or time > 1.0e12 or sim == null or reserved_payroll < 0:
		return _result(false, "Invalid completed work record.")
	var career := kind if kind in ["courier", "maintenance"] else "provisioning"
	if kind not in ["courier", "maintenance", "produce_provisioning", "depot_restock"]:
		return _result(false, "That work has no resident career record.")
	var serial := int(serial_text)
	if serial <= 0 or serial > 1000000000: return _result(false, "Invalid completed work serial.")
	if not state.has(actor) and state.size() >= MAX_RESIDENTS: return _result(false, "The resident register is full.")
	var row: Dictionary = state.get(actor, _new_resident()).duplicate(true)
	if serial <= int(row.last_job_serial): return _result(false, "That work has already been recorded.")
	var level := _level(int(row.careers[career]))
	var expected := floori(float(base_reward) * float(level) * 0.05)
	var surplus := maxi(0, int(sim.balance("treasury")) - reserved_payroll)
	var bonus := expected if surplus >= expected else 0
	if bonus > 0: sim._transfer("treasury", actor, bonus, "Resident %s career bonus" % career)
	row.careers[career] = mini(1000000000, int(row.careers[career]) + 1)
	row.last_job_serial = serial
	state[actor] = row
	return {"ok":true, "message":"Career progress earned.", "career":career, "bonus":bonus,
		"bonus_unfunded":expected > bonus, "resident_life":view(actor)}


static func _new_resident() -> Dictionary:
	return {"schema":1, "nutrition":80.0, "hydration":80.0, "rest":80.0,
		"active_seconds":0.0, "last_action_time":0.0, "last_clinic_time":-60.0,
		"rest_building":"", "rest_until":0.0, "last_job_serial":0,
		"careers":{"courier":0, "maintenance":0, "provisioning":0}}


static func _bed_matches(context: Dictionary, actor: String, building: String, position: Vector3) -> bool:
	var bed: Variant = context.get("bed", {})
	return bed is Dictionary and not building.is_empty() and str(bed.get("building", "")) == building \
		and str(bed.get("owner", "")) == actor and bool(bed.get("residential", false)) \
		and bed.get("position") is Vector3 and bed.position.is_finite() \
		and position.distance_to(bed.position) <= BED_RANGE


static func _clinic_matches(context: Dictionary, building: String, position: Vector3) -> bool:
	var clinic: Variant = context.get("clinic", {})
	return clinic is Dictionary and not building.is_empty() and str(clinic.get("building", "")) == building \
		and str(clinic.get("kind", "")) == "clinic" and clinic.get("position") is Vector3 \
		and clinic.position.is_finite() and position.distance_to(clinic.position) <= CLINIC_RANGE


static func _level(completed: int) -> int:
	var level := 0
	for index in range(CAREER_THRESHOLDS.size()):
		if completed >= int(CAREER_THRESHOLDS[index]): level = index
	return level


static func _valid_actor(actor: String) -> bool:
	if actor == "player": return true
	if not actor.begins_with("member_") or actor.length() != 71: return false
	for c in actor.trim_prefix("member_"):
		if c not in "0123456789abcdef": return false
	return true


static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) \
		and float(value) >= minimum and float(value) <= maximum


static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value, minimum, maximum) and float(value) == floor(float(value))


static func _result(ok: bool, message: String) -> Dictionary:
	return {"ok":ok, "message":message}
