# TROOP: Roots & Rockets

A playable local farming, trade and working-society expansion on the existing Earth and spherical Moon. This guide describes implemented behavior. The broader [original design proposal](design/earth-moon-agriculture.md) remains a roadmap.

## Getting started

Launch this checkout with:

    /opt/homebrew/bin/godot --path . -- frontier

**B** opens the Society board; **B / Escape** closes it. **E** interacts with nearby citizens, plots and workplaces. **Locate** places a waypoint and closes the board so you can walk there. **Find rocket** points to the existing boarding hatch; Earth–Moon travel uses the expedition system.

1. Open **Quests** and accept **A welcome for the neighborhood**, or speak to Ookbar with **E**.
2. Bring your eight starter bananas to the Earth market and deliver the contract for 120 trade credits.
3. Visit your nearly established garden beds. Harvest ready crops; plant empty beds using crop-specific planting stock.
4. Use **Crew** to hire a grower and enable crew care on your plots. Hire orders wait for the citizen's existing task or delivery to finish.
5. Trade at the market, process goods at the workshop, and ship materials from the warehouse to your Moon locker. On the Moon, use the cargo pad for outbound freight.

Markets, deliveries, processing, planting, repairs, solar installation and refueling require visiting the relevant workplace. The board can show remote records; it does not teleport your cargo.

## Farming and processing

There are **24 crop definitions**: banana, plantain, cassava, sweet potato, rice, taro, maize, soybean, common bean, peanut, tomato, cucumber, pepper, lettuce, spinach, radish, carrot, strawberry, cocoa, coffee, tea, cotton, flax and bamboo. All can be selected and planted with their listed material. Banana starts, cassava cuttings and sweet-potato slips are distinct from seeds.

Six player Earth plots and four player Moon plots sit alongside eight cooperative beds. Soil moisture and nutrients are shown as **0–100%**; growth and health also appear as percentages. Crops have different water demand, growth duration, yield and temperature ranges. Weather supplies rain, repeated crops can increase disease, and legume rotations give a bounded nutrient benefit. Watering consumes five litres; nutrient treatment consumes actual supplies. Too much water damages non-wetland crops. Dead crops must be cleared before replanting.

The workshop supports drying bananas, milling rice or maize, pressing soybean oil, weaving cotton, making flax rope, constructing bamboo crates, treating compost, cooking mixed meals and making fish stew. Petroleum is refined at the refinery. **Eleven recipes** consume inputs and energy; player batches take twelve seconds and reserve space for their outputs. An unfinished batch and its progress survive saving.

Earth and Moon inventories are separate. Satchel/locker capacity is 350 aggregate game units; facilities have larger finite capacities. Units represent kilograms for crops and litres for fluids, with discrete units for equipment. These are intentionally simplified capacity and quality models.

## A society that works

**Twenty-four citizens** use **nineteen occupations**: grower, agronomist, greenhouse technician, water operator, packer, warehouse keeper, mechanic, merchant, hauler, farm manager, oil rigger, refinery operator, tanker driver, solar technician, cook, fisher, beekeeper, carpenter and citizen.

Workers follow the same service-road routes and work timers whether their visuals are nearby or distant. Production commits after arrival and work; cargo stays with its carrier until unloading. The board shows current work, blockers, skills, wages and recent outcomes. Nearby route checks can stop a worker for blocking construction; cargo and unfinished work remain held until the route clears. This is bounded obstruction detection on authored roads, not general navigation-mesh replanning.

Growers plant, water, feed, harvest and clear failed crops. Managers choose future plantings from market stock; agronomists inspect and treat crop stress. Technicians service real pumps and seals. Water operators transport filtered or extracted water. Merchants purchase inputs and move surplus against finite budgets. Fishers obtain bait, catch fish and deliver them to the kitchen; carpenters obtain bamboo and deliver finished crates. Citizens eat purchased meals, rest between shifts and spend leisure time around the huts and square.

Hiring transfers future wages to your account responsibility. The default wage is two credits per completed productive task; existing commitments finish before a queued hire takes effect. Crop care uses the plot owner's local supplies. A paused worker completes already committed work/cargo before stopping. Exhausted stock, an unaffordable wage or an unavailable destination produces a concrete blocker.

This is deterministic task planning, movement and resource execution, not human-level AI. Inspection-only duties report observations; not every role is a general-purpose problem solver.

## Oil, trade and transport

Riggers consume machinery diesel and process water while extracting a **finite surveyed crude reserve**. Tanker drivers buy and deliver crude to the refinery. A refining batch consumes ten litres of crude and one unit of process water, producing four gasoline, three diesel, two jet fuel and one bitumen. Drivers deliver distinct fuel products to the fuel station, cargo airfield, marine carrier and the rig's machinery supply.

Municipal vehicles consume fuel through funded purchases; player vehicles also use saved fuel tanks. Park yourself and the vehicle at a depot before buying fuel in **Industry**. Bikes, jeeps and boats use gasoline; jets use jet fuel. A stable vehicle receives its initial half tank once, and registering it again cannot refill it.

Every account has finite credits and every sale needs real stock, buyer funds and storage. Each unit in a bulk order changes the available market depth; surplus lowers subsequent bids. The bid/ask spread and finite buyers constrain repeated trading. Competitive banana score is separate.

On Earth, **Market → Refinery fuel desk** lets you purchase crude or refined products directly from available refinery stock. Bring the appropriate refined fuel to the gas-station or aircraft quest destination.

Earth–Moon freight requires packaging and credits, removes goods from the origin locker, reserves destination space and takes ninety seconds. Packaging travels with the cargo. Contracts hold rewards in escrow, expire after thirty minutes and pay only after the required goods reach the named destination. Cancellation returns escrow to the town.

## Moon utilities and recovery

Sealed crop cells depend on power, water, pressure, cooling and pump condition. Six starter solar panels each provide up to **3.8 kW**; actual output follows the visible Sun and panel condition. The greenhouse starts with 100 kWh battery capacity. Base life support draws 5 kW and each planted bed adds 1.2 kW, so all six lunar beds require 12.2 kW even when crop work is idle. The full twelve-panel installation can sustain this load across day and night with adequate charged storage; the starter system still needs expansion.

One solar kit plus 150 credits adds a panel, up to twelve. One battery kit plus 120 credits adds 100 kWh capacity, up to 1,200 kWh; **new capacity arrives empty**. Buy kits at the market and bring them to the solar field.

The eighty-minute lunar illumination cycle includes real periods of zero panel output. An undersized battery can run dry. Expand storage, preserve solar surplus and keep water and spare parts available. A spare part repairs seals, pump and cooling; water can be transferred into the reservoir. Low utilities slow or stop crops before sustained stress kills them, including ripe crops. The crew can clear losses and replant after service returns.

The sky uses the ESO/S. Brunier Milky Way photograph, NASA Earth imagery and constellation figures, with a rendered Sun and approximate planetary positions. **Sky / Observation** exposure reveals faint objects. Local horizon, exposure and object direction still limit what is visible. This is not a live observatory or precision astronomical ephemeris; see [imagery attribution and astronomy limits](../assets/astronomy/ATTRIBUTION.md).

## Saving and boundaries

The Society board has **Save**. Successful actions save immediately; an autosave runs approximately every twenty active seconds. The local save is **user://frontier/roots_and_rockets.json**, with a previous valid **.bak** checkpoint. Closing the game does not simulate elapsed wall-clock time. The pause menu pauses society progression.

Saved wallets, inventory, plots, workers, routes, cargo, batches, contracts, vehicles and utility state are validated before replacement. Writes use a temporary file and atomic rename. An unreadable existing save is preserved; a valid previous checkpoint can be recovered. Without a usable checkpoint, the controller disables overwriting the unreadable file in that session.

This career is **local and offline**. Existing multiplayer remains separate; arbitrary local wallets and inventory are not imported into public servers. The implementation does not yet provide authenticated shared farms or permanent multiplayer ownership.

The proposal's additional regions, population-driven settlement growth, breeding/research, detailed per-lot freshness/grade/contamination, commodity order books, insurance, loans, cooperative ownership and long-term economic expansion remain deferred. The current system has finite initial planting material, spare parts and market reserves; its prototype economy can require manual replenishment and is not an indefinitely self-sustaining world. No zero-bug or every-hardware claim is made.

## Verification and invariants

Run the registered check from this checkout:

    /opt/homebrew/bin/godot --headless --path . -- frontiertest

Latest core result: **93/93 PASS**. It covers crop causality, empty/full/unfunded market rejection, cargo conservation, escrow and replay handling, actual NPC travel before production, refining fractions, precise vehicle fuel use, solar/battery behavior, corrupt saves, and deterministic save/resume within 1e-9 floating-point tolerance. Credits and discrete goods reconcile exactly.

A 1,600-second fixture produced 318 kg of harvest, extracted 640 litres of crude, refined 590 litres, delivered 252 litres of fuels, completed 142 deliveries and 648 tasks, and preserved all 246,200 starting credits. A separate **5,200 simulated seconds** fixture crossed lunar darkness, battery exhaustion and sunrise recovery while retaining valid state and conserved credits. An isolated 4,800-second electrical fixture kept all six lunar beds powered using twelve panels and an 800 kWh battery initially holding 600 kWh. With normal panel wear, minimum charge was approximately 161 kWh, daytime charging resumed, and the 800 kWh capacity was never exceeded. These are bounded simulation fixtures, not twenty-hour playtests or hardware-performance measurements.

The simulation advances at one-second fixed steps, processes at most eight per frame and bounds delayed catch-up. Rendering, collision, UI, expedition and regression checks are separate from this core test; see the [validation report](ROOTS_AND_ROCKETS_VALIDATION.md) for all 573 checks, M4 frame-time measurements and unresolved limits.
