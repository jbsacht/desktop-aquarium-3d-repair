# Desktop Aquarium 3D Repair

An unofficial compatibility repair for **Desktop Aquarium 3D / Something Fishy! v1.9**
on modern macOS. It addresses the blank or white desktop rendering seen on the
tested Apple silicon Mac, and includes the rendering and fish-selection fixes
listed below.

**Bring your own original app.** This repository contains our new repair code
and local patching tools. It includes no original app executable, original
source code, fish models, textures, icons, nibs, receipts, or wallpaper photos.
There are no prebuilt app downloads. See [NOTICE.md](NOTICE.md).

## Requirements

- macOS with Apple's command-line development tools (`xcode-select --install`).
- Python 3, accessible as `python3`.
- Your own unmodified DesktopAquarium3D **v1.9** installation.
- On Apple silicon, support for running Intel apps through Rosetta.

The repaired app remains **Intel x86_64**; this is not an ARM port. The tool
accepts only the exact tested original executable fingerprint and checks each
instruction before patching. Another build, even with the same version label,
will be refused rather than patched at unverified offsets.

## Build your repaired copy

Quit the original aquarium first, then run these commands from this repository:

```sh
python3 -m unittest discover -s tests -v
python3 build.py --original '/Applications/DesktopAquarium3D.app'
```

If you renamed or moved your original app, pass its actual path to `--original`.
The default output is:

```text
build/Desktop Aquarium 3D Repaired.app
```

Open that copy in Finder. You can move it to Applications afterward. The
original app stays untouched. The builder refuses to overwrite any existing
output, stages all changes in a temporary folder, signs the new copy locally,
and verifies its signature before making the output available.

### Optional background photograph

If macOS's wallpaper URL is missing or inaccessible to the old sandboxed app,
the repair needs a fallback background. By default the builder generates a
neutral blue gradient. To use your own picture instead:

```sh
python3 build.py \
  --original '/Applications/DesktopAquarium3D.app' \
  --output "$HOME/Desktop/Desktop Aquarium 3D Repaired.app" \
  --background "$HOME/Pictures/my-wallpaper.heic"
```

The photograph is converted and bundled **only in your local generated app**.
It is not uploaded. Original and generated app bundles and image files are
excluded by `.gitignore`; do not force-add them or attach them to releases.
The runtime first tries the current wallpaper when readable, then this bundled
fallback. The fallback is a snapshot, not a link that follows future changes.

### Settings and removal

The copy uses its own bundle identifier (`local.aquarium.compatibility`), so
configure its Aquarium Options again; original preferences are not migrated.
To restore the filling animation, enable **Start Empty And Gradually Fill Water**.
Fish selection, water level, lighting, and bubbles still use the original controls.
Run one aquarium edition at a time so their desktop windows do not overlap.

To stop using the repair, quit and remove the repaired copy. The original app
has not been modified. The build retains App Sandbox and read-only access to
user-selected files. It does not change system security settings.

## Included fixes

- Reattach and update the legacy OpenGL surface when its view/window/layer changes.
- Run the coalesced display-link callback on the main thread, including setup UI.
- Request a Retina surface and scale full-window viewports to backing pixels.
- Remove the additional 15/30 FPS gate while retaining display-link pacing.
- Upload supported wallpaper backdrops at up to 4096 pixels on their longest edge.
- Replace coarse background refraction with a continuous per-pixel shader.
- Increase the ripple-light capture from 128×128 to up to 1024×1024.
- Composite the background ripple lighting without the old diagonal receiver edges.
- Remove the squeezed, upside-down photo projection on the water's top surface.
- Clip bubbles to the animated waterline while keeping whole fish visible across it.
- Fix the fish-exclusion C-string length error that could reselect Turquoise Discus.

These are the **regular aquarium repairs**. The separate experimental horror
edition and its click-to-float behavior are not part of this repository.

## Support and limits

The local development build was exercised on Apple silicon / macOS 27.0.1 in
window and desktop modes, including quit/relaunch, visible fish/bubbles,
gradual filling, and saved fish exclusions. Rendering was approximately 60 FPS
on that setup; other systems may differ. Screen-saver idle behavior, login
startup and multiple displays have not been verified.

The original engine still handles swimming. This repair does not write fish
positions or targets, and its waterline mask is not a new collision simulation.
Multi-image background folders retain the original image chooser and may use
its older image-loading path. Sandboxed access to external folders can fail
after restart; a bundled fallback is the reliable option.

Local ad hoc signing replaces the vendor signature **in the copy only**. The
copy is not notarized or distributed as an official vendor update. Do not
disable macOS protections to run this project. If macOS reports a launch issue,
include the error text in an issue, without attaching the app or its assets.

For a refused executable, report the version and SHA-256 printed by the tool.
Do not bypass the fingerprint check: the shim relies on specific runtime
layouts and draw-call sites. Technical details: [docs/repair-notes.md](docs/repair-notes.md).

## Development

```sh
make test
make check-source   # macOS SDK required; compiles no vendor code
```

Tests construct synthetic Mach-O data and cover exact edits, input immutability,
invalid patch sites, malformed headers, load-command padding, double application,
and output path protection. They contain no extracted vendor executable fixture.

The new code is MIT licensed. The original application and its assets are not
relicensed. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
