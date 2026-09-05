# Crownreach city life, vehicles and recovery

Implemented in the local `codex/crownreach-city-housing` source worktree, September 5, 2026. The root `Play TROOP.command` targets this worktree. No installer or managed server was published by this task. Client and server require source protocol 18.

## Characters and scale

Every person uses the existing player `MonkeyRig`: the same head, muzzle, ears, torso, limbs, paws and articulated tail. Standing heights vary deterministically from **1.7018 to 1.8796 metres (5 ft 7 in to 6 ft 2 in)**. The player remains **1.8288 metres (6 ft)**. Drivers are seated through the actual rig and four hand/foot contact targets; they are not shrunk to fit the cabin. All ten car models fit the minimum, player and maximum heights inside the actual roof, floor and sloped glazing.

`city_monkey_models.gd` derives cached posed meshes from all 55 original visible body meshes, retaining five material groups and 6,534 vertices. The far walking atlas is rendered from those same meshes, with source SHA-256 provenance. Close collision actors, park visitors, dog walkers, cyclists, yoga participants, firefighters and builders retain that anatomy. Distant representations reduce rendering cost rather than introducing a different person model.

The final character audit also replaced the approximate ragdoll body with the actual player-model meshes on the existing physical joints. Earth/Moon merchants and workers, AI, remote characters and defeated monkeys use the same anatomy and stature contract. See [canonical character coverage](CANONICAL_CHARACTERS.md).

The municipality contains **2,496 blocks and 38,269 buildings**, approximately **30.034 square miles**. Buildable blocks measure **264 by 900 feet**, enclosed by 24-metre streets. The original 36,861 addresses and their housing/service roles survive; addresses displaced by the park move to the new eastern neighborhoods. The requested block dimensions are a design choice inspired by New York, not a claim that every New York block has identical dimensions. [NYC's assessment guidance](https://www.nyc.gov/html/nycbe/downloads/pdf/AssessmentGrantsPoliciesProceedures.pdf) describes the city's varying block lengths.

## Population and park

The census is exactly **100,000 residents**, represented by persistent district occupancy, workforce, demand and service state. **6,000 cars and 23,920 sidewalk walkers** populate the generated streets. Nearby traffic promotes at most 24 cars and 64 walkers to physical collision actors; distant people and cars retain visible movement above the city. Safely separated downtown allocations concentrate more of the bounded fleet on busy streets. The measured local view contained eight cars within 120 metres and 37 monkeys within 80 metres. These are bounded traffic and crowd simulations, not 100,000 independent people with full physics and individual inventories.

Lantern Central Park occupies about **3.11 km²**, with **2,063 trees**, walking paths, a separate cycle loop, social terraces, yoga, dogs and walkers. Its natural lake has approximately **160,515 m² of water** and four usable rowboats. Water, terrain depth, routes, boat boundaries and map outlines share geometry. Boat controls include rowing, steering, returning to the dock and a supported dry-land exit. See [park controls and implementation](LANTERN_CENTRAL_PARK.md).

The park design draws from the [Central Park Conservancy's history](https://www.centralparknyc.org/park-history) and [boating guide](https://www.centralparknyc.org/activities/guides/boating): a large public landscape combines woodland, paths, recreation and water. This is an original game park, not a scanned reproduction of Central Park.

## Vehicles and shopping

Ten life-size fictional road models have distinct bodywork, dimensions, mass, wheelbase, wheel radius and engine output: hatchback, sedan, estate, coupe, crossover, SUV, pickup, cargo van, taxi and shuttle. They use transparent glazing, visible canonical drivers, interiors, steering controls, wheels, brake lights and turn indicators. The designs use plausible class proportions informed by primary [Toyota compact-car specifications](https://media.toyota.co.uk/the-new-toyota-corolla/), [BMW sedan dimensions](https://www.bmwusa.com/vehicles/3-series/3-series-sedan/bmw-3-series-sedan-technical-highlights.html/330i-sedan.bmw), and [Ford Transit specifications](https://media.ford.com/content/dam/fordmedia/North%20America/US/product/2021/transit/21Transit_TechSpecs.pdf). They are procedural fictional vehicles, not licensed or photogrammetric replicas.

`/vehicle` opens a searchable **A–Z grid of 15 vehicles**, with actual rendered model thumbnails. It includes the ten road models plus the existing motorcycle, safari jeep, airboat and fighter jet, and the park rowboat. Selecting a rowboat takes an Earth admin to the park dock. Named slash-command variants remain available.

Twelve Crown Motor Galleries sell cars through the existing credit economy. Purchases decrement finite stock, register an owner-only vehicle and deliver it to a physical rear court. Display cars occupy a separate row. Each resident owns at most three cars, and the city supports 64 owned vehicles. Collection at a dealership restores a saved vehicle's location; occupied vehicles cannot be recalled. Ownership survives reconnects and server restarts.

Ten store categories sell groceries, bakery goods, coffee, meals, hardware, garden supplies, outdoor goods, energy equipment, fabric and pantry items. Purchases transfer exact credits and existing finite goods into the actual Earth backpack. Prices and stock are authoritative. Replayed requests cannot charge twice or duplicate inventory.

Player cars use real rigid-body suspension, tire grip, steering, braking, automatic gears and model-specific power curves. Service-brake torque scales with loaded mass and wheel radius; large vans do not share compact-car brake strength. Actual tests drive every model over a real collider, accelerate, steer and stop. Ambient traffic follows the road controller rather than running thousands of full rigid-body drivetrains. See the implemented [U.S. traffic profile and limits](CITY_TRAFFIC.md).

## Furniture and collisions

Chairs, sofas and beds have separate approach, turn, lower, sit/recline/sleep and rise paths. The collision guard checks the full animated body, including angular sweeps, hands, feet and tail. An obstruction pauses the movement; a blocked standing route is refused. Furnished-room tails stay tucked so a restored walking pose does not sweep through a dining table. Remote poses and server path timing use the same motion contract. The player collision is not simply disabled while sitting.

Vehicle impacts use physical contact normals and closing speed, with a continuous aircraft sweep against the actual city massing. Hard braking by itself does not create a crash. Impacts deform independent vehicle meshes, reduce drive power, disable severely wrecked vehicles and emit bounded fragments, smoke and a flash. Struck traffic cars stop, show hazards and retain damage through physical/distant handoff while following cars queue. Aircraft damage disables turbine thrust and afterburner. Severe aircraft impacts detach the actual wing, stabilizer, nose and tail meshes around a burned central wreck, with a fireball that fades into smoke. Six detached chunks preserve the source geometry and materials; at most three breakup effects run for twelve seconds each. Small vehicle fragments sweep actual collision space.

A severe aircraft/building impact replaces the actual facade and colliders with a damaged shell. The plane-shaped opening removes wall geometry and collision cells; it is not a flat decal. Fire, smoke, scattered rubble and a scripted upper-floor collapse accompany emergency road closures. Fire engines, repair vans, hose operators and tail-assisted construction workers approach through real streets. Scaffolding and successive construction stages restore the building, with the original geometry returning completely the **following game day at 06:00**. The game day lasts 1,200 simulation seconds; `/time` changes the sky without skipping the economic clock.

Building incidents persist and replicate through the server. The authority checks the authenticated pilot's exact aircraft claim, Earth realm, recent observed approach, location and actual building intersection; it rejects duplicated or invented incidents. Four incidents are allowed at once. Player vehicle dents and wreck state also replicate through the existing authorized driver's state/release messages. The authority retains increasing damage revisions, rejects unclaimed reports and blocks boarding a wreck. Live observers see one aircraft breakup; late joiners receive the stable burned remnant without replaying an old explosion. Snapshot pages remain below 16 KiB. Vehicle damage lasts for the current session; building incidents and purchased-car ownership additionally survive server restarts. Ambient traffic remains a client-side simulation. This is a bounded game destruction system, not a finite-element structural, fuel-combustion or forensic crash simulation. [Emergency response details](CITY_EMERGENCY_RESPONSE.md) describe the crews and reconstruction controls.

## Verification

| Gate | Verified coverage | Result |
| --- | --- | --- |
| `citylifetest` | All old addresses preserved, new layout, exact census, ten store categories, twelve dealerships, finite purchase/save cases, ten car construction paths | 38,447/38,447 |
| `cityplantest` | Complete rectangular municipality, address and parcel geometry, boundaries and population | 2,636/2,636 |
| `cityremaketest` | Physical transit/arrival, building collisions, lake traversal, store purchase, all 2,496 far blocks | 54/54 |
| `cityeconomytest` | Conservation, finite stock, storage, jobs, migration and maximum property state | 137/137 |
| `citydrivingtest` | Ten actual vehicles: suspension contact, acceleration, turn stability and full braking without false crash | 40/40 |
| `citydisastertest` | Actual wall opening/collision, collapse, reconstruction, save/reload/next day, authority checks | 29/29 |
| `vehicleimpacttest` | Actual wall contact, dents, severe/moderate damage, aircraft source triangles, detached wings/nose/tail, one-shot explosion, unchanged pilot/collider and effect bounds | 27/27 headless; 30/30 native |
| `citytrafficimpacttest` | Actual rigid-body contact, struck traffic damage, hazards, queue, handoff, recovery and crossing pole clearance | 16/16 |
| `citytraffictest` | Canonical model provenance, all cabin heights, safely spaced downtown drivers, aerial visibility and physical intersections | 67/67 |
| `avatarheighttest` | Canonical living/dead anatomy, exact endpoint/player heights, actual lunar characters and physical ragdoll/head-detachment behavior | 40/40 |
| `parkactivitytest` | Paths, lake, dogs, yoga, exact actors, actual rowing/return/safe exit; stationary steering also respects the full hull | 43/43 headless; 51/51 native |
| `cityemergencytest` | Real road approaches, blocked traffic avoidance, hose crews, tail-carried timber, damaged tower, staged rebuild and next-day restoration | 14/14 headless; 23/23 native |
| `cityfurnituretest` | Full-body, dynamic-obstacle, all standing exits, authority and 719 actual replicated pose checks | 190/190 |
| Standing exit audit | Restored body/tail clearance at every furnished exit | 83/83 |
| Penthouse suite | Actual rooftop city, all 19 anchors, normal E controls and indexed mesh coverage | 146/146 native |
| `cityuitest` | Compact property/storage/shop/dealership cards, item selection, purchase and collection actions | 139/139 headless and native |
| `worldmaptest` / `cartographytest` | Earth/Moon projections, shared terrain, roads, lake and municipal-edge parcel visibility | 45/45 and 54/54 |
| `citysystemstest` | Power, water, waste and funded services | 30/30 |
| Actual local ENet | Buyer, second resident, replay protection, owner-only car, reconnect and restart collection | All roles pass |
| Actual ENet crash replication | Authorized driver, outsider rejection, fatal release, observer explosion, disabled remote turbine, no-healing revisions, bounded late-join wreck state and reset | 46/46 across four processes |
| `netsecuritytest` | Existing registration, movement, vehicle-claim and voice bounds | 56/56 |

Current logs include `artifacts/city-life/`, `artifacts/central-park/`, `artifacts/emergency-response/`, `artifacts/city-traffic/`, `artifacts/city-penthouse/` and the isolated directory recorded in `artifacts/crownreach/network-result.json`. Each test checks its own subsystem; prior baseline totals are not substituted for these gates.

## Performance and remaining limits

The native park capture on Apple M4, macOS 27 and Metal produced **960×540 saved images** and measured 240 settled frames: median 19.654 ms, p95 29.837 ms and p99 31.471 ms, while other headless task work was running. Its logical viewport and adaptive 3D render scale were not recorded. This is a local functional capture, not a thermal or hardware-wide certification. The first dense-city pass exposed excessive per-person scene nodes and repeated global neighbor-bucket rebuilding. Exact canonical pose meshes and incremental vehicle buckets resolved that measured bottleneck. The final profiler prepared all 2,496 blocks before collecting 180-frame samples with normal game processing and the denser downtown allocation. At the actual **1080×900 saved output**, street median was **14.099 ms**, p95 **26.381 ms**, p99 **34.313 ms**; aerial median **13.590 ms**, p95 **22.793 ms**, p99 **23.578 ms**. Adaptive 3D render scale was also unrecorded in this sample. All 6,000 cars and 23,920 walkers remained represented. The street frame used 545 draw calls and 5.46 million primitives; the citywide population occupied 168 batches. These short M4 samples do not establish a sustained 60 FPS floor; slower frames and initial staging remain. Data, including the measured output dimensions and nearby cohort, is in `artifacts/city-traffic/population-profile.json`.

Photoreal scanned art, independently simulated lives for every census resident, detailed interiors on every tower floor, all U.S. traffic-law exceptions and network-authoritative ambient traffic are not implemented. Some native/headless shutdowns still report the existing particle/shader resource cleanup warning. Source tests and native captures do not establish packaged-app, public-server or other-hardware readiness.
