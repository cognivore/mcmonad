//! awake's macOS interpreter: one session, run in the foreground.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! [`run_session`] carries out what `awake_core` decides, through a [`Host`]:
//! [`Native`] on a Mac, a fake in the tests. The session writes the lease the
//! root guard reads, locks the screen and turns the display off, then looks
//! at the Mac every few seconds until time, the battery floor or the heat
//! ends it, or it is told to stop. Every reading is a mechanical one (`pmset`,
//! `ioreg`, CoreGraphics, the thermal-pressure notification); every decision
//! is the core's.

use std::ffi::{c_char, c_int, c_void};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use awake_core::{EndReason, Holder, Lease, Observation, Phase, Report, Session, Thermal, Tick, Want};

/// The lease a session writes and the guard reads.
pub const LEASE: &str = "/Users/Shared/de.memorici.awake/lease";
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

/// What the session sees of the Mac, apart from the clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MacState {
    pub battery: Option<u8>,
    pub on_ac: bool,
    pub thermal: Thermal,
    pub lid_closed: bool,
    pub display_asleep: bool,
    pub locked: bool,
}

/// Why a wait was cut short.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interrupt {
    /// SIGTERM, SIGINT or SIGHUP: someone asked the session to stop.
    Signal,
    /// The program that started it (mcmonad) closed its end of stdin.
    ParentGone,
}

/// Everything a session does to the world.
pub trait Host {
    fn now(&self) -> u64;
    fn observe(&self) -> Result<MacState, String>;
    fn lock(&self) -> Result<(), String>;
    fn display_off(&self) -> Result<(), String>;
    /// Write the lease, or remove it with `None`.
    fn lease(&self, lease: Option<Lease>) -> Result<(), String>;
    /// Wait until the guard has taken the lease (removed it), at most
    /// `within`. The guard acts only on a lease whose holder is alive, so a
    /// session that asks for sleep stays until it has.
    fn lease_taken(&self, within: Duration) -> bool;
    fn sleep_disabled(&self) -> Result<bool, String>;
    fn holders(&self) -> Vec<Holder>;
    /// The pid of another live session holding the lease, if there is one.
    fn other_session(&self) -> Option<u32>;
    fn log(&self, line: &str);
    /// Wait, unless interrupted.
    fn wait(&self, d: Duration) -> Result<(), Interrupt>;
    fn report(&self, r: &Report);
}

/// How the loop is paced.
#[derive(Clone, Copy, Debug)]
pub struct Pace {
    pub every: Duration,
    /// Ticks the guard has to take hold before the session gives up on it.
    pub guard_grace: u32,
    /// How long to give a lock before looking whether it took.
    pub lock_settle: Duration,
    /// How many `lock_settle` waits a lock has to show up.
    pub lock_checks: u32,
}

pub const NATIVE_PACE: Pace =
    Pace { every: Duration::from_secs(5), guard_grace: 3, lock_settle: Duration::from_secs(1), lock_checks: 5 };

/// How a session finished, for the exit status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Ended,
    Refused,
    Failed,
}

impl Outcome {
    pub fn code(self) -> i32 {
        match self {
            Self::Ended => 0,
            Self::Failed => 1,
            Self::Refused => 2,
        }
    }
}

const GUARD_MISSING: &str = "the guard is not keeping the Mac awake: allow MCMonadCore in System Settings > General > Login Items & Extensions";

/// Run one session to its end.
pub fn run_session(host: &impl Host, pace: Pace, minutes: u64, floor: u8) -> Outcome {
    let refuse = |why: String| {
        host.log(&format!("refused {why}"));
        host.report(&Report { phase: Phase::Refused, line: why, warning: None, holders: Vec::new() });
        Outcome::Refused
    };
    let fail = |why: String| {
        host.log(&format!("failed {why}"));
        host.report(&Report { phase: Phase::Failed, line: why, warning: None, holders: Vec::new() });
        Outcome::Failed
    };
    if let Some(pid) = host.other_session() {
        return refuse(format!("a session is already running (pid {pid}); `awake stop` ends it"));
    }
    let o = match host.observe() {
        Ok(m) => observation(host.now(), &m),
        Err(e) => return fail(format!("could not look at the Mac: {e}")),
    };
    let session = match awake_core::start(&o, minutes, floor) {
        Ok(s) => s,
        Err(e) => return refuse(e.to_string()),
    };
    if let Err(e) = host.lease(Some(session.lease(std::process::id(), Want::Awake, host.now()))) {
        return fail(format!("writing the lease failed: {e}"));
    }
    host.log(&format!("start {session:?}"));
    match lock_and_confirm(host, pace) {
        Ok(()) => {}
        Err(Stop::Interrupted(why)) => return stopped(host, why),
        Err(Stop::Failed(e)) => {
            take_back(host);
            return fail(format!("locking the screen failed: {e}"));
        }
    }
    let mut warning = host.display_off().err().map(|e| format!("turning the display off failed: {e}"));
    let mut last = Report { phase: Phase::Running, line: awake_core::describe(&session, &o), warning, holders: host.holders() };
    host.report(&last);
    let mut ticks: u32 = 0;
    let mut failures: u32 = 0;
    loop {
        if let Err(why) = host.wait(pace.every) {
            return stopped(host, why);
        }
        ticks += 1;
        let o = match host.observe() {
            Ok(m) => {
                failures = 0;
                observation(host.now(), &m)
            }
            Err(e) if failures < 3 => {
                failures += 1;
                host.log(&format!("observe {e}"));
                continue;
            }
            Err(_) => return end(host, &session, "could not look at the Mac three times in a row".into(), true),
        };
        // The session's own end comes first: when time is up, the guard is
        // still holding (the lease has LEASE_GRACE to run) and gets asked to
        // sleep, instead of being blamed.
        let (lock, display_off) = match awake_core::tick(&session, &o) {
            Tick::End(reason) => return end(host, &session, ended(reason), true),
            Tick::Continue { lock, display_off } => (lock, display_off),
        };
        if ticks >= pace.guard_grace && !host.sleep_disabled().unwrap_or(false) {
            return end(host, &session, GUARD_MISSING.into(), false);
        }
        warning = None;
        if lock {
            warning = match host.lock() {
                Err(e) => Some(format!("the lid is closed and locking failed: {e}")),
                // Once is a lid closed since the last look; twice is a lock that does not take.
                Ok(()) if ticks > 1 => Some("the lid is closed but the screen did not lock".into()),
                Ok(()) => None,
            };
        }
        if display_off && let Err(e) = host.display_off() {
            warning = Some(format!("turning the display off failed: {e}"));
        }
        let now = Report {
            phase: Phase::Running,
            line: awake_core::describe(&session, &o),
            warning: warning.clone(),
            holders: host.holders(),
        };
        if now != last {
            host.report(&now);
            last = now;
        }
    }
}

/// What `awake check` found: a session's plan (phase `Ready`) or why there
/// would be none (`Refused`, `Failed`), and what it saw of the Mac.
pub struct Check {
    pub report: Report,
    /// The readings, in words; none when the Mac could not be read.
    pub seen: Option<String>,
}

/// Look at the Mac and say what a session of `length` would do now,
/// changing nothing: no lease, no lock, no display change.
pub fn check(host: &impl Host, length: &str, floor: u8) -> Check {
    let answer = |phase, line: String, seen| Check { report: Report { phase, line, warning: None, holders: Vec::new() }, seen };
    let m = match host.observe() {
        Ok(m) => m,
        Err(e) => return answer(Phase::Failed, format!("could not look at the Mac: {e}"), None),
    };
    let o = observation(host.now(), &m);
    let seen = Some(format!(
        "battery {}{}, heat {:?}, lid {}, display {}, screen {}",
        m.battery.map_or_else(|| String::from("none"), |b| format!("{b}%")),
        if m.on_ac { " on power" } else { " on battery" },
        m.thermal,
        if m.lid_closed { "closed" } else { "open" },
        if m.display_asleep { "asleep" } else { "on" },
        if m.locked { "locked" } else { "unlocked" },
    ));
    if let Some(pid) = host.other_session() {
        return answer(Phase::Refused, format!("a session is already running (pid {pid}); `awake stop` ends it"), seen);
    }
    let planned = awake_core::parse_minutes(length)
        .map_err(|e| e.to_string())
        .and_then(|minutes| awake_core::start(&o, minutes, floor).map_err(|e| e.to_string()));
    match planned {
        Ok(session) => answer(Phase::Ready, awake_core::describe_plan(&session, &o), seen),
        Err(why) => answer(Phase::Refused, why, seen),
    }
}

enum Stop {
    Interrupted(Interrupt),
    Failed(String),
}

/// Lock, then wait until macOS says the screen is locked. A session never
/// goes on with a lock that did not take.
fn lock_and_confirm(host: &impl Host, pace: Pace) -> Result<(), Stop> {
    host.lock().map_err(Stop::Failed)?;
    for _ in 0..pace.lock_checks {
        host.wait(pace.lock_settle).map_err(Stop::Interrupted)?;
        if host.observe().is_ok_and(|m| m.locked) {
            return Ok(());
        }
    }
    Err(Stop::Failed("macOS still reports the screen unlocked".into()))
}

fn take_back(host: &impl Host) {
    if let Err(e) = host.lease(None) {
        host.log(&format!("lease {e}"));
    }
}

/// Stopped on request: normal sleep returns; the Mac is not put to sleep.
fn stopped(host: &impl Host, why: Interrupt) -> Outcome {
    take_back(host);
    let line = match why {
        Interrupt::Signal => "stopped; normal sleep is back",
        Interrupt::ParentGone => "mcmonad went away; normal sleep is back",
    };
    host.log(&format!("end {line}"));
    host.report(&Report { phase: Phase::Ended, line: line.into(), warning: None, holders: Vec::new() });
    Outcome::Ended
}

/// How long a session waits for the guard to act on its request to sleep.
const GUARD_ANSWER: Duration = Duration::from_secs(10);

/// End a session: `sleep` asks the guard to restore and sleep now, and
/// waits for it to; otherwise the lease is removed and normal sleep returns.
fn end(host: &impl Host, session: &Session, why: String, sleep: bool) -> Outcome {
    let mut warning = None;
    if sleep {
        let asked = host.lease(Some(session.lease(std::process::id(), Want::Sleep, host.now())));
        if let Err(e) = &asked {
            host.log(&format!("lease {e}"));
        }
        if asked.is_err() || !host.lease_taken(GUARD_ANSWER) {
            take_back(host);
            warning = Some(String::from("the guard did not answer: normal sleep is back, but the Mac was not put to sleep"));
        }
    } else {
        take_back(host);
    }
    host.log(&format!("end {why}{}", warning.as_deref().map_or_else(String::new, |w| format!(" ({w})"))));
    host.report(&Report { phase: Phase::Ended, line: why, warning, holders: Vec::new() });
    Outcome::Ended
}

fn ended(r: EndReason) -> String {
    format!("{r}; the Mac goes to sleep")
}

fn observation(now: u64, m: &MacState) -> Observation {
    Observation {
        now,
        battery: m.battery,
        on_ac: m.on_ac,
        thermal: m.thermal,
        lid_closed: m.lid_closed,
        display_asleep: m.display_asleep,
        locked: m.locked,
    }
}

// ---------------------------------------------------------------------------
// The Mac

/// Set from a signal handler or the stdin watcher; read by [`Native::wait`].
static INTERRUPT: AtomicU8 = AtomicU8::new(0);
const BY_SIGNAL: u8 = 1;
const BY_PARENT: u8 = 2;

extern "C" fn on_signal(_: c_int) {
    INTERRUPT.store(BY_SIGNAL, Ordering::SeqCst);
}

/// SIGTERM, SIGINT and SIGHUP end the session cleanly instead of killing it.
pub fn stop_on_signals() {
    for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
        unsafe { libc::signal(sig, on_signal as *const () as libc::sighandler_t) };
    }
}

/// The session ends when stdin reaches its end: mcmonad holds the other end
/// of the pipe, so it closes when mcmonad exits, however it exits.
pub fn stop_when_stdin_closes() {
    std::thread::spawn(|| {
        let mut sink = [0u8; 256];
        loop {
            // SAFETY: the buffer is valid for its length.
            let n = unsafe { libc::read(0, sink.as_mut_ptr().cast(), sink.len()) };
            if n == 0 || (n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted) {
                INTERRUPT.store(BY_PARENT, Ordering::SeqCst);
                return;
            }
        }
    });
}

/// How a session's reports are printed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Output {
    /// Words, for a person at a terminal.
    Words,
    /// One [`Report`] JSON line each, for mcmonad.
    Json,
}

pub struct Native {
    pub log: PathBuf,
    pub output: Output,
    /// This program, as the guard sees it.
    pub exe: Option<PathBuf>,
}

impl Native {
    pub fn new(output: Output) -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        Self { log: home.join("Library/Logs/awake.log"), output, exe: this_exe() }
    }
}

impl Host for Native {
    fn now(&self) -> u64 {
        now()
    }
    fn observe(&self) -> Result<MacState, String> {
        let (battery, on_ac) =
            awake_core::parse_battery(&run(PMSET, &["-g", "batt"])?).ok_or("pmset -g batt names no power source")?;
        let lid_closed =
            awake_core::parse_clamshell(&run(IOREG, &["-r", "-k", "AppleClamshellState", "-d", "1"])?).unwrap_or(false);
        Ok(MacState {
            battery,
            on_ac,
            thermal: Thermal::from_pressure_level(thermal_pressure_level()?),
            lid_closed,
            display_asleep: display_asleep(),
            locked: screen_locked()?,
        })
    }
    fn lock(&self) -> Result<(), String> {
        lock_screen()
    }
    fn display_off(&self) -> Result<(), String> {
        run(PMSET, &["displaysleepnow"]).map(drop)
    }
    fn lease(&self, lease: Option<Lease>) -> Result<(), String> {
        let path = Path::new(LEASE);
        match lease {
            None => match std::fs::remove_file(path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(format!("{LEASE}: {e}")),
                _ => Ok(()),
            },
            Some(l) => {
                let dir = path.parent().ok_or("lease has no directory")?;
                std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
                let tmp = dir.join("lease.tmp");
                std::fs::write(&tmp, l.encode()).map_err(|e| format!("{}: {e}", tmp.display()))?;
                std::fs::rename(&tmp, path).map_err(|e| format!("{LEASE}: {e}"))
            }
        }
    }
    fn lease_taken(&self, within: Duration) -> bool {
        let until = Instant::now() + within;
        while Path::new(LEASE).exists() {
            if Instant::now() >= until {
                return false;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        true
    }
    fn sleep_disabled(&self) -> Result<bool, String> {
        awake_core::parse_sleep_disabled(&run(PMSET, &["-g"])?).ok_or_else(|| "pmset -g has no SleepDisabled".into())
    }
    fn holders(&self) -> Vec<Holder> {
        let text = run(PMSET, &["-g", "assertions"]).unwrap_or_default();
        awake_core::parse_holders(&text).into_iter().filter(|h| h.pid != std::process::id()).collect()
    }
    fn other_session(&self) -> Option<u32> {
        let exe = self.exe.as_deref()?;
        let lease = read_lease()?;
        (lease.pid != std::process::id() && lease.want == Want::Awake && lease.until > now() && runs(lease.pid, exe))
            .then_some(lease.pid)
    }
    fn log(&self, line: &str) {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.log) {
            let _ = writeln!(f, "{} pid={} {line}", now(), std::process::id());
        }
    }
    fn wait(&self, d: Duration) -> Result<(), Interrupt> {
        let until = Instant::now() + d;
        loop {
            match INTERRUPT.load(Ordering::SeqCst) {
                BY_SIGNAL => return Err(Interrupt::Signal),
                BY_PARENT => return Err(Interrupt::ParentGone),
                _ => {}
            }
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(());
            }
            std::thread::sleep(left.min(Duration::from_millis(100)));
        }
    }
    fn report(&self, r: &Report) {
        let text = match self.output {
            Output::Json => r.encode(),
            Output::Words => {
                let mut s = match r.phase {
                    Phase::Ready => format!("awake: would run: {}", r.line),
                    Phase::Running => format!("awake: {}", r.line),
                    Phase::Ended => format!("awake: ended: {}", r.line),
                    Phase::Refused => format!("awake: refused: {}", r.line),
                    Phase::Failed => format!("awake: failed: {}", r.line),
                };
                if let Some(w) = &r.warning {
                    s.push_str(&format!("\nawake: warning: {w}"));
                }
                s
            }
        };
        let mut out = std::io::stdout().lock();
        if writeln!(out, "{text}").and_then(|()| out.flush()).is_err() && self.output == Output::Json {
            // Nobody reads the reports any more: mcmonad is gone.
            INTERRUPT.store(BY_PARENT, Ordering::SeqCst);
        }
    }
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// The lease, if a well-formed one is there.
pub fn read_lease() -> Option<Lease> {
    std::fs::read_to_string(LEASE).ok().and_then(|t| Lease::decode(&t))
}

/// This program's executable, resolved as `pid_path` resolves others.
pub fn this_exe() -> Option<PathBuf> {
    std::env::current_exe().ok()?.canonicalize().ok()
}

/// `pid` is alive and runs `exe`.
pub fn runs(pid: u32, exe: &Path) -> bool {
    pid_path(pid).as_deref() == Some(exe)
}

pub fn run(program: &str, args: &[&str]) -> Result<String, String> {
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
pub fn pid_path(pid: u32) -> Option<PathBuf> {
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

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGMainDisplayID() -> u32;
    fn CGDisplayIsAsleep(display: u32) -> u32;
    fn CGSessionCopyCurrentDictionary() -> *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(alloc: *const c_void, s: *const c_char, encoding: u32) -> *const c_void;
    fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFGetTypeID(cf: *const c_void) -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(b: *const c_void) -> u8;
    fn CFRelease(cf: *const c_void);
}

unsafe extern "C" {
    static kOSThermalNotificationPressureLevelName: *const c_char;
    fn notify_register_check(name: *const c_char, token: *mut c_int) -> u32;
    fn notify_get_state(token: c_int, state: *mut u64) -> u32;
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

const CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

fn display_asleep() -> bool {
    // SAFETY: plain CoreGraphics queries without arguments to keep alive.
    unsafe { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

/// `CGSSessionScreenIsLocked` in the login session's dictionary; false when
/// absent. An error when there is no login session to look at.
fn screen_locked() -> Result<bool, String> {
    // SAFETY: a Copy-rule CoreFoundation call; the dictionary is released below.
    let session = unsafe { CGSessionCopyCurrentDictionary() };
    if session.is_null() {
        return Err("no login session (CGSessionCopyCurrentDictionary is empty)".into());
    }
    // SAFETY: the name is a NUL-terminated literal; the string is released below.
    let key = unsafe { CFStringCreateWithCString(std::ptr::null(), c"CGSSessionScreenIsLocked".as_ptr(), CF_STRING_ENCODING_UTF8) };
    let locked = !key.is_null() && {
        // SAFETY: both are live CoreFoundation objects; the value is borrowed (Get rule).
        let value = unsafe { CFDictionaryGetValue(session, key) };
        // SAFETY: the value is checked to be a CFBoolean before it is read as one.
        !value.is_null() && unsafe { CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value) != 0 }
    };
    // SAFETY: each was created or copied above and is released exactly once.
    unsafe {
        if !key.is_null() {
            CFRelease(key);
        }
        CFRelease(session);
    }
    Ok(locked)
}

/// The thermal-pressure level `ProcessInfo.thermalState` is made from.
fn thermal_pressure_level() -> Result<u64, String> {
    static TOKEN: OnceLock<Result<c_int, u32>> = OnceLock::new();
    let token = *TOKEN.get_or_init(|| {
        let mut token: c_int = 0;
        // SAFETY: the name is libSystem's own constant string; the token is written once.
        let status = unsafe { notify_register_check(kOSThermalNotificationPressureLevelName, &raw mut token) };
        if status == 0 { Ok(token) } else { Err(status) }
    });
    let token = token.map_err(|s| format!("notify_register_check failed with status {s}"))?;
    let mut level: u64 = 0;
    // SAFETY: the token was registered above; the level is written once.
    let status = unsafe { notify_get_state(token, &raw mut level) };
    if status == 0 { Ok(level) } else { Err(format!("notify_get_state failed with status {status}")) }
}

/// The Lock Screen that the Apple menu and Ctrl-Cmd-Q use. It locks at once,
/// whatever the "Require password after screen saver" delay, and needs no
/// Accessibility. The function is private to macOS, so it is looked up when
/// called and its absence is an error, never a silent no-op.
fn lock_screen() -> Result<(), String> {
    const RTLD_LAZY: c_int = 1;
    // SAFETY: the path is a NUL-terminated literal.
    let login = unsafe { dlopen(c"/System/Library/PrivateFrameworks/login.framework/Versions/Current/login".as_ptr(), RTLD_LAZY) };
    if login.is_null() {
        return Err("macOS has no login.framework to lock with".into());
    }
    // SAFETY: the handle is live and the name is a NUL-terminated literal.
    let symbol = unsafe { dlsym(login, c"SACLockScreenImmediate".as_ptr()) };
    if symbol.is_null() {
        return Err("login.framework has no SACLockScreenImmediate".into());
    }
    // SAFETY: SACLockScreenImmediate is `int (void)`. Its result is not a
    // documented status, so the session checks the lock took instead.
    let lock = unsafe { std::mem::transmute::<*mut c_void, extern "C" fn() -> c_int>(symbol) };
    lock();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::AtomicBool;

    struct Fake {
        mac: Mutex<MacState>,
        /// Applied to `mac` at the given wait.
        script: Mutex<Vec<(u32, MacState)>>,
        waits: Mutex<u32>,
        clock: Mutex<u64>,
        leases: Mutex<Vec<Option<Lease>>>,
        reports: Mutex<Vec<Report>>,
        locks: Mutex<u32>,
        guard: AtomicBool,
        guard_takes_sleep: bool,
        lock_takes: bool,
        other: Option<u32>,
        interrupt_at: Option<(u32, Interrupt)>,
    }

    fn mac() -> MacState {
        MacState {
            battery: Some(80),
            on_ac: false,
            thermal: Thermal::Nominal,
            lid_closed: true,
            display_asleep: true,
            locked: false,
        }
    }

    fn fake() -> Fake {
        Fake {
            mac: Mutex::new(mac()),
            script: Mutex::new(Vec::new()),
            waits: Mutex::new(0),
            clock: Mutex::new(1_000),
            leases: Mutex::new(Vec::new()),
            reports: Mutex::new(Vec::new()),
            locks: Mutex::new(0),
            guard: AtomicBool::new(true),
            guard_takes_sleep: true,
            lock_takes: true,
            other: None,
            interrupt_at: None,
        }
    }

    impl Host for Fake {
        fn now(&self) -> u64 {
            *self.clock.lock().unwrap()
        }
        fn observe(&self) -> Result<MacState, String> {
            Ok(*self.mac.lock().unwrap())
        }
        fn lock(&self) -> Result<(), String> {
            *self.locks.lock().unwrap() += 1;
            if self.lock_takes {
                self.mac.lock().unwrap().locked = true;
            }
            Ok(())
        }
        fn display_off(&self) -> Result<(), String> {
            self.mac.lock().unwrap().display_asleep = true;
            Ok(())
        }
        fn lease(&self, lease: Option<Lease>) -> Result<(), String> {
            self.leases.lock().unwrap().push(lease);
            Ok(())
        }
        fn lease_taken(&self, _: Duration) -> bool {
            if self.guard_takes_sleep {
                self.leases.lock().unwrap().push(None); // the guard removes it
            }
            self.guard_takes_sleep
        }
        fn sleep_disabled(&self) -> Result<bool, String> {
            Ok(self.guard.load(Ordering::SeqCst))
        }
        fn holders(&self) -> Vec<Holder> {
            Vec::new()
        }
        fn other_session(&self) -> Option<u32> {
            self.other
        }
        fn log(&self, _: &str) {}
        fn wait(&self, d: Duration) -> Result<(), Interrupt> {
            let mut w = self.waits.lock().unwrap();
            *w += 1;
            *self.clock.lock().unwrap() += d.as_secs();
            if let Some((at, why)) = self.interrupt_at
                && *w >= at
            {
                return Err(why);
            }
            if let Some((_, m)) = self.script.lock().unwrap().iter().find(|(at, _)| *at == *w) {
                *self.mac.lock().unwrap() = *m;
            }
            Ok(())
        }
        fn report(&self, r: &Report) {
            self.reports.lock().unwrap().push(r.clone());
        }
    }

    impl Fake {
        fn last_report(&self) -> Report {
            self.reports.lock().unwrap().last().cloned().unwrap()
        }
        fn leases(&self) -> Vec<Option<Lease>> {
            self.leases.lock().unwrap().clone()
        }
    }

    #[test]
    fn a_low_battery_ends_the_session_and_asks_the_guard_to_sleep() {
        let f = fake();
        f.script.lock().unwrap().push((4, MacState { battery: Some(19), locked: true, ..mac() }));
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Ended);
        assert_eq!(*f.locks.lock().unwrap(), 1, "locked once at start");
        assert_asked_sleep(&f);
        let r = f.last_report();
        assert_eq!((r.phase, r.line.as_str()), (Phase::Ended, "the battery fell to 19%; the Mac goes to sleep"));
        assert_eq!(r.warning, None);
    }

    #[test]
    fn time_up_ends_it_and_sleeps() {
        let f = fake();
        assert_eq!(run_session(&f, NATIVE_PACE, 1, 20), Outcome::Ended);
        assert!(f.last_report().line.starts_with("time is up"));
        assert_asked_sleep(&f);
    }

    #[test]
    fn without_the_guard_the_session_ends_and_says_why() {
        let f = fake();
        f.guard.store(false, Ordering::SeqCst);
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Ended);
        assert_eq!(f.leases().last(), Some(&None), "lease removed, no sleep asked");
        assert!(f.last_report().line.contains("Login Items"));
    }

    #[test]
    fn a_lock_that_does_not_take_starts_nothing() {
        let f = Fake { lock_takes: false, ..fake() };
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Failed);
        assert_eq!(f.leases().last(), Some(&None), "the lease is taken back");
        let r = f.last_report();
        assert_eq!(r.phase, Phase::Failed);
        assert!(r.line.contains("unlocked"), "{r:?}");
    }

    #[test]
    fn refuses_below_the_floor_and_beside_another_session() {
        let f = fake();
        *f.mac.lock().unwrap() = MacState { battery: Some(10), ..mac() };
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Refused);
        assert!(f.leases().is_empty(), "nothing written for a refused start");
        let g = Fake { other: Some(4242), ..fake() };
        assert_eq!(run_session(&g, NATIVE_PACE, 30, 20), Outcome::Refused);
        assert!(g.last_report().line.contains("4242"));
        assert_eq!(*g.locks.lock().unwrap(), 0);
    }

    #[test]
    fn a_stop_or_a_vanished_parent_restores_sleep_without_sleeping() {
        for (why, words) in [(Interrupt::Signal, "stopped"), (Interrupt::ParentGone, "mcmonad went away")] {
            let f = Fake { interrupt_at: Some((8, why)), ..fake() };
            assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Ended);
            assert_eq!(f.leases().last(), Some(&None), "{why:?}: lease removed, no sleep asked");
            assert!(f.last_report().line.starts_with(words), "{why:?}");
        }
    }

    #[test]
    fn a_check_plans_or_refuses_in_awake_s_words_and_changes_nothing() {
        let f = fake();
        let c = check(&f, "1h30m", 20);
        assert_eq!((c.report.phase, c.report.line.as_str()), (Phase::Ready, "1:30 · 80% · floor 20%"));
        assert!(c.seen.is_some_and(|s| s.contains("lid closed")));
        let bad = check(&f, "2x", 20);
        assert_eq!(bad.report.phase, Phase::Refused);
        assert!(bad.report.line.contains("not a length of time"), "{:?}", bad.report);
        assert_eq!(check(&f, "13h", 20).report.phase, Phase::Refused, "longer than allowed");
        let busy = Fake { other: Some(4242), ..fake() };
        assert!(check(&busy, "30", 20).report.line.contains("4242"));
        assert!(f.leases().is_empty() && *f.locks.lock().unwrap() == 0, "a check writes no lease and locks nothing");
    }

    #[test]
    fn heat_ends_it() {
        let f = fake();
        f.script.lock().unwrap().push((3, MacState { thermal: Thermal::Serious, locked: true, ..mac() }));
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Ended);
        assert_eq!(f.last_report().line, "the Mac got hot (Serious); the Mac goes to sleep");
        assert_asked_sleep(&f);
    }

    /// The session wrote a sleep request that is still good, and only the
    /// guard took it away.
    fn assert_asked_sleep(f: &Fake) {
        let l = f.leases();
        assert!(matches!(l.first(), Some(Some(Lease { want: Want::Awake, .. }))), "{l:?}");
        match l[l.len() - 2] {
            Some(Lease { want: Want::Sleep, until, .. }) => assert!(until > f.now(), "an expired request: {l:?}"),
            other => panic!("no sleep request: {other:?} in {l:?}"),
        }
        assert_eq!(l.last(), Some(&None), "{l:?}");
    }

    #[test]
    fn a_sleep_request_the_guard_never_takes_is_taken_back_and_said() {
        let f = Fake { guard_takes_sleep: false, ..fake() };
        f.script.lock().unwrap().push((3, MacState { thermal: Thermal::Critical, locked: true, ..mac() }));
        assert_eq!(run_session(&f, NATIVE_PACE, 30, 20), Outcome::Ended);
        let r = f.last_report();
        assert!(r.warning.as_deref().is_some_and(|w| w.contains("not put to sleep")), "{r:?}");
        assert_eq!(f.leases().last(), Some(&None), "the session removed its own request");
    }
}
