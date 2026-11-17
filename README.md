# awake

*AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).*

Close the lid, put the Mac in a bag, and everything keeps running, locked and
dark, until a time limit, a battery floor or the heat ends it. Then the Mac
goes to sleep.

## Using it

The cup in the menu bar starts and stops a session. From a terminal:

```sh
awake 60              # keep awake 60 minutes; ends early at 20% battery
awake 90 --floor 30   # end early at 30%
awake stop            # end now; the Mac is not put to sleep
```

A session locks the screen and turns the display off at once. While it
runs, every five seconds:

- time up, battery at the floor (on battery), or the Mac running hot
  (thermal state serious or worse) ends it and puts the Mac to sleep;
- with the lid closed, the screen is locked again and the display turned
  off again if either changed;
- with the lid open, nothing is forced: you are at the Mac.

The menu also lists other processes that keep the Mac or its display
awake, such as a forgotten `caffeinate -d`.

The lock is macOS's own Lock Screen, the one in the Apple menu, so it needs a
password at once whatever the screen-saver password delay is. A session
whose lock does not take within five seconds does not start. The menu warns
if the screen stays unlocked with the lid closed.

## How it is built

| Part | What it does |
| --- | --- |
| `core/` | Every decision, in pure Rust (`no_std`), with tests |
| `ffi/` | The UniFFI boundary and the session loop; runs `pmset`, writes the lease, logs to `~/Library/Logs/awake.log` |
| `guard/` | `awake-guard`, the only root part, run by launchd from inside the app |
| `host/` | The Swift menu-bar app: reads the Mac, shows the menu, registers the guard |
| `bin/awake` | The command above; it sends `awake://` requests to the app |

Only root can disable sleep, so the guard does it, and it follows one rule:
sleep is disabled exactly while a live Awake holds an unexpired lease
(`/Users/Shared/de.memorici.awake/lease`). If the app quits, crashes or is
killed, the guard restores normal sleep within two seconds, and puts the Mac
to sleep if the lid is closed. It never undoes a setting it did not make.
Its log is `/var/log/de.memorici.awake.guard.log`.

## Building

```sh
./build.sh            # test, build, sign, selftest: build/Awake.app
./build.sh --install  # and install to ~/Applications/Awake.app, then open it
```

The first time it opens, macOS asks you to allow the guard in *System
Settings → General → Login Items*. Until you do, a session ends after
fifteen seconds and says why.

Needs Xcode, Nix and a Developer ID Application identity (`SIGN_IDENTITY`).
