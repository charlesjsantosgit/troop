extends Node
## Driver-independent selection coverage for Windows, Mac and fallback renderers.

func run(main) -> void:
	var cases := [
		["metal", "forward_plus", Viewport.SCALING_3D_MODE_METALFX_TEMPORAL],
		["vulkan", "forward_plus", Viewport.SCALING_3D_MODE_FSR2],
		["d3d12", "forward_plus", Viewport.SCALING_3D_MODE_FSR2],
		["opengl3", "gl_compatibility", Viewport.SCALING_3D_MODE_BILINEAR],
		["metal", "mobile", Viewport.SCALING_3D_MODE_BILINEAR],
		["dummy", "", Viewport.SCALING_3D_MODE_BILINEAR],
	]
	var passed := 0
	for item in cases:
		var ok: bool = main.scaling_mode_for_backend(item[0], item[1]) == item[2]
		passed += int(ok)
		print("RENDERBACKEND %s/%s %s" % [item[0], item[1], "PASS" if ok else "FAIL"])
	print("RENDERBACKENDTEST %d/%d %s" % [passed, cases.size(),
		"PASS" if passed == cases.size() else "FAIL"])
	get_tree().quit(0 if passed == cases.size() else 1)
