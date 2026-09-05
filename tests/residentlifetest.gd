extends Node

const Life = preload("res://scripts/resident_life.gd")
const LifePanel = preload("res://scripts/resident_life_panel.gd")
const Sim = preload("res://scripts/frontier_sim.gd")

var checks := 0
var passed := 0

class FakeController extends Node:
	var snapshot: Dictionary = {}
	var requests: Array = []
	func city_view() -> Dictionary: return snapshot
	func request_action(kind: String, payload: Dictionary) -> Dictionary:
		requests.append({"kind":kind, "payload":payload.duplicate(true)})
		return {"ok":true, "message":"Done"}


func run(_main = null) -> void:
	_state_and_active_time()
	_consumption()
	_shared_inventory()
	_rest()
	_clinic()
	_careers()
	_panel()
	print("RESIDENTLIFETEST result=%d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	get_tree().quit(0 if passed == checks else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if condition: passed += 1
	else: push_error("RESIDENTLIFETEST FAIL: " + description)


func _world():
	var sim = Sim.new()
	sim.new_game(2026)
	return sim


func _resident():
	var life = Life.new()
	life.advance("player", 0.1, Vector3.ZERO, 400.0)
	return life


func _state_and_active_time() -> void:
	var life = Life.new()
	_check(Life.valid(Life.new_state()) and life.import_state(null), "missing legacy records migrate to an empty bounded register")
	_check(life.view("player").nutrition == 80.0 and life.state.is_empty(), "viewing a new resident does not mutate persistence")
	_check(not life.advance("forged", 1.0, Vector3.ZERO, 400.0), "invalid resident identities cannot allocate records")
	_check(not life.advance("player", NAN, Vector3.ZERO, 400.0), "non-finite elapsed time rejected")
	_check(life.advance("player", 36000.0, Vector3.ZERO, 400.0), "active advance accepts a long frame without a catch-up loop")
	_check(float(life.state.player.active_seconds) == Life.MAX_ACTIVE_STEP and float(life.state.player.hydration) > 79.0,
		"one huge elapsed-time update charges at most five seconds of needs")
	var serialized := JSON.stringify(life.state)
	var loaded = Life.new()
	_check(loaded.import_state(JSON.parse_string(serialized))
		and is_equal_approx(float(loaded.state.player.nutrition),float(life.state.player.nutrition))
		and is_equal_approx(float(loaded.state.player.hydration),float(life.state.player.hydration))
		and float(loaded.state.player.active_seconds) == float(life.state.player.active_seconds),
		"JSON persistence roundtrip preserves needs and active time without offline deterioration")
	var loaded_before := JSON.stringify(loaded.state)
	var corrupt: Dictionary = loaded.state.duplicate(true)
	corrupt.player.hydration = -1
	_check(not loaded.import_state(corrupt) and JSON.stringify(loaded.state) == loaded_before, "invalid needs fail import without changing good state")
	corrupt = loaded.state.duplicate(true)
	corrupt.player.careers.courier = 1.5
	_check(not Life.valid(corrupt), "fractional career progress rejected")
	corrupt = loaded.state.duplicate(true)
	corrupt.player.rest_until = INF
	_check(not Life.valid(corrupt) and not Life.valid(Life.migrate("invalid")), "invalid clocks and malformed older state are not silently reset")
	life.state.player.nutrition = 20.0
	life.state.player.hydration = 20.0
	life.state.player.rest = 20.0
	life.advance("player", 5.0, Vector3.ZERO, 405.0)
	_check(float(life.view("player").nutrition) == 20.0 and is_equal_approx(float(life.view("player").stamina_multiplier),0.85),
		"low needs have a bounded mild effect without starvation death")
	_check(Life.valid(life.state), "advanced minimum-need state remains valid")


func _consumption() -> void:
	var life = _resident()
	var sim = _world()
	var stock := int(sim.stock("player_earth", "banana"))
	var total := int(sim.total_goods("banana"))
	var money := int(sim.total_money())
	var result: Dictionary = life.action("life_consume", {"item":"banana"}, sim, "player", Vector3.ZERO, 400.0)
	_check(result.ok and sim.stock("player_earth", "banana") == stock - 1, "eating removes exactly one real backpack banana")
	_check(sim.total_goods("banana") == total - 1 and int(sim.state.resource_ledger.consumed.banana) == 1,
		"food is recorded as consumed in the shared resource ledger")
	_check(float(life.view("player").nutrition) > 97.0 and sim.total_money() == money, "food restores nutrition without changing money")
	var water := int(sim.stock("player_earth", "water"))
	result = life.action("life_consume", {"item":"water"}, sim, "player", Vector3.ZERO, 400.0)
	_check(result.ok and life.view("player").hydration == 100.0 and sim.stock("player_earth", "water") == water - 1,
		"drinking consumes actual water and caps hydration at full")
	var before := JSON.stringify([life.state, sim.state])
	result = life.action("life_consume", {"item":"water"}, sim, "player", Vector3.ZERO, 400.0)
	_check(not result.ok and JSON.stringify([life.state, sim.state]) == before, "unneeded water does not waste items or mutate persistence")
	result = life.action("life_consume", {"item":"spare_parts", "nutrition":100}, sim, "player", Vector3.ZERO, 400.0)
	_check(not result.ok and JSON.stringify([life.state, sim.state]) == before, "payload cannot turn arbitrary goods into food")
	result = life.action("life_consume", {"item":"banana"}, sim, "player", Vector3.ZERO, 9000.0)
	_check(not result.ok and JSON.stringify([life.state, sim.state]) == before, "forged future time fails atomically")
	result = life.action("life_consume", {"item":"meal"}, sim, "player", Vector3.ZERO, 400.0)
	_check(not result.ok and JSON.stringify([life.state, sim.state]) == before, "missing food cannot be consumed or minted")
	_check(sim.validate_state(sim.state), "ordinary frontier validation accepts the consumption and money ledgers")


func _rest() -> void:
	var life = _resident()
	var sim = _world()
	life.state.player.rest = 30.0
	var context := {"bed":{"building":"village-cottage", "position":Vector3.ZERO, "owner":"player", "residential":true}}
	var payload := {"building":"village-cottage"}
	var before := JSON.stringify(life.state)
	var result: Dictionary = life.action("life_rest", payload, sim, "player", Vector3(30,0,0), 400.0, context)
	_check(not result.ok and JSON.stringify(life.state) == before, "remote bed rest denied without state change")
	result = life.action("life_rest", {"building":"village-cottage", "bed":context.bed}, sim, "player", Vector3.ZERO, 400.0)
	_check(not result.ok, "client-supplied bed metadata is not authority")
	var wrong_owner: Dictionary = context.duplicate(true)
	wrong_owner.bed.owner = "someone_else"
	_check(not life.action("life_rest", payload, sim, "player", Vector3.ZERO, 400.0, wrong_owner).ok,
		"another resident's bed cannot restore the actor")
	result = life.action("life_rest", payload, sim, "player", Vector3.ZERO, 400.0, context)
	_check(result.ok and life.view("player").resting and life.state.player.rest == 30.0, "bed action starts a timed rest rather than an instant refill")
	life.advance("player", 5.0, Vector3.ZERO, 405.0, context)
	_check(float(life.state.player.rest) > 49.0, "remaining physically beside owned bed restores rest during active time")
	var rested := float(life.state.player.rest)
	life.advance("player", 5.0, Vector3(10,0,0), 410.0, context)
	_check(not life.view("player").resting and float(life.state.player.rest) < rested, "walking away cancels rest and prevents remote recovery")
	sim.state.time = 420.0
	life.action("life_rest", payload, sim, "player", Vector3.ZERO, 420.0, context)
	rested = float(life.state.player.rest)
	life.advance("player", 1.0, Vector3.ZERO, 9999.0, context)
	_check(not life.view("player").resting and float(life.state.player.rest) < rested, "expired rest does not credit offline recovery")
	_check(Life.valid(life.state), "rest lifecycle stays persistable")


func _shared_inventory() -> void:
	var sim = _world()
	var first := "member_" + "a".repeat(64)
	var second := "member_" + "b".repeat(64)
	var members := {
		first:{"credits":100, "inventories":{"earth":{"banana":2,"water":2}, "moon":{}}},
		second:{"credits":100, "inventories":{"earth":{"banana":2,"water":2}, "moon":{}}},
	}
	sim.configure_shared_players(members)
	var life = Life.new()
	var result: Dictionary = life.action("life_consume", {"item":"banana"}, sim, first, Vector3.ZERO, 400.0)
	_check(result.ok and members[first].inventories.earth.banana == 1 and members[second].inventories.earth.banana == 2,
		"online resident eats only from its attached shared inventory")
	_check(life.state.has(first) and not life.state.has(second) and life.view(second).nutrition == 80.0,
		"active resident needs and view do not allocate or change an unrelated member")
	var context := {"clinic":{"building":"clinic-1", "position":Vector3.ZERO, "kind":"clinic"}, "health":30.0}
	result = life.action("life_clinic", {"building":"clinic-1"}, sim, first, Vector3.ZERO, 400.0, context)
	_check(result.ok and members[first].credits == 100-Life.CLINIC_PRICE and members[second].credits == 100,
		"online clinic fee uses the actor's shared wallet without charging another member")


func _clinic() -> void:
	var life = _resident()
	var sim = _world()
	life.state.player.nutrition = 20.0
	life.state.player.hydration = 30.0
	life.state.player.rest = 40.0
	var context := {"clinic":{"building":"clinic-1", "position":Vector3.ZERO, "kind":"clinic"}, "health":30.0}
	var before := JSON.stringify([life.state, sim.state])
	_check(not life.action("life_clinic", {"building":"clinic-1"}, sim, "player", Vector3(50,0,0), 400.0, context).ok
		and JSON.stringify([life.state, sim.state]) == before, "clinic requires physical proximity before charging")
	_check(not life.action("life_clinic", {"building":"clinic-2"}, sim, "player", Vector3.ZERO, 400.0, context).ok,
		"clinic ID must match server-known service")
	var total := int(sim.total_money())
	var wallet := int(sim.balance("player"))
	var treasury := int(sim.balance("treasury"))
	var result: Dictionary = life.action("life_clinic", {"building":"clinic-1"}, sim, "player", Vector3.ZERO, 400.0, context)
	_check(result.ok and result.heal_to == 100.0 and life.state.player.nutrition == 70.0 and life.state.player.rest == 70.0,
		"clinic restores needs and returns an authoritative health effect")
	_check(sim.balance("player") == wallet - Life.CLINIC_PRICE and sim.balance("treasury") == treasury + Life.CLINIC_PRICE
		and sim.total_money() == total, "clinic fee transfers to treasury without minting or losing money")
	before = JSON.stringify([life.state,sim.state])
	_check(not life.action("life_clinic", {"building":"clinic-1"}, sim, "player", Vector3.ZERO, 400.0, context).ok
		and JSON.stringify([life.state,sim.state]) == before, "repeated treatment is rejected without duplicate fees")
	sim._transfer("player", "treasury", sim.balance("player"), "Test exhausted funds")
	sim.state.time = 440.0
	before = JSON.stringify([life.state,sim.state])
	_check(not life.action("life_clinic", {"building":"clinic-1"}, sim, "player", Vector3.ZERO, 440.0, context).ok
		and JSON.stringify([life.state,sim.state]) == before, "unfunded treatment leaves all state unchanged")
	_check(sim.validate_state(sim.state) and Life.valid(life.state), "clinic ledgers and resident state remain valid")
	var healthy = _resident()
	var funded_sim = _world()
	context.health = 100.0
	before = JSON.stringify([healthy.state,funded_sim.state])
	_check(not healthy.action("life_clinic", {"building":"clinic-1"}, funded_sim, "player", Vector3.ZERO, 400.0, context).ok
		and JSON.stringify([healthy.state,funded_sim.state]) == before, "known full health and adequate needs avoid unnecessary clinic charge")
	context.erase("health")
	_check(healthy.action("life_clinic", {"building":"clinic-1"}, funded_sim, "player", Vector3.ZERO, 400.0, context).ok,
		"unknown multiplayer combat health permits otherwise valid paid treatment")


func _careers() -> void:
	var life = _resident()
	var sim = _world()
	var total := int(sim.total_money())
	var wallet := int(sim.balance("player"))
	for index in range(1,4):
		var result: Dictionary = life.record_job("player", "city_job_%d" % index, "courier", 100, sim, 400.0)
		_check(result.ok and result.bonus == 0, "beginner courier job %d earns progress before pay tier unlock" % index)
	_check(life.view("player").career_rows[0].level == 2 and life.view("player").career_rows[0].bonus_percent == 5,
		"three completed courier jobs unlock a persistent five-percent pay tier")
	var result: Dictionary = life.record_job("player", "city_job_4", "courier", 100, sim, 400.0)
	_check(result.ok and result.bonus == 5 and sim.balance("player") == wallet + 5 and sim.total_money() == total,
		"experienced work receives a real treasury-funded bonus with conserved total money")
	var before := JSON.stringify([life.state,sim.state])
	_check(not life.record_job("player", "city_job_4", "courier", 100, sim, 400.0).ok
		and JSON.stringify([life.state,sim.state]) == before, "replayed completion cannot duplicate progress or money")
	result = life.record_job("player", "city_job_5", "courier", 100, sim, 400.0, sim.balance("treasury"))
	_check(result.ok and result.bonus == 0 and result.bonus_unfunded and life.state.player.careers.courier == 5,
		"committed city payroll is protected while career progress still advances")
	var restored = Life.new()
	_check(restored.import_state(JSON.parse_string(JSON.stringify(life.state)))
		and not restored.record_job("player", "city_job_3", "courier", 100, sim, 400.0).ok,
		"completion deduplication survives save/load")
	result = life.record_job("player", "city_job_6", "maintenance", 105, sim, 400.0)
	_check(result.ok and result.bonus == 0 and life.state.player.careers.maintenance == 1
		and life.state.player.careers.courier == 5, "legal careers progress independently")
	_check(not life.record_job("player", "city_job_7", "invented", 100, sim, 400.0).ok,
		"unknown career cannot manufacture a funded reward")
	_check(sim.validate_state(sim.state) and Life.valid(life.state), "career transactions preserve simulation validation")


func _panel() -> void:
	var life = _resident()
	var mock := FakeController.new()
	add_child(mock)
	mock.snapshot = {"resident_life":life.view("player"), "backpack_counts":{"banana":2,"water":1}}
	var host := VBoxContainer.new()
	add_child(host)
	var panel = LifePanel.build(host, mock, mock.snapshot, {"kind":"info"})
	_check(panel._food.get_child_count() == 2 and "Food 80%" in panel._needs.text, "life panel exposes real available food, water and needs")
	panel._food.get_child(0).pressed.emit()
	_check(mock.requests.size() == 1 and mock.requests[0].kind == "life_consume"
		and mock.requests[0].payload.item == "banana", "food button submits a concrete city authority action")
	mock.snapshot.action_pending = true
	panel.refresh(mock.snapshot)
	_check(panel._food.get_child(0).disabled and panel._food.get_child(1).disabled, "pending authority request disables duplicate life buttons")
	panel.refresh({})
	_check(not panel.visible, "life card waits for the first authoritative resident view")
	panel._process(0.5)
	_check(panel.visible, "initially hidden life card appears when its network snapshot arrives")
	host.free()
	mock.free()
