# awake

Bounded macOS lid-closed-awake mode that cleanly puts the machine back to sleep when the timer expires.

## What it does

- Disables lid-close sleep (`pmset -b disablesleep 1`)
- Blocks idle sleep (`caffeinate -s -i`)
- Locks the session (sends Ctrl+Cmd+Q — the macOS Lock Screen shortcut — via osascript) and turns off the backlight (`pmset displaysleepnow`)
- Restores defaults on exit — whether the timer expires, you Ctrl-C, or the process is killed
- After the timer expires, puts the machine to sleep (`pmset sleepnow`)

> First run only: macOS will prompt your terminal (Terminal.app / iTerm / Ghostty / …) for **Accessibility** permission so it can send the lock keystroke. Approve it in *System Settings → Privacy & Security → Accessibility*, then re-run. Without it, awake falls back to invoking the screen saver, which only locks if you have "Require password after screen saver begins" enabled.

### Why not just `pmset displaysleepnow`?

`pmset displaysleepnow` turns off the backlight; it does **not** lock the session. macOS only engages the lock after the "Require password after sleep or screen saver begins" delay (often 5s–1min), and that timer doesn't always fire when the system is being held awake by `caffeinate`. Opening the lid inside that window leaves you logged in. Ctrl+Cmd+Q locks the session immediately and unconditionally.

Useful for transferring a laptop in a backpack between buildings without losing in-flight work, or letting a long-running task finish while the machine is closed.

## Usage

```sh
sudo awake 30          # 30 minutes
sudo awake 90 --force  # > 45 min requires --force (heat risk in a closed bag)
```

Must run as root because `pmset -b disablesleep` requires it.

## Install

### As a flake package

```nix
{
  inputs.awake.url = "github:cognivore/awake";

  outputs = { nixpkgs, awake, ... }: {
    # ... use awake.packages.${system}.default
  };
}
```

### Standalone

```sh
nix run github:cognivore/awake -- 30
```

## Why this exists

`caffeinate` alone doesn't survive a lid-close — macOS overrides the assertion. `pmset disablesleep` does work, but if you forget to turn it off your laptop runs hot until reboot. `awake` ties the two together with a bounded timer and a cleanup trap, so the machine always ends up in a safe state.

## Platform

macOS only. The `pmset` and `caffeinate` invocations are Darwin-specific.

## License

MIT.
