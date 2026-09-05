class_name CityPenthouseView
extends Node3D
## The suite looks directly into the same Earth world as its street entrance.
## This lightweight descriptor owns no meshes, substitute sky, or compressed city.
const Plan = preload("res://scripts/city_plan.gd")
var city_world: Node3D
var property_id := ""
var source_position := Vector3.ZERO
var _hour := 12.0
var _daylight := 1.0

func build(data: Dictionary, live_city: Node3D) -> void:
	name = "LiveCityView"
	property_id = str(data.id)
	source_position = data.position
	city_world = live_city

func update_time(hour: float, daylight: float) -> void:
	_hour = hour
	_daylight = daylight

func stats() -> Dictionary:
	return {"render_batches":0,"collision_count":0,"geometry_scale":1.0,
		"source_position":source_position,"room_origin":global_position,
		"hour":_hour,"daylight":_daylight,"live_city_visible":is_instance_valid(city_world) and city_world.visible,
		"property":property_id}
