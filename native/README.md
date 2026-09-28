# Native backends · the same game, no wasm

SuperBox64 SpriteKit games talk to the platform through one contract: the
KitABI `env` surface (about 100 C functions for graphics, sound, input,
storage). On the web that surface is filled by the wasm-web-kit JS runtime.
It can be filled by anything else, which gives every game three shapes from
ONE source tree:

| Permutation | What runs | What fills KitABI | Ships as |
|---|---|---|---|
| 1. Web | game.wasm in the browser | runtime.js + canvas | a website |
| 2. Cartridge | game.wasm in wasmtime | `wasmtime-host.swift` | host + .wasm "ROM" |
| 3. Direct | native machine code | `sdl3-backend.swift`, linked in | one binary |

Both backends implement the KitABI surface on SDL3: a Canvas2D-compatible
matrix stack, thick polylines via `SDL_RenderGeometry`, the SFML event
vocabulary from SDL events, WAV voices mixed on one device, and the
persistence store as a file. They are Embedded Swift clean (no Swift stdlib,
no Foundation).

`wasmtime-host.swift` (permutation 2) uses the wasmtime C API to run the
game wasm as a cartridge — one host per platform plays every game built on
the framework. `sdl3-backend.swift` (permutation 3) links directly; game
source + framework modules + Box2D + this backend become a single native
executable. KitABI functions the game never calls are stubbed automatically
from the header.

## Build

Both builds use CSDL3 and CWasmtime module maps with **relative header
paths** (`SDL3/SDL.h`, `wasmtime.h`) — the build scripts pass `-I` flags
to find system-installed headers. On macOS the scripts detect Homebrew
paths automatically; on Linux they use `/usr/include` and `/usr/lib`.

### Permutation 2: wasmtime host

```sh
brew install sdl3 wasmtime        # macOS; apt install libSDL3-dev libwasmtime-dev on Linux
./build-wasmtime-host.sh
./asteroidz-wasmtime-host         # loads asteroidz-embedded.wasm via wasmtime
```

### Permutation 3: direct native binary

```sh
brew install sdl3                 # or use vendor/libSDL3.a for a static build
GAME_SRC=../../../Sources GAME_MAIN=path/to/native-main.sh ./build-native-game.sh
```

`build-sdl3-static.sh` builds a trimmed static SDL3 into `vendor/libSDL3.a`
(linked automatically when present — no Homebrew SDL3 dependency).

## Why both matter

Permutation 2 makes wasm files behave like game cartridges, one host per
platform plays every game ever built on the framework. Permutation 3 skips
wasm entirely for stores that want plain binaries (Steam, itch, consoles),
still from 100% common game source. The web build stays untouched either way;
the WABI header attribute only applies under `__wasm__`.

---

**AgentiLoop:** [agentiloop.ai](https://agentiloop.ai/)

Copyright © 2026 AgentiLoop.ai, a Logos InkPen LLC company. All rights reserved.
