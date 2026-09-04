# Playing TROOP with classmates

Use school-approved devices and networks, and play only when permitted. Managed
school computers may require an administrator to approve this unsigned preview.
Do not disable school security controls to install or connect.

## Get the same version

1. Open the [TROOP 0.5.0 download page](https://github.com/charlesjsantosgit/troop/releases/tag/v0.5.0)
   or check the [latest release](https://github.com/charlesjsantosgit/troop/releases/latest).
2. Download the **Windows x86_64 Setup.exe** or **macOS universal.dmg** for your
   computer. The content `.pck` is for the updater, not a standalone game.
3. If you already have **0.4.10**, apply the signed in-game update when offered
   and restart, or use the full 0.5.0 installer. **Versions older than 0.4.10
   require the full installer** to obtain updater bootstrap **3**. Close every
   running copy before installing. On a Mac, replace TROOP.app in Applications
   and launch that copy. Windows Setup installs for your user.
4. Check that the installed game's menu shows **0.5.0**. Installing a new copy
   does not update a different old copy left in Downloads or another folder;
   launch the updated installation when joining friends.

The server and all classmates must run **0.5.0**. Older clients cannot join the
0.5.0 server, even though multiplayer protocol **11** is unchanged.

No Godot installation, GitHub account, home server, or router port forwarding is
needed. Windows on ARM, Chromebooks, browsers, and phones are not verified targets.
The macOS build includes Apple Silicon and Intel executables.

## Join and talk

- **PLAY ONLINE** keeps the classic shared combat, vehicles and lunar expedition.
  The new **ROOTS & ROCKETS · LIVING SOCIETY** and **MOON EXPEDITION** menu choices
  run a separate offline career with farming, jobs, markets and industry. Those
  wallets and farms are saved locally and are not imported into public games.
  The Earth terrain and lunar visual fixes are shared by the updated modes.
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
- Public multiplayer colonies and their farm/market progress are session-only:
  disconnecting or restarting the server resets them. Solo colony saves are local
  to your computer. Do not expect an online colony to survive between school days.

## If someone cannot connect

- Check the menu version first. An update-required message means the client and
  server differ in game version or protocol. Apply the offered update and
  confirm **0.5.0**; use the full installer if the update cannot apply. If your
  installation predates 0.4.10, restarting an old content pack cannot upgrade
  its bootstrap: close TROOP and replace it with the full 0.5.0 installation.
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
