class_name VehicleImpactEffects
extends Node3D
## Bounded impact fragments and smoke. Chassis collision remains in Godot's
## rigid-body solver; these small visual fragments sweep real collision space.
const MAX_BURSTS := 8
const DEBRIS_COUNT := 24
const SMOKE_COUNT := 20
var _bursts: Array[Dictionary] = []
var total_impacts := 0

func impact(point: Vector3, normal: Vector3, speed: float, velocity: Vector3, excluded: RID) -> void:
	if _bursts.size()>=MAX_BURSTS:
		_bursts[0].node.queue_free()
		_bursts.pop_front()
	var holder := Node3D.new()
	holder.position = point+normal*.16
	add_child(holder)
	var fragments := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mm.mesh = mesh
	mm.instance_count = DEBRIS_COUNT
	fragments.multimesh = mm
	var metal := StandardMaterial3D.new()
	metal.vertex_color_use_as_albedo = true
	metal.metallic = .5
	metal.roughness = .55
	fragments.material_override = metal
	holder.add_child(fragments)
	var smoke := MultiMeshInstance3D.new()
	var sm := MultiMesh.new()
	sm.transform_format = MultiMesh.TRANSFORM_3D
	sm.use_colors = true
	var puff := QuadMesh.new()
	puff.size = Vector2.ONE
	sm.mesh = puff
	sm.instance_count = SMOKE_COUNT
	smoke.multimesh = sm
	var soot := ShaderMaterial.new()
	soot.shader = preload("res://scripts/impact_cloud.gdshader")
	soot.set_shader_parameter("opacity", .48)
	smoke.material_override = soot
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(smoke)
	var rng := RandomNumberGenerator.new()
	rng.seed = total_impacts*137+absi(roundi(point.x*13+point.z*31))
	var particles: Array[Dictionary] = []
	for i in range(DEBRIS_COUNT):
		var direction := (normal+Vector3(rng.randf_range(-.8,.8),rng.randf_range(.1,1.0),rng.randf_range(-.8,.8))).normalized()
		var size := Vector3(rng.randf_range(.06,.20),rng.randf_range(.025,.08),rng.randf_range(.10,.38))*clampf(speed/18.0,.5,2.1)
		particles.append({"at":Vector3.ZERO,"sweep_at":Vector3.ZERO,"velocity":direction*minf(speed*.25,18)+velocity*.07,"size":size,"spin":Vector3(rng.randf_range(-5,5),rng.randf_range(-5,5),rng.randf_range(-5,5)),"rotation":Vector3.ZERO,"rest":false})
		mm.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(size),Vector3.ZERO))
		mm.set_instance_color(i,Color("ffd297") if i<5 and speed>18 else Color("66717c"))
	for i in range(SMOKE_COUNT): sm.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*.01),Vector3.ZERO))
	var flash := OmniLight3D.new()
	flash.light_color = Color("ffb15d")
	flash.omni_range = minf(14,speed*.22)
	flash.light_energy = 2.0 if speed>30 else .35
	flash.shadow_enabled = false
	holder.add_child(flash)
	_bursts.append({"node":holder,"fragments":fragments,"smoke":smoke,"flash":flash,"particles":particles,"age":0.0,"strength":clampf(speed/32.0,.2,2.0),"exclude":excluded})
	total_impacts += 1
	set_process(true)

func _process(dt: float) -> void:
	for index in range(_bursts.size()-1,-1,-1):
		var burst := _bursts[index]
		burst.age += dt
		var age: float = burst.age
		if age>8.0:
			burst.node.queue_free()
			_bursts.remove_at(index)
			continue
		burst.flash.light_energy *= exp(-dt*15)
		for i in range(burst.particles.size()):
			var p: Dictionary = burst.particles[i]
			if not p.rest:
				p.velocity += Vector3.DOWN*9.8*dt
				p.at += p.velocity*dt
				p.rotation += p.spin*dt
				if Engine.get_process_frames()%3==i%3:
					var query := PhysicsRayQueryParameters3D.create(burst.node.global_position+p.sweep_at,burst.node.global_position+p.at,1,[burst.exclude])
					var hit := get_world_3d().direct_space_state.intersect_ray(query)
					if not hit.is_empty():
						p.at = Vector3(hit.position)-burst.node.global_position+Vector3(hit.normal)*.03
						p.velocity = Vector3(p.velocity).bounce(hit.normal)*.24
						p.rest = Vector3(p.velocity).length()<.8
					p.sweep_at = p.at
			burst.fragments.multimesh.set_instance_transform(i,Transform3D(Basis.from_euler(p.rotation).scaled(p.size),p.at))
		for i in range(SMOKE_COUNT):
			var phase := float(i)/SMOKE_COUNT
			var growth := maxf(0,age-phase*.8)
			var radius := (.18+growth*.55)*float(burst.strength)
			var at := Vector3(sin(float(i)*2.4)*growth*.23,growth*(1.0+phase),cos(float(i)*2.4)*growth*.23)
			burst.smoke.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*radius),at))
			var grey := .12 if burst.strength>1.0 else .45
			burst.smoke.multimesh.set_instance_color(i,Color(grey,grey*.95,grey*.9,clampf(1-age/8,0,1)))
	if _bursts.is_empty(): set_process(false)

func stats() -> Dictionary:
	return {"active_bursts":_bursts.size(),"max_bursts":MAX_BURSTS,"fragments":_bursts.size()*DEBRIS_COUNT,"smoke_puffs":_bursts.size()*SMOKE_COUNT,"draw_batches":_bursts.size()*2,"total_impacts":total_impacts}

static func dent(vehicle: Node3D, point: Vector3, normal: Vector3, speed: float) -> int:
	var changed := 0
	var radius := clampf(speed*.055,.7,4.5)
	var depth := clampf((speed-5)*.022,0,1.1)
	for node: Node in vehicle.find_children("*","MeshInstance3D",true,false):
		if node.get_meta("canonical_model","")=="MonkeyRig" or node.mesh==null: continue
		var ancestor := node.get_parent()
		var actor := false
		while ancestor!=vehicle and ancestor!=null:
			if ancestor is MonkeyRig: actor = true
			ancestor = ancestor.get_parent()
		if actor or not node.mesh is ArrayMesh: continue
		var source: ArrayMesh = node.get_meta("undamaged_mesh",node.mesh)
		var damaged := ArrayMesh.new()
		var modified := false
		for surface in range(source.get_surface_count()):
			var arrays := source.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in range(vertices.size()):
				var world_vertex: Vector3 = node.global_transform*vertices[i]
				var distance := world_vertex.distance_to(point)
				if distance>=radius: continue
				world_vertex += normal*depth*pow(1-distance/radius,2)
				vertices[i] = node.global_transform.affine_inverse()*world_vertex
				modified = true
			arrays[Mesh.ARRAY_VERTEX] = vertices
			damaged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
			damaged.surface_set_material(surface,source.surface_get_material(surface))
		if modified:
			node.set_meta("undamaged_mesh",source)
			node.mesh = damaged
			changed += 1
	return changed
