//! awake-guard: the one root part of awake.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! AI-assisted update (mcmonad merge: it lives in
//! MCMonadCore.app/Contents/Helpers and honours the `awake` beside it):
//! model Claude Opus 5.5 (`claude-opus-5-5`); reasoning effort unavailable
//! (not exposed by the harness).
//!
//! launchd runs it as root from inside MCMonadCore.app (an SMAppService
//! daemon that mcmonad-core registers). Every two seconds it reads the lease
//! a session writes, looks at the Mac, asks the core's `guard_step` what to
//! do, and does it: `pmset -a disablesleep 1` while a live `awake` holds an
//! unexpired lease, 0 as soon as it does not (the session ended, crashed, or
//! was killed), and `pmset sleepnow` when the session asks or when it is lost
//! with the lid closed. Only the `awake` beside this program counts. It only
//! ever undoes a setting it made itself, recorded by its marker file, which
//! also carries that knowledge across its own restarts and reboots.
//!
//! `--dry-run` prints what it would do once and changes nothing, so it can be
//! checked without root.

use std::path::{Path, PathBuf};
use std::time::Duration;
use std::{env, fs, thread};

use awake_core::{GuardPlan, GuardSight, guard_step, parse_clamshell, parse_sleep_disabled};
use awake_native::{LEASE, now, read_lease, run, runs};

const MARKER: &str = "/var/db/de.memorici.awake.owned";
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

fn main() {
    let dry = env::args().any(|a| a == "--dry-run");
    let awake = match awake_beside() {
        Ok(p) => p,
        Err(e) => {
            log(&format!("cannot find awake beside the guard: {e}"));
            std::process::exit(1);
        }
    };
    log(&format!("started; honouring {}; dry-run {dry}", awake.display()));
    loop {
        match look(&awake) {
            Ok(sight) => {
                let plan = guard_step(&sight);
                if plan != GuardPlan::default() {
                    log(&format!("saw {sight:?}; plan {plan:?}"));
                    if !dry {
                        apply(&plan);
                    }
                }
            }
            Err(e) => log(&format!("could not look: {e}")),
        }
        if dry {
            return;
        }
        thread::sleep(Duration::from_secs(2));
    }
}

/// `Contents/Helpers/awake`, beside this `Contents/Helpers/awake-guard`.
fn awake_beside() -> std::io::Result<PathBuf> {
    let me = env::current_exe()?.canonicalize()?;
    me.with_file_name("awake").canonicalize()
}

fn look(awake: &Path) -> Result<GuardSight, String> {
    let lease = read_lease();
    let holder_is_awake = lease.is_some_and(|l| runs(l.pid, awake));
    let pmset = run(PMSET, &["-g"])?;
    let sleep_disabled = parse_sleep_disabled(&pmset).ok_or("pmset -g has no SleepDisabled line")?;
    let lid_closed = parse_clamshell(&run(IOREG, &["-r", "-k", "AppleClamshellState", "-d", "1"])?).unwrap_or(false);
    Ok(GuardSight {
        now: now(),
        lease,
        holder_is_awake,
        sleep_disabled,
        owned: Path::new(MARKER).exists(),
        lid_closed,
    })
}

fn apply(plan: &GuardPlan) {
    if let Some(on) = plan.set_disabled {
        match run(PMSET, &["-a", "disablesleep", if on { "1" } else { "0" }]) {
            Ok(_) => {
                let marked = if on { fs::write(MARKER, b"awake\n") } else { fs::remove_file(MARKER).or_else(absent) };
                if let Err(e) = marked {
                    log(&format!("marker {MARKER}: {e}"));
                }
            }
            Err(e) => log(&format!("disablesleep {on}: {e}")),
        }
    }
    if plan.remove_lease
        && let Err(e) = fs::remove_file(LEASE).or_else(absent)
    {
        log(&format!("lease: {e}"));
    }
    if plan.sleep_now
        && let Err(e) = run(PMSET, &["sleepnow"])
    {
        log(&format!("sleepnow: {e}"));
    }
}

fn absent(e: std::io::Error) -> std::io::Result<()> {
    if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }
}

/// launchd sends stdout to the guard's log file.
fn log(line: &str) {
    println!("{} {line}", now());
}
