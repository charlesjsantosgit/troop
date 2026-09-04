# Photographic space and lunar relief

Rocket passengers see the packaged ESO / S. Brunier full-sphere photograph through both outward and return travel. The old finite black shell, generated star boxes and decorative nebula/planet props no longer cover the real sky. Earth and Moon remain actual voyage geometry. Atmospheric scattering fades smoothly during departure and return; the existing lunar observation mode retains its constellation guide and instrument exposure.

Ordinary Earth flight keeps the original day/night sky through 12,000 game metres. The photograph gradually emerges between 12,000 and 30,000 metres, and the original sky and fog return on descent. **This is a compact-world visual transition, not Earth's real atmospheric boundary:** the game's separate Moon realm starts at 36,000 metres. No realm, oxygen, gravity or flight-physics rule changes with this visual effect.

Lunar rim shadows trace ten bounded samples towards the current Sun using six 65 × 65 floating-point height faces copied from the welded terrain vertices. This preserves direction-dependent relief beyond the short actor-shadow range without adding overlapping terrain or enlarging shadow cascades. The lookup interpolates the terrain height grid; it is a practical approximation, not a full ray tracer. The compact spherical horizon can naturally conceal distant crater interiors from a ground-level eye.

The photograph is a long-exposure sky reference. Planet positions use the existing deterministic approximate orbital model and the accelerated game clock; this is not navigation-grade astronomy or a claim that faint nebulae are naked-eye bright.

## Verification

Run from the active project:

```sh
godot --headless --path . --script res://tests/spacephototest.gd
godot --headless --path . -- lunarskytest
godot --headless --path . --script res://tests/expeditionintegrationtest.gd
godot --headless --path . -- lunarexpeditiontest
```

The focused gate passed 14/14 checks; the existing sky gate passed 18/18 and both expedition gates passed 81/81. Native Metal captures cover outbound/return vacuum, both atmosphere transitions, opposite low-Sun crater lighting, ground-level crater relief, and the Earth free-flight sky. Captures and logs are in `artifacts/shared-societies/space`.

A bounded native comparison used Apple M4, Forward+, 1280 × 720, the same static Moon camera, 20 warm-up frames and 120 recorded frames per shader. Total-frame p95 was 17.135 ms for the previous shader and 17.150 ms for the terrain-height shadows. Render-thread CPU p95 was 0.474 / 0.420 ms. GPU timestamps were unavailable (the backend returned zero); these are total-frame results, not isolated shader timings. Other hardware, larger resolutions and cold-entry stalls were not measured by this comparison.
