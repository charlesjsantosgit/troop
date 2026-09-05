class_name CityCommerce
extends RefCounted
## Shared authored inventory and vehicle sales metadata. Stock lives in CityEconomy.
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const SHOPS := {
	"grocer":{"label":"FRESH & LOCAL","service":"produce_market","items":[["banana",6],["tomato",5],["rice",8],["water",3]]},
	"bakery":{"label":"HEARTH BAKERY","service":"courier_depot","items":[["meal",12],["flour",7],["honey",10]]},
	"cafe":{"label":"CANOPY COFFEE","service":"courier_depot","items":[["coffee",9],["tea",7],["meal",12]]},
	"restaurant":{"label":"THE CORNER KITCHEN","service":"courier_depot","items":[["meal",12],["fish",14],["water",3]]},
	"hardware":{"label":"NEIGHBORHOOD HARDWARE","service":"maintenance_depot","items":[["spare_parts",28],["lumber",15],["rope",8]]},
	"garden":{"label":"GARDEN & GROW","service":"produce_market","items":[["tomato_seed",8],["banana_start",14],["compost",6],["nutrients",12]]},
	"outdoors":{"label":"TRAIL & TIDE OUTFITTERS","service":"maintenance_depot","items":[["rope",8],["cloth",16],["dried_food",10]]},
	"energy":{"label":"HOME ENERGY STORE","service":"maintenance_depot","items":[["battery_kit",95],["solar_kit",140],["spare_parts",28]]},
	"textiles":{"label":"CROWN FABRICS","service":"maintenance_depot","items":[["cloth",16],["cotton",8],["flax",7]]},
	"pantry":{"label":"DAILY PANTRY","service":"courier_depot","items":[["cooking_oil",9],["flour",7],["dried_food",10]]},
}

static func category(building: Dictionary) -> String:
	return str(building.get("retail_type",""))

static func offers(building: Dictionary) -> Array[Dictionary]:
	var shop: Dictionary = SHOPS.get(category(building),{})
	var rows: Array[Dictionary] = []
	for item: Array in shop.get("items",[]):
		rows.append({"kind":str(building.kind),"item":str(item[0]),"label":str(item[0]).replace("_"," ").capitalize(),"price":int(item[1]),"service":str(shop.service)})
	return rows

static func name_for(building: Dictionary) -> String:
	if category(building)=="dealership": return "CROWN MOTOR GALLERY"
	return str(SHOPS.get(category(building),{}).get("label",""))

static func delivery_position(building: Dictionary, slot := 0) -> Vector3:
	var side := -1.0 if int(building.lot)%2==0 else 1.0
	var center: Vector3 = building.position
	# Dedicated rear court, clear of sidewalks and the public carriageway.
	return Vector3(center.x-side*23.4,8.6,center.z+(float(slot%3)-1.0)*8.0)

static func display_position(building: Dictionary, slot := 0) -> Vector3:
	var side := -1.0 if int(building.lot)%2==0 else 1.0
	var center: Vector3 = building.position
	# A separate parallel row leaves the three delivery bays unobstructed.
	return Vector3(center.x-side*18.6,8.0,center.z+(float(slot%3)-1.0)*8.0)

static func model_from_vehicle_id(id: String) -> int:
	var pieces := id.split(":")
	if pieces.size()==3 and pieces[1].begins_with("admin#"): return Fleet.index_for_id(pieces[2])
	return Fleet.index_for_id(pieces[2]) if pieces.size()==4 and pieces[0]=="v" and pieces[1]=="city" and pieces[3].is_valid_int() else -1
