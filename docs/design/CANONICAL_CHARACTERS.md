# Canonical monkey characters

Every living person is built from `MonkeyRig`, the player's actual character model. Player standing height is 1.8288 m (6 ft). NPC standing height comes from `MonkeyRig.npc_height(identity)` or the same function through `CityMonkeyModels.height_for`, bounded to 1.7018–1.8796 m (5 ft 7 in–6 ft 2 in). These are sole-to-crown anatomical heights in the straight standing rest pose. Seated, working and walking poses bend the same joints; hats and helmets are equipment.

| Character path | Canonical model and stature |
| --- | --- |
| Local player, AI rivals, friendly villagers | `player.gd`, inherited by `ai_monkey.gd` and `friendly_monkey.gd`, creates `MonkeyRig` and applies player or identity-based NPC height. |
| Remote players and remote AI | `puppet.gd` creates the same rig; human peers use player height and negative AI peers use identity-based NPC height. |
| Earth and Moon workers, merchants and vehicle operators | `frontier_citizen.gd` creates the actual rig and an equally tall physical capsule. Changing profession or entering a vehicle preserves that stature. |
| Lunar cheesekeeper and farmer | `moon_merchant.gd` and `moon_farm_worker.gd` create the same rig and height-derived capsules beneath their lunar suits and workwear. |
| Near city pedestrians | `city_crowd.gd` uses complete articulated meshes baked by `city_monkey_models.gd`, scaled uniformly from its canonical base stature. |
| Mid-distance and distant city residents | `city_ambient_life.gd` uses those same complete meshes nearby and a rendered atlas of the same rig farther away. Atlas provenance records source hashes; per-resident scale uses the same height function. |
| City car drivers | `city_vehicle_models.gd` obtains actual seated rig meshes through `CityMonkeyModels.seated`; seat placement and recline fit the vehicle without shrinking the occupant. |
| Park participants and emergency crews | `park_actor_batch.gd` submits complete canonical pose meshes with their original material surfaces and identity-derived uniform height. Dogs, bicycles, helmets and tools are separate props. |
| Defeated local and remote characters | `monkey_ragdoll.gd` transfers the actual rig's meshes and materials onto the existing articulated physical bodies. The face, hands, full furry tail and winter scarf retain the original geometry and standing stature. |

The final audit found and removed the ragdoll's separately authored approximate body. It leaves the established rigid-body masses, collider dimensions, joint connections and head-detachment behavior intact. The canonical source rig and the city pose helper were not edited, preserving the verified population-atlas hashes. The mechanical shooting-range targets in the debug world remain equipment rather than people.

`tests/avatarheighttest.gd` passed **40/40** in `artifacts/avatarheight-canonical-audit.log`. It checks actual sole/crown vertices, local and remote player dimensions, AI/friendly characters, both dedicated lunar residents and their capsules, all 24 simulation residents through profession changes, seated/reset stature, original ragdoll vertex arrays and rest transforms at both requested endpoints plus player height, and moving physical body/headshot defeat with the same mesh resources. Existing rope/weapon contact and ragdoll collision-dimension checks also pass. This final ragdoll change was verified headlessly; no new native ragdoll screenshot was taken.
