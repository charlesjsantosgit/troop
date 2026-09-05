extends SceneTree
## Isolated real ENet driver / observer / late-join regression.
const JET_A := "v:admin#1-901"
const JET_B := "v:admin#1-902"
const AT := Vector3(3000,1000,0)
var role := ""
var directory := ""
var net: Node
var world: Node3D
var jets: Dictionary = {}
var events: Dictionary = {}
var passed := 0
var checks := 0
var done := false
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, label: String) -> void:
	checks+=1
	if ok:passed+=1
	print("VEHICLECRASHNET ",role," ","PASS " if ok else "FAIL ",label)
func _run() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.size()!=3:quit(2);return
	role=args[0];directory=args[2]
	if role not in ["server","driver","observer","late"] or not directory.is_absolute_path() or not directory.get_file().begins_with("troop-vehicle-crash-"):quit(2);return
	ProjectSettings.set_setting("application/config/use_custom_user_dir",true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",directory.get_file()+"-"+role)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	for key in ["TROOP_ADMIN_KEY","TROOP_ADMIN_TOKEN","TROOP_STATE_DIR"]:OS.unset_environment(key)
	net=root.get_node("Net")
	create_timer(90).timeout.connect(func():check(false,"fixture deadline");_finish())
	if role=="server":await _server(int(args[1]));return
	check(net.join("127.0.0.1","Crash-"+role,int(args[1]))==OK,"authenticated ENet connection starts")
	var deadline:=Time.get_ticks_msec()+18000
	while (not net.names.has(net.local_id()) or net.frontier_network.views.size()<6) and Time.get_ticks_msec()<deadline:await process_frame
	check(net.names.has(net.local_id()) and net.frontier_network.views.size()==6,"registered identity and ordinary world bootstrap complete")
	world=load("res://scripts/world.gd").new()
	world.name="CrashReplicaWorld"
	root.add_child(world)
	world.set_process(false);world.set_physics_process(false)
	net.vehicle_crash_changed.connect(world._on_vehicle_crash_changed)
	net.vehicle_crash_changed.connect(func(id,_row,animate):if animate:events[id]=int(events.get(id,0))+1)
	if role=="late":
		await _late();return
	for id in [JET_A,JET_B]:_spawn(id)
	if role=="driver":await _driver()
	else:await _observer()
func _server(port:int)->void:
	OS.set_environment("TROOP_STATE_DIR",directory.path_join("state"))
	check(net.start_dedicated(2026,port,"127.0.0.1")==OK,"isolated dedicated authority starts")
	check(net._bind_admin_vehicle_kind(1,JET_A,3,AT,0.0) and net._bind_admin_vehicle_kind(1,JET_B,3,AT+Vector3.RIGHT*40,0.0),"authority registers two immutable aircraft identities")
	_write("ready")
	while not FileAccess.file_exists(directory.path_join("stop")):
		if FileAccess.file_exists(directory.path_join("attack-done")) and not FileAccess.file_exists(directory.path_join("attack-verified")):
			check(net.vehicle_crashes.is_empty(),"registered outsider cannot damage another driver's claimed aircraft")
			_write("attack-verified")
		if FileAccess.file_exists(directory.path_join("driver-done")) and not FileAccess.file_exists(directory.path_join("server-wrecks")):
			check(net.vehicle_crashes.size()==2 and net.vehicle_crashes[JET_A].wrecked and net.vehicle_crashes[JET_B].wrecked,"authority retains both wrecks after state and fatal-release updates")
			check(not net.claimed_vehicles.has(JET_A) and not net.claimed_vehicles.has(JET_B),"reliable ejection releases both seats without erasing wreck state")
			var prior=net.vehicle_crashes.duplicate(true)
			var row:Dictionary=prior[JET_A]
			for index in range(97):net.vehicle_crashes["v:snapshot#"+str(index)]=row
			var pages:Array=net.vehicle_crash_snapshot_pages()
			check(pages.size()>=4 and pages.all(func(page):return page.size()<=32 and var_to_bytes(page).size()<=net.MAX_CRASH_PAGE_BYTES),"late-join snapshots split into bounded sixteen-kilobyte pages")
			net.vehicle_crashes=prior
			_write("server-wrecks")
		await create_timer(.04).timeout
	check(net.vehicle_crashes.size()==2,"disconnect and late join preserve stable wreck identities")
	net.shutdown()
	check(net.vehicle_crashes.is_empty() and net._vehicle_crash_live.is_empty(),"session shutdown clears damage and one-shot event state")
	_finish()
func _spawn(id:String)->Node:
	var node:Node=world.spawn_vehicle(3,id,AT+(Vector3.RIGHT*40 if id==JET_B else Vector3.ZERO),0.0)
	node.freeze=true;node.set_physics_process(false)
	node.global_position=AT+(Vector3.RIGHT*40 if id==JET_B else Vector3.ZERO)
	jets[id]=node
	return node
func _packet(id:String,crash:Dictionary)->void:
	var jet:Node=jets[id]
	net.send_state(jet.seat_global(),0.0,Vector3.ZERO,12,false,Vector3.ZERO,0.0,PackedVector3Array(),0,true,false,0,false,0.0,false,3,id,Vector3.ZERO,crash)
func _position(at:Vector3)->void:
	for frame in range(4):
		net.send_state(at,0.0,Vector3.ZERO,0,false,Vector3.ZERO,0.0,PackedVector3Array(),0,true,false,0,false,0.0)
		await create_timer(.06).timeout
func _claim(id:String)->void:
	await _position(jets[id].global_position)
	check(net.request_vehicle(id,1),"seat request uses the ordinary vehicle claim path")
	var deadline:=Time.get_ticks_msec()+5000
	while int(net.claimed_vehicles.get(id,0))!=net.local_id() and Time.get_ticks_msec()<deadline:await process_frame
	check(int(net.claimed_vehicles.get(id,0))==net.local_id(),"authority grants this registered driver the exact aircraft")
func _driver()->void:
	await _wait_file("observer-ready")
	await _claim(JET_A)
	_write("claimed")
	await _wait_file("attack-verified")
	var jet:Node=jets[JET_A]
	jet.report_collision_impact(jet.global_position+Vector3(0,0,7),Vector3.BACK,20)
	var damage:Dictionary=jet.crash_state()
	check(damage.damage>0 and not damage.wrecked,"moderate real collision produces compact damage metadata")
	for index in range(4):_packet(JET_A,damage);await create_timer(.06).timeout
	await _wait_damage(JET_A,false)
	check(net.vehicle_crashes.has(JET_A) and not net.vehicle_crashes[JET_A].wrecked,"owner's ordinary movement packet replicates damage through authority")
	var revision:int=net.vehicle_crashes[JET_A].revision
	jet.global_position.x+=100
	check(jet.crash_state()==damage and net._valid_vehicle_crash_payload(jet.crash_state(),3),"contact coordinates stay stable after the damaged aircraft moves")
	_packet(JET_A,damage)
	await create_timer(.15).timeout
	var healing:=damage.duplicate();healing.damage=1
	_packet(JET_A,healing)
	await create_timer(.15).timeout
	check(net.vehicle_crashes[JET_A].damage==damage.damage and net.vehicle_crashes[JET_A].revision==revision,"replays and client healing cannot decrease damage or replay a crash")
	var malformed:Array=[{"damage":-1},damage.merged({"point":Vector3(10000,0,0)},true),damage.merged({"normal":Vector3.ZERO},true),damage.merged({"speed":NAN},true),damage.merged({"extra":"x".repeat(600)},true)]
	for payload:Dictionary in malformed:_packet(JET_A,payload);await create_timer(.06).timeout
	check(net.vehicle_crashes[JET_A].revision==revision,"malformed, distant, nonfinite and oversized crash data cannot change authority state")
	jet._impact_cooldown=-100
	jet.report_collision_impact(jet.global_position+Vector3(0,0,7),Vector3.BACK,620)
	net.release_vehicle(JET_A,[jet.global_position,0.0,0.0,0.0],jet.crash_state())
	await _wait_damage(JET_A,true)
	check(net.vehicle_crashes[JET_A].wrecked and net.vehicle_crashes[JET_A].speed==400.0,"fatal reliable release delivers an extreme closing-speed wreck within the bounded payload before any later twenty-hertz state")
	await _claim(JET_B)
	var other:Node=jets[JET_B]
	other.report_collision_impact(other.global_position,Vector3.UP,80)
	for index in range(3):_packet(JET_B,other.crash_state());await create_timer(.06).timeout
	await _wait_damage(JET_B,true)
	check(net.vehicle_crashes[JET_B].wrecked,"live authorized aircraft state triggers the same severe wreck")
	net.release_vehicle(JET_B,[other.global_position,0.0,0.0,0.0],other.crash_state())
	await create_timer(.2).timeout
	_write("driver-done")
	await _wait_file("observer-done")
	_finish()
func _observer()->void:
	_write("observer-ready")
	await _wait_file("claimed")
	var forged:Dictionary={"damage":1000,"wrecked":true,"point":Vector3.ZERO,"normal":Vector3.UP,"speed":100.0}
	for index in range(4):_packet(JET_A,forged);await create_timer(.06).timeout
	net.release_vehicle(JET_A,[AT,0.0,0.0,0.0],forged)
	await create_timer(.2).timeout
	_write("attack-done")
	await _wait_file("driver-done")
	for id in [JET_A,JET_B]:
		await _wait_damage(id,true)
		var jet:Node=jets[id]
		check(jet.wrecked and jet.drive_power_factor()==0 and jet._breakup_started,"actual remote aircraft receives wreck propulsion and breakup state")
		check(not jet._detail_body.visible and not jet._far_silhouette.visible and jet.get_node_or_null("BrokenFuselageRemnant")!=null,"remote aircraft replaces both intact render tiers with its burned center")
		jet.apply_remote_state(jet.seat_global(),0.0,Vector3(0,0,2.95),Vector3.ZERO)
		check(not jet.afterburner and jet.spool==0.0 and jet._remote_rpm==0.0,"a later old throttle packet cannot relight the replicated wreck")
		check(not net.claimed_vehicles.has(id),"remote ejection releases the occupied seat")
	var effects:Node=world.get_node_or_null("AircraftBreakupEffects")
	check(effects!=null and effects.total_breakups==2,"each remotely observed severe wreck explodes exactly once")
	check(events.get(JET_A,0)==2 and events.get(JET_B,0)==1,"ordinary retransmission and release do not duplicate accepted crash revisions")
	await _position(AT+Vector3.RIGHT*40)
	net.request_vehicle(JET_B,2)
	await create_timer(.25).timeout
	check(not net.claimed_vehicles.has(JET_B),"authority refuses boarding a wreck after its driver exits")
	_write("observer-done")
	_finish()
func _late()->void:
	await _wait_damage(JET_A,true)
	await _wait_damage(JET_B,true)
	for id in [JET_A,JET_B]:
		var jet:Node=_spawn(id)
		check(jet.wrecked and jet._breakup_started and jet.get_node_or_null("BrokenFuselageRemnant")!=null,"late streaming builds the actual stable burned wreck")
		check(not jet._detail_body.visible and not jet._far_silhouette.visible,"late join never shows an intact version of the destroyed plane")
	var effects:Node=world.get_node_or_null("AircraftBreakupEffects")
	check(effects!=null and effects.total_breakups==0 and effects.stats().active_bursts==0 and events.is_empty(),"snapshot arrival does not replay old fireballs, smoke or live crash events")
	_write("late-done")
	_finish()
func _wait_damage(id:String,wreck:bool)->void:
	var deadline:=Time.get_ticks_msec()+8000
	while (not net.vehicle_crashes.has(id) or bool(net.vehicle_crashes[id].wrecked)!=wreck) and Time.get_ticks_msec()<deadline:await process_frame
func _wait_file(name:String)->void:
	var deadline:=Time.get_ticks_msec()+20000
	while not FileAccess.file_exists(directory.path_join(name)) and Time.get_ticks_msec()<deadline:await create_timer(.025).timeout
	check(FileAccess.file_exists(directory.path_join(name)),"synchronized "+name)
func _write(name:String)->void:
	var file:=FileAccess.open(directory.path_join(name),FileAccess.WRITE)
	file.store_string("ready")
func _finish()->void:
	if done:return
	done=true
	if is_instance_valid(world):world.queue_free()
	net.shutdown()
	for frame in range(4):await process_frame
	print("VEHICLECRASHNETTEST ",role," ",passed,"/",checks," ","PASS" if passed==checks else "FAIL")
	quit(0 if passed==checks else 1)
