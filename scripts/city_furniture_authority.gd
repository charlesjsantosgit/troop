extends Node
## Separate physics spaces reproduce the exact room colliders without placing
## hidden furniture in the live city. One bounded fixture per room dimensions.
const Rooms=preload("res://scripts/city_interior.gd")
const Motion=preload("res://scripts/city_furniture_motion.gd")
var fixtures:Dictionary={}
var last_error:=""
func _key(data:Dictionary)->String:
	return Rooms.housing_type(data)+str(Rooms.room_dimensions(data))
func prepare(data:Dictionary)->void:
	var id:=_key(data)
	if fixtures.has(id):return
	# Residents share the same fixed housing layouts; trim unused geometry if
	# future content introduces more than eight distinct sizes.
	if fixtures.size()>=8:
		var oldest:String=fixtures.keys()[0]
		fixtures[oldest].viewport.queue_free()
		fixtures.erase(oldest)
	var viewport:=SubViewport.new()
	viewport.name="FurnitureAuthoritySpace"
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	viewport.size=Vector2i(2,2)
	add_child(viewport)
	var room:=Rooms.new()
	viewport.add_child(room)
	room.build(data)
	var actor:=CharacterBody3D.new()
	actor.collision_layer=0
	actor.collision_mask=1
	viewport.add_child(actor)
	var rig:=MonkeyRig.new()
	actor.add_child(rig)
	rig.setup("Furniture authority",false)
	var motion:=Motion.new()
	motion.setup(actor,rig)
	fixtures[id]={"viewport":viewport,"room":room,"actor":actor,"rig":rig,"motion":motion,"ready_frame":Engine.get_physics_frames()+2}
func check_path(data:Dictionary,path:Array,origin:Vector3)->bool:
	prepare(data)
	var fixture:Dictionary=fixtures[_key(data)]
	if Engine.get_physics_frames()<int(fixture.ready_frame):
		last_error="The room is still preparing. Try the furniture again in a moment."
		return false
	var local_path:=path.duplicate(true)
	for point:Dictionary in local_path:
		point.root-=origin
		if point.has("floor"):point.floor-=origin.y
	var clear:bool=fixture.motion.preflight(local_path)
	last_error="" if clear else "The furniture route is blocked. Approach from the clear space beside it."
	return clear
