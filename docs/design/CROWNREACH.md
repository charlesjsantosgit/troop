# Crownreach: a home, a trade, a city

Crownreach is TROOP's main Earth city. The September 2026 remake concentrates it into a dense metropolis of approximately 30 square miles, with a skyline of tall residential and commercial towers around Lantern Square. The residential Beacon rises 199.8 metres; the distinct commercial Crownreach Spire rises 647.8 metres. Ground-floor shops, transit, street trees and a pedestrian gathering area anchor the city at walking height. Practical neighborhoods spread outward into smaller homes, workshops, food markets and logistics yards. The city belongs to its residents; claiming a village does not give one player ownership of the metropolis.

## Scale that means something

The municipal grid is 52 by 48 blocks. Street centerlines are 104.4672 by 298.32 metres apart, enclosing 264 by 900 foot buildable blocks with 24-metre streets. The municipal footprint is 5.432 by 14.319 km, 77.787 km², or approximately 30.034 square miles. Lantern Square remains at Earth coordinates (14,400, 0). Streets, entrances and parcel boundaries share deterministic world coordinates.

All 36,861 original city building IDs survive. The expanded park displaces 104 blocks; their addresses and housing/service identities move to eastern neighborhoods, preserving saved owners and cupboards. The city now contains 38,269 buildings. Each block has two parcel columns and eight rows, with entrances facing the actual public streets. No miniature roads cross these parcels. Core towers rise into the hundreds of metres; outer neighborhoods mix low-rise housing, industry and public services.

The census is exactly 100,000 monkeys across twelve aggregate districts. Nearby pedestrians, drivers, park visitors and emergency crews use the same MonkeyRig anatomy as the player, at standing heights from 1.7018 to 1.8796 metres (5 ft 7 in to 6 ft 2 in); the player remains 1.8288 metres. Long-distance pedestrians use images rendered from that exact model. Thousands of lightweight cars and walkers remain visible above the city. Census residents do not each have an individual live physics rig or inventory.

The remade exterior uses procedural physically based glass, limestone and metal facades. Window panes follow a metre-scaled floor grid, with mullions, varied blinds and occupied-room shading. The shader smooths that grid as buildings recede to avoid shimmering. Towers share a podium, shaft, setback and mechanical crown across visual detail, distant silhouettes and collision. Nearby construction adds coping, corner piers, crown louvers, storefront glazing, door frames, canopies and small service signs. Window detail is shaded on the facade instead of creating a separate mesh for every window on every floor.

Lantern Central Park spans eight columns and thirteen rows of city blocks, with a landscaped interior approximately 808 by 3,850 metres (3.11 km²). Its irregular lake has 160,515 m² of water, a shared physical terrain basin up to 1.6 metres deep, an eastern boathouse and four usable rowboats. Nine walking routes, a separate cycling loop longer than six kilometres, 2,063 trees, yoga groups, dog walkers and social terraces occupy the lawns and woodland. Every visitor uses the actual player monkey model, scaled between 5 ft 7 in and 6 ft 2 in. Press E at the activity locations or a docked boat to participate. The water mesh, basin, boat boundary, maps and park routes use shared canonical geometry. See [Lantern Central Park](LANTERN_CENTRAL_PARK.md) for controls, resource budgets and validation.

## Housing progression

1. **Village cottage:** the cheapest permanent home, a bed and a modest store cupboard; affordable from the starting allowance.
2. **Town apartment:** compact living above local services, more storage and easy access to jobs.
3. **Suburban home:** a small town home with a larger furnished room and more storage.
4. **City apartment:** a larger apartment close to urban markets and transport.
5. **Penthouse:** the premium home, generous rooms and premium furnishings.
6. **Warehouse:** commercial floor space and the largest inventory capacity; useful for a trading business rather than just a luxury upgrade.

Purchases debit the player's existing trade-credit wallet and credit the municipal property account. Ownership is persistent and exclusive. Any generated building with a supported housing role can be purchased at its entrance; the six example listings are guides, not the complete supply. Ownership is one record per building, with one reusable interior, rather than a separate apartment purchase on each floor. Storage transfers actual backpack goods, respects capacity and never creates stock. A selected residential property becomes the return/respawn address at that building's outdoor door. Listings show the exact price, capacity and location before buying. Entry, storage and services belong to the building being visited.

## Luxury penthouse

The penthouse has been rebuilt around the supplied interior references: a warm, double-height home with panoramic glazing, a cream sectional, rounded upholstered seating, grained wood, stone surfaces and bronze details. The 26-by-22-metre lower floor includes a living area, kitchen with an island, dining area, bedroom and entrance console. A four-metre-high mezzanine adds a study and reading corner beneath the eight-metre ceiling. Twenty-two visible timber stair treads sit above a continuous walkable collision ramp; transparent barriers protect both the stairs and the overlook.

The new bedroom, cupboard and residence console remain functional property services. The bed sets the owned penthouse as home, the cupboard moves real backpack goods, and the console opens the property's details. Normal entry and exit use the existing controller and physical address. No ownership, inventory or purchase-price schema changes are required for the interior redesign.

The skyline outside the glazing is the actual traversable city. The suite occupies the real top eight metres of its property, at a 191.8-metre floor elevation in the Beacon. Only the host building's occupied roof volume is opened, consistently in nearby/distant geometry and collision. Surrounding buildings retain their exact positions and heights. The camera inherits Earth's live sky, time, weather lighting and environment. Leaving restores its previous view and clipping distance. There is no miniature city, copied skyline or compressed viewpoint.

Press E at a chair to sit, at a sofa to recline, or at the mattress to sleep. Separate jointed enter, seated, reclined, sleeping and rise animations play. E, movement or jump gets up if the standing capsule has clear supported space. The bed's home-setting service and cupboard storage still work. Furniture occupancy and replicated poses are checked by the server.

`Play Penthouses.command` opens a fresh, interactive sunset preview of the owned Beacon penthouse. The preview receives an allowance from its temporary career treasury, purchases through the normal door action and enters through the normal controller. It does not load or save existing career progress. Normal movement and service interaction remain active. In an existing career, buy the 4,800-credit penthouse at its entrance and choose **Enter property**.

The earlier rooftop-view suite passed 144/144 before this expansion. Current full-body furniture validation is recorded in [CITY_LIFE.md](CITY_LIFE.md); it supersedes the old capsule-only seating checks. Furniture motion sweeps the actual articulated body, including angular changes and tail, through approach, lowering, sitting/reclining and exit. Dynamic obstructions pause motion and refuse a blocked exit.

## A working city

Districts combine housing with services, loading yards, parks and employment. Player courier contracts carry finite goods between designated workplaces. Maintenance contracts consume real supplies and require a timed task and completion at the workplace. Provisioning connects urban demand to the existing farming inventory. Work payments come from a funded municipal employer; repeated clicks cannot skip travel, duplicate cargo or create money. Aggregate district updates account for production, consumption and service shortages without individually ticking hundreds of thousands of characters. The nearby pedestrians and cars provide ambient street life; they do not award goods, finish player contracts or run a separate authoritative delivery economy.

Every generated building has an address and an entrance with a housing or service role. Reusable interiors provide homes, loading/storage rooms or public counters. Only designated workplaces offer the implemented contracts; a generic service label does not imply an additional playable profession. Mixed-use workplaces remain accessible for their jobs while cupboard and bed actions require ownership. Furnishings are fixed, with one instanced interior per visited property. The penthouse has several living areas and a walkable mezzanine; individual tower floors, furniture editing, rental income and property resale are not implemented.

Ten storefront categories offer groceries, bakery items, coffee, meals, hardware, gardening supplies, outdoor goods, energy equipment, fabrics and pantry staples. Purchases debit real credits and transfer finite shared stock into the Earth backpack. Twelve Crown Motor Galleries sell ten vehicle classes, with searchable model cards, a three-car private garage and collection at physical delivery bays. Initial stock migration adds the newly introduced product lines once while preserving existing goods and empty shelves.

## Getting started

The existing towns get a marked transit stop and housing entrances. A short guide introduces the sequence: visit a cottage, inspect its cost, buy it, enter, move an item into storage, then try a city job. Transit connects the existing village to Crownreach and its districts; destinations remain reachable in the same Earth world. Menus stay compact and opaque, with clear backpack/storage quantities and contextual actions.

For a direct look at the source remake, `Play Crownreach.command` opens a fresh, nonpersistent daytime session in Lantern Square. The normal career continues to use the village transit route and its existing saves.

## Acceptance and performance

- Preserve existing village and lunar saves, accounts, roads and inventories.
- Reject malformed ownership records, remote transactions, forged job completions and duplicated requests.
- Verify money conservation, storage capacity, migration, deterministic city addresses and exact population totals.
- Use one underlying terrain surface for streets and building sites so the city cannot reintroduce overlapping ground planes.
- Bound streamed blocks, physical actors and building colliders independently of census population.
- Measure actual frame times and node counts in the native renderer; report the tested machine and unresolved limits.
- A source build, an installed application and the public server are separate delivery states. Record which are verified instead of implying all were updated.

## Implemented progression and limits

| Property | Price | Storage | Can set home |
| --- | ---: | ---: | --- |
| Village cottage | 450 | 80 | Yes |
| Town apartment | 700 | 120 | Yes |
| Suburban home | 1,200 | 220 | Yes |
| City apartment | 1,600 | 180 | Yes |
| Penthouse | 4,800 | 300 | Yes |
| Warehouse | 2,600 | 1,000 | No |

There are 38,269 city buildings plus three village/town properties. Each player may own up to eight properties and three vehicles; the city save supports 512 properties, 64 owned vehicles and 64 active jobs. Private cupboard contents are sent only for the owner’s currently visited room.

The detailed neighborhood streams at most 25 city blocks, building one detailed block per render frame. Building colliders occupy at most a 3-by-3 block neighborhood, separate from Earth terrain streaming. The nearby traffic pool is capped at 24 physical cars and 64 articulated walkers. Persistent distant traffic and walkers are rendered independently; the park and emergency responders have their own bounded pools.

The distant skyline shares canonical building massing and facade materials, with capacity for 153,076 massing sections across 2,496 blocks. Nearby detail replaces distant shells without duplication. Far blocks stage at most once per frame, prioritizing the neighborhood and recently unloaded detail; full-city preparation takes many frames. Continuous aircraft/building intersection checks use the same canonical geometry even beyond the ordinary collision window.

Ten player contracts cover couriers, utility repair, fresh produce and replenishing depot supplies. One active contract uses one sealed cargo slot rather than silently adding goods beyond backpack capacity. Work pays 40–120 credits from municipal funds. Transit costs six credits. District workers and household demand advance once per simulated minute; shortages affect service condition and effective workforce.

To begin, use the village journal's Places page to locate transit, or visit the marked cottage near the village. In Crownreach, B opens the city guide. E operates the physical door, cupboard, bed, noticeboard or stop. Furnished rooms add local lights and exclude precipitation; penthouse glazing retains the actual Earth environment and surrounding city.

## Arrival safety

Bus travel, room transitions and home returns apply a dedicated arrival hold. This is independent of the rocket/cabin lock, so routine vehicle updates cannot release an arriving player. While held, player physics keeps velocity at zero and defers movement, and the interface says that the ground is being prepared. The controller resets Earth streaming focus and checks readiness in physics ticks rather than waiting for distant skyline completion.

Outdoor release requires active terrain collision for every chunk touched by a footprint extending 0.45 metres in each horizontal direction, including all four chunks at a junction. Five downward probes must also find sufficiently level support under the center and corners. Interior arrivals use the same support probes against the already-built room floor. After at least two physics ticks, a successful check releases only the arrival lock and clears velocity. If outdoor terrain preparation stalls for more than three seconds, the controller may warm one required chunk per physics tick; it does not synchronously build the entire city. The dedicated regression pauses normal world processing for one second while player physics continues, then checks that height stays fixed during the hold and movement releases once support is ready.

## Current realism validation

See [CITY_REALISM.md](CITY_REALISM.md) for the requested-subsystem checklist, implementation boundaries, research and current validation. [CITY_TRAFFIC.md](CITY_TRAFFIC.md) documents the specific U.S. traffic-control profile. [PLANET_CARTOGRAPHY.md](PLANET_CARTOGRAPHY.md) documents the exact Earth/Moon samplers and projections.

Current native and headless evidence, including park activities, full-size driver fit, commerce, full-body furniture, maps and disaster recovery, is recorded in [CITY_LIFE.md](CITY_LIFE.md). Prior test totals below describe the earlier city baseline, not this expanded layout.

The local source uses network protocol **18**, requiring matching client and server geometry, vehicle registration and furniture semantics. No installer or public server was published by this work. Rendering remains procedural; the simulation is not a photorealistic asset set, an engineering collapse solver, or a simulation of every municipal operation.

## Previous city baseline (before the remake)

Existing source logs record CityPlan **2,423/2,423** (`artifacts/crownreach-regressions/cityplantest-home-relocation.log`), city economy **93/93** (`artifacts/crownreach-regressions/cityeconomytest.log`), and city UI/interior **100/100** (`artifacts/crownreach-ui/headless-final.log`) passing checks. The capped economy fixture records a 43,328-byte wrapped reply under the 49,152-byte network limit, including one context-scoped cupboard and both realm bags. The earlier isolated native UI/room capture records **90/90** on Apple M4; it precedes the final source assertions and full-city arrival changes.

The full-city native run on September 4, 2026 passed **24/24**, including the deliberately stalled arrival and a stay through all 2,304 distant blocks. The player retained ground contact at Lantern Square. The final scene contained 25 detailed blocks, 212 building collision shapes, 207 rendering batches, and 18 local actors. This Apple M4 / macOS 27 / Metal run used the Dummy audio driver for diagnostic isolation and a 1,600 by 1,066 viewport with adaptive rendering enabled.

Across 1,945 skyline-staging frames, p95 was 27.281 ms and p99 was 33.299 ms. The subsequent 300-frame sample measured p50 17.933 ms, p95 35.077 ms, p99 51.483 ms, and a 215.833 ms maximum. Occasional hitches remain; these measurements do not establish hitch-free play or performance on other hardware. The two existing particle/material shader cleanup diagnostics also remain at renderer shutdown. Earlier measurements with another native TROOP copy rendering its menu were discarded for performance conclusions.

Packaged-app verification and public-server rollout are separate release gates. The source checks and native editor-binary run above do not establish that those release stages passed.
