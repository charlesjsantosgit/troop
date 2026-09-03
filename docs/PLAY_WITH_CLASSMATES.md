# Playing TROOP with classmates

Use school-approved devices and networks, and play only when permitted. Managed
school computers may require an administrator to approve this unsigned preview.
Do not disable school security controls to install or connect.

## Get the same version

1. Open the [official TROOP download page](https://github.com/charlesjsantosgit/troop/releases/latest).
2. Download the **Windows x86_64 Setup.exe** or **macOS universal.dmg** for your
   computer. The content `.pck` is for the updater, not a standalone game.
3. Close any running copy of TROOP and install it. On a Mac, copy TROOP.app to
   Applications. Windows Setup installs for your user without a game server.
4. Launch the installed game and check that its menu shows **0.4.7**. Existing
   **0.4.5** installations can download this compatible update automatically and
   apply it on restart. Earlier installations need the full installer once for
   updater bootstrap 2 and multiplayer protocol 11.

The server and all classmates must run **0.4.7**. A running 0.4.5 client cannot
join the 0.4.7 server until its update activates, even though both use protocol 11.

No Godot installation, GitHub account, home server, or router port forwarding is
needed. Windows on ARM, Chromebooks, browsers, and phones are not verified targets.
The macOS build includes Apple Silicon and Intel executables.

## Join and talk

- Choose a recognizable player name, then **PLAY ONLINE**. Everyone joins the
  same public world at `troop-public-canopy.fly.dev`; it is not a private class room.
- The loading screen shows the current setup stage. **CANCEL CONNECTION** safely
  returns to the menu if you need to retry. A fresh graphics cache can still
  cause a several-second first-use shader pause; subsequent joins reuse that cache,
  although smaller single-frame hitches can still occur.
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
  server differ in game version or protocol. On 0.4.5, let the automatic update
  finish and restart; on earlier versions, install the latest official build.
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
bootstrap, or project-setting changes instead ask you to open a full installer.
The game's cryptographic update signature is separate from operating-system
publisher signing: current Windows installers are unsigned and Mac previews are
ad-hoc signed, so first-install approval may still be required.
