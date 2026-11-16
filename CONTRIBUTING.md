# Contributing

Run `make test` and, on macOS, `make check-source` before submitting a change.
Use synthetic fixtures for patch tests. Test real builds locally from an app
you own; do not commit or upload the vendor app, its resources, disassembly,
receipts, user photographs, or generated repaired app bundles.

For another original build, first establish its architecture, runtime layouts
and call sites. Do not add an override that blindly accepts unknown binaries.
Document the tested OS/hardware and whether desktop mode, window mode,
relaunch, wallpaper loading and saved fish selections were exercised.

Bug reports should include the error message, app version, OS version,
architecture and the fingerprint printed by the builder. Crop any shared
screenshots to avoid exposing personal information; do not include proprietary
app assets as attachments.
