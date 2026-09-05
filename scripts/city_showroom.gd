extends RefCounted
const Commerce=preload("res://scripts/city_commerce.gd")
const Fleet=preload("res://scripts/city_vehicle_models.gd")
static func add_display(parent: Node3D, records: Array[Dictionary], origin: Vector2) -> void:
	for record in records:
		if Commerce.category(record)!="dealership": continue
		# Three empty examples in the rear delivery court: real size, no fake driver.
		for slot in range(3):
			var car:=Node3D.new()
			car.name="DealerDisplay"+str(slot)
			var at:=Commerce.display_position(record,slot)
			car.position=at-Vector3(origin.x,0,origin.y)
			parent.add_child(car)
			var index:=posmod(int(record.district)*3+slot,Fleet.CATALOG.size())
			Fleet.build(car,index,Fleet.paint_for(slot,index),true,false)
			var label:=Label3D.new()
			label.text=str(Fleet.spec(index).label)
			label.font_size=32
			label.pixel_size=.005
			label.position=Vector3(0,2.3,0)
			label.billboard=BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test=false
			label.visibility_range_end=80
			car.add_child(label)
