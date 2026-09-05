extends Node
const Car=preload("res://scripts/city_car.gd")
const Fleet=preload("res://scripts/city_vehicle_models.gd")
var passed:=0
var checks:=0
func check(ok:bool,label:String)->void:
	checks+=1
	if ok:passed+=1
	else:push_error("CITYDRIVING FAIL "+label)
func frames(count:int)->void:
	for i in range(count):await get_tree().physics_frame
func run()->void:
	# Ten separate test lanes on a real elevated collider; this cannot silently
	# pass using the procedural terrain fallback or a prescribed vehicle route.
	var floor:=StaticBody3D.new();var shape:=CollisionShape3D.new();var box:=BoxShape3D.new()
	box.size=Vector3(600,2,600);shape.shape=box;floor.position=Vector3(90,19999,100);floor.add_child(shape);add_child(floor)
	var cars:Array[Vehicle]=[]
	var drivers:Array[Node3D]=[]
	for index in range(Fleet.CATALOG.size()):
		var car:=Car.new();car.configure_model(index);car.position=Vector3(index*22,20000.5,0);car.vid="v:admin#1-%d:%s"%[index+1,Fleet.spec(index).id]
		add_child(car);cars.append(car)
		var driver:=Node3D.new();add_child(driver);drivers.append(driver)
	await frames(150)
	for i in range(cars.size()):
		var car:=cars[i]
		var contacts:=0
		for wheel in car.wheels:
			if wheel.compression>.005 and wheel.compression<wheel.travel*.95:contacts+=1
		print("CITYDRIVE REST ",car.display_name()," at=",car.position," compression=",car.wheels.map(func(w):return w.compression)," damage=",car.crash_damage)
		check(contacts==4 and car.global_position.y>20000 and car.global_position.y<20001,"four loaded suspension contacts without bottoming "+car.display_name())
		car.begin_drive(drivers[i]);car.set_inputs(1,0,0,false,false)
	await frames(240)
	for car in cars:
		print("CITYDRIVE GO ",car.display_name()," at=",car.position," v=",car.linear_velocity," roll=",car.rotation," damage=",car.crash_damage)
		check(car.forward_speed()>4 and car.forward_speed()<40 and car.global_position.z>8,"real drivetrain accelerates forward "+car.display_name())
		car.set_inputs(.25,0,.25,false,false)
	await frames(60)
	for car in cars:
		check(absf(car.global_basis.get_euler().y)>.04 and car.global_basis.y.dot(Vector3.UP)>.85,"moderate steering turns without rolling "+car.display_name())
		car.set_inputs(0,1,0,false,false)
	var stopped:Dictionary={}
	for i in range(300):
		await get_tree().physics_frame
		for car in cars:
			if car.speed()<.5:
				stopped[car.vid]=true;car.set_inputs(0,0,0,true,false)
	for car in cars:
		check(stopped.has(car.vid) and car.speed()<.9 and not car.wrecked and car.crash_damage==0,"brakes stop without a false crash or spontaneous reverse "+car.display_name())
		print("CITYDRIVE STOP ",car.display_name()," speed=",car.speed()," at=",car.position," stopped=",stopped.has(car.vid)," damage=",car.crash_damage)
		car.driver=null;car.queue_free()
	for driver in drivers:driver.queue_free()
	floor.queue_free();await get_tree().process_frame
	print("CITYDRIVINGTEST result=%d/%d %s"%[passed,checks,"PASS" if checks==passed else "FAIL"])
	get_tree().quit(0 if checks==passed else 1)
