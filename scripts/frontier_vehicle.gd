class_name FrontierVehicle
extends SafariJeep
## The same suspension, tire forces, engine, chassis and rider anchors as the
## player jeep. Headless towns omit mesh/audio construction, never physics.
var site: Node3D
var worker_id := ""
var profession := ""
var cargo_label: Label3D
var manifest_text := ""
var _cargo_visual: Node3D


func _init() -> void:
	super()
	npc_controlled = true


func terrain_height_at(x: float, z: float) -> float:
	if is_instance_valid(site) and site.has_method("surface_height"):
		var local := site.to_local(Vector3(x, site.global_position.y, z))
		return site.to_global(Vector3(local.x, site.surface_height(local.x, local.z), local.z)).y
	return super(x, z)


func _build_body() -> void:
	if DisplayServer.get_name() == "headless":
		return
	super()
	if profession in ["tanker_driver", "hauler", "freight_hauler"]:
		var props := FrontierProps.new(self)
		_cargo_visual = Node3D.new()
		add_child(_cargo_visual)
		# A compact service 4x4 carries the actual 12–24 litre/12kg loads.
		# It is deliberately not a painted full-size tanker with jeep physics.
		if profession == "tanker_driver":
			props.cylinder(Vector3(0, 0.87, -0.9), 0.36, 0.85,
				Color(0.65,0.68,0.65), false, Vector3(PI*0.5,0,0))
			props.box(Vector3(0,0.88,-1.35),Vector3(0.34,0.25,0.03),Color(0.95,0.62,0.13))
		else:
			props.box(Vector3(0,0.83,-0.95),Vector3(0.9,0.55,0.8),Color(0.51,0.35,0.18))
		cargo_label = props.text(Vector3(0,2.35,-0.6),"",Color(0.98,0.86,0.63),23,28.0)
		props.flush()


func _build_engine_audio() -> void:
	if DisplayServer.get_name() != "headless":
		super()


func add_exhaust(outlet: Vector3, direction: Vector3, profile_kind: int) -> VehicleExhaust:
	if DisplayServer.get_name() == "headless":
		return null
	return super(outlet, direction, profile_kind)


func update_manifest(carrying: Dictionary) -> void:
	if carrying.is_empty():
		manifest_text = "Empty · collecting next load"
	else:
		var item := str(carrying.get("item", "cargo"))
		manifest_text = "%s · %s %s" % [item.replace("_", " ").capitalize(),
			str(carrying.get("quantity", 0)), "L" if item in ["diesel","gasoline","jet_fuel","crude_oil"] else "kg"]
	# A newly reassigned practical worker keeps the same physical vehicle. Add
	# its cargo readout when its first real manifest arrives, without respawning.
	if cargo_label == null and not carrying.is_empty() and DisplayServer.get_name() != "headless":
		var props := FrontierProps.new(self)
		cargo_label=props.text(Vector3(0,2.35,-0.6),manifest_text,Color(0.98,0.86,0.63),23,28.0)
	if cargo_label != null:
		cargo_label.text=manifest_text
