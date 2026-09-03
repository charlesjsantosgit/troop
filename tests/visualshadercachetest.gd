extends Node
## Run through the main CLI so Visuals/Gen use the ordinary autoload context:
## godot --headless --path . -- visualshadercachetest
## Identity/parameter parity is headless; actual pipeline timing is rendered.

var passed := 0
var total := 0


func run() -> void:
	call_deferred("_run")


func _run() -> void:
	var color_a := Color(0.30, 0.13, 0.055)
	var color_b := Color(0.62, 0.37, 0.19)
	var fur_a := Visuals.fur_material(color_a)
	var fur_b := Visuals.fur_material(color_b)
	_check(fur_a != fur_b and fur_a.get_rid() != fur_b.get_rid(),
		"different fur colors retain distinct material resources and RIDs")
	_check(_same_shader(fur_a, fur_b),
		"different fur colors share the same shader object and RID")
	_check(fur_a.get_shader_parameter("base_color") == color_a
			and fur_b.get_shader_parameter("base_color") == color_b,
		"each fur material preserves its requested color")
	_check(Visuals.fur_material(color_a) == fur_a,
		"the existing per-color material cache remains stable")
	fur_a.set_shader_parameter("base_color", Color(0.1, 0.2, 0.3))
	_check(fur_b.get_shader_parameter("base_color") == color_b
			and _same_shader(fur_a, fur_b),
		"a material uniform edit neither leaks to its peer nor replaces the shader")
	fur_a.set_shader_parameter("base_color", color_a)

	var independent := Visuals._material(Visuals.FUR_SHADER,
		{"base_color": Color(0.72, 0.42, 0.22)})
	_check(independent != fur_a and _same_shader(independent, fur_a),
		"factory calls with identical source reuse the program, not the material")
	var alternate_code := Visuals.FUR_SHADER.replace("34.0", "35.0")
	var alternate := Visuals._material(alternate_code, {"base_color": color_a})
	_check(alternate.shader != fur_a.shader
			and alternate.shader.get_rid() != fur_a.shader.get_rid(),
		"different shader source creates a distinct shader object and RID")
	_check(alternate.shader.code == alternate_code
			and fur_a.shader.code == Visuals.FUR_SHADER,
		"full source strings remain exact and unmodified")

	var leaves_a := Visuals.foliage_material(Color(0.12, 0.32, 0.16))
	var leaves_b := Visuals.foliage_material(Color(0.28, 0.48, 0.12))
	_check(leaves_a != leaves_b and _same_shader(leaves_a, leaves_b),
		"foliage palette variants share only their shader")
	_check(leaves_a.get_shader_parameter("base_color")
			!= leaves_b.get_shader_parameter("base_color"),
		"quantized foliage colors remain independent")
	var ground := Visuals.far_ground_material()
	var skyline_ground := Visuals.skyline_ground_material()
	_check(_independent_handoff(ground, skyline_ground),
		"ground LOD tiers share a program but retain separate handoff uniforms")
	var water := Visuals.far_water_material()
	var skyline_water := Visuals.skyline_water_material()
	_check(_independent_handoff(water, skyline_water)
			and water.get_shader_parameter("water_microdetail")
			== skyline_water.get_shader_parameter("water_microdetail"),
		"water LOD tiers retain handoffs and their shared texture")
	var canopy := Visuals.far_jungle_material()
	var skyline_canopy := Visuals.skyline_jungle_material()
	_check(_independent_handoff(canopy, skyline_canopy),
		"canopy LOD tiers share a program without merging their handoffs")
	var still_vine := Visuals.vine_material(0.0)
	var moving_vine := Visuals.vine_material(0.25)
	_check(_same_shader(still_vine, moving_vine)
			and is_zero_approx(float(still_vine.get_shader_parameter("wind_strength")))
			and is_equal_approx(float(moving_vine.get_shader_parameter("wind_strength")), 0.25),
		"vine motion variants retain independent wind uniforms")

	var materials: Array[ShaderMaterial] = [fur_a, fur_b, independent, alternate,
		leaves_a, leaves_b, ground, skyline_ground, water, skyline_water,
		canopy, skyline_canopy, still_vine, moving_vine]
	var original_shaders: Array[Shader] = []
	for material in materials:
		original_shaders.append(material.shader)
	Visuals.set_season(SeasonalCycle.Season.WINTER)
	Visuals.set_far_focus(Vector3(240.0, 0.0, 400.0))
	var immutable := true
	for index in range(materials.size()):
		immutable = immutable and materials[index].shader == original_shaders[index]
	for code in Visuals._shaders_by_source:
		immutable = immutable and Visuals._shaders_by_source[code].code == code
	_check(immutable and float(leaves_a.get_shader_parameter("snow_amount")) == 1.0
			and ground.get_shader_parameter("focus_xz") == Vector2(240.0, 400.0),
		"live seasonal and focus updates change uniforms without changing shader code or identity")
	var program_ids: Dictionary = {}
	for material in materials:
		program_ids[material.shader.get_rid()] = true
	_check(program_ids.size() == 7 and materials.size() == 14,
		"fourteen independent materials use exactly seven required shader programs")

	print("VISUALSHADERCACHETEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _same_shader(a: ShaderMaterial, b: ShaderMaterial) -> bool:
	return a.shader == b.shader and a.shader.get_rid().is_valid() \
		and a.shader.get_rid() == b.shader.get_rid()


func _independent_handoff(a: ShaderMaterial, b: ShaderMaterial) -> bool:
	return a != b and _same_shader(a, b) \
		and a.get_shader_parameter("near_fade") != b.get_shader_parameter("near_fade")


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
