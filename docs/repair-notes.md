# Implementation notes

The build tool extracts the x86_64 slice of a locally supplied original app.
Its supported SHA-256 is:

```text
c91d8a80eb75e23880da12fc2bc47c5c03efda9ff1e244ae126a8ce58500a15d
```

The original v1.9 slice is fingerprinted before any app is copied or changed.
Short expected instruction sequences at the following file offsets provide
additional checked boundaries; full original instructions/disassembly are
not distributed as a separate artifact.

| Location | Change |
| --- | --- |
| `0x14ee7` | Omit the call drawing the photo-textured top surface. |
| `0x4aaf` | Remove the additional elapsed-time frame gate. |
| `0x40d5` | Pass string length plus one to the fish-exclusion C-string conversion. |
| Mach-O header padding | Add `LC_LOAD_DYLIB` for `@executable_path/AquariumCompatibility.dylib`. |

The header edit requires empty space before the first section. It validates
command/section bounds and refuses a second patch. The library is x86_64 and
uses the system Cocoa, QuartzCore, OpenGL and CoreVideo frameworks.

## Compatibility library

The library installs Objective-C lifecycle/render hooks and dyld OpenGL
interposers. It updates the original custom NSView's drawable attachment and
moves the complete display-link callback onto the main queue. Per-view pending
callbacks are coalesced to prevent queue buildup.

The framebuffer uses the view's backing scale; the separate ripple capture
uses a power-of-two resolution that fits the drawable, capped at 1024. A GLSL
1.20 shader composites the photo refraction and original ripple-light map
before the 3D pass. A shader compile failure keeps the original backdrop path.
The standalone additive receiver is suppressed to avoid diagonal projection
boundaries. The original ripple-light projection onto fish remains.

The current fill fraction supplies the bubble scissor. The verified material
draw site temporarily lifts that mask for fish and restores it immediately.
No swim coordinates or targets are changed.

The shim reads known fields in the v1.9 scene/settings layout. The fingerprint
is therefore a compatibility requirement, not just a convenience. Supporting
another build requires reviewing its layouts and call sites; changing only
the expected hash is insufficient.

## Local artifacts

The generated app contains the user's original vendor resources because it is
a local copy of their installed app. That output is **not** repository content.
The build manifest stores the input fingerprint and whether a generated or
user-supplied fallback was used; it does not store the original app or photo path.

Keep original binaries, modified bundles, original source/decompilation dumps,
photos, receipts, and credentials out of commits, issues and releases. New
repair source, synthetic tests, documentation and patch metadata are the
intended distributable contents.
