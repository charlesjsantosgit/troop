extends RefCounted
## Materials are owned by the room batches and released with the room. No
## process-wide resource cache keeps native shader resources alive on shutdown.
const SURFACE = preload("res://scripts/city_penthouse_surface.gdshader")
const KINDS := {"oak": 0, "walnut": 1, "marble": 2, "fabric": 3,
	"plaster": 4, "bronze": 5, "dark_metal": 6, "rug": 7, "leaf": 8}

static func get_material(kind: String, color: Color = Color.WHITE) -> Material:
	if kind == "glass":
		var glass := StandardMaterial3D.new()
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.albedo_color = Color(0.68, 0.80, 0.84, 0.055)
		glass.roughness = 0.08
		glass.metallic = 0.1
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		glass.no_depth_test = false
		return glass
	if kind == "emissive":
		var glow := StandardMaterial3D.new()
		glow.albedo_color = color
		glow.emission_enabled = true
		glow.emission = color
		glow.emission_energy_multiplier = 2.4
		glow.roughness = 0.3
		return glow
	var material := ShaderMaterial.new()
	material.shader = SURFACE
	material.set_shader_parameter("surface_kind", int(KINDS.get(kind, 4)))
	material.set_shader_parameter("tint", color)
	return material
