class_name AircraftBreakupEffects
extends Node3D
## Presentation of a wreck, built from the actual aircraft's current triangles.
## The authoritative RigidBody, collider and pilot never belong to this effect.
const MAX_BURSTS := 3
const LIFETIME := 12.0
const FIRE_COUNT := 18
const SMOKE_COUNT := 24
const MAX_CHUNKS := 8
var _bursts: Array[Dictionary] = []
var total_breakups := 0

func break_apart(aircraft: Node3D, body: Node3D, velocity: Vector3, normal: Vector3, animate := true) -> Dictionary:
	while animate and _bursts.size() >= MAX_BURSTS:
		_bursts.pop_front().node.queue_free()
	var holder := Node3D.new()
	holder.name = "AircraftExplosion"
	add_child(holder)
	holder.global_transform = aircraft.global_transform
	var buckets := {}
	var source_triangles := 0
	var source_meshes := 0
	for source: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		if source.mesh == null or not source.visible: continue
		var actor := false
		var ancestor: Node = source
		while ancestor != body and ancestor != null:
			if ancestor is MonkeyRig: actor = true
			ancestor = ancestor.get_parent()
		if actor: continue
		# The luminous nozzle plume is not solid aircraft skin.
		if source.material_override is StandardMaterial3D and source.material_override.blend_mode == BaseMaterial3D.BLEND_MODE_ADD: continue
		var frame := aircraft.global_transform.affine_inverse() * source.global_transform
		var mesh_center: Vector3 = frame * source.mesh.get_aabb().get_center()
		source_meshes += 1
		for surface in range(source.mesh.get_surface_count()):
			var arrays := source.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var material: Material = source.get_active_material(surface)
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for offset in range(0, count - 2, 3):
				var ids := [indices[offset],indices[offset+1],indices[offset+2]] if not indices.is_empty() else [offset,offset+1,offset+2]
				var center: Vector3 = frame * ((vertices[ids[0]]+vertices[ids[1]]+vertices[ids[2]])/3.0)
				var chunk := _chunk_for(center if source.name == "FuselageShell" else mesh_center)
				if not buckets.has(chunk): buckets[chunk] = {}
				var material_key := material.get_instance_id() if material else 0
				if not buckets[chunk].has(material_key):
					var builder := SurfaceTool.new()
					builder.begin(Mesh.PRIMITIVE_TRIANGLES)
					builder.set_material(material)
					buckets[chunk][material_key] = {"builder":builder,"count":0}
				var row: Dictionary = buckets[chunk][material_key]
				var st: SurfaceTool = row.builder
				for index: int in ids:
					st.set_normal((frame.basis.inverse().transposed()*normals[index]).normalized() if normals.size()>index else Vector3.UP)
					st.set_color(colors[index] if colors.size()>index else Color.WHITE)
					st.set_uv(uv[index] if uv.size()>index else Vector2.ZERO)
					st.add_vertex(frame*vertices[index])
				row.count += 1
				source_triangles += 1
	var chunks: Array[Dictionary] = []
	var render_batches := 0
	var copied_triangles := 0
	var remnants := Node3D.new()
	remnants.name = "BrokenFuselageRemnant"
	aircraft.add_child(remnants)
	var soot := StandardMaterial3D.new()
	soot.albedo_color = Color("292b2c")
	soot.metallic = .35
	soot.roughness = .92
	for kind: String in buckets:
		var root := Node3D.new()
		root.name = kind
		holder.add_child(root)
		var merged := ArrayMesh.new()
		for row: Dictionary in buckets[kind].values():
			row.builder.index()
			row.builder.commit(merged)
			copied_triangles += int(row.count)
		var bounds := merged.get_aabb()
		var center := bounds.get_center()
		root.position = center
		var visual := MeshInstance3D.new()
		visual.mesh = merged
		visual.position = -center
		root.add_child(visual)
		render_batches += merged.get_surface_count()
		# A burned central section stays attached to the authoritative wreck
		# after the short-lived detached pieces expire. No intact plane reappears.
		if kind == "fuselage":
			var remnant := MeshInstance3D.new()
			remnant.mesh = merged
			remnant.material_override = soot
			remnants.add_child(remnant)
			root.queue_free()
			continue
		var direction := center.normalized()
		direction.y = .35 + float(chunks.size()%3)*.13
		direction = (direction + aircraft.global_basis.inverse()*normal*.3).normalized()
		var spin := Vector3(.9+chunks.size()*.17, -.7+chunks.size()*.21, 1.0 if center.x>0 else -1.0)
		chunks.append({"node":root,"visual":visual,"start":center,"velocity":direction*(7.0+chunks.size()*.7)+aircraft.global_basis.inverse()*velocity*.10,
			"spin":spin,"rest":false,"extent":maxf(.12,minf(bounds.size.x,minf(bounds.size.y,bounds.size.z))*.4)})
	if not animate:
		holder.queue_free()
		return {"source_triangles":source_triangles,"copied_triangles":copied_triangles,"source_meshes":source_meshes,"chunks":0,"chunk_names":buckets.keys(),"draw_batches":0,"remnant":remnants}
	var fire := _cloud(holder,FIRE_COUNT,true)
	var smoke := _cloud(holder,SMOKE_COUNT,false)
	var flash := OmniLight3D.new()
	flash.light_color = Color("ffae44")
	flash.light_energy = 7.0
	flash.omni_range = 24.0
	flash.shadow_enabled = false
	holder.add_child(flash)
	var burst := {"node":holder,"chunks":chunks,"fire":fire,"smoke":smoke,"flash":flash,"age":0.0,"exclude":aircraft.get_rid(),"batches":render_batches+2}
	_bursts.append(burst)
	total_breakups += 1
	_update_cloud(burst)
	set_process(true)
	return {"source_triangles":source_triangles,"copied_triangles":copied_triangles,"source_meshes":source_meshes,"chunks":chunks.size(),"chunk_names":buckets.keys(),"draw_batches":render_batches+2,"remnant":remnants}

static func _chunk_for(center: Vector3) -> String:
	if center.z < -3.5:
		if absf(center.x)>1.0: return "left_tail" if center.x<0 else "right_tail"
		return "tail"
	if absf(center.x)>1.2: return "left_wing" if center.x<0 else "right_wing"
	if center.z>3.0: return "nose"
	return "fuselage"

func _cloud(parent: Node3D, count: int, burning: bool) -> MultiMeshInstance3D:
	var cloud := MultiMeshInstance3D.new()
	cloud.name = "FireballAndFlames" if burning else "RisingSoot"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var puff := QuadMesh.new()
	puff.size = Vector2.ONE
	mm.mesh = puff
	mm.instance_count = count
	cloud.multimesh = mm
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/impact_cloud.gdshader")
	material.set_shader_parameter("burning", 1.0 if burning else 0.0)
	cloud.material_override = material
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(cloud)
	return cloud

func _process(dt: float) -> void:
	for index in range(_bursts.size()-1,-1,-1):
		var burst: Dictionary = _bursts[index]
		burst.age += dt
		if burst.age >= LIFETIME:
			burst.node.queue_free()
			_bursts.remove_at(index)
			continue
		var step := minf(dt,.05)
		for piece: Dictionary in burst.chunks:
			if not piece.rest:
				piece.velocity += burst.node.global_basis.inverse()*Vector3.DOWN*9.8*step
				var before: Vector3 = piece.node.global_position
				var next: Vector3 = before + burst.node.global_basis*piece.velocity*step
				var query := PhysicsRayQueryParameters3D.create(before,next,1,[burst.exclude])
				var hit := get_world_3d().direct_space_state.intersect_ray(query)
				if hit.is_empty(): piece.node.global_position=next
				else:
					piece.node.global_position=Vector3(hit.position)+Vector3(hit.normal)*float(piece.extent)
					var local_normal: Vector3 = burst.node.global_basis.inverse()*Vector3(hit.normal)
					piece.velocity=Vector3(piece.velocity).bounce(local_normal)*.23
					piece.rest=Vector3(piece.velocity).length()<2.0
				piece.node.rotate_object_local(Vector3(piece.spin).normalized(),Vector3(piece.spin).length()*step)
			piece.visual.transparency=clampf((float(burst.age)-10.0)*.5,0.0,1.0)
		_update_cloud(burst)
	if _bursts.is_empty(): set_process(false)

func _update_cloud(burst: Dictionary) -> void:
	var age: float = burst.age
	burst.flash.light_energy = 7.0*exp(-age*4.0)
	burst.fire.visible = age<4.5
	for index in range(FIRE_COUNT):
		var phase := float(index)/FIRE_COUNT
		var angle := float(index)*2.39996
		var initial := 2.3*sin(phase*PI)+.2
		var blast := clampf(age/.22,0.0,1.0)*maxf(0.0,1.0-age/1.25)
		var flame := fmod(age*1.7+phase,1.0)
		var radius := (.5+initial*blast)*(1.0-flame*.3)
		var at := Vector3(cos(angle)*initial*blast,(phase-.25)*4.0*blast,sin(angle)*initial*blast)
		if age>1.0: at=Vector3(cos(angle)*1.6,flame*4.0+.3,sin(angle)*2.7)
		var size := Vector3(radius,radius*(1.0+flame*1.7),radius)
		burst.fire.multimesh.set_instance_transform(index,Transform3D(Basis.IDENTITY.scaled(size),at))
		burst.fire.multimesh.set_instance_color(index,Color(1.0,.18+phase*.55,.025,clampf(1.0-age/4.5,0.0,1.0)*(1.0-flame*.6)))
	for index in range(SMOKE_COUNT):
		var phase := float(index)/SMOKE_COUNT
		var growth := maxf(0.0,age-phase*2.2)
		var radius := .3+growth*.65
		var at := Vector3(sin(index*2.4)*growth*.26,growth*(.8+phase*.7),cos(index*2.4)*growth*.26)
		burst.smoke.multimesh.set_instance_transform(index,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*radius),at))
		var alpha := clampf(growth*.65,0.0,.8)*clampf((LIFETIME-age)/3.0,0.0,1.0)
		burst.smoke.multimesh.set_instance_color(index,Color(.10,.105,.11,alpha))

func stats() -> Dictionary:
	var chunks := 0
	var batches := 0
	for burst in _bursts:
		chunks += burst.chunks.size()
		batches += int(burst.batches)
	return {"active_bursts":_bursts.size(),"max_bursts":MAX_BURSTS,"chunks":chunks,"fire_puffs":_bursts.size()*FIRE_COUNT,"smoke_puffs":_bursts.size()*SMOKE_COUNT,"draw_batches":batches,"total_breakups":total_breakups}
