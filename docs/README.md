# Lordran Native documentation

The root [README](../README.md) is the player-facing entry point. It covers
requirements, packaging, controls, settings and troubleshooting. The Chinese
version is [README.zh-CN.md](../README.zh-CN.md).

## Choose a path

| If you want to... | Start here |
|---|---|
| Build and use the app | [Root README](../README.md) |
| Understand the architecture or build manually | [Development guide](development.md) |
| Extract files and bring up the host | [Porting guide](porting/README.md) |
| Inspect title-specific build and shader data | [Game profile](../dm/games/README.md) |
| Understand NVN on Metal | [Graphics guide](../dm/gfx/README.md) |
| Check validation status and unresolved issues | [Bring-up notes](../dm/games/01004AB00A260000/bringup.md) |

## Documentation layout

```text
README.md                         Player-facing English entry point
README.zh-CN.md                   Player-facing Chinese entry point
docs/
  README.md                       Documentation index
  development.md                  Architecture, builds and regression checks
  porting/
    README.md                     Porting and debugging overview
    01-extract.md                 NSP extraction and workspaces
    02-bringup.md                 Host bring-up and failure catalogue
    03-graphics.md                Shader and NVN-on-Metal investigation
    04-debugging.md               Crash, memory, rendering and device diagnostics
dm/
  games/README.md                 Title profile reference
  gfx/README.md                   Graphics implementation reference
```

The `dm/` documents stay beside the implementation they describe. The
`dm/third_party/` and `dm/ios/vphone/` READMEs document vendored components and
standalone probes; they are not part of the player or porting paths above.

## Reading order for development

1. Read the [development guide](development.md) for the build model and
   workspace variables.
2. Follow [01 — Extracting an NSP](porting/01-extract.md) to prepare the
   external game workspace.
3. Use [02 — Host bring-up](porting/02-bringup.md) for the first boot and
   [03 — Graphics](porting/03-graphics.md) for rendering issues.
4. Use [04 — Debugging recipes](porting/04-debugging.md) for crash reports,
   captures and device diagnostics.
