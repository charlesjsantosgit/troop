class_name FrontierServicePoints
extends RefCounted
## Physical service doors shared by graphics, interaction and server reach tests.
## Pure data: safe to load on a dedicated server without rendering scripts.
const EARTH := {
	"town_square":Vector2(3.8,-0.3),"cooperative":Vector2(-35,-23),
	"earth_market":Vector2(0,-15),"water":Vector2(-18,-18),
	"kitchen":Vector2(18,-18),"warehouse":Vector2(30,-35),
	"workshop":Vector2(40,15),"oil_rig":Vector2(120,-35),
	"refinery":Vector2(95,10),"gas_station":Vector2(60,35),
	"airfield":Vector2(100,65),"carrier":Vector2(145,-80),
	"housing":Vector2(-32,25),
}
const MOON := {
	"town_square":Vector2(4,2.5),"lunar_greenhouse":Vector2(-23,-10.3),
	"moon_market":Vector2(0,-12),"solar_array":Vector2(28,-18.6),
	"solar":Vector2(28,-18.6),"habitat":Vector2(-15,13),
	"housing":Vector2(-15,13),"cargo":Vector2(28,20),
	"ice_mine":Vector2(-55,-35),"water":Vector2(-55,-35),
}
static func service_position(planet: String, id: String) -> Vector2:
	return (MOON if planet=="moon" else EARTH).get(id,Vector2.INF)
