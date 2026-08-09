# TROOP changelog

## 0.4.1 — FLIGHT READY

This patch publishes the finished TROOP 0.4 planet and vehicle work in a new
Windows-detectable package. The earlier public 0.4.0 build predates these fixes;
0.4.1 is a genuinely newer signed release rather than a replacement asset with
the same version number.

### Windows delivery and multiplayer compatibility

- Package, installer, content pack, and signed update-manifest version: **0.4.1**.
- Network protocol **8** carries the revised expedition clocks, planetary realm,
  vehicle state, and presentation recovery consistently between authority and
  clients.
- The protocol and project settings changed, so this patch deliberately uses
  the full Windows installer. TROOP detects 0.4.1 from its menu; choose
  **DOWNLOAD TROOP 0.4.1 UPDATE**, then **OPEN TROOP 0.4.1 INSTALLER**.
- Installer-required updates now say **INSTALLER REQUIRED** instead of claiming
  to be downloading before the player starts the download, and the completion
  prompt explicitly asks the player to close TROOP while Setup replaces files.
- The dedicated server is deployed from the same merged source before the
  release tag is published, preventing a protocol-7 server/protocol-8 client
  mismatch.

### Vehicles and monkey recovery

- Motorcycle braking no longer drives the wheels backward. Braking compresses
  the front suspension and unloads the rear without destabilizing the chassis.
- Coasting steering, wheelie response, and vehicle wheel behavior retain the
  easier control feel while staying physically readable.
- Holding W and Up for takeoff now latches the runway heading until the pilot
  gives deliberate A/D or horizontal mouse input, so small tire-solver yaw can
  no longer accumulate into a sideways departure on a slower machine.
- Local and remote monkey rigs now restore every authored body transform and
  clear stale look, recoil, hand, and seated solvers after vehicle exit, defeat,
  and repeated revive. Leaving a plane can no longer scatter limbs until the
  player reconnects.

### Planet, roads, Moon, and high-speed streaming

- Pangaea, permanent polar ice, Earth-scale wrapping, broad mountain systems,
  organic coast and hillside roads, driveable bridges, and warm-lit freeway
  tunnels now share one deterministic terrain contract.
- The atlas, orbital Earth, Moon, and voyage presentation use bundled 4096x2048
  Earth and lunar textures while local map detail still comes from the live
  generator.
- The rocket rises vertically, turns toward the Moon, blends into its chase
  camera, and completes the outbound trip in 60 seconds. The fitted articulated
  pressure suit follows the monkey rig without corrupting normal movement.
- Circular stratos coverage, complementary LOD fades, delayed detail foliage,
  atmospheric nadir color, bounded mesh construction, and forward mountain
  collision look-ahead keep terrain readable at aircraft altitude and speed.
- Focused release gates now cover curved roads, bridges and tunnels, altitude
  streaming, 1,000 mph coverage, lunar integration, vehicles, suspension, and
  local/remote rig recovery.

### Complete 0.4.1 feature details

TROOP 0.4 turns the generated wilderness into a planet and opens the Moon as a
fully playable destination. The update is designed around one coordinate and
seed contract: terrain, roads, water, the atlas, vehicles, and every multiplayer
peer all reconstruct the same Earth-like world without shipping a giant map.

### A world, not an endless tile

- The seed now shapes one connected Pangaea-scale supercontinent with an
  irregular coastline, offshore islands, a truly large surrounding ocean,
  inland seas, and much larger connected lakes.
- The climate system adds open plains, temperate grassland, desert,
  rocky alpine ranges, tundra, polar ice, wetlands, bamboo country,
  highlands, and the original rainforest canopy.
- Macro relief uses broad uplift and erosion-shaped ridges instead of stacking
  short-wavelength bumps. Major mountain country targets a roughly 1,200 m
  characteristic elevation, while a normalized summit envelope reaches 6,000 m.
- The playable sphere is Earth scale: **40,077,312 m around**. Planet coordinates
  use equirectangular longitude and latitude; east/west travel joins exactly,
  while crossing a pole reflects latitude and moves longitude by 180 degrees,
  so a monkey can keep travelling and circumnavigate the complete world.
- Permanent polar ice shelves and caps stay separate from Pangaea and follow
  the same pole-reflection contract as terrain, water, roads, and multiplayer.
- Generated content remains reproducible from the world seed and is built in
  bounded streaming lanes. High-speed vehicles still prefetch a swept corridor
  rather than trying to materialize the planet at once.
- Altitude now expands a circular stratos view progressively to the full
  15-mile/24 km range. Near trees and details sleep and wake with hysteresis,
  neighboring LOD tiers cross-fade instead of doubling up, distant terrain
  carries canopy color, and the lower sky and nadir retain an atmospheric
  planet palette rather than fading to black.
- At aircraft altitude, skyline or stratos terrain fully owns the view beneath
  the camera instead of retaining an invisible fine-ground corridor. Descent
  keeps that successor coverage until every lower shell is resident again,
  stratos meshes sample in bounded row steps, and a forward terrain probe wakes
  collision for a level aircraft approaching rising mountain terrain.

### Roads everywhere

- The small spawn road chain has become a deterministic road hierarchy spanning
  the planet. Seed-curved arterials follow Pangaea's coast and broad hill and
  mountain corridors, while regional connectors and local access roads meet at
  organic, non-orthogonal junctions under one analytic surface contract.
- Road crowns are graded against the terrain, kept dry where possible, capped at
  a driveable slope, and visible in gameplay terrain, the horizon and skyline
  LODs, and the local atlas without extra road meshes or replication traffic.
- Trees, rocks, undergrowth, huts, and other procedural obstacles observe the
  same road-clearance field.
- Where an arterial crosses water or a ravine, streaming creates a driveable
  bridge with a deck, rails, piers, markings, and nearby collision. Dry mountain
  crossings can instead become arched tunnels with portal rings, collision, and
  six warm interior lamps. Each structure is owned and emitted once by its
  route chunk, including at longitude seams and reflected poles.

### Atlas and orbital globe

- X opens a smooth full-screen world atlas while M continues to cycle the
  compact minimap for immediate navigation.
- The atlas zooms from local satellite-style detail through regional and
  continental scales to an atmospheric 3D globe surrounded by space.
- Terrain height, biome color, oceans, lakes, ice, canopy cover, and the road
  hierarchy come directly from the generator at local and regional scales. The
  whole-globe view uses a bundled 4096×2048 Pangaea Earth texture while the Moon
  and voyage views use a matching 4096×2048 lunar texture. Bounded tiles derived
  from the generator keep local and regional zooming responsive without sampling
  the full planet at gameplay resolution.
- Live player markers show names and facing directions. Vehicle headings remain
  correct, and globe markers use the same spherical coordinate conversion as
  terrain and multiplayer.
- The globe view includes the Moon as an inspectable destination, with a
  progressively refined highland, maria, and crater atlas, and keeps UI labels
  readable while the planet itself rotates and eases under mouse input.

### Four-monkey lunar expedition

- A generated launch vehicle seats up to four monkeys and provides explicit
  boarding, launch, outbound flight, lunar landing, return, re-entry, and ocean
  splashdown states.
- The outbound journey lasts exactly **60 seconds**. Its first 10 seconds build
  into a progressive vertical climb above the pad before the rocket bends into
  its lateral arc; ignition, atmosphere departure, space coast, lunar approach,
  descent, and touchdown remain visible instead of hiding a teleport behind a
  loading screen.
- At the end of vertical ascent, the voyage camera now hands off over three
  seconds from the launch framing to the orbital chase view, avoiding the old
  long-distance focus snap while the rocket continues along its flight path.
- Bounded launch flame and exhaust scale across ascent and descent. Return
  flight lasts exactly **45 seconds**, with a separate visible plasma/fire
  envelope during atmospheric re-entry before the ocean approach and
  splashdown.
- Splashdown now has one authority-owned 18-second recovery state. Existing
  players and late joiners see the same ocean pose, boarding stays locked until
  recovery finishes, and every peer returns to the launch pad together.
- Disembarking places the monkey safely beside the hatch and consumes the
  original interaction tap, preventing an immediate same-frame reboard. Admin
  extraction from either voyage also returns the monkey to safe world terrain
  instead of preserving a cinematic cabin coordinate.
- The space vista exposes dense stars, familiar constellations, planets, the
  Sun, nebula color, a luminous spiral galaxy, and a receding Earth. Camera cues
  pan from the shrinking planet toward the approaching Moon while preserving a
  comfortable horizon.
- The Moon has a detailed deterministic 768 m cratered landing region, 1.62 m/s²
  surface gravity, a vacuum environment, a safe landing site, a launch vehicle
  oxygen refill, and a readable Earth in the lunar sky. Its celestial disk is
  also larger and easier to read from Earth.
- Admins can travel directly to the Moon for building or moderation without
  bypassing the normal multiplayer realm state.

### Suits, oxygen, backpacks, and moon cheese

- Every lunar visitor receives a fitted, articulated pressure suit whose torso,
  helmet, sleeves, gloves, and boots follow the monkey's authored joints, plus
  chest controls, an **18-slot space backpack**, and twin oxygen tanks. The local
  first-person arms receive matching pressure sleeves and gloves without
  double-rendering the third-person shell.
- Oxygen drains only during vacuum exposure, warns before depletion, and can be
  refilled at the rocket. Life-support state has deterministic test hooks so the
  full capacity can be verified without waiting in real time.
- The new compact inventory is available only with a normal or space backpack.
  Normal packs provide 12 slots and space packs provide 18, with stable stack
  ordering, explicit capacity checks, and a keyboard-accessible grid. One normal
  pack is guaranteed in the northwest origin supply hut, with more discoverable
  in wilderness huts.
- A cheerful lunar villager runs a tiny cheese shop. Bananas remain the shared
  currency, while purchased Moon Cheese enters the backpack as a stackable item.
  Multiplayer purchases spend the authoritative banana balance.

### Multiplayer, controls, and performance

- Network protocol 8 adds authoritative planetary realm, rocket manifest,
  voyage phase, arrival, and lunar purchase state. Late joiners receive the
  current mission state instead of seeing a client-only rocket.
- The four rocket seats are authority-arbitrated, capped, and released on
  disconnect. Launch and return requests are rate-limited and validated against
  the current manifest and realm.
- Remote passenger replicas lock to their authored cabin seats instead of
  interpolating toward stale world packets, then resume ordinary interpolation
  on landing or disembark.
- Space-suit presentation follows the replicated realm: lunar monkeys are
  suited, returning Earth monkeys remove the pressure shell while retaining
  their space-backpack inventory, and late joiners see the same result.
- Local and remote rigs now restore their complete authored pose and clear
  transient look, recoil, hand, and vehicle solvers after vehicle exit,
  defeat, and revive, preventing a stale seated or death pose from leaking into
  ordinary movement on either peer.
- Planet wrap and remote marker positioning use nearest-image coordinates near
  the longitude seam so nearby peers do not appear a world-width apart.
- Atlas generation, celestial visuals, rocket particles, and lunar terrain use
  bounded caches or shared materials. Earth terrain streaming remains asleep
  when the local player is on the elevated lunar world; rain, snow, leaves, and
  fireflies also suspend in transit and vacuum, then restore on Earth.
- New focused diagnostics cover spherical continuity, biome/elevation targets,
  global roads and transport structures, map projections and cache bounds, the
  exact 60-second outbound, 45-second return, and 18-second recovery clocks,
  four-seat enforcement, lunar gravity, oxygen, inventory capacity, cheese
  trading, pose reset, the return sequence, moving stratos-edge residency,
  seamless altitude handoffs, and 1,000 mph terrain/collision streaming.

### Release and compatibility

- Player-facing version: **TROOP 0.4**; package/tag version: **0.4.1**.
- Network protocol: **8**. Older clients are rejected with the existing guided
  updater flow instead of entering a mismatched world.
- Windows x86_64 and Universal macOS builds continue to ship through the signed
  release pipeline alongside the cross-platform content update.

## 0.4.0 — ONE SMALL STEP

The first public TROOP 0.4 build established the generated planetary world and
playable Moon expedition. It shipped the original 98,304 m spherical chart,
twelve-biome continent and island generator, initial planet-wide analytic road
hierarchy, zoomable atlas and globe, four-seat rocket, lunar gravity, pressure
suits, oxygen, backpacks, and Moon Cheese shop.

### Original public baseline

- Package/tag version: **0.4.0**; network protocol: **7**.
- The original outbound voyage lasted 180 seconds and the return lasted 120
  seconds. The 0.4.1 patch above shortens and polishes both routes.
- This historical release remains available for provenance, but its equal
  version number cannot deliver later fixes to an installed 0.4.0 client.

## 0.3.10 — THE VEHICLE UPDATE: POLISH PASS

- Added predictive high-speed world streaming, long-range canopy rendering,
  lower angel-wing anchors, heading-up vehicle minimap behavior, hit markers,
  and the enlarged seed-driven smiling Sun.
- Completed the fighter-jet stability and aiming pass, vehicle chase cameras,
  motorcycle suspension and wheelies, automatic Jeep shifting and tachometer,
  exhaust effects, six-hangar runway, and multiplayer vehicle visibility.
