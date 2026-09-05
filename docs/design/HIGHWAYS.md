# Crownreach controlled-access highways

Implemented September 5, 2026 in the playable Moon worktree. This is a coherent fictional U.S. road profile for gameplay, not a claim of compliance with every jurisdiction's engineering or traffic laws.

## Playable route

H-1, the Crownreach Beltway, is a continuous rounded loop 250 metres outside the city's current rectangular boundary. Its four 550-metre-radius bends connect the long straight sections. Its road deck is ten metres above the city's eight-metre datum. H-2, the Westgate Expressway, follows the existing settlement access corridor from x=1,020 to the surface distributor west of Exit 1. It has smooth, 620-metre-long vertical transitions at both signed terminals. The village, town and suburb roads connect to that existing distributor; the new motorway does not replace their roads or insert motorway lanes through their pedestrian streets.

The beltway has four complete diamond interchanges: Westgate / Settlements, Northlight, East Market and South Depot. Each has two exits and two entrances, with directionally correct right-side connections. Each ground-level cross street passes below the mainline and reaches an existing Crownreach boundary street. Exit 1's z=0 distributor also joins H-2. There are no traffic lights or crossing ground streets on the elevated beltway. Exit ramps terminate at signed surface STOP junctions. The terminal route and interchange links form a continuous drivable network.

Each direction has two 3.66-metre travel lanes, a 1.22-metre inner shoulder and a 3.05-metre outer shoulder. A 4.88-metre central separation contains a continuous concrete barrier. Mainline edges have barriers outside interchange merge/diverge zones. The beltway is posted at 55 mph and the expressway at 65 mph. Ramps have a 35 mph regulatory sign and an advance exit advisory; distributor streets use 25 mph. The selected limits and geometry are authored game design values, rather than traffic-study findings.

Ramp paths contain a 120-metre lateral transition and a 260-metre parallel speed-change section, followed by a curved graded connection. The measured maximum grade over every generated road segment is 4.48%. Opposite carriageways have opposite legal travel directions. Advance guide signs, numbered exits, roadside speed-limit signs, ramp STOP / DO NOT ENTER signs and freeway-end signs identify the route. The map draws the same plan and labels access points.

## Physical implementation

`highway_plan.gd` generates all geometry deterministically from the current CityPlan bounds. One spatial index provides road position, legal direction, speed and terrain-clearance queries. `highway_world.gd` builds the same polylines into real StaticBody3D deck meshes, concrete slab sides and undersides, central / outer barrier collision and regularly spaced supporting piers. The road surface is not an image laid over terrain. Vehicle suspension raycasts hit its physical triangles. Ground under overpasses stays low and the distributor has its own independent collider, preserving actual underpass clearance.

The terrain contract calls HighwayPlan from CrownreachTerrain, so near collision terrain, far LOD terrain, vegetation reservation and surface coloring agree on the cleared corridor. Trees and procedural buildings are excluded from road footprints. Existing city content is preserved. The west-edge civic parcels near x=CityPlan.MIN_X-38 and z=43/-43/-116 remain outside the ramp footprints.

The geometry is created once per scene and divided into 137 compact spatial tiles. There is no per-frame highway mesh regeneration or replication of decorative road geometry. The world map reads the same roads. The physical highway is shared deterministic geometry on all peers; ambient highway traffic is a separate behavior system.

## Public API

- `HighwayWorld.configure(world)` constructs the world. Add the HighwayWorld node beneath the Earth world, then configure it once. No update-focus method is required.
- `HighwayPlan.road_sample(Vector3)` returns the road ID, kind, closest road point, legal travel direction, speed in mph and m/s, signed lateral offset, along-road coordinate and `on_road`. It includes vertical distance when choosing an overlapping road, so police can distinguish the distributor below a bridge from the highway above it.
- `posted_speed(Vector3)` returns m/s when the player is physically on this network, and zero elsewhere. Other road systems can supply their limits after that zero result.
- `nearest_access(Vector3)` returns the nearest access record and straight-line distance in metres.
- `route_guidance(Vector3)` provides the current road / limit and nearest access name. This is nearby-access guidance, not turn-by-turn routing or a promise that the nearest exit is ahead in the current direction.
- `roads()` and `access_points()` are read-only shared records for maps and traffic planning. Callers must not mutate them.

## Primary references

- [FHWA current MUTCD](https://mutcd.fhwa.dot.gov/kno_11th_Editionr1.htm) identifies the 11th Edition incorporating Revision 1, December 2025, as current. The [complete official PDF](https://mutcd.fhwa.dot.gov/pdfs/11th_Editionr1/mutcd11theditionr1hl.pdf) was read locally. Section 3A.03 informed the yellow left / white right edge convention. Section 3B.07 informed dotted white separation beside speed-change lanes. Section 3B.08 describes channelizing lines at ramp neutral areas. Chapter 2E informed green advance interchange guidance. This implementation uses simplified game sign layouts and markings, not certified production sign drawings.
- [California DMV: Navigating the Roads](https://www.dmv.ca.gov/portal/handbook/california-driver-handbook/navigating-the-roads/) informed right-side entrance/exit positioning, same-direction broken white lane lines, and separation from opposing traffic. No assumption is made that California law governs this fictional city.

## Validation and remaining boundaries

Run `/opt/homebrew/bin/godot --headless --path . -- highwaytest` from this worktree. The registered main-scene test checks connected endpoints, all road grades, legal directions, speed queries, terrain clearance, independent upper/lower collision at Exit 1, and actual raycast support at the start, middle and end of every ramp. An ordinary CityCar rests on four loaded tires, accelerates using its real drivetrain on the elevated expressway, and brakes to a stop without losing road support. The test does not set the vehicle along a prescribed rail.

Running the same mode with the native renderer saves `artifacts/highways/westgate-interchange.png` and `driver-view.png`. These are isolated physical-highway fixtures for examining the geometry and markings; they do not represent a full-city traffic benchmark. Native M4 rendering passed the same checks. The existing renderer shutdown ParticlesShaderRD / shader RID diagnostic remains visible at teardown.

The highway is drivable, connected and physically collidable. It does not yet add a dedicated highway NPC driver population, lane-changing traffic AI, ramp-meter signals, incident lane closures, crash attenuators, superelevation, drainage, a construction-sign library, or network-authoritative freeway traffic. The two H-2 ends are explicit surface-road terminals rather than additional free-flow motorway-to-motorway interchanges. This is not a full civil-engineering model or an all-seed/hardware road-performance certification.
