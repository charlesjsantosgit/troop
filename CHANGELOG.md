# TROOP changelog

## 0.4.0 — ONE SMALL STEP

TROOP 0.4 turns the generated wilderness into a planet and opens the Moon as a
fully playable destination. The update is designed around one coordinate and
seed contract: terrain, roads, water, the atlas, vehicles, and every multiplayer
peer all reconstruct the same Earth-like world without shipping a giant map.

### A world, not an endless tile

- The world now has deterministic continents and island chains separated by
  truly large oceans, inland seas, and much larger connected lakes.
- The climate system adds open plains, temperate grassland, desert,
  rocky alpine ranges, tundra, polar ice, wetlands, bamboo country,
  highlands, and the original rainforest canopy.
- Macro relief uses broad uplift and erosion-shaped ridges instead of stacking
  short-wavelength bumps. Major mountain country targets a roughly 1,200 m
  characteristic elevation, while a normalized summit envelope reaches 6,000 m.
- Planet coordinates use equirectangular longitude and latitude over a sphere.
  East/west travel wraps naturally; crossing a pole reflects latitude and moves
  longitude by 180 degrees, so a monkey can keep travelling and circumnavigate
  the complete world.
- Generated content remains reproducible from the world seed and is built in
  bounded streaming lanes. High-speed vehicles still prefetch a swept corridor
  rather than trying to materialize the planet at once.

### Roads everywhere

- The small spawn road chain has become a deterministic road hierarchy spanning
  the planet: long interregional trunks, regional connectors, and local access
  links share one analytic surface contract.
- Road crowns are graded against the terrain, kept dry where possible, capped at
  a driveable slope, and visible in gameplay terrain, the horizon and skyline
  LODs, and the local atlas without extra road meshes or replication traffic.
- Trees, rocks, undergrowth, huts, and other procedural obstacles observe the
  same road-clearance field.

### Atlas and orbital globe

- X opens a smooth full-screen world atlas while M continues to cycle the
  compact minimap for immediate navigation.
- The atlas zooms from local satellite-style detail through regional and
  continental scales to an atmospheric 3D globe surrounded by space.
- Terrain height, biome color, oceans, lakes, ice, canopy cover, and the road
  hierarchy come directly from the generator at local and regional scales. The
  whole-globe view keeps the macro terrain, biome, water, and ice fields legible;
  bounded cached tiles keep zooming responsive without a planet-sized texture.
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
- The outbound journey lasts a full three minutes. The presentation progresses
  through ignition, launch ascent, atmosphere departure, a space coast, lunar
  approach, descent, and touchdown instead of teleporting behind a loading
  screen.
- Bounded launch flame and exhaust scale across ascent and descent. Return
  flight is faster, with a separate visible plasma/fire envelope during
  atmospheric re-entry before the ocean approach and splashdown.
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

- Every lunar visitor receives a pressure suit, clear helmet, boots, chest
  controls, a space backpack, and twin oxygen tanks fitted to the monkey rig.
- Oxygen drains only during vacuum exposure, warns before depletion, and can be
  refilled at the rocket. Life-support state has deterministic test hooks so the
  full capacity can be verified without waiting in real time.
- The new compact inventory is available only with a normal or space backpack.
  It uses a smaller slot count than Minecraft, stable stack ordering, explicit
  capacity checks, and a keyboard-accessible grid. One normal pack is guaranteed
  in the northwest origin supply hut, with more discoverable in wilderness huts.
- A cheerful lunar villager runs a tiny cheese shop. Bananas remain the shared
  currency, while purchased Moon Cheese enters the backpack as a stackable item.
  Multiplayer purchases spend the authoritative banana balance.

### Multiplayer, controls, and performance

- Network protocol 7 adds authoritative planetary realm, rocket manifest,
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
- Planet wrap and remote marker positioning use nearest-image coordinates near
  the longitude seam so nearby peers do not appear a world-width apart.
- Atlas generation, celestial visuals, rocket particles, and lunar terrain use
  bounded caches or shared materials. Earth terrain streaming remains asleep
  when the local player is on the elevated lunar world; rain, snow, leaves, and
  fireflies also suspend in transit and vacuum, then restore on Earth.
- New focused diagnostics cover spherical continuity, biome/elevation targets,
  global roads, map projections and cache bounds, the exact 180-second outbound
  timeline, four-seat enforcement, lunar gravity, oxygen, inventory capacity,
  cheese trading, and the return sequence.

### Release and compatibility

- Player-facing version: **TROOP 0.4**; package/tag version: **0.4.0**.
- Network protocol: **7**. Older clients are rejected with the existing guided
  updater flow instead of entering a mismatched world.
- Windows x86_64 and Universal macOS builds continue to ship through the signed
  release pipeline alongside the cross-platform content update.

## 0.3.10 — THE VEHICLE UPDATE: POLISH PASS

- Added predictive high-speed world streaming, long-range canopy rendering,
  lower angel-wing anchors, heading-up vehicle minimap behavior, hit markers,
  and the enlarged seed-driven smiling Sun.
- Completed the fighter-jet stability and aiming pass, vehicle chase cameras,
  motorcycle suspension and wheelies, automatic Jeep shifting and tachometer,
  exhaust effects, six-hangar runway, and multiplayer vehicle visibility.
