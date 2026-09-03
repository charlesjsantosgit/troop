extends SceneTree
## Recreated HUD optics reuse immutable shader code, not their material state.
## godot --headless --path . --script res://tests/scopeshadercachetest.gd

const ScopeOverlay := preload("res://scripts/sniper_scope_overlay.gd")

var passed := 0
var total := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scope_a := ScopeOverlay.new()
	var scope_b := ScopeOverlay.new()
	root.add_child(scope_a)
	root.add_child(scope_b)
	scope_a.size = Vector2(1600, 900)
	scope_b.size = Vector2(1280, 720)
	var material_a: ShaderMaterial = scope_a._vignette_material
	var material_b: ShaderMaterial = scope_b._vignette_material
	var shader_rid := material_a.shader.get_rid()
	_check(shader_rid.is_valid() and material_a.shader == material_b.shader \
		and shader_rid == material_b.shader.get_rid(),
		"independent scope overlays share one shader object and RID")
	_check(material_a != material_b and material_a.get_rid() != material_b.get_rid(),
		"each overlay retains a separate material and uniform storage")
	_check(material_a.get_shader_parameter("viewport_size") == scope_a.size \
		and material_b.get_shader_parameter("viewport_size") == scope_b.size \
		and is_equal_approx(float(material_a.get_shader_parameter("aperture_radius")), 396.0) \
		and is_equal_approx(float(material_b.get_shader_parameter("aperture_radius")), 316.8),
		"different viewport sizes preserve their own optical apertures")
	scope_a.size = Vector2(1000, 600)
	_check(material_a.get_shader_parameter("viewport_size") == Vector2(1000, 600) \
		and is_equal_approx(float(material_a.get_shader_parameter("aperture_radius")), 264.0) \
		and material_b.get_shader_parameter("viewport_size") == Vector2(1280, 720) \
		and is_equal_approx(float(material_b.get_shader_parameter("aperture_radius")), 316.8),
		"resizing one scope does not change its peer's uniforms")
	scope_a.set_scope_state(true, 4.0, 100.0, 0.2, ScopeOverlay.TARGET_HEAD)
	_check(scope_a.visible and scope_a.is_processing() \
		and not scope_b.visible and not scope_b.is_processing(),
		"activation and target blinking remain local to the selected scope")
	scope_a.clear_scope()
	_check(not scope_a.visible and not scope_a.is_processing() \
		and material_a.shader.get_rid() == shader_rid \
		and material_a.shader.code == ScopeOverlay.VIGNETTE_SHADER,
		"clearing the scope preserves its original shader source and identity")
	# Keep only a non-owning RID value while all prior materials are released.
	scope_a.free()
	scope_b.free()
	material_a = null
	material_b = null
	var replacement := ScopeOverlay.new()
	root.add_child(replacement)
	replacement.size = Vector2(800, 600)
	_check(replacement._vignette_material.shader.get_rid() == shader_rid \
		and replacement._vignette_material.shader.code == ScopeOverlay.VIGNETTE_SHADER,
		"a replacement HUD reuses the program after all earlier scopes are freed")
	_check(replacement._vignette_material.get_shader_parameter("viewport_size") \
		== Vector2(800, 600) and not replacement.visible and not replacement.is_processing(),
		"replacement optics start with fresh geometry and inactive state")
	replacement.free()
	print("SCOPESHADERCACHETEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)


func _check(condition: bool, label: String) -> void:
	total += 1
	passed += int(condition)
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
