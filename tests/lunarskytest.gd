extends Node
## Optical infinity, imported astronomy data and shared solar direction contracts.
var passed := 0
var total := 0

func run() -> void:
    call_deferred("_run")

func _run() -> void:
    var sky := LunarSky.new()
    var diagnostic := sky.diagnostics()
    _check(diagnostic.photograph_loaded and diagnostic.earth_loaded and diagnostic.constellation_guide_loaded,
        "photographic sky, NASA Earth and NASA constellation guide are packaged and load")
    var photograph := sky.get_material().get_shader_parameter("photographic_sky") as Texture2D
    _check(photograph.get_width()==4000 and photograph.get_height()==2000,
        "full-sphere photograph retains its native two-to-one projection")
    var targets := sky.get_targets()
    var names: Array[String]=[]
    var unit_directions := true
    for target in targets:
        names.append(str(target.name))
        var direction: Vector3=target.direction
        unit_directions=unit_directions and direction.is_finite() and absf(direction.length()-1.0)<0.00001
    var all_planets := true
    for planet in LunarSky.PLANET_NAMES:
        all_planets=all_planets and names.has(planet)
    _check(all_planets and diagnostic.planets==7,"every other Solar System planet has an individual observation target")
    _check(unit_directions,"all star/planet/galaxy target directions are finite unit vectors")
    _check(names.has("Andromeda Galaxy") and names.has("Large Magellanic Cloud") and names.has("Lagoon Nebula"),
        "galaxies and nebulae are observation targets in the photograph's coordinate frame")
    var material_id := sky.get_material().get_instance_id()
    sky.set_observation_mode(true)
    _check(is_equal_approx(float(sky.get_material().get_shader_parameter("observation_strength")),1.0),
        "observation mode enables photographic exposure and genuine constellation guide")
    sky.set_observation_mode(false)
    _check(sky.get_material().get_instance_id()==material_id and not sky.observation_mode,
        "changing observation exposure reuses the material")
    var j2000_earth := LunarSky._orbital_position("Earth",0.0)
    _check(j2000_earth.length()>0.982 and j2000_earth.length()<0.985 and j2000_earth.y>0.96,
        "JPL orbital solver places Earth near January perihelion at J2000")
    var default_sun: Vector3=sky.get_targets()[0].direction
    sky.set_sun_direction(Vector3.ZERO)
    _check((sky.get_targets()[0].direction as Vector3).is_equal_approx(default_sun),
        "a zero solar direction cannot corrupt the sky frame")
    var moon := MoonWorld.new()
    moon.setup(404_1969)
    add_child(moon)
    _check(moon.lunar_environment.background_mode==Environment.BG_SKY and moon.lunar_environment.sky.sky_material==moon.lunar_sky.get_material(),
        "the production Moon camera uses the photographic sky at optical infinity")
    _check(not moon.has_node("AirlessBlackSky") and not moon.has_node("LunarStarField"),
        "finite shells cannot clip, occlude the real starfield or create parallax")
    var direction := Vector3(-0.4,0.3,0.5).normalized()
    moon.set_lunar_sun_direction(direction)
    var sunlight := moon.get_node("HarshLunarSunlight") as DirectionalLight3D
    var terrain := moon.terrain_mesh.material_override as ShaderMaterial
    _check(sunlight.basis.z.is_equal_approx(direction)
        and (terrain.get_shader_parameter("lunar_sun_direction") as Vector3).is_equal_approx(direction)
        and (moon.lunar_sky.material.get_shader_parameter("sun_direction") as Vector3).is_equal_approx(direction),
        "terrain shadows, terrain relief, Earth phase and visible Sun share one direction")
    _check(sunlight.directional_shadow_max_distance<=120.0,
        "distant relief does not extend expensive near-camera shadow range")
    for test_direction in [Vector3.UP,Vector3.DOWN,Vector3.RIGHT,Vector3.FORWARD]:
        moon.set_lunar_sun_direction(test_direction)
        _check(sunlight.basis.is_finite() and sunlight.basis.z.is_equal_approx(test_direction),
            "solar basis remains stable at axis %s" % test_direction)
    _check(is_equal_approx(LunarSky.SUN_DIAMETER_DEGREES,0.533) and is_equal_approx(LunarSky.EARTH_DIAMETER_DEGREES,1.9),
        "Earth and Sun retain real lunar apparent angular diameters")
    moon.queue_free()
    await get_tree().process_frame
    print("LUNARSKYTEST %d/%d %s" % [passed,total,"PASS" if passed==total else "FAIL"])
    get_tree().quit(0 if passed==total else 1)

func _check(ok: bool,label: String) -> void:
    total+=1
    if ok:
        passed+=1
    print("[%s] %s" % ["PASS" if ok else "FAIL",label])
