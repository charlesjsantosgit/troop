# Playing TROOP with classmates

Use school-approved devices and networks, and play only when permitted. Managed
school computers may require an administrator to approve this unsigned preview.
Do not disable school security controls to install or connect.

## Get the same version

1. Open the [TROOP 0.8.0 download page](https://github.com/charlesjsantosgit/troop/releases/tag/v0.8.0)
   or check the [latest release](https://github.com/charlesjsantosgit/troop/releases/latest).
2. Download the **Windows x86_64 Setup.exe** or **macOS universal.dmg** for your
   computer. The content `.pck` is for the updater, not a standalone game.
3. **Install the full 0.8.0 package**, including when upgrading from 0.7.1.
   This update changes the multiplayer city service protocol to 15.
   Close every running copy before installing. On a Mac, replace TROOP.app in
   Applications and launch that copy. Windows Setup installs for your user.
   Existing saves are preserved.
4. Check that the installed game's menu shows **0.8.0**. Installing a new copy
   does not update a different old copy left in Downloads or another folder;
   launch the updated installation when joining friends.

The server and all classmates must run **0.8.0**. Older clients cannot join the
0.8.0 server. This release uses multiplayer protocol **15**.

No Godot installation, GitHub account, home server, or router port forwarding is
needed. Windows on ARM, Chromebooks, browsers, and phones are not verified targets.
The macOS build includes Apple Silicon and Intel executables.

## Join and talk

- **PLAY ONLINE · SHARED TOWNS** brings Roots & Rockets to the shared world.
  Explore three Earth towns and three Moon towns. Press **E** beside a person
  or workplace; press **B → Tutorial** for guided lessons. One player can claim
  each town, and every visitor can still trade and do their own requests.
  Existing offline careers remain separate and do not import their wallets.
- Choose a recognizable player name, then **PLAY ONLINE**. Everyone joins the
  same public world at `troop-public-canopy.fly.dev`; it is not a private class room.
- The loading screen shows the current setup stage. **CANCEL CONNECTION** or
  **Esc** safely returns to the menu if you need to retry. Startup improvements
  inherited from 0.4.10 shortened fresh-cache startup in local M4 Mac testing;
  M1/Tahoe has not been directly tested. A smaller startup/menu hitch and
  first-use gameplay shader pauses remain; this is not hitch-free on every Mac.
- The dedicated server has a **24-player connection limit**. That is a configured
  cap, not a guarantee of performance with 24 players on every device or network.
- Hold **T** to speak to nearby players; release it to stop. Voice is proximity
  chat, so move closer if a distant classmate cannot hear you. Microphone access
  is optional, and voice volume/key binding can be changed in Settings.
- Press **Enter** for text chat and **Esc** for controls/settings or to leave.
- Begin near the spawn area and test movement, chat, and voice with one friend
  before organizing a larger group. Rocket expeditions have four passenger seats.
- Shared society claims, player bags, wallets, crops and delivery progress are
  stored on the server and survive reconnects and deployments. Keep the same
  installation identity to keep your ownership. The older expedition-colony
  side activity retains its separate session-only online rules.


## If actions feel delayed

- Look at **Ping** beside FPS. Higher ping means requests take longer to make a
  round trip to the server. **Unstable** means timing varies substantially or
  reliable packets are being lost. Pause shows the connection details.
- If ping stays low but animation looks choppy, lower graphics settings and
  compare FPS. The network and rendering readouts measure different things.
- Compare the same action on another permitted network. A large improvement
  there points toward the original connection; the readout alone cannot prove
  that school Wi-Fi is the cause.
- Press E once for a vehicle and wait for its boarding notice. Walking away
  cancels your interest; a delayed reply will not pull you back into that seat.

## If someone cannot connect

- Check the menu version first. An update-required message means the client and
  server differ in game version or protocol. Apply the offered update and
  confirm **0.8.0**. This release requires the full installer; restarting an old
  content pack does not activate its new multiplayer configuration.
- The game needs outbound **UDP 30623**. Some school networks block game traffic;
  a successful browser download does not prove that multiplayer is allowed.
- Ask school IT whether the game, its public host, and that outbound port are
  permitted. If they are blocked, use offline play or an approved network instead
  of bypassing the restriction.
- School-managed device policies may also block unsigned installers or microphone
  access. Ask the administrator rather than changing security settings yourself.
- A server deployment restarts the shared session. Reopen the menu and reconnect
  after the deployment completes; transient match state may reset.

## Updates

TROOP verifies its update manifest with an embedded public signing key and checks
downloaded file sizes and SHA-256 hashes. Compatible content updates download in
the background and apply on a safe menu restart or the next launch. Engine,
bootstrap, or non-version project-setting changes instead ask you to open a full installer.
The game's cryptographic update signature is separate from operating-system
publisher signing: current Windows installers are unsigned and Mac previews are
ad-hoc signed, so first-install approval may still be required.

Press **I** for your backpack. At a merchant, press **E**, select a stock or backpack tile, choose a quantity, then **Buy** or **Sell**. The two grids show the same finite inventory used for planting and jobs. Personal pockets remain available in the backpack; Earth and Moon town supplies move through the cargo terminal.

## Crownreach housing and jobs

In the village, open **B → Places → Crownreach → Find transit** and follow the gold marker. Press **E** at the stop; a ticket costs **6 credits**. Choose **Lantern Square** or a district/workplace. In Crownreach, **B** opens the city guide.

Press **E** at an entrance to inspect its property or jobs. A cottage costs **450 credits**. After buying, enter and use **E** at its cupboard for real backpack storage or at the bed to set your respawn home. Courier work starts at **Westgate Courier Depot**; a sealed parcel uses a separate job slot. Follow its destination, wait for the work timer and finish at the matching workplace to earn wages.

Crownreach covers about 205 square miles. Its 400,000 residents are represented by district simulation with a bounded nearby crowd. Individual players own properties; claiming an existing town does not transfer ownership of the entire city.
