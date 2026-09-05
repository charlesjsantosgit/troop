# Crownreach: a home, a trade, a city

Crownreach is TROOP's main Earth city. Lantern Square is its illuminated meeting place: tall signs, ground-floor shops, transit, street trees and a pedestrian gathering area. Practical neighborhoods spread outward into smaller homes, workshops, food markets and logistics yards. The city belongs to its residents; claiming a village does not give one player ownership of the metropolis.

## Scale that means something

The municipal grid is 48 by 48 blocks, each 480 metres across: 23.04 km on each side, 530.84 km², approximately 205 square miles. Crownreach begins east of the existing settlements. Streets, building addresses and entrances have deterministic world coordinates. The footprint is traversable space, not a map label on a small level.

The population is exactly 400,000 monkeys in deterministic building occupancy totals and twelve aggregate district records. Districts track population, workforce, food reserves, demand and service condition. Only a bounded neighborhood crowd has animated physical bodies; individual census residents do not each have a live rig, personal schedule or inventory. Aggregate economic updates and nearby rendering have separate budgets. Building shells use shared geometry and materials; local detail and collision stream around the player. Furnished rooms load on entry.

## Housing progression

1. **Village cottage:** the cheapest permanent home, a bed and a modest store cupboard; affordable from the starting allowance.
2. **Town apartment:** compact living above local services, more storage and easy access to jobs.
3. **Suburban home:** a small town home with a larger furnished room and more storage.
4. **City apartment:** a larger apartment close to urban markets and transport.
5. **Penthouse:** the premium home, generous rooms and premium furnishings.
6. **Warehouse:** commercial floor space and the largest inventory capacity; useful for a trading business rather than just a luxury upgrade.

Purchases debit the player's existing trade-credit wallet and credit the municipal property account. Ownership is persistent and exclusive. Any generated building with a supported housing role can be purchased at its entrance; the six example listings are guides, not the complete supply. Ownership is one record per building, with one reusable interior, rather than a separate apartment purchase on each floor. Storage transfers actual backpack goods, respects capacity and never creates stock. A selected residential property becomes the return/respawn address at that building's outdoor door. Listings show the exact price, capacity and location before buying. Entry, storage and services belong to the building being visited.

## A working city

Districts combine housing with services, loading yards, parks and employment. Player courier contracts carry finite goods between designated workplaces. Maintenance contracts consume real supplies and require a timed task and completion at the workplace. Provisioning connects urban demand to the existing farming inventory. Work payments come from a funded municipal employer; repeated clicks cannot skip travel, duplicate cargo or create money. Aggregate district updates account for production, consumption and service shortages without individually ticking hundreds of thousands of characters. The nearby pedestrians and cars provide ambient street life; they do not award goods, finish player contracts or run a separate authoritative delivery economy.

Every generated building has an address and an entrance with a housing or service role. Reusable interiors provide homes, loading/storage rooms or public counters. Only designated workplaces offer the implemented contracts; a generic service label does not imply an additional playable profession. Mixed-use workplaces remain accessible for their jobs while cupboard and bed actions require ownership. This version has fixed furnishings, decorative windows and one room per visited property, without individually explorable tower floors, furniture editing, rental income or property resale.

## Getting started

The existing towns get a marked transit stop and housing entrances. A short guide introduces the sequence: visit a cottage, inspect its cost, buy it, enter, move an item into storage, then try a city job. Transit connects the existing village to Crownreach and its districts; destinations remain reachable in the same Earth world. Menus stay compact and opaque, with clear backpack/storage quantities and contextual actions.

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

There are 36,861 city buildings plus the three new village/town properties. Each player account may own up to eight properties; a saved city supports 512 owned properties and 64 active player jobs. Storage capacity counts the total quantity of goods, not the number of distinct item types. All owned properties expose capacity/usage summaries, but full cupboard contents are sent only for the owner's currently visited room.

The detailed neighborhood streams at most 25 city blocks in a 5-by-5 window, building at most one detailed block per render frame. Building colliders are enabled only in the nearby 3-by-3 window, up to nine city blocks; underlying Earth terrain collision streams separately. The three village/town properties are separate from this city-block budget. There are at most 16 walking residents and four cars, using physical collision and bounded local routes.

The distant skyline has a separate fixed-capacity MultiMesh: one simplified box silhouette per city building, up to 36,861 instances across all 2,304 blocks. It has no building colliders or cast shadows. The 25-block detail cap does not truncate this distant city to a small neighborhood. At most one far block is staged or restored per render frame: recently unloaded detail is restored first, then nearby unstaged blocks within six blocks of the player, then the remaining municipal grid. Distant shells are hidden when their detailed block loads and restored when it unloads, avoiding overlapping shells. The final fill pass accounts for currently detailed blocks with hidden silhouettes, so reaching the instance cap does not draw a duplicate city over local geometry. Distant preparation progresses over many frames; it is not an instantaneous full-city load.

Ten player contracts cover couriers, utility repair, fresh produce and replenishing depot supplies. One active contract uses one sealed cargo slot rather than silently adding goods beyond backpack capacity. Work pays 40–120 credits from municipal funds. Transit costs six credits. District workers and household demand advance once per simulated minute; shortages affect service condition and effective workforce.

To begin, use the village journal's Places page to locate transit, or visit the marked cottage near the village. In Crownreach, B opens the city guide. E operates the physical door, cupboard, bed, noticeboard or stop. Furnished rooms use local lighting and exclude outdoor fog and precipitation; leaving restores the outdoor environment.

## Arrival safety

Bus travel, room transitions and home returns apply a dedicated arrival hold. This is independent of the rocket/cabin lock, so routine vehicle updates cannot release an arriving player. While held, player physics keeps velocity at zero and defers movement, and the interface says that the ground is being prepared. The controller resets Earth streaming focus and checks readiness in physics ticks rather than waiting for distant skyline completion.

Outdoor release requires active terrain collision for every chunk touched by a footprint extending 0.45 metres in each horizontal direction, including all four chunks at a junction. Five downward probes must also find sufficiently level support under the center and corners. Interior arrivals use the same support probes against the already-built room floor. After at least two physics ticks, a successful check releases only the arrival lock and clears velocity. If outdoor terrain preparation stalls for more than three seconds, the controller may warm one required chunk per physics tick; it does not synchronously build the entire city. The dedicated regression pauses normal world processing for one second while player physics continues, then checks that height stays fixed during the hold and movement releases once support is ready.

## Recorded validation scope

Existing source logs record CityPlan **2,423/2,423** (`artifacts/crownreach-regressions/cityplantest-home-relocation.log`), city economy **93/93** (`artifacts/crownreach-regressions/cityeconomytest.log`), and city UI/interior **100/100** (`artifacts/crownreach-ui/headless-final.log`) passing checks. The capped economy fixture records a 43,328-byte wrapped reply under the 49,152-byte network limit, including one context-scoped cupboard and both realm bags. The earlier isolated native UI/room capture records **90/90** on Apple M4; it precedes the final source assertions and full-city arrival changes.

The full-city native run on September 4, 2026 passed **24/24**, including the deliberately stalled arrival and a stay through all 2,304 distant blocks. The player retained ground contact at Lantern Square. The final scene contained 25 detailed blocks, 212 building collision shapes, 207 rendering batches, and 18 local actors. This Apple M4 / macOS 27 / Metal run used the Dummy audio driver for diagnostic isolation and a 1,600 by 1,066 viewport with adaptive rendering enabled.

Across 1,945 skyline-staging frames, p95 was 27.281 ms and p99 was 33.299 ms. The subsequent 300-frame sample measured p50 17.933 ms, p95 35.077 ms, p99 51.483 ms, and a 215.833 ms maximum. Occasional hitches remain; these measurements do not establish hitch-free play or performance on other hardware. The two existing particle/material shader cleanup diagnostics also remain at renderer shutdown. Earlier measurements with another native TROOP copy rendering its menu were discarded for performance conclusions.

Packaged-app verification and public-server rollout are separate release gates. The source checks and native editor-binary run above do not establish that those release stages passed.
