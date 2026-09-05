# Lantern Central Park

Lantern Central Park is a large playable landscape inside Crownreach. Its winding paths, open lawns, woodland, lake promenade, and eastern boathouse take cues from Central Park; it is a fictional park fitted to this game's actual city and terrain. The Conservancy describes the original park as 843 acres, and its Lake as a 20-acre rowing destination. [Central Park history](https://www.centralparknyc.org/park-history), [The Lake](https://www.centralparknyc.org/locations/the-lake), [Boathouse](https://www.centralparknyc.org/locations/central-park-boathouse).

## Shared geography

`CityPlan` defines the park across eight city columns and thirteen city rows. The surrounding blocks occupy about 3.24 km². The landscaped interior is approximately 808 m by 3,850 m (3.11 km²), inset from the perimeter streets. Internal city streets are removed. Existing property identities are preserved by the city's address relocation scheme.

The natural lake has 160,515 m² of actual water, about 16.1 hectares or 39.7 acres. Its irregular shore is the level set of `CityPlan.pond_depth`, shared by terrain, water geometry, maps, and the rowboat boundary guard. Maximum basin depth is 1.6 m; the water elevation is 7.88 m. It is a deeper boating lake, not the former shallow decorative pond.

`CityParkLayout` supplies all nine walking routes, the separate seven-metre cycling loop, activity locations, boathouse, and four canonical boat definitions. Paths stay dry and inside the park. The cycling loop is longer than six kilometres. The full landscape is a persistent node, so nearby city-block streaming does not duplicate or delete sections of the lake.

## Activities and boats

The park contains 56 walkers, six dog walkers with dogs, 18 yoga participants, 24 cyclists, and 18 people socializing. Every person uses meshes baked directly from the same `MonkeyRig` as the player, including the face, paws, limbs and furry articulated tail. Deterministic standing heights fall between 1.7018 m and 1.8796 m (5 ft 7 in–6 ft 2 in). Cached joint poses animate walking, cycling, waving, and three yoga positions; uniforms and equipment are attached props.

- At the dog meadow, press **E** to throw a ball. A dog chases it, picks it up, and returns to the player.
- At the Great Lawn yoga group, press **E** to start the guided tree/warrior/breathing pose cycle.
- At the social terrace, press **E** to greet the neighbors and trigger their response.
- Cyclists ride a separate continuous loop. This is ambient cycling; the park does not introduce a new player bicycle vehicle.
- Walk onto an eastern timber landing and press **E** beside a rowboat. **W/S** row forward/backward; **A/D** steer. **E** while offshore requests a return to that boat's landing. Once docked, **E** disembarks onto the solid landing.

Four boats (`v:park-rowboat-01` through `04`) use the existing vehicle camera, rider pose, player interaction, canonical spawn and network vehicle systems. Their hulls have real convex collisions. The complete hull must remain in sufficiently deep lake water. Proposed steering and translation are collision-checked together before either is committed, including stationary turns beside a landing. Offshore disembarking is blocked; dock exit checks the real floor and player capsule using the world collision layer, including while the normal driving state has disabled the player's collision mask. Each landing has a solid deck and a gentle physical access ramp.

## Rendering and physical budgets

The park has 2,063 trees, 22,218 ground vertices, 258 water vertices, and 757 path segments. Trunks and crowns are instanced. A spatially indexed pool enables at most 64 nearby physical trunks and matching nearby canopy shadows. Woodland placement excludes the lake, paths, lawns, activity clearings and boathouse.

Dog, bicycle and equipment components share four instanced primitive batches. Monkey bodies use cached canonical pose meshes with their original material surfaces. Only actors within 440 m are submitted; their deterministic activity clocks continue outside this range. The animation update rate is bounded at 20 Hz. Terrain/tree generation yields periodically during construction.

## Validation

The initial actual-scene park gate passed 39/39 both before and after canonical player-model integration. It exercises shared shoreline and route geometry, all four canonical boat spawns and landing collisions, real E interactions, fetch completion, yoga animation, boarding, held-W rowing, steering, offshore exit prevention, return to dock, safe disembarking, and the nearby tree collider budget. Logs are `artifacts/park-headless.log` and `artifacts/park-headless-canonical.log`.

The current headless gate passes **43/43** in `artifacts/park-headless-turning.log`, adding explicit canonical mesh/height checks, path triangle orientation, and three seconds of stationary steering beside the real landing. Held-input rowing, subsequent steering, automatic return and safe disembarking still pass after the orientation guard.

`parkactivitytest` runs the headless scene gate. `parkactivitysnap` adds native aerial, lake/boathouse, yoga, dog meadow, social terrace, cycling, and player-rowboat captures in `artifacts/central-park`. Aerial capture waits for the complete city's far geometry to finish staging. The final native run passed **51/51**, including explicit canonical-model/height and path front-face checks. All seven saved views were inspected; the final lake image shows the boathouse and docks, the cycling image includes the actual route, and the rowing image shows the real seated player. Log: `artifacts/park-native-final.log`.

On Apple M4 / Metal, the accepted native run saved all seven images at **960×540 pixels**. Its 240 settled Great Lawn frames measured p50 **19.654 ms**, p95 **29.837 ms**, p99 **31.471 ms**, maximum **33.844 ms**. The accepted log does not record the logical viewport size or 3D render scale, so these timings must not be described as a 1600×900 rendering benchmark. This was a shared development run with other headless task work, not an isolated hardware benchmark. Other hardware remains unmeasured. There were no script or shader compilation errors in the accepted run; shutdown retained the shared one `ParticlesShaderRD` and one shader-RID cleanup diagnostic. Headless timing is not performance evidence.

Native timings and PNG dimensions are preserved separately in `artifacts/central-park/validation-native.json`, reconstructed explicitly from `artifacts/park-native-final.log` and the original PNG headers, with hashes and unknown fields left null. The later 43/43 headless report is preserved in `validation-headless.json`. `validation.json` now indexes those two reports. Future capture runs log image pixel dimensions, logical viewport dimensions and the observed 3D render-scale range separately.
