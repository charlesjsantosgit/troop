# Roots & Rockets implementation checks

Verified September 3, 2026 using Godot 4.7 in the `troop-planet-moon-04` checkout, on branch `codex/roots-and-rockets`. The existing root `Play TROOP.command` opens this checkout. This is a local source update; the public server and downloadable release have not been changed.

## Functional results

| Registered CLI mode | Result | Main coverage |
|---|---:|---|
| `frontiertest` | 93/93 | Crop causality, conservation, funded trades/contracts, timed jobs, freight, fuel, a fully powered six-bed lunar day/night cycle and persistence |
| `frontierplaytest` | 66/66 | Actual player/terrain contact, all management pages and bounds, refinery purchase, NPC conversation, quest callback, vehicle propulsion, real roadblock recovery, pause, realm travel and isolated saving |
| `frontierroutetest` | 8/8 | 5,634 road/crop route segments, 600 tanker/suited-worker sweeps, profession changes and cargo labels |
| `lunarskytest` | 18/18 | Photographic assets, approximate planetary positions, shared Sun/phase/relief direction and optical infinity |
| `moonspheretest` | 13/13 | Spherical collider, seams, capsule contact and radial rigid-body gravity |
| `moonstagedsetuptest` | 20/20 | Deterministic progressive construction, idempotence and cancellation |
| `vehicletest` | 153/153 | Existing non-career vehicle physics and controls |
| `combattest` | 132/132 | Existing combat, weapon, hit and AI behavior |
| `mooncolonytest` | 70/70 | Existing lunar colony transactions and save isolation |

Total: **573 passing checks**. This counts test assertions, not every sampled route segment as a separate assertion. No runtime script/engine errors were recorded by the final gameplay fixture. The renderer reports shutdown resource warnings described below.

Run a test from this checkout with:

```sh
/opt/homebrew/bin/godot --headless --path . -- frontierplaytest
```

The fixture uses a disposable career and checks the production save's hash. It does not load, fund or overwrite the player's real society. UI purchase tests drive actual buttons; the roadblock test inserts and removes an actual physics collider.

## Rendered performance

The bounded `frontierbench` fixture runs the complete game with 24 citizens, warms up for 180 frames and samples 720 frames per world. Hardware: Apple M4 / Metal 4.0. Logical viewport: 1600 × 1333; final adaptive 3D scale: 1.00 for both samples. Native window dimensions can differ because the project's existing canvas stretch expands its reference viewport.

| Scene | Mean frame | p95 | p99 | Worst sampled frame |
|---|---:|---:|---:|---:|
| Earth town | 11.10 ms | 17.68 ms | 20.32 ms | 26.30 ms |
| Lunar agriculture | 8.16 ms | 15.72 ms | 16.87 ms | 17.70 ms |

The Earth obstruction checks reuse the generator's exact graded-town height instead of resampling planetary roads for every worker probe. Moon foundations still solve against the existing spherical triangle sampler. These short M4 samples do not establish sustained thermal behavior, M1/M3/Windows performance or cold shader-compilation limits.

## Visual review

Inspected the new main-menu entry, Earth town at walking height, farms panel at a smaller window, Moon grow-cell service aisles, lunar pads, crater relief and photographic observation sky. Fixed a management-panel height overflow, crossing industrial routes, cargo labels reading metadata as quantities, stale profession visuals, and Moon pads intersecting terrain.

Local captures and logs are preserved under `artifacts/frontier/`. Reproduce examples with:

```sh
/opt/homebrew/bin/godot --path . -- frontiershot town-walk /tmp/troop-town.png
/opt/homebrew/bin/godot --path . -- frontiershot moon-walk /tmp/troop-moon.png
/opt/homebrew/bin/godot --path . -- frontiershot ui /tmp/troop-farms.png Farms
/opt/homebrew/bin/godot --path . -- frontierbench
```

## Remaining limits

- Godot's renderer still reports a particle-shader/RID resource leak during shutdown. The non-career vehicle and combat tests also reproduce this warning family; the final career fixture reports two DummyShader RIDs. This is unresolved and prevents a zero-bug claim.
- The society is offline. Shared persistent multiplayer economies and deployment are outside this delivered change.
- This implements the working core of the original proposal. Additional regions, research/breeding, detailed produce lots/grades, population growth, financial institutions and permanent cooperative ownership remain roadmap items. See the [gameplay guide](ROOTS_AND_ROCKETS.md) for precise implemented behavior and resource limits.
- Astronomy uses real imagery with an approximate epoch and compressed gameplay clock. See [attribution and astronomical limits](../assets/astronomy/ATTRIBUTION.md).
