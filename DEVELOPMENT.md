# mcmonad — Development Guide

## Prerequisites

- macOS on Apple Silicon (aarch64-darwin)
- [Nix](https://nixos.org/) with flakes enabled (Determinate Nix recommended)
- [direnv](https://direnv.net/) (optional but recommended — `use flake` in `.envrc`)
- Xcode Command Line Tools (`xcode-select --install`)

## Two processes, two toolchains

mcmonad is two binaries that communicate over a Unix socket:

| Binary | Language | Toolchain source | Build tool |
|--------|----------|-----------------|------------|
| `mcmonad-core` | Swift | System (Xcode CLI Tools) | Swift Package Manager |
| `mcmonad` | Haskell | Nix (`haskellPackages`) | cabal |

### Why system Swift, not Nix Swift

nixpkgs provides Swift 5.10.1 via `swiftPackages`. This works for CLI tools
using `swiftPackages.stdenv` + `swiftpm2nix`. However:

- mcmonad-core targets **Swift 6** strict concurrency (`@MainActor`, `Sendable`,
  isolation checking). Swift 5.10 can opt in with `@_strictConcurrency` but
  this is fragile and not the same thing.
- The SkyLight/Accessibility APIs we use are tightly coupled to the macOS SDK
  version. System Swift's SDK is always correct for the running OS. Nix's
  `apple-sdk` packages lag behind.
- Every real macOS tiling WM in nixpkgs (yabai on aarch64, etc.) ships prebuilt
  binaries or uses system toolchains. This is the established pattern.

**When nixpkgs gets Swift 6** (tracked in [NixOS Discourse: Swift 6 coming
soon?](https://discourse.nixos.org/t/swift-6-coming-soon/55447)), we can switch
to a pure Nix build for mcmonad-core. The architecture is ready for it — just
change `core-package.nix` from system Swift to `swiftPackages.stdenv`.

### Why Nix Haskell, not system Haskell

The Haskell side is fully managed by Nix:

- `haskellPackages.ghcWithPackages` provides GHC + all dependencies in one
  coherent package set. No version conflicts, no `cabal update` surprises.
- `haskellPackages.xmonad` (v0.18.0) is available — our key library dependency.
- QuickCheck, aeson, network, mtl, containers — all cached on Hydra.
- No system Haskell is needed or expected.

---

## Nix flake structure

```nix
# flake.nix
{
  description = "mcmonad — mac-native tiling window manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Haskell package set with our dependencies
        hsPkgs = pkgs.haskellPackages;

        # GHC with all deps pre-wired
        ghcWithDeps = hsPkgs.ghcWithPackages (hp: [
          hp.xmonad        # StackSet and friends
          hp.aeson          # JSON IPC codec
          hp.network        # Unix socket
          hp.QuickCheck     # property tests
          hp.mtl            # ReaderT/StateT
          hp.containers     # Map, Set
          hp.bytestring     # IO
          hp.text           # Text
        ]);
      in
      {
        packages = {
          # Haskell binary (pure Nix build)
          mcmonad = hsPkgs.callCabal2nix "mcmonad" ./haskell { };

          # Swift binary (uses system Swift — impure by necessity)
          mcmonad-core = pkgs.stdenv.mkDerivation {
            pname = "mcmonad-core";
            version = "0.1.0";
            src = ./core;

            buildPhase = ''
              # Use system swift via xcrun
              xcrun swift build -c release \
                --package-path . \
                --scratch-path .build
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp .build/release/mcmonad-core $out/bin/
            '';

            # Impure: requires Xcode CLI Tools on the build machine
            __impureHostDeps = [
              "/usr/bin/xcrun"
              "/usr/bin/swift"
              "/usr/bin/swiftc"
              "/Library/Developer/CommandLineTools"
              "/Applications/Xcode.app"
            ];
          };

          default = pkgs.symlinkJoin {
            name = "mcmonad";
            paths = [
              self.packages.${system}.mcmonad
              self.packages.${system}.mcmonad-core
            ];
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            # Haskell
            ghcWithDeps
            hsPkgs.cabal-install
            hsPkgs.haskell-language-server

            # Debugging / IPC testing
            pkgs.jq
          ];

          # Swift comes from system — just make sure it's findable
          shellHook = ''
            echo "mcmonad dev shell"
            echo "  Swift:   $(swift --version 2>/dev/null | head -1 || echo 'not found — install Xcode CLI Tools')"
            echo "  GHC:     $(ghc --version)"
            echo "  cabal:   $(cabal --version | head -1)"
            echo "  xmonad:  $(ghc-pkg list xmonad | tail -1 | tr -d ' ')"
          '';
        };
      }
    ) // {
      homeManagerModules.default = import ./nix/home-manager.nix self;
    };
}
```

---

## Development workflow

### First-time setup

```bash
cd ~/Github/mcmonad

# Enter dev shell (or let direnv do it)
nix develop

# Verify toolchains
swift --version       # Should be 6.x from Xcode
ghc --version         # Should be 9.x from Nix
cabal --version       # From Nix
ghc-pkg list xmonad   # Should show xmonad-0.18.x
```

### Building mcmonad-core (Swift)

```bash
cd core/
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run tests (if any)

# Binary is at:
.build/debug/mcmonad-core      # or .build/release/mcmonad-core
```

### Building mcmonad (Haskell)

```bash
cd haskell/
cabal build                    # Build library + executable
cabal test                     # Run QuickCheck properties
cabal run mcmonad              # Run the WM

# Or via Nix (hermetic):
nix build .#mcmonad
```

### Running both together

```bash
# Terminal 1: start the Swift daemon
cd core && swift run mcmonad-core

# Terminal 2: start the Haskell brain
cd haskell && cabal run mcmonad

# Or via Nix:
nix build . && ./result/bin/mcmonad-core &
./result/bin/mcmonad
```

### Testing the IPC contract manually

```bash
# Start mcmonad-core, then connect with socat or nc:
socat - UNIX-CONNECT:~/.config/mcmonad/core.sock

# Send a command:
{"cmd":"query-windows"}
# Receive JSON response with all visible windows

{"cmd":"query-screens"}
# Receive JSON response with screen geometry
```

### Running QuickCheck properties

```bash
cd haskell/
cabal test

# Or run with more iterations:
cabal test --test-options="--quickcheck-tests=10000"
```

---

## Nix packaging for distribution

### Build both binaries

```bash
nix build .               # Builds default (both)
nix build .#mcmonad       # Haskell only
nix build .#mcmonad-core  # Swift only

ls -la result/bin/
# mcmonad        (Haskell binary)
# mcmonad-core   (Swift binary)
```

### home-manager integration

Users add to their home-manager config:

```nix
{
  imports = [ mcmonad.homeManagerModules.default ];

  services.mcmonad = {
    enable = true;
    # mcmonad-core runs as KeepAlive launchd agent
    # mcmonad runs as KeepAlive launchd agent (depends on core)
  };
}
```

Then `home-manager switch` installs both binaries and creates launchd agents.

### home-manager.nix structure

```nix
# nix/home-manager.nix
flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.mcmonad;
  pkg = flake.packages.${pkgs.stdenv.hostPlatform.system}.default;
  homeDir = config.home.homeDirectory;
in
{
  options.services.mcmonad = {
    enable = lib.mkEnableOption "mcmonad tiling window manager";
  };

  config = lib.mkIf cfg.enable {
    # Swift daemon — always running
    launchd.agents.mcmonad-core = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkg}/bin/mcmonad-core" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad-core.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad-core.log";
      };
    };

    # Haskell brain — also always running, reconnects to core
    launchd.agents.mcmonad = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkg}/bin/mcmonad" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad.log";
      };
    };
  };
}
```

---

## When nixpkgs gets Swift 6

Replace the impure `mcmonad-core` derivation with a pure build:

```nix
mcmonad-core = let
  generated = pkgs.swiftpm2nix.helpers ./core/nix;
in pkgs.swiftPackages.stdenv.mkDerivation {
  pname = "mcmonad-core";
  version = "0.1.0";
  src = ./core;
  nativeBuildInputs = [ pkgs.swiftPackages.swift pkgs.swiftPackages.swiftpm ];
  configurePhase = generated.configure;
  installPhase = ''
    binPath="$(swiftpmBinPath)"
    mkdir -p $out/bin
    cp $binPath/mcmonad-core $out/bin/
  '';
};
```

Generate the lockfiles:

```bash
cd core/
nix-shell -p swiftPackages.swift swiftPackages.swiftpm swiftpm2nix
swift package resolve
swiftpm2nix
# Generates core/nix/ directory with dependency pins
```

This gives a fully hermetic, reproducible build. Until then, the impure build
with `__impureHostDeps` is the pragmatic choice — it's what the macOS Nix
ecosystem actually does.

---

## Project structure recap

```
mcmonad/
├── CLAUDE.md                           # Architecture principles
├── PLAN.md                             # Implementation plan
├── DEVELOPMENT.md                      # This file
├── flake.nix                           # Nix flake (both toolchains)
├── flake.lock
├── .envrc                              # use flake
│
├── core/                               # mcmonad-core (Swift)
│   ├── Package.swift                   # SPM manifest
│   └── Sources/...                     # Swift source
│
├── haskell/                            # mcmonad (Haskell)
│   ├── mcmonad.cabal                   # depends on xmonad
│   ├── src/...                         # Haskell source
│   ├── app/Main.hs                     # Entry point
│   └── tests/Properties.hs            # QuickCheck
│
└── nix/
    └── home-manager.nix                # launchd agent config
```
