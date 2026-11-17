//! awake-guard: the one root part of awake.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! launchd runs it as root from inside Awake.app (SMAppService daemon). Every
//! two seconds it reads the lease the app writes, looks at the Mac, asks the
//! core's `guard_step` what to do, and does it: `pmset -a disablesleep 1`
//! while a live Awake holds an unexpired lease, 0 as soon as it does not
//! (the app quit, crashed, or was killed), and `pmset sleepnow` when the
//! app asks or when a session is lost with the lid closed. It only ever
//! undoes a setting it made itself, recorded by its marker file, which also
//! carries that knowledge across its own restarts and reboots.
//!
//! `--dry-run` prints what it would do once and changes nothing, so it can be
//! checked without root.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, fs, thread};

use awake_core::{GuardPlan, GuardSight, Lease, guard_step, parse_clamshell, parse_sleep_disabled};

pub const LEASE: &str = "/Users/Shared/de.memorici.awake/lease";
const MARKER: &str = "/var/db/de.memorici.awake.owned";
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

fn main() {
    let dry = env::args().any(|a| a == "--dry-run");
    let app = match app_executable() {
        Ok(p) => p,
        Err(e) => {
            log(&format!("cannot find the app beside the guard: {e}"));
            std::process::exit(1);
        }
    };
    log(&format!("started; app {}; dry-run {dry}", app.display()));
    loop {
        match look(&app) {
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

/// `Contents/MacOS/Awake`, beside this `Contents/MacOS/awake-guard`.
fn app_executable() -> std::io::Result<PathBuf> {
    let me = env::current_exe()?.canonicalize()?;
    Ok(me.with_file_name("Awake"))
}

fn look(app: &Path) -> Result<GuardSight, String> {
    let lease = fs::read_to_string(LEASE).ok().and_then(|t| Lease::decode(&t));
    let holder_is_app = lease.is_some_and(|l| pid_path(l.pid).as_deref() == Some(app));
    let pmset = run(PMSET, &["-g"])?;
    let sleep_disabled = parse_sleep_disabled(&pmset).ok_or("pmset -g has no SleepDisabled line")?;
    let lid_closed = parse_clamshell(&run(IOREG, &["-r", "-k", "AppleClamshellState", "-d", "1"])?).unwrap_or(false);
    Ok(GuardSight {
        now: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()),
        lease,
        holder_is_app,
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

fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(program)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{program} {args:?}: {} {}", out.status, String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The executable a pid runs, if it is alive.
fn pid_path(pid: u32) -> Option<PathBuf> {
    let pid = i32::try_from(pid).ok()?;
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf is valid for its length, which is what proc_pidpath writes at most.
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    buf.truncate(n as usize);
    PathBuf::from(String::from_utf8(buf).ok()?).canonicalize().ok()
}

/// launchd sends stdout to the guard's log file.
fn log(line: &str) {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    println!("{now} {line}");
}
