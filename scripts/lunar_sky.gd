class_name LunarSky
extends RefCounted
## A real photographic sky with an optional astronomical observation overlay.
## Planets use JPL's approximate Keplerian elements for a reproducible epoch;
## the compact game's solar cycle rotates this celestial frame, not the photograph.

const PANORAMA_PATH := "res://assets/astronomy/eso_milky_way.jpg"
const EARTH_PATH := "res://assets/astronomy/nasa_blue_marble.png"
const FIGURES_PATH := "res://assets/astronomy/nasa_constellation_figures.png"
const EPOCH_UNIX := 1788436800.0 # 2026-09-03 12:00 UTC; deterministic simulation epoch.
const EARTH_DIRECTION := Vector3(-0.4802642, 0.3802092, -0.7904349)
const SUN_DIAMETER_DEGREES := 0.533
const EARTH_DIAMETER_DEGREES := 1.90
const PLANET_NAMES := ["Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]
# a, e, I, L, longitude of perihelion, longitude of ascending node;
# next six entries are their rates per Julian century. JPL table 1 (1800-2050).
const ELEMENTS := {
    "Mercury": [0.38709927,0.20563593,7.00497902,252.25032350,77.45779628,48.33076593,0.00000037,0.00001906,-0.00594749,149472.67411175,0.16047689,-0.12534081],
    "Venus": [0.72333566,0.00677672,3.39467605,181.97909950,131.60246718,76.67984255,0.00000390,-0.00004107,-0.00078890,58517.81538729,0.00268329,-0.27769418],
    "Earth": [1.00000261,0.01671123,-0.00001531,100.46457166,102.93768193,0.0,0.00000562,-0.00004392,-0.01294668,35999.37244981,0.32327364,0.0],
    "Mars": [1.52371034,0.09339410,1.84969142,-4.55343205,-23.94362959,49.55953891,0.00001847,0.00007882,-0.00813131,19140.30268499,0.44441088,-0.29257343],
    "Jupiter": [5.20288700,0.04838624,1.30439695,34.39644051,14.72847983,100.47390909,-0.00011607,-0.00013253,-0.00183714,3034.74612775,0.21252668,0.20469106],
    "Saturn": [9.53667594,0.05386179,2.48599187,49.95424423,92.59887831,113.66242448,-0.00125060,-0.00050991,0.00193609,1222.49362201,-0.41897216,-0.28867794],
    "Uranus": [19.18916464,0.04725744,0.77263783,313.23810451,170.95427630,74.01692503,-0.00196176,-0.00004397,-0.00242939,428.48202785,0.40805281,0.04240589],
    "Neptune": [30.06992276,0.00859048,1.77004347,-55.12002969,44.96476227,131.78422574,0.00026291,0.00005105,0.00035372,218.45945325,-0.32241464,-0.00508664],
}
const SKY_SHADER := """
shader_type sky;
uniform sampler2D photographic_sky : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D earth_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D constellation_figures : filter_linear_mipmap, repeat_enable;
uniform mat3 world_to_galactic = mat3(1.0);
uniform vec3 sun_direction = vec3(-0.29,0.78,-0.55);
uniform vec3 earth_direction = vec3(-0.48,0.38,-0.79);
uniform vec3 planet_directions[7];
uniform float observation_strength = 0.0;
uniform float earth_rotation = -0.45;
uniform float earth_visibility = 1.0;
uniform float atmosphere_strength = 0.0;
uniform vec4 atmosphere_top : source_color = vec4(0.027,0.082,0.239,1.0);
uniform vec4 atmosphere_horizon : source_color = vec4(0.063,0.169,0.357,1.0);
uniform vec4 atmosphere_bottom : source_color = vec4(0.008,0.025,0.075,1.0);
uniform float atmosphere_energy = 0.72;
vec2 galactic_uv(vec3 d) {
    return vec2(0.5 - atan(d.y,d.x) / 6.28318530718,
        0.5 - asin(clamp(d.z,-1.0,1.0)) / 3.14159265359);
}
vec3 atmospheric_scattering(vec3 d) {
    float gradient=pow(clamp(abs(d.y),0.0,1.0),0.58);
    // One horizon color prevents a false plane when an elevated eye sees below
    // its local horizontal. The same gradient supplies only atmospheric radiance.
    return mix(mix(atmosphere_horizon.rgb,atmosphere_bottom.rgb,gradient),
        mix(atmosphere_horizon.rgb,atmosphere_top.rgb,gradient),
        smoothstep(-0.04,0.04,d.y))*atmosphere_energy;
}
void sky() {
    COLOR = atmospheric_scattering(normalize(EYEDIR))*atmosphere_strength;
    if (!AT_CUBEMAP_PASS) {
        vec3 d = normalize(EYEDIR);
        vec2 uv = galactic_uv(normalize(world_to_galactic*d));
        // Long-exposure photograph. Observation view makes its faint nebulae
        // readable; no blue atmospheric gradient or atmospheric star twinkle.
        vec3 photo = texture(photographic_sky,uv).rgb;
        COLOR = photo * mix(0.65,3.2,observation_strength);
        float figures = texture(constellation_figures,uv).r;
        COLOR += vec3(0.14,0.43,0.61)*figures*observation_strength*0.62;
        for (int i=0; i<7; i++) {
            float separation = length(d-planet_directions[i]);
            float width = mix(0.00055,0.0017,observation_strength);
            vec3 tint = vec3(0.93,0.85,0.68);
            if (i==2) { tint=vec3(1.0,0.38,0.19); }
            if (i==5) { tint=vec3(0.45,0.80,0.87); }
            if (i==6) { tint=vec3(0.22,0.41,0.90); }
            // Uranus and Neptune require the instrument exposure to be useful.
            float strength = i>=5 ? mix(0.015,0.9,observation_strength) : 1.0;
            COLOR += tint*(1.0-smoothstep(width*0.3,width,separation))*strength*1.7;
        }
        vec3 ed = normalize(earth_direction);
        float ef = dot(d,ed);
        if (earth_visibility>0.0 && ef>0.99970) {
            vec3 right = normalize(cross(vec3(0.0,1.0,0.0),ed));
            vec3 up = normalize(cross(ed,right));
            vec2 p = vec2(dot(d,right),dot(d,up)) / 0.0165799;
            float r2 = dot(p,p);
            if (r2<1.05) {
                float facing = sqrt(max(0.0,1.0-r2));
                vec3 n = normalize(right*p.x+up*p.y-ed*facing);
                vec2 earth_uv=vec2(0.5+atan(n.z,n.x)/6.28318530718+earth_rotation,
                    0.5-asin(clamp(n.y,-1.0,1.0))/3.14159265359);
                vec3 earth = texture(earth_map,earth_uv).rgb;
                float sunlight=max(dot(n,normalize(sun_direction)),0.0);
                vec3 lit = earth*(0.006+sunlight*1.65);
                float limb=pow(1.0-facing,4.0)*smoothstep(-0.10,0.35,dot(n,sun_direction));
                lit+=vec3(0.08,0.30,0.72)*limb*0.30;
                COLOR=mix(COLOR,lit,1.0-smoothstep(0.985,1.02,r2));
            }
        }
        // 0.533 degree solar disc: no atmospheric corona/glow in a vacuum.
        float sun_distance=length(d-normalize(sun_direction));
        float sun=1.0-smoothstep(0.00456,0.00473,sun_distance);
        COLOR=mix(COLOR,vec3(9.0,8.55,7.70),sun);
        COLOR=mix(COLOR,atmospheric_scattering(d),atmosphere_strength);
    }
}
"""

static var _shared_shader: Shader
static var _shared_panorama: Texture2D
static var _shared_earth: Texture2D
static var _shared_figures: Texture2D
var material: ShaderMaterial
var observation_mode := false
var _frame := Basis.IDENTITY
var _epoch_sun := Vector3.UP
var _base_planets := PackedVector3Array()
var _targets: Array[Dictionary] = []
var _sun_direction := Vector3(-0.29,0.78,-0.55).normalized()

func _init() -> void:
    if not _shared_shader:
        _shared_shader = Shader.new()
        _shared_shader.code = SKY_SHADER
        _shared_panorama = load(PANORAMA_PATH) as Texture2D
        _shared_earth = load(EARTH_PATH) as Texture2D
        _shared_figures = load(FIGURES_PATH) as Texture2D
    material = ShaderMaterial.new()
    material.shader = _shared_shader
    material.set_shader_parameter("photographic_sky",_shared_panorama)
    material.set_shader_parameter("earth_map",_shared_earth)
    material.set_shader_parameter("constellation_figures",_shared_figures)
    material.set_shader_parameter("earth_direction",EARTH_DIRECTION)
    _build_ephemeris(EPOCH_UNIX)
    set_sun_direction(_sun_direction)

func get_material() -> ShaderMaterial:
    return material

func set_observation_mode(enabled: bool) -> void:
    observation_mode = enabled
    material.set_shader_parameter("observation_strength",1.0 if enabled else 0.0)

func set_sun_direction(direction: Vector3) -> void:
    if direction.length_squared()<0.0001:
        return
    _sun_direction=direction.normalized()
    # Preserve every star/planet's relation to the epoch Sun while adapting to
    # the accelerated solar clock. This is an observation model, not navigation.
    _frame=Basis(Quaternion(_epoch_sun,_sun_direction))
    material.set_shader_parameter("world_to_galactic",_frame.inverse())
    material.set_shader_parameter("sun_direction",_sun_direction)
    var planets := PackedVector3Array()
    for direction_v in _base_planets:
        planets.append(_frame*direction_v)
    material.set_shader_parameter("planet_directions",planets)

func get_targets() -> Array[Dictionary]:
    var results: Array[Dictionary] = [
        {"name":"Sun","direction":_sun_direction,"detail":"0.533 degree disc · accelerated lunar day"},
        {"name":"Earth","direction":EARTH_DIRECTION,"detail":"NASA Blue Marble · 1.90 degree disc · phase follows Sun"},
    ]
    for target in _targets:
        var copy: Dictionary=target.duplicate()
        copy.direction=_frame*(target.direction as Vector3)
        results.append(copy)
    return results

func attribution_text() -> String:
    return "Sky photograph: ESO/S. Brunier · Earth and constellation guide: NASA/GSFC"

func diagnostics() -> Dictionary:
    return {"photograph_loaded":_shared_panorama!=null,"earth_loaded":_shared_earth!=null,
        "constellation_guide_loaded":_shared_figures!=null,"planets":_base_planets.size(),
        "constellations":88,"epoch_utc":"2026-09-03 12:00 UTC","observation_mode":observation_mode,
        "sun_degrees":SUN_DIAMETER_DEGREES,"earth_degrees":EARTH_DIAMETER_DEGREES,
        "source":"ESO/S. Brunier + NASA/GSFC + JPL approximate elements"}

func _build_ephemeris(unix_time: float) -> void:
    var century := (unix_time/86400.0+2440587.5-2451545.0)/36525.0
    var earth := _orbital_position("Earth",century)
    _epoch_sun=_equatorial_to_galactic(_ecliptic_to_equatorial(-earth)).normalized()
    _base_planets.clear()
    _targets.clear()
    for planet in PLANET_NAMES:
        var direction := _equatorial_to_galactic(_ecliptic_to_equatorial(_orbital_position(planet,century)-earth)).normalized()
        _base_planets.append(direction)
        _targets.append({"name":planet,"direction":direction,
            "detail":"JPL approximate epoch position · instrument visibility" if planet in ["Uranus","Neptune"]
            else "JPL approximate epoch position"})
    # J2000 object coordinates; actual photographic features share this frame.
    for entry in [
        ["Orion",83.82,-5.39,"Orion constellation · M42 nebula"],
        ["Cassiopeia",15.0,60.0,"W-shaped constellation"],
        ["Ursa Major",165.0,56.0,"Big Dipper asterism"],
        ["Crux",186.65,-60.0,"Southern Cross constellation"],
        ["Andromeda Galaxy",10.6847,41.269,"M31 · photographic exposure"],
        ["Large Magellanic Cloud",80.89,-69.76,"Milky Way satellite galaxy"],
        ["Small Magellanic Cloud",13.19,-72.83,"Milky Way satellite galaxy"],
        ["Lagoon Nebula",270.925,-24.38,"M8 · photographic exposure"],
        ["Milky Way centre",266.405,-28.936,"Sagittarius · Galactic centre"],
    ]:
        var ra := deg_to_rad(float(entry[1]))
        var dec := deg_to_rad(float(entry[2]))
        var eq := Vector3(cos(dec)*cos(ra),cos(dec)*sin(ra),sin(dec))
        _targets.append({"name":entry[0],"direction":_equatorial_to_galactic(eq).normalized(),"detail":entry[3]})

static func _orbital_position(planet: String,century: float) -> Vector3:
    var values: Array=ELEMENTS[planet]
    var elements: Array[float]=[]
    for i in range(6):
        elements.append(float(values[i])+float(values[i+6])*century)
    var a: float=elements[0]
    var e: float=elements[1]
    var inclination := deg_to_rad(elements[2])
    var perihelion := deg_to_rad(elements[4]-elements[5])
    var node := deg_to_rad(elements[5])
    var mean_anomaly := wrapf(deg_to_rad(elements[3]-elements[4]),-PI,PI)
    var eccentric_anomaly := mean_anomaly
    for i in range(8):
        eccentric_anomaly-=(eccentric_anomaly-e*sin(eccentric_anomaly)-mean_anomaly)/(1.0-e*cos(eccentric_anomaly))
    var x := a*(cos(eccentric_anomaly)-e)
    var y := a*sqrt(1.0-e*e)*sin(eccentric_anomaly)
    return Vector3(
        (cos(perihelion)*cos(node)-sin(perihelion)*sin(node)*cos(inclination))*x
            +(-sin(perihelion)*cos(node)-cos(perihelion)*sin(node)*cos(inclination))*y,
        (cos(perihelion)*sin(node)+sin(perihelion)*cos(node)*cos(inclination))*x
            +(-sin(perihelion)*sin(node)+cos(perihelion)*cos(node)*cos(inclination))*y,
        sin(perihelion)*sin(inclination)*x+cos(perihelion)*sin(inclination)*y)

static func _ecliptic_to_equatorial(p: Vector3) -> Vector3:
    var obliquity := deg_to_rad(23.43928)
    return Vector3(p.x,cos(obliquity)*p.y-sin(obliquity)*p.z,sin(obliquity)*p.y+cos(obliquity)*p.z)

static func _equatorial_to_galactic(p: Vector3) -> Vector3:
    # ICRS/J2000 to Galactic rotation (Hipparcos convention used by NASA SVS).
    return Vector3(Vector3(-0.05487556,-0.87343709,-0.48383502).dot(p),
        Vector3(0.49410943,-0.44482963,0.74698224).dot(p),
        Vector3(-0.86766615,-0.19807637,0.45598378).dot(p))
