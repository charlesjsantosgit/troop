extends RefCounted
## Canonical local furniture anchors shared by the room, player and authority.
## Roots are sole origins; the rig preserves its real 1.8288 m stature.
const ENTER_SEAT := 16
const SIT := 17
const RECLINE := 18
const SLEEP := 19
const RISE := 20
const REACH := 2.5

static func item(id: String, label: String, mode: String, approach: Vector3,
		root: Vector3, yaw: float, exits: Array) -> Dictionary:
	return {"id": id, "label": label, "mode": mode, "position": approach,
		"root": root, "yaw": yaw, "exits": exits, "kind": "furniture"}

static func penthouse_chairs() -> Array[Dictionary]:
	# A chair keeps an adult seat height; width varies with the dining setting.
	# Approaches sit in the surrounding circulation aisles, clear of tables.
	var result: Array[Dictionary] = [
		{"id":"olive_west","center":Vector3(2.15,0,2.3),"yaw":0.28,"width":1.0,"olive":true,"approach":Vector3(2.46,0.06,3.38)},
		{"id":"olive_east","center":Vector3(7.4,0,1.82),"yaw":-0.32,"width":1.0,"olive":true,"approach":Vector3(7.05,0.06,2.88)},
		{"id":"bedroom_chair","center":Vector3(-11.25,0,4.8),"yaw":-PI*0.22,"width":0.85,"olive":true,"approach":Vector3(-11.7,0.06,6.15)},
		{"id":"study_chair","center":Vector3(-5,4,-7.4),"yaw":PI,"width":1.0,"olive":true,"approach":Vector3(-5,4.06,-8.28)},
	]
	for index in range(3):
		var x := -8.7+float(index)*1.15
		result.append({"id":"kitchen_chair_"+str(index),"center":Vector3(x,0,-4.05),
			"yaw":PI,"width":0.82,"olive":false,"approach":Vector3(x,0.06,-4.94)})
		var dining_x := -9.1+float(index)*1.4
		for side in range(2):
			result.append({"id":"dining_chair_%d_%d"%[index,side],
				"center":Vector3(dining_x,0,-2.2 if side==0 else 2.0),
				"yaw":0.0 if side==0 else PI,"width":0.62,"olive":false,
				"approach":Vector3(dining_x,0.06,-1.38 if side==0 else 1.18)})
	return result

static func penthouse() -> Dictionary:
	var result := {}
	# Furniture faces +Z; the anatomical monkey rig faces local -Z.
	for spec in penthouse_chairs():
		result[spec.id] = item(spec.id,"Sit in the chair","chair",spec.approach,
			spec.center+Vector3.UP*0.10+Basis(Vector3.UP,float(spec.yaw))*Vector3(0,0,0.42 if float(spec.width)>=0.95 else 0.30),float(spec.yaw)+PI,[spec.approach])
		result[spec.id]["mount"]=spec.center+Basis(Vector3.UP,float(spec.yaw))*Vector3(0,0.06,0.88)
	result.sectional = item("sectional","Relax on the sofa","sofa",Vector3(2.55,0.06,5.34),
		Vector3(2.8,0.17,6.08),0.0,[Vector3(2.55,0.06,5.34),Vector3(1.0,0.06,6.5)])
	result.sectional_middle = item("sectional_middle","Relax on the sofa","sofa",Vector3(4.95,0.06,5.5),
		Vector3(4.95,0.17,6.08),0.0,[Vector3(4.95,0.06,5.5)])
	result.chaise = item("chaise","Relax on the chaise","sofa",Vector3(6.36,0.06,5.42),
		Vector3(6.86,0.17,4.30),PI*0.5,[Vector3(6.36,0.06,5.42)])
	result.mezzanine_sofa = item("mezzanine_sofa","Relax on the upstairs sofa","sofa",Vector3(5.6,4.06,-8.25),
		Vector3(5.6,4.17,-9.07),PI,[Vector3(5.6,4.06,-8.25)])
	result.bedroom_bench = item("bedroom_bench","Sit on the bedroom bench","chair",Vector3(-8.2,0.06,4.10),
		Vector3(-8.2,0.15,4.70),0.0,[Vector3(-8.2,0.06,4.10)])
	result.bed_sleep = item("bed_sleep","Lie down and sleep","bed",Vector3(-6.25,0.06,6.15),
		Vector3(-7.8,0.50,7.04),0.0,[Vector3(-6.25,0.06,6.15),Vector3(-6.25,0.06,7.15)])
	result.bed_sleep["mount"]=Vector3(-6.2,0.06,6.15)
	result.bed_sleep["mount_yaw"]=PI*0.5
	return result

static func home(housing: String, size: Vector3) -> Dictionary:
	if housing.is_empty() or housing == "warehouse": return {}
	var bed := Vector3(-size.x*0.5+1.25,0,size.z*0.5-1.5)
	var stand := bed+Vector3(1.4,0.06,-0.45)
	var result := {"bed_sleep":item("bed_sleep","Lie down and sleep","bed",stand,
		bed+Vector3(0,0.45,-0.05),0.0,[stand])}
	result.bed_sleep["mount"]=stand
	result.bed_sleep["mount_yaw"]=PI*0.5
	result.bed_sleep["climb_height"]=1.1
	if housing in ["city_apartment","town_apartment"]:
		var sofa := Vector3(size.x*0.5-1.0,0,-size.z*0.5+1.5)
		stand = sofa+Vector3(-1.25,0.06,0)
		result.sofa = item("sofa","Relax on the sofa","sofa",stand,
			sofa+Vector3(-0.58,0.20,0),PI*0.5,[stand])
	return result

static func world_item(local: Dictionary, origin: Vector3) -> Dictionary:
	var result := local.duplicate(true)
	result.position += origin
	result.root += origin
	if result.has("mount"): result.mount += origin
	for i in range(result.exits.size()): result.exits[i] += origin
	return result

static func resting_animation(mode: String) -> int:
	return SLEEP if mode == "bed" else RECLINE if mode == "sofa" else SIT

static func is_furniture_animation(animation: int) -> bool:
	return animation >= ENTER_SEAT and animation <= RISE
