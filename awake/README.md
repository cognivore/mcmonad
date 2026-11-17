# awake

*AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).*

Close the lid, put the Mac in a bag, and everything keeps running, locked and
dark, until a time limit, a battery floor or the heat ends it. Then the Mac
goes to sleep.

awake ships inside mcmonad: both programs below are in
`MCMonadCore.app/Contents/Helpers`, the mcmonad menu has *Keep awake*, and
the guard's approval is one of mcmonad's permissions (see mcmonad's README).

## Using it

From mcmonad's menu (*Keep awake ▸ 30 minutes …*), or from a terminal:

```sh
awake 60              # keep awake 60 minutes; ends early at 20% battery
awake 90 --floor 30   # end early at 30%
awake check           # what it sees of the Mac and what a session would do
awake stop            # end the running session; the Mac is not put to sleep
```

A session locks the screen with macOS's own Lock Screen (a password is
needed at once, whatever the screen-saver delay) and turns the display off.
A session whose lock does not take within five seconds does not start.
While it runs, every five seconds:

- time up, battery at the floor (on battery), or the Mac running hot
  (thermal pressure serious or worse) ends it and puts the Mac to sleep;
- with the lid closed, the screen is locked again and the display turned
  off again if either changed;
- with the lid open, nothing is forced: you are at the Mac.

Ctrl-C, `awake stop`, *Stop* in the menu, or mcmonad going away ends it
early: normal sleep comes back and the Mac is not put to sleep (unless the
lid is closed, below).

## How it is built

| Part | What it does |
| --- | --- |
| `core/` | Every decision, in pure Rust (`no_std`), with tests |
| `native/` | `awake`, which runs a session in the foreground, and `awake-guard`; they read the Mac (`pmset`, `ioreg`, CoreGraphics, the thermal-pressure notification) and carry out the core's answers |

Only root can disable sleep, so the guard does it, and it follows one rule:
sleep is disabled exactly while a live `awake` (the one beside the guard)
holds an unexpired lease (`/Users/Shared/de.memorici.awake/lease`). If the
session ends, crashes or is killed, the guard restores normal sleep within
two seconds, and puts the Mac to sleep if the lid is closed. It never undoes
a setting it did not make. mcmonad-core registers the guard with
SMAppService; until you allow MCMonadCore under *System Settings → General →
Login Items & Extensions*, a session ends after fifteen seconds and says why.
The guard's log is `/var/log/mcmonad-awake-guard.log`; sessions log to
`~/Library/Logs/awake.log`.

`awake --json` prints one line per change for mcmonad (protocol 1,
`awake_core::Report`) and also ends when its stdin closes, so a session
never outlives the mcmonad-core that started it.

## Building

mcmonad's flake builds it (`nix build .#awake`). For work on it alone:

```sh
nix shell --inputs-from .. nixpkgs#cargo nixpkgs#rustc nixpkgs#clippy
cargo test && cargo clippy --all-targets -- -D warnings
```
