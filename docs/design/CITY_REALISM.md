# Crownreach: live views and functioning neighborhoods

This document describes the first September 5 realism pass. The subsequent city expansion, canonical monkey characters, fleet, park and disaster systems are documented in [CITY_LIFE.md](CITY_LIFE.md). It covers the systems below in the running game. It is a procedural game city; it is not a photogrammetry reconstruction or a complete municipal engineering model.

## Implemented systems

| Request | Implementation | Validation |
| --- | --- | --- |
| Actual penthouse view | The suite occupies the top eight metres of its actual property tower. The host parcel is clipped consistently in its nearby geometry, distant geometry and collision. All surrounding buildings, roads, sky and time come from the real Earth scene. | `citypenthousetest`, `citypenthousesnap` |
| Furniture interaction | E sits in chairs, reclines on sofas and lies on beds, with entering, resting and rising poses. The full articulated body is swept through translation and rotation; blocked motion pauses, and blocked exits are refused. Multiplayer checks the same furniture path, room and occupancy. | Physical stair/seat/bed tests, authority and remote-pose checks |
| Time command | `/time 21:30`, numeric hours, `day`, `night`, `dawn`, `dusk`, and `clear`. Offline solar phase has an offset independent of monotonic simulation time; online changes retain the shared admin clock. | Parser cases and real slash commands across repeated Frontier updates |
| Bright night city | Lit-window energy remains visible at distance, with individual occupied rooms, brighter street/shop lamps and the same complete street surface beneath distant buildings. District power availability affects windows and nearby shop lights. | Native street and rooftop screenshots |
| Mixed building scale | 38,269 buildings mix low-rise homes, mid-rise blocks and selected tall towers. Residential Beacon is 199.8 m high, with its suite floor at 191.8 m; the actual Crownreach Spire is 647.8 m. Brick, limestone, glass, slab blocks and selected stepped towers vary the streetscape. | Full deterministic address census and shared geometry/collision checks |
| Accurate maps | Progressive terrain-sampled Earth and Moon charts, correctly projected landmarks, streets, parcels, park, pond, transit, settlements, spaceport, colony, player and waypoint. | See [planet cartography](PLANET_CARTOGRAPHY.md) |
| Traffic | Lane graph, posted speeds, acceleration/braking, queues, stops, turns, signals, pedestrians, crosswalks, one-way signs and power-failure behavior. | See [traffic rules and tests](CITY_TRAFFIC.md) |
| City services | Persistent district tax receipts, operating spending, grid supply, pumping/storage, wastewater treatment, waste collection/recovery/disposal, road capacity, clinic service and their effect on food output/workforce. | `citysystemstest`, economy and UI regressions |
| Player work and shops | Existing real finite goods and wages continue; street-crew and collection-fleet repairs join water/power maintenance. Repairs consume actual backpack parts and restore the corresponding district service. Shops sell finite stocked goods. | Economy conservation, physical job completion, shared-server tests |

## Research translated into mechanics

EPA's [smart-growth principles](https://www.epa.gov/smartgrowth/about-smart-growth) emphasize mixed uses, housing choice, walkable neighborhoods, open space and transportation options. The game combines varied housing and ground-floor services with walkable streets, a park and transit; these are design applications of those principles rather than a claim to simulate planning approval or land economics.

EPA describes the dependence of [water utilities on electricity](https://www.epa.gov/sustainable-water-infrastructure/energy-efficiency-water-utilities), particularly pumping and treatment. Accordingly, a failed power supply reduces pumping and wastewater treatment. Reservoirs provide a finite buffer. Reduced water and electricity impair clinic service, food production and productive work. Budget-funded crews offset ordinary wear; player repair jobs accelerate restoration.

EPA's [waste-management hierarchy](https://www.epa.gov/smm/sustainable-materials-management-non-hazardous-materials-and-waste-management-hierarchy) distinguishes recovery from residual disposal. The collection model accumulates waste, spends operating funds, and separates recovered material from disposal. The game's recovery fraction is an explicit balancing assumption, not a claimed real-world municipal rate. Aggregate service units and district tax receipts never create tradeable player inventory or player credits.

Transportation uses the FHWA MUTCD and an explicitly selected NYC-style operating policy, documented separately. States and cities have differing laws: this implementation does not claim to implement every jurisdiction's vehicle code.

## Persistence and bounded simulation

Existing building IDs, ownership, stored goods and service roles are preserved. Older district saves receive the new infrastructure fields on import. The complete operational state is saved, while network views send only the eight service figures needed by panels and rendering; the response cap is 65,536 bytes. Twelve district rows represent 100,000 census residents; nearby physical actors are a separate bounded sample. Infrastructure updates are capped at 60 minute intervals per advance.

The local source protocol is 18 because rooftop positions and replicated interaction semantics require matching clients and server. This work has not published an installer or updated the managed server.

## Coverage limits

The simulation covers neighborhood land use, housing, markets and logistics, transport control, public-space landscaping, power/water/waste/service dependencies and paid maintenance. Detailed electric circuits, pipe hydraulics, real household travel demand, full hospital treatments, municipal elections, every building floor and all U.S. road-law exceptions are not simulated. Performance and appearance are checked locally on Apple M4/Metal; this is not an assertion of photorealism or a hardware-wide performance guarantee.

## Earlier validation before the city expansion

The native city run passes **63/63**, including actual admin slash-command persistence, all 2,304 distant blocks, transit, building collision, pond traversal, shop purchase and seven screenshots (`artifacts/city-remake/native-realism.log`). Its Apple M4/Metal viewport was 1,600 by 1,333 at adaptive render scale 0.86. A 299-interval settled sample measured p50 12.924 ms, p95 18.978 ms, p99 22.712 ms and maximum 94.708 ms. Short-run hitches remain, and these timings are not evidence for other hardware.

The earlier service-system gate passed **30/30**, economy **137/137**, compact UI/interiors **127/127**, existing Frontier society regression **93/93**, and networking security **56/56**. The actual local ENet run passes **48 checks** across buyer, visitor and reconnect/server-restart roles. Logs are grouped under `artifacts/city-realism/`. Native city shutdown still emits five particle-shader/RID cleanup diagnostics; the running scene has no script or shader compile errors.


Final additional gates: **2,462/2,462** CityPlan; **129/129** headless and **144/144** native penthouse/furniture; **42/42** traffic behavior with four native signal/display matches; **50/50** headless and **64/64** native cartography. Penthouse coverage includes every one of the 18 major furniture pieces (19 anchors) and complete indoor skyline staging. The cartography worker now fills Moon collision vertices lazily, allowing a coarse preview before the whole planet is sampled. Full local terrain tiles reach 129×129 samples and globe images reach 1025×513. Native deferred capture cleanup removes the penthouse ObjectDB warning; the shared particle-shader shutdown diagnostic remains.
