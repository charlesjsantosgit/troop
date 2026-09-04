> Implementation status, September 3, 2026: a playable local Roots & Rockets expansion now exists. See [the gameplay and implementation guide](../ROOTS_AND_ROCKETS.md) for implemented systems, verification and deferred proposal items. The original proposal below is preserved; its full-expansion targets are not a completion claim.

# TROOP: Roots & Rockets

Status: expansion proposal, not implemented. Prepared September 3, 2026 against the current checkout. Crop timings, prices, population budgets, and freight costs below are proposed game tuning, not real agricultural or aerospace estimates.

## The promise

Start with a small jungle farm. Build a cooperative of growers, technicians, merchants, and haulers. Supply towns on Earth, open a lunar greenhouse, and eventually operate a food network connecting both worlds.

The defining experience is a world where work has consequences you can see: a worker harvests a named lot, a driver loads it, a market sells it, and a settlement eats it. A late shipment changes dinner menus, prices, and tomorrow's planting decisions.

Introduce a persistent **Frontier** mode alongside TROOP's existing movement and combat play. Keep swinging, physical interaction, exploration, and readable procedural animation central. Farms provide destinations and reasons to travel; supply routes create adventures.

## 1. Two worlds with different problems

| | Earth | Moon |
|---|---|---|
| Agricultural advantage | Existing ecosystems, outdoor growing, access to water and biological inputs | Carefully controlled environments and proximity to lunar consumers |
| Main constraints | Soil, weather, pests, terrain, labor, storage and transport | Pressure, power, heat rejection, water recovery, nutrients, maintenance and freight |
| Landscape | Canopy orchards, wetland farms, terraces, villages and river ports | Crater settlements, shielded grow rooms, service tunnels, cargo pads and ice-processing outposts |
| Good businesses | Staple crops, fruit, seed stock, food processing and export consolidation | Fresh food near consumers, habitat service, recycling, local freight and seed trials |
| Movement | Swing paths, canopy bridges, riverboats and cargo cableways | Low-gravity traversal, tethers, cranes and cargo rovers |
| Failure to recover from | A damaged irrigation line or wet harvest | A failing pump, power deficit or delayed replacement part |

Earth remains valuable throughout progression. A lunar farm should gain an advantage over repeated fresh-food imports when it becomes efficient; simply putting every Earth crop on the Moon must not multiply its value forever.

### Earth regions

- **Emerald Rainforest:** banana and plantain orchards, cocoa, cassava and shaded nursery beds. Manage canopy light, drainage, access and fungal pressure.
- **Bamboo Grove:** mixed farms, workshops, trellises and bamboo construction supplies. Provide a strong early cooperative district.
- **Flooded Wetland:** rice and taro plots, water gates, raised warehouses and boat access. Flood tolerance depends on crop and growth stage.
- **Cloud Highland:** tea and coffee districts where conditions fit, sheltered vegetables, contour terraces and cool stores. Slope and temperature make siting matter.
- **Port settlements:** grading, auctions, packaging, refrigeration, machinery services and access to space freight. These are the economic connection between local farming and lunar development.

Village layouts grow around useful infrastructure. A village that consistently has food, jobs, housing and utilities can add residents and funded demand over time. Growth has explicit capacity and immigration limits.

### Lunar regions

- **First Landing:** starter habitat, greenhouse rental bays, training crew and a reliable scheduled port.
- **Polar Works:** expensive water extraction and processing linked to surveyed ice deposits; equipment and energy constrain output.
- **Crater Gardens:** shielded commercial farms with shared utilities and independent growers.
- **Far-Side Station:** a remote research customer reached through relay communications and longer local logistics routes.

These are proposed fictional settlements. Ice is not present in every crater, and the far side is not permanently dark. The Moon has roughly one-sixth Earth's surface gravity, a non-breathable exosphere and severe surface temperature variation. Those facts motivate enclosed farms, suit procedures and thermal systems. [NASA: Moon Facts](https://science.nasa.gov/moon/facts/)

## 2. Agriculture with depth and physical feedback

### Soil and crop health

Each cultivated plot stores moisture, drainage/compaction, organic matter, pH, nitrogen/phosphorus/potassium availability, disease pressure and recent crop history. Crop definitions describe tolerated conditions and resource demands; the interface initially surfaces only the limiting factors.

An inspection might report: **"Roots waterlogged. Open the west drain; more fertilizer will not help."** Better tools improve diagnosis. A beginner can follow recommendations while an expert adjusts rotations, planting density and irrigation schedules.

Growth progresses through establishment, vegetative growth, flowering or equivalent development, harvest readiness and decline. Temperature, light, water and nutrition affect progress and yield; severe stress can cause recoverable damage before crop loss. All crops use the same authoritative progression clock.

- Irrigation networks have tanks, pumps, valves, flow capacity and measurable leaks.
- Rain changes soil moisture; drainage and slopes determine where excess water goes.
- Repeated monoculture can increase relevant pest or disease pressure.
- Legume rotations can contribute nitrogen under suitable conditions; harvest exports nutrients and other inputs remain necessary.
- Compost, mulch and cover crops consume actual inputs and take time to work.
- Pollination requirements are crop-specific. Orchards can benefit from managed habitat; lunar crops use appropriate manual or mechanical methods where needed.
- Seed saving, cuttings and nursery starts follow each crop's propagation method. Banana planting material comes from suckers or nursery stock rather than generic packets of banana seeds.
- Breeding produces bounded tradeoffs across repeated generations or trials: flavor, shelf life, resistance, yield and resource demand. It cannot bypass plant biology.

Healthy plants look healthy. Dry leaves droop, fruit ripens, wet ground darkens, old leaves discolor and crop rows visibly thin after harvest. Symptoms communicate a problem without uniquely identifying every cause; inspection resolves uncertainty.

### Launch roster and expansion crops

| Crop group | Proposed crops | Role in the economy |
|---|---|---|
| Tropical fruit and roots | Banana, plantain, cassava, sweet potato | Local food, dependable production and processing |
| Wetland staples | Rice, taro | Settlement food stocks and bulk contracts |
| Grain and legumes | Maize, soybean, common bean, peanut | Calories, protein, oil and crop rotation choices |
| Fresh vegetables | Tomato, cucumber, pepper, lettuce, spinach, radish, carrot | Perishable local sales and greenhouse specialization |
| Fruit and beverages | Strawberry, cocoa, coffee, tea | Quality-sensitive customers and processing |
| Material crops | Cotton, flax, bamboo | Cloth, ropes, crates, trellises and farm infrastructure |

This 24-crop roster is a full-expansion target. The first playable release starts with banana, sweet potato, bean, lettuce, tomato and rice. Crop placement follows local conditions rather than allowing every crop to flourish in every biome.

Later specialist production adds culinary mushrooms, managed aquaculture and dedicated seed nurseries after the core resource flows work. Mushrooms consume suitable organic substrate; fish require feed, oxygen and water management.

### Farming that fits TROOP

- Swing between orchard platforms to inspect bunches and carry small valuable loads.
- Lower harvested fruit in baskets; dropping it can reduce sale grade.
- Build cargo cableways, trellises and canopy walkways with procedural construction pieces.
- Choose a light harvest satchel or a heavier crate; substantial bulk moves by equipment and hired haulers.
- Repair a pump through an accessible physical interaction, then watch the pressure and crop condition recover.
- Ground-level carts and riverboats move staples; express canopy routes favor seedlings, samples and urgent parts.

Manual work should feel satisfying but delegation must remove repeated chores. The player can remain a hands-on grower or become a farm designer, merchant, engineer or expedition leader.

## 3. Lunar agriculture as habitat engineering

The first lunar farm is a pressure-rated grow room with shielding and controlled light. Larger installations use serviceable modules, isolated crop compartments and visible shared utility lines. Viewing windows and protected observation spaces provide the Earth-over-the-horizon spectacle without treating an ordinary glass dome as complete protection.

### Required systems

1. **Pressure and atmosphere:** compartment integrity, circulation, monitored gas conditions and airlock procedures.
2. **Power:** lighting, pumps, heating/cooling and emergency equipment share generation and storage capacity. Show power in kW and stored energy in kWh.
3. **Thermal control:** lamps and machinery add heat; radiators and coolant loops must remove it.
4. **Root-zone support:** nutrient solution, suitable substrate, oxygen availability, pH and conductivity monitoring.
5. **Water recovery:** condensate and recoverable wastewater return through treatment. Losses, contamination and maintenance prevent a perpetual-water loop.
6. **Consumables:** replacement seals, filters, nutrients, growth media, planting stock and packaging.
7. **Protection:** shielding, dust control, suitlocks and isolated work areas.

Plants contribute to habitat resource flows, but a small salad bed cannot instantly replace emergency oxygen reserves or a working life-support system. Production and life-support equipment retain separate capacity limits.

NASA's plant facilities use controlled lighting, nutrient delivery and managed root environments. That supports the controlled-farm direction; it does not establish the yields of a future commercial lunar farm. [NASA: Advanced Plant Habitat](https://science.nasa.gov/mission/advanced-plant-habitat/)

### Crops and research

Early candidates are leafy greens and radishes. Expand to dwarf tomatoes, peppers, strawberries, potatoes, dwarf wheat and soybeans as trial outcomes and available space justify them. These are gameplay candidates, not a claim that this complete crop set has been validated on the Moon.

Each crop competes for growing area, energy, water, nutrients and labor. Compare food value, freshness, crop duration and input costs. A specialized leafy-green farm and a staple-crop installation serve different needs.

Regolith trials are a later research branch. Returned lunar regolith supported small Arabidopsis plants in controlled Earth experiments with added water and nutrients, but the plants showed stress and poorer growth than controls. Accordingly, ordinary lunar dust is not fertile potting soil; substrate processing and nutrient inputs remain necessary. [NASA: Scientists Grow Plants in Lunar Soil](https://www.nasa.gov/humans-in-space/scientists-grow-plants-in-lunar-soil/)

The signature late-game project is **the first reliable lunar banana orchard**: a costly, carefully maintained community garden and specialty business. Its value comes from fresh produce, identity and local demand, rather than an automatic rarity multiplier.

### Emergencies with counterplay

A failing irrigation pump should produce declining flow, sensor warnings and a technician response before a crop is lost. The crew can isolate a bay, switch to an authorized reserve line, fetch a replacement seal or ask for help. Compartmentalization keeps one failure from deleting an entire settlement.

Lunar light and shadow use their own schedule. Long darkness matters to power planning; real waiting times are compressed and clearly presented. Low gravity changes movement and handling, not an automatic plant-growth speed bonus.

## 4. Processing makes the harvest useful

| Chain | What it creates | What constrains it |
|---|---|---|
| Banana → grading → fresh sale or drying | Premium fresh fruit and longer-lived food | Maturity, packaging, drying energy and customer demand |
| Rice/maize → drying → milling → cooking | Staple ingredients and prepared meals | Moisture, milling capacity, storage and labor |
| Soybean/peanut → pressing/processing | Oil, food ingredients and byproducts | Equipment, recipes, heat and conversion yields |
| Cotton/flax → fiber → thread → cloth/rope | Work clothing, sacks and equipment inputs | Labor, workshops and processing losses |
| Crop residues → compost treatment → amendment | Recoverable soil nutrients and organic matter | Feedstock, time, sanitation and nutrient balance |
| Lunar crops → packing → habitat kitchens | Fresh meals and fulfilled supply contracts | Food safety, shelf life and transport between habitats |

Every recipe lists inputs, outputs, byproducts, losses, labor and energy. Drying removes water; it does not preserve the fresh mass while also creating dried food. Recoverable waste has a destination in the ledger.

Quality is multidimensional: freshness, damage, contamination status, variety and relevant traits. Kitchens can accept cosmetically imperfect food that a premium stall rejects. Unsafe food cannot become safe simply by receiving a lower cosmetic grade.

## 5. Markets built on real goods and funded demand

### Money and stock

Use persistent **trade credits** for Frontier commerce and physical produce lots for harvested bananas. Keep competitive banana score separate. A floating score pickup cannot mint agricultural inventory or persistent money.

Households, farms, merchants, carriers, employers and settlement treasuries have finite wallets and inventories. Workers earn wages and buy meals. Kitchens buy ingredients. Farms buy inputs. Merchants replenish from producers. Buyers cannot buy indefinitely after their money, storage or needs run out.

Money ordinarily transfers between accounts. Taxes fund treasury work; carrier and market fees pay service providers. Any starter grants or external settlement funding are explicit, bounded ledger sources. Account-creation and restart rules must prevent repeatedly claiming grants into a shared economy. Money removed at the simulation boundary is an explicit sink. Monitor liquidity and solvency so a purely draining economy cannot silently grind to a halt.

Newly discovered terrain does not create unlimited purchasing power. Settlement demand depends on actual supported population and funded institutions, with limits on expansion and active production.

### Markets players can read

Each market exposes:

- **Buy orders:** commodity, accepted grade, quantity, funded price, delivery location and expiry.
- **Sell orders:** a specific reserved stock lot, available quantity and asking price.
- **Recent sales:** actual transactions, not fabricated activity.
- **Stock cover:** usable stock available to local consumers relative to expected consumption. Include inventory in open local sell orders; exclude already sold inventory, outbound commitments and protected non-sale reserves. Listing a crate for sale cannot make local supply appear to disappear.
- **Incoming cargo:** owner-authorized shipment information, ETA and uncertainty.
- **Causes:** concise facts such as "Cooling failure reduced this week's tomato harvest."

Reference prices guide NPC bidding using inventory, forecast demand, input costs, acceptable substitutes, arrival times and risk. Actual trades clear against finite funded orders. Buyer bid and seller ask differ, and bulk trades consume available order depth. A 1,000 kg sale cannot receive the initial 1 kg price on every kilogram.

The accompanying interactive example uses a deliberately small illustrative model: 100 kg initially available local stock, 100 kg/day planned demand, a three-day target, 20 credits/kg base reference, scarcity exponent 0.6 and buyer bid at 90% of reference. Reference is clamped between 0.5× and 2× base. It displays the next-unit bid after hypothetical deliveries, not proceeds for an executed bulk trade. The full game must also account for cash, capacity, substitutes and order depth.

Remote prices carry a timestamp and source. A broker knows a remote shortage through a market bulletin, instrument report or contact. Traveling to a market is not necessary for every quote, but knowledge must come through an actual communication channel.

### Earth–Moon freight

Cargo moves through packing, origin storage, manifest reservation, loading, departure, arrival inspection and destination delivery. Packaging counts toward mass and volume. Chilled cargo consumes service capacity. Local haulers physically handle it; long-distance flights use scheduled journey records and staged departure/arrival scenes.

Passenger travel and freight travel can be compressed for playability, but cargo has a visible ETA and remains in one authoritative location. A purchase on another world grants ownership there, not instant access in the player's backpack.

Useful exports from Earth include seed stock, nutrient concentrates, replacement equipment, processed staples and occasional fresh emergency or premium shipments. Lunar growers primarily serve lunar consumers. Return business can include high-value research samples and nursery trials; lunar resource businesses principally serve nearby space infrastructure where that makes economic sense. Broad commodity return exports are a later fictional industrial extension, not an assumed cheap-food route to Earth.

### Worked trade

A lunar greenhouse reserves 4,800 credits for 20 kg of nutrient concentrate at 240 credits/kg. These are illustrative game prices.

| Item | Credits |
|---|---:|
| Buy 20 kg concentrate on Earth at 100/kg | 2,000 |
| Buy 2 kg packaging | 40 |
| Ship 22 kg gross mass at 60/kg | 1,320 |
| Pay port handling | 100 |
| Total cost | 3,460 |
| Receive funded delivery payment | 4,800 |
| Trader profit | 1,340 |

A trader starting with 5,000 credits ends with 6,340. Supplier +2,000, packaging seller +40, carrier +1,320, port +100, buyer −4,800 and trader +1,340 reconcile to zero net money creation. Concentrate and packaging remain separately accounted for. The order is exhausted; repeating the route requires another real buyer and another available shipment.

### Contracts and institutions

Start with spot sales, funded delivery orders, processing jobs and standing supply agreements. Contracts state grade, quantity, deadline, partial-delivery policy, freight responsibility and escrow rules. Crew wages, storage rentals and farm leases create approachable recurring business.

Later add cooperative ownership, equipment finance and insurance only after the core economy is stable. Loans need funding and repayment capacity; insurance needs a funded reserve and explicit coverage. Neither is an unlimited emergency-money button.

## 6. NPCs whose intelligence is visible in their work

"Ultra realistic" is the desired feeling: consistent knowledge, believable routines, competent work and understandable decisions. It is not a promise of human-level AI.

| Role | Useful work | Evidence the player sees |
|---|---|---|
| Grower | Plant, irrigate, prune and harvest | Actual tool use, changed plots and delivered produce |
| Agronomist | Inspect crops, diagnose issues and run trials | Samples, confidence, observations and recommendations |
| Greenhouse technician | Maintain climate, pumps and alarms | Gauge checks, installed parts and tested repairs |
| Water operator | Allocate and treat water; mix nutrient feeds | Measured batches, tank changes and protected reserves |
| Packing specialist | Grade, weigh, label and pack harvests | Traceable lots and correct packaging |
| Warehouse keeper | Receive, rotate and preserve stock | Crate movement, cold-store checks and spoilage reports |
| Mechanic | Service tools, vehicles and machinery | Diagnosis, compatible spares and completed maintenance |
| Merchant | Buy inputs and sell surplus within limits | Real quotes, funded orders and delivered-cost comparisons |
| Dispatcher/hauler | Schedule, load and deliver freight | Manifests, reachable routes, fuel use and cargo arrival |
| Farm manager | Coordinate shifts, priorities and training | Work assignments, handovers and resolved blockers |

Each citizen has a persistent identity, skills, occupation, employer, schedule, needs, relationships and bounded memories. Skills improve through relevant work. Earth orchard expertise does not automatically confer knowledge of lunar nutrient equipment.

### The decision loop

1. **Observe:** gather facts through vision, inspections, instruments, authorized records and other people. Store source, time and confidence.
2. **Choose:** compare urgency, deadlines, travel, skill, available inputs, fatigue and employer priorities.
3. **Plan:** expand a goal into tasks with prerequisites and reservations.
4. **Act:** physically execute nearby work or advance a valid distant job over time.
5. **Verify:** check the authoritative result. An animation or sentence is not proof of production.
6. **Remember and report:** retain relevant results, revise stale beliefs and identify the next useful action.

For example, harvesting becomes: obtain empty container → reach bed → inspect maturity → pick available produce → deliver to packing → record accepted quantity. Two workers cannot reserve the same fruit or destination capacity.

### Autonomy the player can trust

The Crew board shows name, demonstrated skills, wage, shift, work zone, assignment, blocker, ETA and recent output. Set standing orders rather than clicking each plant:

> Maintain this greenhouse. Keep two days of water in reserve. Spend up to 80 credits per shift. Buy filters only below 12 credits. Tell me if you cannot protect the crop.

Orders also define permitted facilities, substitutions, emergency priorities and protected inventory. Provide pause, reassign, recall, take over and "Why are you doing this?" actions. An impossible job becomes a concrete reported blocker instead of an endless animation loop.

Personality changes reasonable tradeoffs. A cautious technician holds more spares; a frugal merchant accepts a longer route when deadlines permit. Workers remember fulfilled contracts, late pay, unsafe equipment and help received. Relationships influence retention, referrals, teaching and trust through actual events.

Daily life includes meals, rest, commutes, shift handovers and leisure. These are coordinated through settlement services so the player does not hand-feed every employee. Well-run farms retain experienced crews; poor conditions trigger warnings, reduced availability and eventually departures.

### Physical credibility and dialogue

Workers inspect leaf undersides, set a crate down before opening a panel, secure cargo, make room in narrow doors and clean equipment between affected plots. Lunar crews check suit readiness and wait for the airlock cycle. Motion, tool contact and work sounds should explain what they are doing.

Dialogue draws from real state: **"Pump three stopped at 06:10. I switched this bay to the reserve line. I need one seal."** Conversation cannot create money, grant ownership or declare unfinished work complete. Richer optional dialogue can explain the same facts without becoming the economic authority.

## 7. Progression and emergent adventures

### First session

The player meets Ookbar at a small cooperative, takes a paid harvest job, carries produce to the stall and sees its stock increase. That income funds a starter plot. The player plants a short-cycle crop, repairs a simple water line and hires a hauler for a delivery. A regional order introduces grading and storage.

Target a meaningful first harvest within roughly 15–25 minutes of active play, using established starter plants and clearly accelerated growth. Longer-lived orchards establish over several sessions; nursery transplants let players begin without waiting for real-world years.

### Career milestones

1. **Useful neighbor:** a small mixed farm and regular customers.
2. **Village supplier:** processing, irrigation and a crew with paid shifts.
3. **Regional cooperative:** shared warehouse, transport and standing contracts.
4. **Export business:** port access and reliable Earth–Moon shipments.
5. **Lunar grower:** leased bay, trained technician and a controlled crop cycle.
6. **Independent settlement:** multiple compartments, reserve utilities and local kitchens.
7. **Interworld cooperative:** complementary farms, research, training and infrastructure across both worlds.

### Event examples

- **Too Many Bananas:** several orchards ripen together. Fresh prices fall; drying, alternate buyers and storage become valuable.
- **The Missing Seal:** a lunar pump fault creates a maintenance job and a parts shipment. Successful repair reduces emergency food demand.
- **Before the Rain:** move a dry harvest into storage before incoming weather; hiring extra hands competes with the overtime cost.
- **The Empty Launch Slot:** a canceled cargo reservation creates a short-lived freight opportunity with a real capacity limit.
- **A Better Bean:** run a controlled cultivar trial with recorded inputs and compare measured results.
- **First Lunar Feast:** deliver a varied meal from local crops; success follows actual food production and kitchen capacity.

Events arise from simulation state or explicitly funded requests. A scripted celebration still purchases the food it uses.

## 8. Time, persistence and multiplayer

Retain TROOP's calendar-driven seasonal presentation. Agriculture uses explicit accelerated growth rules and crop-appropriate climate thresholds; the player never has to wait until next real spring to participate. Protected growing and regional crops provide year-round options. Lunar farms use independent habitat and illumination schedules.

Solo Frontier saves pause when closed. A managed shared world continues while operating, with NPC routines and player-configured reserve policies. Before leaving, show expected water, power, wages and storage coverage. Recovery favors salvage and repair; cooperative mode does not erase an entire established farm because one player missed a login.

Server downtime freezes authoritative simulation at its last committed time unless a bounded, explicitly designed recovery policy says otherwise. Client clocks and reconnects cannot accelerate growth, collect wages twice or refresh expired stock.

Default cooperative settlements protect civilian farms and trade infrastructure from casual destruction. Frontier conflict routes can support optional convoy raids, escorts and contested outposts with visible rules, capacity-backed losses and recovery. Competitive combat progression stays separate from business wealth.

Players can own plots, share cooperative facilities or hire each other for cultivation, maintenance and shipping. Separate rights for building, harvesting, withdrawing, spending and hiring prevent one broad access toggle from controlling everything.

## 9. Implementation grounded in this checkout

The current game supplies reusable terrain streaming, seasons, monkey rigs, movement and interaction patterns. The inspected code does not yet supply the proposed agriculture, lunar map, persistent commerce or worker simulation.

| Current code | What must change |
|---|---|
| `scripts/trade_ui.gd:10` defines six fixed offers; `:156` uses banana score | Add real accounts, goods, stock, sell orders and merchant identity |
| `scripts/main.gd:342` discards villager identity when opening trade | Bind the interface to the selected merchant and market |
| `scripts/player.gd:737` caps received supplies | Reserve capacity and settle only accepted quantities atomically |
| `scripts/friendly_monkey.gd:146` returns a villager to its post and makes it hop | Introduce persistent citizens, jobs, knowledge and work execution |
| `scripts/net.gd:232` clears session score and collection state | Create a separate persistent Frontier save and transaction domain |
| `scripts/world.gd:532` creates live friendly nodes with serial IDs | Store durable citizen records independently of scene nodes |
| `scripts/world.gd:1097` streams collision around players | Use distant economic simulation and bounded nearby navigation/collision support |
| `scripts/world.gd` moon references currently describe lighting and sky | Build a playable lunar world with travel, physics, habitats and infrastructure |

### Proposed modules and state

- **Agriculture definitions:** crops, growth requirements, tools, recipes and equipment.
- **Plot simulation:** soil, planted crop state, care history and harvest availability.
- **Habitat simulation:** compartment resources, utility topology and equipment state.
- **Inventory ledger:** identified lots, ownership, mass/volume, quality and location.
- **Economy service:** wallets, escrow, order books, wages, contracts and atomic transfers.
- **Freight service:** manifests, routes, reservations, transit and delivery acceptance.
- **Citizen simulation:** identities, observations, skills, policies, work orders and social events.
- **Persistence:** schema versions, migrations, checkpoints and replay-safe transaction records.

Use fixed-point quantities and integer currency. The authority validates ownership, location, sufficient funds, reserved stock, destination capacity, price and request identity. A retry receives the previous result. Multi-step UI flows cannot debit first and hope that delivery succeeds.

Persistent multiplayer identity is a prerequisite: a display name or temporary ENet peer ID is not proof of farm or wallet ownership. Establish authenticated stable accounts and reconnect handling before enabling shared permanent assets. Offline saves stay in their own economy rather than importing arbitrary goods into the public world.

Generate locations with stable world/region/plot identities and separately salted randomness. Save mutations independently of chunk nodes so revisiting a farm cannot reroll crops or refill a warehouse.

### Performance approach

Simulate resource flows per plot, lot, room and work order. Use procedural crop meshes and instancing for visible rows. Nearby workers receive animation, collision and staggered perception; distant workers use scheduled events and route progress with the same resource costs.

Materializing a distant worker transfers its current job and inventory exactly once. It cannot teleport goods, finish an unavailable path or bypass a damaged machine. Plan against spatial indexes and event subscriptions; cap path retries and expose blocked jobs.

Prototype an active settlement around 20–30 visible workers, then profile traversal, farming and combat together on target hardware. Larger population counts are data-simulation targets until measurement proves them. Preserve bounded per-frame streaming rather than letting every farm spawn full physics at any distance.

## 10. Delivery sequence and acceptance gates

| Stage | Playable result | Completion gate |
|---|---|---|
| 1. Earth cooperative | Six crops, one farm, one finite market, grower and hauler, save/load | Player plants, hires, harvests, sells and reloads without lost or duplicated state |
| 2. Regional economy | Multiple buyers, processing, cold storage, wages and local freight | Surplus lowers bids; shortages cause funded orders; transport costs affect profit |
| 3. Lunar foothold | Playable lunar area, one greenhouse, technician and Earth freight | Complete delivery, crop cycle, equipment failure and recovery under real resource constraints |
| 4. Living settlements | Managers, shifts, training, relationships and cooperative ownership | Crews complete policies independently and explain blocked or changed plans |
| 5. Full expansion | Expanded crop roster, research, regional specialties and optional conflict routes | Multiplayer recovery, long-run economy and supported-hardware budgets pass |

These are dependency stages, not calendar estimates. Stage 1 is the recommended first implementation target because it proves the whole loop through direct play.

### Required verification

1. **Crop causality:** repeatable fixtures for water, nutrition, light, disease, growth, harvest and recovery; season and climate are explicit test inputs.
2. **Money and goods:** randomized transaction sequences reconcile wallets plus escrow and inventories plus production/consumption/loss ledgers.
3. **Concurrency:** two buyers or workers contend for the final lot; exactly one gets it and no rejected party is charged.
4. **Capacity and quality:** full storage, incorrect grade, partial delivery, cancellation and stale quotes resolve under the agreed policy.
5. **Freight:** cargo has one owner/location, mass includes packaging, travel consumes time and resources, and departure/arrival cannot replay.
6. **Useful AI:** follow a complete work order; remove a tool or block a route and observe valid replanning or a specific blocker.
7. **Limited knowledge:** a worker learns a hidden fault only through an instrument, inspection or report; dialogue identifies its evidence.
8. **Bounded spending:** competing emergencies cannot bypass wages, purchase ceilings, permissions or protected reserves.
9. **Persistence:** chunk unload, save/reload, disconnect, restart and crash recovery preserve lots, jobs, escrow and stable ownership.
10. **Economic recovery:** shortages lead to substitutes, repair, trade and replenishment; NPCs never solve them by silently creating unlimited money or goods.
11. **Long-run stability:** verify household affordability, employer solvency, supplier replenishment and funded expansion through repeated crop cycles.
12. **Presentation and performance:** inspect hand/tool contact, crate movement, crop stages and airlocks; profile busy farms during terrain traversal and multiplayer activity.

Register future autoload-dependent checks as project CLI test modes and follow the current README's verification workflow. This proposal itself changes no gameplay and does not claim any of those implementation gates have passed.
