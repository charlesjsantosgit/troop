# City emergency response

`CityDisasters` creates a bounded response scene for each authoritative city incident. `CityEmergencyResponse.configure(world, record)` receives the saved building, impact, direction and timing record; `update_phase(phase, progress, age)` projects the same incident clock used by the physical damaged-building shell. Incident creation, closure of streets, persistence, collapse geometry, repair progress and next-morning restoration remain in the incident controller and network authority.

A fire engine approaches along an actual directed `CityTraffic` road edge, enters from its normal traffic lane and eases to the incident-side curb. A repair van follows during stabilization. Routes exclude the park and lake, obey road direction, and remain inside the carriageway. Both response vehicles have physical box hulls and use swept movement, stopping on an obstruction. When a stopped road actor blocks the traffic lane, the response vehicle sweeps sideways into the clear curb strip of the same road and passes physically; it does not disable collisions or move the other car. Their appearance, wheels, compartments, ladder, lamps and reflective trim use the same bounded equipment batch as other response props.

Once the engine arrives, at most eight monkeys work at the curb. Two operate animated hoses during the fire phase. Stabilization and rebuilding introduce hard hats, cones, stacked timber and hand tools. Four builders carry timber across their actual hand joints while their articulated tail holds a toolbox handle. The bodies, faces, hands and tails are direct baked copies of the player `MonkeyRig`, at deterministic heights from 1.7018–1.8796 m. Helmets, vests and tools are props; they do not replace the player's character model.

Each incident has two vehicles, up to eight crew members, twelve cones, one timber stack and at most 48 instanced water segments. It adds no dynamic lights. Canonical pose caches and the equipment meshes bound draw resources; teardown frees the entire response scene when the incident resolves. The damaged building's scaffolding is supplied by `CityDamageShell`.

`cityemergencytest` exercises approaches across more than 200 real parcels, actual disaster-controller installation, physical engine and van arrival, bounded crews and water, rebuilding, and teardown. The current headless scene gate passed **14/14** in `artifacts/emergency-headless-final.log`. The stopped-car fixture verifies that a deliberately placed physical obstacle remains unmoved while the response sweeps through the clear curb strip.

The final `cityemergencysnap` run passed **23/23** on Apple M4 / Metal with normal audio, including native hose geometry changing after a renderer frame, both vehicle arrivals, four tail-grip carriers, and resource teardown. All seven 960×540 images in `artifacts/emergency-response` were inspected:

- `firefighters-at-curb.png` and `builders-tail-carry.png` show the actual response crews and vehicles.
- `aircraft-shaped-wall-opening.png` shows absent wall cells, with the city visible through the aircraft silhouette.
- `upper-building-collapse.png` shows the actual tall property's lowered and tilted upper section at eight seconds.
- `reconstruction-scaffold-early.png` and `reconstruction-scaffold-late.png` show the complete scaffold and successive physical reconstruction heights.
- `restored-building-next-morning.png` shows the original complete building restored at 06:00, after removing the incident scene.

Log: `artifacts/emergency-native-damage-final.log`. The final arrival completed in 2,139 ms over 35 physics frames. The capture fixture allows a bounded 90-second initial wait for complete terrain/collision readiness; the first cold native run exceeded its former 20-second fixture deadline. This is a capture readiness check, not an isolated performance benchmark. The accepted final run had no compile/gameplay errors or ObjectDB leak. It retained two particle-shader and two shader-RID shutdown diagnostics while exercising two incident scenes, consistent with the shared renderer cleanup limitation.
