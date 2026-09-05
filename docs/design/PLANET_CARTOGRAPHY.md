# Playable-world cartography

The X-key world map now charts the Earth and Moon that the player can actually explore. It keeps the existing drag/WASD pan, wheel zoom, body selection, Home/recenter and close controls. Earth and Moon remember separate views, and the Moon supports close terrain inspection as well as a globe. The panel scales to the viewport, up to 1,380 by 920 pixels.

## Geographic source

Local Earth tiles and the Earth globe use the same seeded `Gen` terrain sampler as the playable world, including town grading, the runway, the city plateau and the pond basin. Imported continent photography and the unrelated satellite detail overlay are no longer navigation data. Colors use continuous shared climate and elevation fields, avoiding the ground material's tiny biome/color variations at global scale. Water classification and elevation remain tied to actual terrain.

Moon tiles and its globe sample `MoonWorld.surface_position`, the same welded cubed-sphere triangles used for physical support. The map uses the actual 450-metre playable radius and the expedition's seed (`world_seed ^ 0x4d4f4f4e`), or the live Moon's seed when available. Radial positions cover all six faces and both hemispheres; markers are no longer squeezed into an invented patch on an astronomical globe. The map converts through the live Moon transform before projecting players or waypoints.

Earth coordinates retain the game's equirectangular convention. Crossing longitude wraps; crossing a pole reflects latitude and shifts longitude by half a turn. The nearest equivalent map image follows the same rule as gameplay even after multiple circumnavigations. Lunar coordinates similarly map a direction to angles and back without losing the far side. Planar charts stretch distances near poles; globe views show the complete spherical surface. The scale bar expresses chart metres, with the Moon explicitly labeled by its playable radius. Shading displays the physical Moon mesh’s faceted relief at close zoom; its geometry is deliberately not replaced by a smoother, inaccurate height field.

## Features and readability

Canvas vectors draw the real 52×48 rectangular city street grid, the complete full-size building footprints at close zoom, the 104-block park boundary and natural lake, seeded regional roads and the runway. The park has no invented internal streets. The city access road and town connections use the authored layout. Transit stops, the spaceport, settlements, available worksite interactions and lunar colony facilities have labels at their real coordinates. Existing city, society and lunar waypoints use the same projection as players. Realm membership still comes from network authority, so Earth, Moon and transit peers cannot appear on the wrong surface.

Labels have collision avoidance and zoom thresholds; minor services give way to towns and major destinations at broader scales. Lines and marker outlines are antialiased. Terrain textures use linear mipmap filtering. The minimap also explicitly requests linear filtering and uses Metal-compatible RGBA8 uploads while preserving its established local lunar chart and bounded baker.

## Work and memory limits

One worker owns unparented private Earth/Moon samplers. It never reads the live generator's mutable caches, scene nodes or rendering resources. Jobs carry immutable seed/body/rectangle options; only a completed Image crosses back to the canvas. At most one texture is published per frame. Closing cancels pending work, and stale results are rejected when the seed changes.

Terrain tiles progressively refine through 4, 8, 16, 32, 64 and 128 cells, including common edge samples. A final tile has 129-by-129 actual terrain samples and mipmaps. A single LRU retains at most 64 local tiles across bodies and zoom levels. The private Earth macro cache is capped at 32,768 entries; Moon queries cache exact welded vertices on demand, bounded by the physical sphere’s 24,578 vertices. Local previews do not wait for the entire lunar grid to be populated. The globe similarly refines from 33-by-17 through 1,025-by-513 samples per body. A finished map retains its cache when closed; rendering and requests stop. The first view is intentionally coarse while real terrain arrives, without stamping unrelated detail over it.

## Verification

Run `godot --headless --path . -- cartographytest` from the active worktree. The actual-scene regression currently passes **54/54** in `artifacts/cartography-rectangular-edges.log`. It checks independent seeded caches, Earth height agreement at towns/city/pond/runway/seams, seed variation, Moon direction roundtrips and triangle-height agreement across all six faces, repeated planet wrap, full surrounding parcel footprints and the expanded park clearing, park street exclusion, all six hangar positions/orientations, transit/waypoint/spaceport/farm coordinates, cursor-anchored Moon zoom, real mipmapped worker results, exact texture-edge alignment, cache limits and closed-map idling. Four municipal-corner cases ensure parcel outlines remain present when a close map view crosses the city boundary. Extra street-to-continental projection and 4K tile-budget cases verify the wider zoom range; canonical geometry queries keep the city visible after repeated longitude and meridian wraps.

The earlier map revision passed **64/64** in `cartographysnap`, before the rectangular-block and large-park expansion, including native captures of the city overview, close streets/park, spaceport, Earth globe, Moon colony, Moon globe and far-side terrain. The capture wait explicitly requests the current rectangle before checking its tile keys, preventing a completed previous view from falsely satisfying the new view’s refinement requirement. Close terrain captures reach 129-by-129 samples per tile, both globes reach 1,025-by-513, and the broad city overview relies on its exact vector street plan over a coarser terrain preview. All seven images from that earlier revision were inspected; they do not constitute native visual evidence for the later park expansion. Logs, screenshots and raw measurements are in `artifacts/cartography/`.

On an Apple M4 with Metal and a 1,600-by-900 viewport, the initial local lunar stage-2 refinement completed in **3.323 seconds**, using 1,967 queried vertices rather than waiting for all 24,578. Native captures ran without another Godot GPU workload. Each timing below is the p95 of 90 frames after the view reached its required detail; update and draw are map CPU timings, not whole-game frame times or GPU timings.

| View | Map update p95 | Map draw p95 |
| --- | ---: | ---: |
| City overview | 0.584 ms | 3.726 ms |
| Streets and park | 0.087 ms | 6.151 ms |
| Spaceport | 0.084 ms | 2.492 ms |
| Earth globe | 0.019 ms | 1.550 ms |
| Moon colony | 0.102 ms | 1.659 ms |
| Moon globe | 0.020 ms | 1.213 ms |
| Lunar far side | 0.152 ms | 1.325 ms |

This is M4 evidence; other hardware and thermal sessions remain unmeasured. The native process exited successfully with no script errors. Godot still reports one shared `ParticlesShaderRD` and one shader RID cleanup diagnostic at shutdown.

The older `worldmaptest` passes **45/45** in `artifacts/worldmap-cartography.log` and retains projection, realm visibility, minimap terrain/heading and UI-input coverage; assertions that required unrelated imported atlases were replaced by the new generator-specific regression.
