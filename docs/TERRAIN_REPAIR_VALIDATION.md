# Earth terrain and debug-floor repair

The near Earth terrain was fully opaque while the Horizon mesh faded in over
it. Flat town plots produced coplanar depth fighting; different mesh resolutions
also exposed intersecting polygons. During partial loading, the previous scalar
handoffs could choose an unavailable terrain level. Debug Skyline and Stratos
samples additionally bypassed the flat two-metre floor used by actors/collision.

The four ground shaders now share one ownership calculation and a 32×32 RGBA
residency texture. Each channel represents committed meshes at that level's
sector scale. Absent levels are skipped, and the last available level retains
coverage. The atlas updates only when membership or its origin changes. Ground
meshes no longer disappear independently through camera-to-sector-center culling.
Water and foliage retain their existing streaming policies.

Near terrain approaches its actual 12 m parent triangle's height and uploaded
color between 48–60 m, before the 64–96 m coverage handoff. Its shading also
matches the parent before switching. The parent targets reuse existing samples;
no additional generator evaluations are needed. Original terrain vertices,
collision faces, and four-vertex flight shells remain intact. All four debug
terrain samplers now use the same flat floor, with no canopy height/coverage.

## Automated checks

| Check | Result |
| --- | --- |
| `terraincoveragetest.gd` | 138/138; 108,312 ownership samples |
| `terrainmorphtest.gd` | 60/60; 3,468 actual mesh vertices |
| `streaminglodtest.gd` | 117/117, including 74,880 water coverage samples |
| `debugtest` | 37/37 |
| `onlineperformancetest` | 11/11; exact collision parity and coarse promotion |
| Total | 363 checks passed |

Ownership checks cover positive/negative boundaries, missing levels, partial
online entry, ascent/descent, remote collision patches, equal-count membership
replacement, and zero-hash pixels. The mesh check compares actual uploaded
Horizon triangles with near targets: maximum height error 0.00006105 m and color
error 0.00000003, including a hillside over 1 km above sea level.

The debug suite's existing version-rejection assertion was corrected to accept
the intended source-build explanation case-insensitively. It also asserts that
source runs create no update-manifest or download requests.

## Renderer evidence

Native Godot 4.7 Forward+/Metal on Apple M4, 1080×720 captured viewport:

- `artifacts/terrain-repair/before-town.png` and `after-town.png` show the repair.
- Eight captures each cover town, ordinary Earth, and debug terrain: spawn,
  positive/negative chunk crossings, outskirts, flight at 700 m clearance,
  partially loaded descent, and settled descent.
- Two additional ordinary hillside captures use seed 4321 at x=-120000,
  z=400000, elevation approximately 1014 m. The Earth/hillside diagnostic hides
  local foliage and fog so the actual terrain remains visible.
- Six debug-aircraft views (both sides, high, low, mounted view, and course)
  confirm the aircraft mesh is visible. The reproduced defect was the ground.

Screenshots and logs are under `artifacts/terrain-repair/` and
`artifacts/debug-plane/`. The reusable renderer fixture is
`tests/terrain_render_capture.gd`; it runs a fresh unsaved session.

These checks establish the reported overlap/floor repair on this renderer.
Higher terrain levels retain their existing approximation of shape and normals;
this is not a guarantee of identical LOD shading everywhere or other-GPU coverage.
The pre-existing ParticlesShaderRD/RID cleanup warning still occurs on renderer
shutdown. No new shader compile errors or runtime script errors were reported.
