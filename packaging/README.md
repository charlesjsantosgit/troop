# TROOP releases and signed updates

TROOP has two update paths:

- Ordinary scripts, scenes, shaders, and generated game content ship as
  `TROOP-<version>-content.pck`. The first `Updater` autoload verifies the
  release signature, expected size, and SHA-256 digest before mounting it in
  `_init()`, before any other autoload or scene. A staged pack that does not
  survive the next boot's stability checkpoint is rolled back automatically.
- Godot engine, updater-bootstrap, native-library, signing, icon, or
  `project.godot` changes require the full Windows installer or macOS disk
  image. A full installer is also the recovery path if a content update cannot
  load.

The full PCK is currently about half a megabyte, so releases intentionally use
one complete latest pack instead of a chain of delta patches. The builder also
proves that the Windows and macOS PCKs are byte-identical before publishing that
cross-platform asset.

## Release assets

Every stable GitHub release contains:

- `TROOP-<version>-Windows-x86_64-Setup.exe`
- `TROOP-<version>-macOS-universal.dmg`
- `TROOP-<version>-content.pck`
- `TROOP-<version>-SHA256SUMS.txt`
- `TROOP-update.json`

`TROOP-update.json` deliberately keeps the same name in every release, so a
client can use GitHub's public
`/releases/latest/download/TROOP-update.json` URL without an API token or API
rate-limit dependency. Its outer JSON contains the exact manifest bytes and an
RSA-4096/SHA-256 signature. The signed payload pins the repository, tag,
version, channel, Godot compatibility, minimum updater bootstrap, multiplayer
protocol, release URL, and the exact name, URL, size, and hash of all three
executable/content assets.

The public key is checked in at `packaging/update_public_key.pem` and embedded
in `scripts/updater.gd`. The private key must never enter this repository or a
game package.

## One-time GitHub setup

This directory did not originally have Git metadata or a remote. Create or
choose the GitHub repository before the first public release. Release downloads
must be public; if the source should stay private, use a separate public
release-only repository because the installed game must never contain a GitHub
personal access token.

1. Initialize/push the repository and enable GitHub Actions.
2. In repository Settings, enable release immutability. The workflow creates a
   draft, uploads every asset, then publishes it, which is compatible with
   immutable releases.
3. Create a protected GitHub Actions environment named `release`.
4. Add its secret `UPDATE_SIGNING_KEY_B64`. On this development Mac, the
   generated private key is stored with mode `0600` at
   `/Users/charlessantos/.config/troop/update-signing-private.pem`. Copy its
   single-line base64 representation into the secret without committing it.
5. Keep an offline encrypted backup. Losing the key means installed bootstrap
   versions cannot trust future PCK updates. A key rotation must be authorized
   by a release signed with the current key or delivered in a full installer.
6. Add the Actions variable `TROOP_PUBLIC_SERVER_HOST` with the deployed public
   hostname, for example `your-fly-app.fly.dev` (no scheme or port). The release
   workflow validates and embeds it so **PLAY ONLINE** works in player builds.

The workflow injects GitHub's trusted `GITHUB_REPOSITORY` value into
`application/config/update_repository` immediately before export. Source and
editor builds keep that setting empty, so they do not phone home. Automatic
checks also stay disabled in the editor and in headless test runs. Exported
games check shortly after startup and every six hours while they remain open.
The workflow checks the Godot editor and template downloads against the
SHA-256 digests in Godot's official GitHub release metadata before running
either one.

## Publishing a release

1. Set `application/config/version` in `project.godot` to the new numeric
   version (`major.minor.patch`, with an optional fourth numeric component).
2. Review `packaging/release_metadata.json`:
   - increment `network_protocol` when multiplayer wire compatibility breaks;
     keep `application/config/network_protocol` in `project.godot` equal to it;
   - set `requires_installer` to `true` for engine, updater bootstrap, native
     library, or non-version `project.godot` changes;
   - update the short player-facing `notes`;
   - raise `minimum_bootstrap` only when old bootstraps must not load the PCK.
3. Run the updater test and the ordinary game tests.
4. Commit, create the matching `v<version>` tag, and push the tag. The release
   workflow validates that the tag and `project.godot` version match.

The first build that contains this updater must be installed manually because
older builds have no trusted public key or bootstrap. After that, compatible
PCK releases download automatically and activate on the next launch. Version
0.2.0 therefore ships with `requires_installer=true`; change it to `false` only
for a later release whose changes are genuinely safe to load as a content PCK.

## Local build and manifest

Install Godot 4.7 stable and matching Windows x86_64/macOS templates. Install
NSIS on the Mac with `brew install nsis`, then run:

```bash
./packaging/build_installers.sh
```

The builder refuses to overwrite any existing versioned output. It imports
resources, runs the source smoke test, exports both platforms, validates the PE
files and macOS code signature, smoke-tests the exported Mac app, validates the
DMG, compares the platform PCKs, and writes checksums.

To make and independently verify a local signed envelope after the artifacts
exist:

```bash
python3 packaging/make_update_manifest.py \
  --version 0.2.0 \
  --repository OWNER/REPOSITORY \
  --private-key /Users/charlessantos/.config/troop/update-signing-private.pem

python3 packaging/verify_update_manifest.py \
  --envelope dist/TROOP-update.json \
  --public-key packaging/update_public_key.pem \
  --dist dist \
  --repository OWNER/REPOSITORY
```

Run the offline in-engine signature, tamper, version, size, and hash tests with:

```bash
godot --headless --path . --script res://tests/updatetest.gd
```

## Trust and installer caveat

The signed update manifest prevents a changed GitHub response, mirror, CDN, or
local staged PCK from silently becoming executable game code. The updater only
loads an exact version-derived path under `user://updates`; it never scans for
arbitrary PCK files. It remembers the highest signed version it has seen to
reject a replayed downgrade and re-verifies the signed receipt and pack on
every boot.

This does not replace operating-system code signing. The checked-in presets
contain no credentials: Windows game/installer outputs remain unsigned and the
Mac app uses Godot's ad-hoc signature. Preview users will still see SmartScreen
or Gatekeeper warnings on the first full install. A public warning-free release
must Authenticode-sign and timestamp both `TROOP.exe` and Setup, and must use a
Developer ID Application identity, hardened runtime, Apple notarization, and a
stapled ticket for macOS. Store those credentials only in protected CI secret
storage. PCK-only updates avoid repeating an installer warning, but they do not
make an unsigned base executable equivalent to a properly signed one.

GitHub release immutability and Actions attestations provide useful additional
provenance. The installed client still relies on the embedded RSA key because
it can verify that trust chain offline without shipping GitHub credentials.
