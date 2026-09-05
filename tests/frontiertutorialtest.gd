extends SceneTree
## Guided progress observes successful gameplay and resumes without economy edits.
class Journal extends Control:
	func close() -> void: hide()
class Host extends Node:
	var simulation: RefCounted
	var owner_main: Node
	var ui := Journal.new()
	var waypoint := {}
	var owns_town := false
	var planet := "earth"
	func current_town() -> Dictionary: return {"is_owner":owns_town}
	func current_planet() -> String: return planet
	func interactions() -> Array: return [{"id":"nana","position":Vector3(0,0,-15)}, {"id":"town_square","position":Vector3(4,0,0)}]

var checks := 0
var passed := 0
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("TUTORIAL %s %s" % ["OK" if ok else "FAIL",label])
func _run() -> void:
	var host := Host.new()
	root.add_child(host)
	host.add_child(host.ui)
	host.simulation = load("res://scripts/frontier_sim.gd").new()
	host.simulation.new_game(2026)
	var guide = load("res://scripts/frontier_tutorial.gd").new()
	host.add_child(guide)
	var canvas := CanvasLayer.new()
	host.add_child(canvas)
	host.ui.hide()
	guide.configure(host, canvas, "user://frontier/tests/tutorial-%d.cfg" % OS.get_process_id())
	guide._panel.hide()
	guide._refresh_card()
	check(guide._panel.visible and guide._title.text.contains("Meet Nana"),
		"a host without optional city support refreshes the actual tutorial card")
	host.ui.show()
	guide._refresh_card()
	check(not guide._panel.visible, "opening the journal still hides the optional tutorial card")
	host.ui.hide()
	var before: Dictionary = host.simulation.state.duplicate(true)
	guide.observe_interaction("ookbar")
	check(guide.step == 0, "unrelated NPC cannot complete the merchant lesson")
	guide.observe_interaction("nana")
	check(guide.step == 1, "meeting the actual merchant advances the guide")
	guide.observe_action("buy", {"item":"banana"}, {"ok":false})
	guide.observe_action("buy", {"item":"water"}, {"ok":true})
	check(guide.step == 1, "failed and unrelated purchases never complete the lesson")
	var bought: Dictionary = host.simulation.action("buy", {"market":"earth_market","item":"banana","quantity":1})
	guide.observe_action("buy", {"item":"banana"}, bought)
	check(bought.ok and guide.step == 2, "real successful purchase progresses tutorial")
	guide.observe_interaction("town_square")
	var accepted: Dictionary = host.simulation.action("accept_quest", {"id":"first_harvest"})
	guide.observe_action("accept_quest", {"id":"first_harvest"}, accepted)
	check(accepted.ok and guide.step == 4, "real funded contract acceptance advances")
	var delivered: Dictionary = host.simulation.action("deliver_quest", {"id":"first_harvest"})
	guide.observe_action("deliver_quest", {"id":"first_harvest"}, delivered)
	check(delivered.ok and guide.complete and not guide.active, "real delivery finishes first-day lesson")
	var economy: Dictionary = host.simulation.state.duplicate(true)
	var resumed = load("res://scripts/frontier_tutorial.gd").new()
	host.add_child(resumed)
	resumed.controller = host
	resumed.path = guide.path
	resumed._load_progress()
	check(resumed.complete and resumed.step == 5, "tutorial completion survives save and resume")
	resumed.restart()
	check(resumed.step == 0 and resumed.active and host.simulation.state == economy,
		"replay starts lesson without resetting money bags quests or crops")
	resumed.pause()
	resumed.observe_interaction("nana")
	check(resumed.step == 0 and not resumed.active, "paused tutorial never consumes progress events")
	resumed.chapter = "farming"
	resumed.active = true
	resumed.step = 0
	resumed._skip_existing_progress()
	check(resumed.step == 0, "visiting another player's town does not count as ownership")
	host.owns_town = true
	resumed._skip_existing_progress()
	check(resumed.step == 1, "existing town owner can resume farming without a second claim")
	resumed.observe_action("plant", {"plot":"earth_4"}, {"ok":true})
	resumed.observe_action("water", {"plot":"earth_5"}, {"ok":true})
	check(resumed.step == 2, "lesson keeps the exact planted bed as its watering target")
	resumed.observe_action("water", {"plot":"earth_4"}, {"ok":true})
	check(resumed.step == 3, "watering chosen bed advances to growth and harvest")
	check(before != host.simulation.state and host.simulation.total_money() == int(before.initial_money),
		"only actual trade and contract operations changed the finite economy")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(guide.path))
	host.queue_free()
	await process_frame
	print("FRONTIERTUTORIAL %d/%d %s" % [passed,checks,"PASS" if passed==checks else "FAIL"])
	quit(0 if checks==passed else 1)
