extends Node
const State=preload("res://scripts/city_incident_state.gd")
signal changed(records:Array)
var _replica:Array=[]
var _clock:=0.0
var _signature:PackedByteArray=PackedByteArray()
var _motion:Dictionary={}
func reset()->void:
	_replica.clear();_motion.clear();_signature=PackedByteArray();_clock=0
func observe_motion(id:String,at:Vector3)->void:
	var now:=Time.get_ticks_msec()
	var row:Dictionary=_motion.get(id,{})
	if not row.is_empty():
		var elapsed:=float(now-int(row.sample_time))/1000.0
		if elapsed>=.015 and elapsed<=.5:
			var velocity:Vector3=(at-Vector3(row.position))/elapsed
			if velocity.length()>=35 and velocity.length()<=400:
				row["approach"]=velocity;row["approach_time"]=now
	row["position"]=at;row["sample_time"]=now;_motion[id]=row
func _ready()->void:process_mode=Node.PROCESS_MODE_ALWAYS
func snapshot()->Array:
	var net=get_parent()
	if net.is_host and is_instance_valid(net.frontier_network) and net.frontier_network.society_ready:
		return net.frontier_network.societies.state.get("city",{}).get("incidents",{}).values().duplicate(true)
	return _replica.duplicate(true)
func request_snapshot()->void:
	if get_parent().active and not get_parent().is_host:
		_replica.clear()
		rpc_id(1,"sv_snapshot")
@rpc("any_peer","call_remote","reliable",2)
func sv_snapshot()->void:
	var net=get_parent();var peer:=multiplayer.get_remote_sender_id()
	if net.is_host and net.names.has(peer) and net._allow_rate(peer,"incident_snapshot",1):rpc_id(peer,"cl_snapshot",snapshot())
func report(vehicle_id:String,at:Vector3,direction:Vector3,closing_speed:float)->void:
	if get_parent().is_host:_report(get_parent().local_id(),vehicle_id,at,direction,closing_speed)
	else:rpc_id(1,"sv_impact",vehicle_id,at,direction,closing_speed)
@rpc("any_peer","call_remote","reliable",2)
func sv_impact(vehicle_id:String,at:Vector3,direction:Vector3,speed:float)->void:
	_report(multiplayer.get_remote_sender_id(),vehicle_id,at,direction,speed)
func _report(peer:int,vehicle_id:String,at:Vector3,direction:Vector3,speed:float)->bool:
	var net=get_parent()
	if not net.is_host or not net.names.has(peer) or not net._allow_rate(peer,"incident",1):return false
	if not at.is_finite() or not direction.is_finite() or direction.length()<.9 or direction.length()>1.1 or not is_finite(speed) or speed<40 or speed>400:return false
	if net.player_realm(peer)!=net.PlayerRealm.EARTH or int(net.claimed_vehicles.get(vehicle_id,-1))!=peer or net._canonical_vehicle_kind(vehicle_id)!=Vehicle.Kind.JET:return false
	var latest:Vector3=net._vehicle_positions.get(vehicle_id,Vector3.INF)
	if latest.distance_to(at)>80:return false
	var motion:Dictionary=_motion.get(vehicle_id,{})
	if not motion.get("approach") is Vector3 or Time.get_ticks_msec()-int(motion.get("approach_time",0))>800:return false
	var approach:Vector3=motion.approach
	if approach.normalized().dot(direction)<.5 or speed>approach.length()*1.35+15:return false
	var frontier=net.frontier_network
	if not frontier.society_ready or not frontier.storage_error.is_empty():return false
	var hit:=State.find_hit(at-direction*8,at+direction*8,1.0)
	if hit.is_empty():return false
	var city=frontier.societies._city()
	if city==null:return false
	var records:Dictionary=city.state.get("incidents",{})
	if records.has(hit.building) or records.size()>=State.MAX_INCIDENTS:return false
	var checkpoint:Dictionary=frontier.societies.export_state()
	city.advance(float(frontier.societies.state.time))
	records[hit.building]=State.record(hit.building,hit.point,direction,float(frontier.societies.state.time))
	city.state["incidents"]=records;frontier.societies.state.city=city.state
	if frontier.persistence_enabled and not frontier.societies.save_game(frontier.storage_path):
		frontier.societies.import_state(checkpoint);return false
	_broadcast();return true
func _process(dt:float)->void:
	if not get_parent().active:
		if not _replica.is_empty() or not _motion.is_empty() or not _signature.is_empty():reset()
		return
	_clock-=dt
	if _clock>0:return
	_clock=1
	for id in _motion.keys():
		if Time.get_ticks_msec()-int(_motion[id].sample_time)>5000:_motion.erase(id)
	if get_parent().is_host:_broadcast()
func _broadcast()->void:
	var rows:=snapshot();var bytes:=var_to_bytes(rows)
	if bytes==_signature:return
	_signature=bytes;changed.emit(rows)
	if get_parent().active and multiplayer.has_multiplayer_peer():rpc("cl_snapshot",rows)
@rpc("authority","call_remote","reliable",2)
func cl_snapshot(rows:Array)->void:
	if get_parent().is_host or rows.size()>State.MAX_INCIDENTS:return
	var records:Dictionary={}
	for row in rows:
		if not row is Dictionary:return
		records[str(row.get("id",""))]=row
	if not State.valid(records):return
	_replica=rows.duplicate(true);changed.emit(_replica)
