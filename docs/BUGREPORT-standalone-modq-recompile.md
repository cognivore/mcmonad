> **RESOLVED 2026-06-25** in `nix/app-bundle.nix`. The fixes described in §7/§8
> below were *authored but never actually committed* — the buggy code (undefined
> `$GHC_TOPDIR_SRC`, wrong `BUNDLED_PKGDB` depth, and a `sed -i ''''` that renders
> to broken bash) was still shipping. The real fix: (1) relocate every package
> `.conf` off `/nix/store` to `${pkgroot}`/`Frameworks` via a temp-file sed; (2)
> §4 — unversioned dev symlinks + `@rpath` install names on the bundled C libs,
> with the `mcmonad-ghc` wrapper injecting the matching `-L`/`-rpath`; (3) a loud
> build guard (grep the DB text + `ghc-pkg check`) plus an end-to-end verifier,
> `scripts/verify-bundle-recompile.sh`, which compiles a trial config and asserts
> the output is `/nix`-free and runs. Verified end to end. See `docs/configuring.md`.

# Bug report: standalone `.app` cannot recompile user configs (Mod-q is a silent no-op)

**Severity:** High — the headline feature ("Users write Haskell. It compiles. It
runs. `Mod-q` recompiles and restarts.") does not work on the shipped `.app`.
The failure is **silent**: the user edits `~/.config/mcmonad/mcmonad.hs`, presses
`Mod-q`, and nothing changes — the launcher quietly keeps running the bundled
default config.

**Affected:** Anyone running the standalone `MCMonad.app` bundle on a machine
**without the originating `/nix/store`** (i.e. the intended end-user install).
home-manager / Nix users are *not* affected, because their machine still has the
`/nix/store` paths the bundle's package DB points at — which is exactly why this
was never noticed in development.

**Found on:** `MCMonad.app` built 2026‑06‑20, GHC 9.10.3, aarch64-darwin,
running against repo `39939a4` (v0.99999999). Reported 2026‑06‑24.

---

## 1. Symptom

```
$ vim ~/.config/mcmonad/mcmonad.hs      # change layout / workspaces / keys
# press Mod-q
# ... nothing changes. Old behaviour persists. No error shown to the user.
```

`~/.config/mcmonad/` has **no** `mcmonad-aarch64-darwin` custom binary, and the
launcher log shows it running the bundled default:

```
[mcmonad-launcher] Starting mcmonad (haskell)   # = Contents/MacOS/mcmonad (default)
```

## 2. Root cause (primary): the bundled GHC's package DB points at dead `/nix/store` paths

`Mod-q` runs `$MCMONAD_GHC --make ~/.config/mcmonad/mcmonad.hs -o <custom-bin>`
(`MCMonad.Operations.recompile`). On the `.app`, `$MCMONAD_GHC` is
`Contents/MacOS/mcmonad-ghc`. That GHC **cannot compile anything that imports the
library**:

```
$ Contents/MacOS/mcmonad-ghc --make ~/.config/mcmonad/mcmonad.hs -o /tmp/x
mcmonad.hs:6:1: error: [GHC-22211]
    Could not load module ‘MCMonad’.
    There are files missing in the ‘mcmonad-0.1.0.0’ package,
    try running 'ghc-pkg check'.
```

The package DB registers `mcmonad`, `xmonad`, `xmonad-contrib`, `aeson`,
`utf8-string`, … with `import-dirs` / `library-dirs` under `/nix/store/...` that
**do not exist** on the user's machine:

```
$ Contents/GHC/bin/ghc-pkg describe mcmonad | grep -A1 import-dirs
import-dirs:
    /nix/store/87s0lh7n10fihihw07iw1xhi9zk9kca0-mcmonad-0.1.0.0/lib/ghc-9.10.3/lib/aarch64-osx-ghc-9.10.3-cb67/mcmonad-0.1.0.0-8t8mydRHJ3d9ZgbnRP0cfp
$ ls /nix/store/87s0lh7n10fihihw07iw1xhi9zk9kca0-mcmonad-0.1.0.0   # MISSING
```

The library files are *physically present in the bundle* — just registered at the
wrong path:

```
$ ls Contents/GHC/lib/aarch64-osx-ghc-9.10.3-cb67/mcmonad-0.1.0.0-*/MCMonad.hi
Contents/GHC/lib/aarch64-osx-ghc-9.10.3-cb67/mcmonad-0.1.0.0-8t8mydRHJ3d9ZgbnRP0cfp/MCMonad.hi   # EXISTS
```

### Where the bundler went wrong — `nix/app-bundle.nix`, "Bundle GHC" section

Two bugs in the package-DB rewrite made it a **silent no-op** for the add-on
packages:

1. **Undefined variable.** Step 4 read configs from
   `GWP_PKGDB="$GHC_TOPDIR_SRC/package.conf.d"`, but `$GHC_TOPDIR_SRC` was
   **never defined**, so it expanded to `/package.conf.d` — the loop matched no
   files and copied nothing.

2. **Wrong DB location.** `BUNDLED_PKGDB="$GHC_TOPDIR/lib/package.conf.d"` was one
   level too deep. `ghc --print-libdir` is `.../lib/ghc-<ver>/lib`, and the
   package DB lives *directly* inside it, so after
   `cp -rL "$GHC_LIBDIR" "$GHC_TOPDIR"` the DB is at
   **`$GHC_TOPDIR/package.conf.d`**, not `$GHC_TOPDIR/lib/package.conf.d`. The
   step-5 rewrite loop therefore iterated a non-existent directory and rewrote
   **zero** configs — every `/nix/store` path survived.

   (The `else` branch was also internally inconsistent: it copied package files
   into `$GHC_TOPDIR/lib/packages/` but rewrote the config to
   `${pkgroot}/packages/` — and `${pkgroot}` is `$GHC_TOPDIR`, so
   `${pkgroot}/packages` ≠ `$GHC_TOPDIR/lib/packages`.)

## 3. Root cause (secondary / latent): the verifier only checked dylibs, never the package DB

The bundle's own guard — *"Verifying no remaining /nix/store references in
binaries"* — runs `otool -L` over binaries and dylibs. It inspects **Mach-O load
commands only**. It never greps the **package-DB `.conf` text**, so a DB full of
dead `/nix/store` `import-dirs` passed every check and shipped. This is why the
regression was invisible.

## 4. Root cause (deeper / still open): C-library linkage for an out-of-bundle binary

Even with the package DB repointed so GHC *resolves* the Haskell packages,
**linking a user config still fails** on the standalone `.app`:

```
ld: library 'Xft' not found
clang: error: linker command failed with exit code 1
```

`xmonad-contrib` → `X11` declares C `extra-libraries` (`Xft`, `X11`, `Xinerama`,
`Xrandr`, `Xss`, `fontconfig`, `freetype`, …). Two problems:

- The bundled C dylibs in `Contents/Frameworks/` are **versioned**
  (`libXft.2.dylib`, `libgmp.10.dylib`, …). `ld -lXft` looks for
  `libXft.dylib` (unversioned) and doesn't find them.
- Their install names are `@executable_path/../Frameworks/...`, which is relative
  to the binary being run. The custom binary lives at
  `~/.config/mcmonad/mcmonad-aarch64-darwin` — **outside** the bundle — so
  `@executable_path/../Frameworks` resolves to `~/.config/Frameworks` (wrong) at
  runtime even if it did link.

So a relocated, in-bundle GHC fundamentally cannot produce a *working*
out-of-bundle binary without (a) unversioned dev symlinks for the C libs, (b) an
absolute/`@rpath` link path into the bundle's `Frameworks`, and (c) `@rpath`
install names on those dylibs.

## 5. Reproduction

```bash
# On a machine WITHOUT the build's /nix/store (or simulate by ignoring it):
cd /tmp                                  # clean cwd — see note below
/Applications/MCMonad.app/Contents/MacOS/mcmonad-ghc \
    --make ~/.config/mcmonad/mcmonad.hs -o /tmp/out
# => "Could not load module 'MCMonad'. ... files missing in the 'mcmonad-0.1.0.0' package"
```

> Note: run from a clean cwd. macOS's filesystem is case-insensitive, so running
> the compile **from inside `~/.config/mcmonad`** makes the config file
> `mcmonad.hs` shadow the library module `MCMonad` (GHC: *"File name does not
> match module name: Saw `Main`, Expected `MCMonad`"*). The daemon avoids this by
> recompiling from cwd `/`; anyone reproducing by hand should `cd /tmp` first or
> they'll chase the wrong error.

## 6. Fast diagnosis recipe (for next time)

Three commands localize this class of bug immediately:

```bash
GHC=/Applications/MCMonad.app/Contents/GHC
# (a) Does the DB resolve files in-bundle? "cannot find ..." == broken DB.
"$GHC/bin/ghc-pkg" --global-package-db "$GHC/lib/package.conf.d" check 2>&1 | grep "cannot find"
# (b) Where does it think the library lives, and does that path exist?
"$GHC/bin/ghc-pkg" --global-package-db "$GHC/lib/package.conf.d" field mcmonad import-dirs
# (c) End-to-end, from a clean cwd:
( cd /tmp && /Applications/MCMonad.app/Contents/MacOS/mcmonad-ghc --make ~/.config/mcmonad/mcmonad.hs -o /tmp/out )
```

## 7. Fix applied in this commit (`nix/app-bundle.nix`)

Rewrote the "Bundle GHC" steps 4–6:

- **Locate** the DB with `find "$GHC_TOPDIR" -maxdepth 2 -name package.conf.d`
  instead of hardcoding a depth (removes both the undefined `$GHC_TOPDIR_SRC` and
  the wrong `lib/` level).
- **Repoint** every `/nix/store` *directory* reference to where the files
  actually live in the bundle, relative to `${pkgroot}` (Haskell packages →
  their in-bundle `<platform>/<pkg-id>`, found by unique store basename; system C
  libs → `Contents/Frameworks`). No copying — `cp -rL "$GHC_LIBDIR"` already
  placed everything in-bundle.
- **Guard** with `ghc-pkg check` after recache: the build now **fails loudly** if
  any package can't resolve its `.hi`/`.a` in-bundle ("cannot find ..."). This is
  the check that was missing.

**Verification status:** `nix flake check` and `nix eval .#mcmonad-app.drvPath`
pass (the derivation evaluates). A full `nix build .#mcmonad-app` was **not** run
in the environment where this fix was authored (it needs Xcode/CLT for
`mcmonad-core`'s `swift build` + a long bundle assembly). **Before release,
rebuild and verify on a `/nix/store`-free machine:**

```bash
nix build .#mcmonad-app
# install, then from a clean cwd:
( cd /tmp && /path/to/MCMonad.app/Contents/MacOS/mcmonad-ghc --make ~/.config/mcmonad/mcmonad.hs -o /tmp/out && /tmp/out --protocol-version )
```

This fix addresses **§2 and §3** (package resolution + the missing guard). It
does **not** by itself resolve **§4** (C-library linkage for an out-of-bundle
binary) — see below.

## 8. Recommended complete fix for standalone Mod-q (§4)

**Option A — preferred, simplest, robust: don't ship a crippled relocated GHC for
recompilation.** Point `MCMONAD_GHC` at a real `ghcWithPackages`
(`packages.mcmonad-ghc`, which the flake already builds) whose dylibs have
absolute, present, correctly-named install names. A user config then links and
runs from anywhere. This is exactly what was deployed as the live workaround on
the affected machine (see `~/HOW_TO_UPDATE_MCMONAD_CONFIG.MD`) and it works:

```bash
nix build .#mcmonad-ghc --out-link ~/.config/mcmonad/.ghc-with-mcmonad   # gcroot
# set MCMONAD_GHC=~/.config/mcmonad/.ghc-with-mcmonad/bin/ghc in the launchd agent env
```

The catch: this requires Nix on the end-user machine, which defeats the
self-contained `.app` goal. For Nix users it is the clean answer. Consider having
the home-manager module set `MCMONAD_GHC` to `packages.mcmonad-ghc` explicitly
rather than relying on the bundled wrapper.

**Option B — make the bundled GHC truly self-contained.** If the `.app` must
recompile without Nix, the bundler additionally needs to, for every C
`extra-libraries` dependency pulled in by the package set:

1. create **unversioned** dev symlinks in a link dir
   (`libXft.dylib -> libXft.2.dylib`, `libgmp.dylib -> libgmp.10.dylib`, …);
2. make the `mcmonad-ghc` wrapper inject
   `-L<bundle>/Contents/Frameworks` **and**
   `-optl-Wl,-rpath,<abs path to bundle>/Contents/Frameworks`;
3. set those dylibs' install names to `@rpath/<name>` (not `@executable_path/...`)
   so an out-of-bundle custom binary can load them.

Given mcmonad is a **macOS** WM that only depends on `xmonad`/`xmonad-contrib`
for the pure `StackSet`/`LayoutClass` types and never uses X11 at runtime, a
cleaner long-term route is to drop the `X11` C-library dependency from the
recompile closure entirely (e.g. depend only on the parts of `xmonad` that don't
drag in `X11`, or vendor the needed pure modules). That removes the whole
`Xft`/`X11` link problem at the source.

## 9. Live workaround applied to the affected machine (for reference)

So the user could switch to their new config immediately (full detail in
`~/HOW_TO_UPDATE_MCMONAD_CONFIG.MD`):

1. `nix build .#mcmonad-ghc --out-link ~/.config/mcmonad/.ghc-with-mcmonad` (gcroot).
2. Compiled `~/.config/mcmonad/mcmonad.hs` → `mcmonad-aarch64-darwin` with that
   GHC from a clean cwd; stamped `.proto` = 7 (matches the bundle).
3. Added `MCMONAD_GHC=.../.ghc-with-mcmonad/bin/ghc` to the launchd agent's
   `EnvironmentVariables` so future `Mod-q` recompiles use the working GHC.
4. Switched supervision from the GUI/LaunchServices launch to the
   `com.mcmonad.agent` launchd agent (`KeepAlive`), which re-evaluated and
   selected the custom binary.

`Mod-q` now recompiles successfully (verified: exit 0, proto 7).
