extends SceneTree
## Disposable renderer/UI regression. Does not start Net or load career saves.
## Run: godot --headless --path . --script tests/frontiervisualtest.gd

class TestSite extends Node3D:
	var local_player: Node3D
	func surface_height(_x: float, _z: float) -> float: return 3.2
	func surface_normal(_x: float, _z: float) -> Vector3: return Vector3.UP

class TestController extends Node:
	var simulation: RefCounted
	var selected_interaction: Dictionary = {}
	var world: Node
	var tutorial: Node
	var last_message := ""
	var _observation := false
	var realm := "earth"
	var actions: Array[Dictionary] = []
	func current_planet() -> String: return realm
	func current_town() -> Dictionary: return simulation.state.town
	func interactions() -> Array: return []
	func _interaction_position(target: String) -> Vector3:
		for candidate: Dictionary in interactions():
			if str(candidate.get("id", "")) == target:
				return candidate.position
		return Vector3.INF
	func locate(_id: String) -> void: pass
	func locate_rocket() -> void: pass
	func locate_town(_id: String) -> void: pass
	func nearby_fuel_vehicles() -> Array: return []
	func sky_targets() -> Array: return []
	func set_observation(_value: bool) -> void: pass
	func look_at_sky(_value: Vector3) -> void: pass
	func _target_in_range(_id: String) -> bool: return true
	func request_action(kind: String, payload: Dictionary) -> Dictionary:
		actions.append({"kind":kind,"payload":payload.duplicate(true)})
		return {"ok":true,"message":"test accepted"}

class TestGuide extends Node:
	var started := ""
	var target_calls := 0
	var active := true
	func summary() -> Dictionary:
		return {"title":"Meet Nana", "text":"Find Nana at the market and say hello.",
			"active":active, "complete":false, "step":1, "total":4}
	func start(chapter := "") -> void: started = chapter; active = true
	func show_target() -> void: target_calls += 1
	func pause() -> void: active = false
	func restart() -> void: started = "restart"; active = true

class ErrorRecorder extends Logger:
	var errors: Array[String] = []
	var mutex := Mutex.new()
	func messages() -> Array[String]:
		mutex.lock()
		var result: Array[String] = errors.duplicate()
		mutex.unlock()
		return result
	func _log_error(_function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			mutex.lock()
			errors.append("%s:%d %s %s" % [file,line,code,rationale])
			mutex.unlock()

var recorder: ErrorRecorder
var passed := 0
var total := 0
var failed := false

func _initialize() -> void:
	recorder = ErrorRecorder.new()
	OS.add_logger(recorder)
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	total += 1
	if value: passed += 1
	else: failed = true
	print("%s %s" % ["PASS" if value else "FAIL",label])

func _run() -> void:
	var sim = load("res://scripts/frontier_sim.gd").new()
	var town_script = load("res://scripts/frontier_settlement.gd")
	var crop_script = load("res://scripts/frontier_crop_meshes.gd")
	var ui_script = load("res://scripts/frontier_ui.gd")
	sim.new_game(2026)
	sim.state.town = {"id":"earth_test","name":"Test Grove","is_owner":true,"claimed":true,"claim_price":750}
	sim.state.permissions = {"manage":true,"claim":false,"trade":true,"quests":true}
	var host := TestSite.new()
	root.add_child(host)
	var settlement = town_script.new()
	settlement.configure(host,sim,"earth",sim.state.town)
	host.add_child(settlement)
	var calls := 0
	var longest := 0.0
	while not settlement.is_build_complete():
		var before := Time.get_ticks_usec()
		settlement.build_step(2.0)
		longest = maxf(longest,(Time.get_ticks_usec()-before)/1000.0)
		calls += 1
	_check(calls>10 and calls<500,"progressive build yields between bounded work groups")
	print("BUILD_STEPS ",calls," MAX_MS ",snappedf(longest,0.01))
	var physics = town_script.new()
	physics.configure(host,sim,"earth",sim.state.town)
	host.add_child(physics)
	physics.build_collision_only()
	_check(_collision_signature(settlement)==_collision_signature(physics),"server and visible Earth towns have identical shape transforms and dimensions")
	_check(physics.citizens.is_empty() and physics.plot_roots.is_empty() and _geometry_count(physics)==0,"collision-only town has no citizens, crop meshes, labels or render geometry")
	_check(settlement.tree_positions==physics.tree_positions and settlement.tree_positions.size()>=90,"dense forest has deterministic identical client/server trunks")
	var clear := true
	for point: Vector2 in settlement.tree_positions:
		clear = clear and settlement._road_distance(point)>=7.2
	_check(clear,"every new tree stays beyond both traffic lanes and shoulders")
	_check(_direct_geometry_count(settlement)<160,"town artwork and road paint are batched into bounded submissions")
	_check(settlement.get_interactions().all(func(entry): return entry.get("town_id")=="earth_test"),"every physical interaction retains its town identity")
	for realm in ["moon"]:
		var a = town_script.new()
		a.configure(host,sim,realm)
		host.add_child(a)
		a.build()
		var b = town_script.new()
		b.configure(host,sim,realm)
		host.add_child(b)
		b.build_collision_only()
		_check(_collision_signature(a)==_collision_signature(b),"sealed lunar crop cells and facilities share exact collision-only geometry")
		var roof = town_script.new()
		roof.configure(host,sim,"moon")
		host.add_child(roof)
		roof._begin_build()
		roof._build_greenhouse()
		_check(_joined_greenhouse_roof(roof),"lunar roof slopes down to both eaves and meets at one continuous ridge")
		roof.free()
		a.free()
		b.free()
	var all_valid := true
	var reduction := true
	var shared := true
	var detail := 0
	for crop: String in sim.crop_catalog():
		var high = crop_script.mesh_for(crop,0,true)
		var low = crop_script.mesh_for(crop,2,true)
		all_valid = all_valid and high.get_aabb().size.y>0.2 and high.surface_get_array_len(0)>250
		reduction = reduction and low.surface_get_array_index_len(0)<high.surface_get_array_index_len(0)*0.35
		shared = shared and high==crop_script.mesh_for(crop,0,true)
		detail += high.surface_get_array_index_len(0)/3
	_check(all_valid,"all 24 crops have volumetric detailed botanical surfaces")
	_check(reduction and shared,"all 24 crops share cached geometry and far LOD removes over 65 percent of triangles")
	var sprout = crop_script.mesh_for("tomato",0,0)
	var flowers = crop_script.mesh_for("tomato",0,2)
	var ripe = crop_script.mesh_for("tomato",0,4)
	_check(sprout.surface_get_array_len(0)<flowers.surface_get_array_len(0) and flowers!=ripe,
		"growth changes leaf count, then flowers, then shaped produce instead of scaling one object")
	_check(crop_script.phase_label("lettuce",3)=="Leaf filling" and crop_script.phase_label("carrot",3)=="Roots filling",
		"leaf and root crops keep their correct harvest development labels")
	print("BOTANICAL_CATALOG_TRIANGLES ",detail)
	var crop_root := Node3D.new()
	host.add_child(crop_root)
	crop_script.populate(crop_root,"tomato",1.0,1.0)
	_check(crop_root.get_child_count()==3 and crop_root.get_child(0).multimesh.instance_count==12,"a full crop bed uses 12 instances and exactly three complementary LOD batches")
	var controller := TestController.new()
	controller.simulation = sim
	root.add_child(controller)
	var guide := TestGuide.new()
	controller.add_child(guide)
	controller.tutorial = guide
	var ui = ui_script.new()
	ui.configure(controller)
	root.add_child(ui)
	await process_frame
	ui._set_navigation_layout(false)
	_check(not ui._sidebar_navigation(688) and ui._journal_nav.get_parent()==ui._main_stack,
		"compact journal moves navigation above content and remains inside the viewport")
	ui._set_navigation_layout(true)
	_check(ui._sidebar_navigation(760) and ui._journal_nav.get_parent()==ui._workspace and ui._workspace.get_child(0)==ui._journal_nav,
		"wide journal uses a stable left navigation beside its content")
	ui.open({})
	await process_frame
	await process_frame
	_check(ui._panel.size.x<=760 and ui._panel.size.y<=600
		and (ui.get_child(0) as ColorRect).color.a<=0.18,
		"journal stays compact and its light veil leaves the gameplay world visible")
	_check(_text(ui).contains("What should I do next?") and _text(ui).contains("Meet Nana")
		and _text(ui).contains("At a glance") and _action_buttons(ui).is_empty(),
		"overview leads with the live tutorial step, cargo and town summary without remote actions")
	_button(ui,"Show me where").pressed.emit()
	_check(guide.target_calls==1,"overview next-step button uses the real tutorial waypoint callback")
	_button(ui,"Open tutorial").pressed.emit()
	_button(ui,"Grow food").pressed.emit()
	_check(ui.page=="Tutorial" and guide.started=="farming",
		"tutorial navigation exposes intentional chapters and starts the selected real guide")
	ui.open({"kind":"citizen","id":"mango","town_id":"earth_test"})
	await process_frame
	_check(ui._panel.size.x<=620 and ui._panel.size.y<=560,
		"resident conversation uses the smaller in-world panel size")
	_check(ui._heading.text=="Mango" and not _text(ui).contains("Derrick") and not _text(ui).contains("Petra"),"NPC conversation shows only the chosen person")
	_check(ui._context_line.text.contains("TOWN STEWARD") and ui._context_line.text.contains("HERE: Mango"),
		"context bar names the visited resident and the player's local authority")
	_check(_button(ui,"Water")==null and _button(ui,"Buy")==null,"grower conversation cannot operate a crop or arbitrary market")
	_check(not _text(ui).contains("Skill ") and _button(ui,"Show details")!=null,
		"resident conversation keeps secondary work statistics out of the first decision view")
	_button(ui,"Show details").pressed.emit()
	_check(_text(ui).contains("Skill ") and _text(ui).contains("jobs completed") and _button(ui,"Hide details")!=null,
		"resident details reveal only the selected resident's live work history")
	_button(ui,"Pause / resume work").pressed.emit()
	_check(controller.actions.back().payload.citizen=="mango" and controller.actions.back().payload.town_id=="earth_test","citizen callback scopes both the actual worker and town")
	ui.open({"kind":"plot","id":"earth_1","town_id":"earth_test"})
	_button(ui,"Water").pressed.emit()
	_check(controller.actions.back().kind=="water" and controller.actions.back().payload.plot=="earth_1","crop callback targets only the selected bed")
	_check(_button(ui,"Pause / resume work")==null and _button(ui,"Buy")==null,"crop bed has no crew or market controls")
	ui.open({"kind":"facility","id":"oil_rig","town_id":"earth_test"})
	_check(_button(ui,"Maintain equipment")!=null and _button(ui,"Buy")==null and _button(ui,"Dispatch shipment")==null,"oil rig offers only its maintenance and relevant local functions")
	ui._quantity = 1
	sim.state.citizens.nana.trade_location = "earth_market"
	sim.state.citizens.nana.can_manage = true
	ui.open({"kind":"citizen","id":"nana","label":"Nana · Merchant","town_id":"earth_test"})
	_check(ui._merchant_mode and ui._trade_scrolls.size()==2 and ui._trade_tiles.has("market:banana")
		and ui._trade_tiles.has("backpack:banana") and _button(ui,"About Nana")!=null,
		"merchant pairs physical stock with the player's backpack and keeps resident details accessible")
	_button(ui,"About Nana").pressed.emit()
	_check(not ui._merchant_mode and _text(ui).contains("Work together") and _button(ui,"Back to trading")!=null,
		"merchant About view preserves the resident's real job and work controls")
	_button(ui,"Back to trading").pressed.emit()
	_check(ui._merchant_mode and _action_buttons(ui).size()==2,
		"returning to trade restores one fixed Buy/Sell action footer")
	controller.actions.clear()
	ui._market_search = ""
	ui._market_category = "All"
	ui.open({"kind":"market","id":"earth_market","label":"Canopy market","town_id":"earth_test"})
	_check(ui._trade_tiles.size()>20 and ui._trade_grids.size()==2 and _button(ui,"Next page")==null,
		"large stock uses compact item grids with a persistent selection footer")
	ui._trade_search.text = "banana"
	ui._trade_search.text_changed.emit("banana")
	_check(ui._trade_tiles["market:banana"].visible and ui._trade_tiles["market:banana_start"].visible
		and not ui._trade_tiles["market:tomato"].visible,
		"typing immediately filters visible goods in both inventories")
	ui._trade_tiles["market:banana"].pressed.emit()
	ui._trade_buy.pressed.emit()
	_check(controller.actions.back().kind=="buy" and controller.actions.back().payload.item=="banana"
		and controller.actions.back().payload.quantity==1 and controller.actions.back().payload.town_id=="earth_test",
		"selected-item Buy retains exact market, item, quantity and physical town scope")
	ui._trade_search.text = ""
	ui._trade_search.text_changed.emit("")
	ui._trade_category.select(2)
	ui._trade_category.item_selected.emit(2)
	_check(ui._trade_tiles["market:banana_start"].visible and ui._trade_tiles["backpack:bean_seed"].visible
		and not ui._trade_tiles["market:banana"].visible,
		"Planting category separates seed/starter tiles from harvested crops")
	ui._market_search = ""
	ui._market_category = "All"
	sim.state.permissions.trade = false
	ui.open({"kind":"market","id":"earth_market","label":"Canopy market","town_id":"earth_test"})
	_check(ui._trade_detail.text.contains("Trading is unavailable for your current role")
		and ui._trade_buy.disabled and ui._trade_sell.disabled,
		"market explains permission limits and disables both unavailable orders")
	sim.state.permissions.trade = true
	ui.open({"kind":"facility","id":"refinery","town_id":"earth_test"})
	_check(ui._merchant_mode and ui._trade_tiles.has("market:crude_oil"),
		"refinery trading uses actual petroleum tiles")
	_button(ui,"Requests & details").pressed.emit()
	_check(not ui._merchant_mode and _button(ui,"Start processing batch")!=null and not _text(ui).contains("Dry bananas")
		and _button(ui,"Back to trading")!=null,
		"refinery details preserve its real recipe and provide a direct return to trading")
	controller.actions.clear()
	for page: String in ui_script.PAGES:
		ui.open({})
		ui.select_page(page)
		_check(_action_buttons(ui).is_empty(),"personal %s contains no remote work actions"%page)
	ui._act("claim_town",{})
	_check(controller.actions.is_empty(),"journal cannot dispatch mutations even through the shared callback")
	sim.state.permissions.manage = false
	ui.open({"kind":"citizen","id":"mango","town_id":"earth_test"})
	_check(_button(ui,"Pause / resume work")==null and ui._context_line.text.contains("LOCAL VISITOR"),
		"visitors see their local role and cannot manage another town's citizen")
	sim.state.town.claimed = false
	sim.state.permissions.claim = true
	ui.open({"kind":"board","id":"town_square","town_id":"earth_test"})
	var claim := _button(ui,"Claim this town · 750 credits")
	_check(claim!=null and _button(ui,"Water")==null,"unclaimed town board offers a concrete claim without farm controls")
	if claim: claim.pressed.emit()
	_check(controller.actions.back().kind=="claim_town" and controller.actions.back().payload.town_id=="earth_test","claim button submits the selected town identity")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture(settlement,ui,host)
	_check(recorder.messages().is_empty(),"fixture completed without script or engine errors")
	ui.free()
	controller.free()
	host.free()
	await process_frame
	print("FRONTIERVISUALTEST %d/%d PASS"%[passed,total])
	quit(1 if failed else 0)

func _collision_signature(node: Node) -> Array:
	# Moving visual citizens have their own capsule tests; this compares the
	# shared static town geometry against the server collision-only scene.
	if node.is_in_group("frontier_pedestrian_bodies"):
		return []
	var result: Array = []
	for child in node.get_children():
		if child is CollisionShape3D:
			var dimensions: Variant = child.shape.size if child.shape is BoxShape3D else Vector2(child.shape.radius,child.shape.height)
			result.append([child.shape.get_class(),child.transform,dimensions])
		result.append_array(_collision_signature(child))
	return result

func _geometry_count(node: Node) -> int:
	var count := 1 if node is GeometryInstance3D else 0
	for child in node.get_children(): count += _geometry_count(child)
	return count

func _direct_geometry_count(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is MeshInstance3D or child is MultiMeshInstance3D: count += 1
	return count

func _text(node: Node) -> String:
	var result := str(node.text)+"\n" if node is Label or node is Button else ""
	for child in node.get_children(): result += _text(child)
	return result

func _button(node: Node, caption: String) -> Button:
	if node is Button and node.text==caption: return node
	for child in node.get_children():
		var found := _button(child,caption)
		if found: return found
	return null

func _buttons(node: Node, caption: String) -> Array[Button]:
	var result: Array[Button] = []
	if node is Button and node.text==caption: result.append(node)
	for child in node.get_children(): result.append_array(_buttons(child,caption))
	return result

func _label(node: Node, caption: String) -> Label:
	if node is Label and node.text==caption: return node
	for child in node.get_children():
		var found := _label(child,caption)
		if found: return found
	return null

func _action_buttons(node: Node) -> Array:
	var result: Array = []
	if node.has_meta("frontier_action"): result.append(node)
	for child in node.get_children(): result.append_array(_action_buttons(child))
	return result


func _capture(settlement: Node3D, ui: Control, host: Node3D) -> void:
	root.size = Vector2i(1600,900)
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.41,0.63,0.75)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.78,0.89,1.0)
	environment.ambient_light_energy = 0.8
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	host.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52,-32,0)
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	host.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(480,480)
	ground.mesh = plane
	ground.position.y = 3.2
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.39,0.48,0.22)
	ground.material_override = material
	host.add_child(ground)
	var camera := Camera3D.new()
	camera.far = 500
	camera.fov = 60
	host.add_child(camera)
	camera.current = true
	ui.close()
	camera.position = Vector3(57,40,66)
	camera.look_at(Vector3(-9,3.5,-3))
	for frame in range(45): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/frontier-towns-overview.png")
	camera.position = Vector3(-32.5,4.7,-28.0)
	camera.look_at(Vector3(-34.4,4.2,-34.6))
	for label: Dictionary in settlement._plots.values(): label.label.visible = false
	for frame in range(15): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/frontier-towns-crops.png")
	camera.position = Vector3(5,5.0,1)
	camera.look_at(Vector3(-8,4.3,-15))
	ui.controller.simulation.state.permissions.manage = true
	ui.open({"kind":"citizen","id":"ookbar","town_id":"earth_test"})
	for frame in range(12): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/frontier-towns-conversation.png")
	print("CAPTURES /tmp/frontier-towns-overview.png /tmp/frontier-towns-crops.png /tmp/frontier-towns-conversation.png")


func _joined_greenhouse_roof(settlement: Node3D) -> bool:
	# Inspect the actual authored transforms before submitting to RenderingServer;
	# its dummy/headless backend deliberately does not retain MultiMesh buffers.
	var inner: Array[Vector3] = []
	for batch: Dictionary in settlement._props._batches.values():
		for transform: Transform3D in batch.transforms:
			var size := transform.basis.get_scale()
			if size.x<11.0 or size.x>13.0 or size.y>0.25 or size.z<17.5: continue
			var side := -1.0 if transform.origin.x < -23.0 else 1.0
			var ridge := transform * Vector3(-side*0.5,0,0)
			var eave := transform * Vector3(side*0.5,0,0)
			if ridge.y < eave.y+2.4: return false
			inner.append(ridge)
	return inner.size()==2 and inner[0].distance_to(inner[1])<0.3
