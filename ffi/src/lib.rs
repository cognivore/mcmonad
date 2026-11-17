//! The boundary between awake's Rust and its Swift menu-bar host, and the
//! native interpreter of the effects Rust owns.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! Swift implements [`Mac`]: it observes the machine (battery, heat, lid,
//! display, lock) and renders [`MenuState`]s. Rust owns everything else: the
//! session loop and its clock, the lease the guard reads, locking (with
//! macOS's own Lock Screen), turning the display off, reading `pmset`,
//! and the one log. Every decision is `awake_core`'s.

use std::fmt::Debug;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use awake_core::{EndReason, Lease, Observation, Session, Thermal, Tick, Want};
use tokio::runtime::{Builder, Runtime};
use tokio::task::JoinHandle;

uniffi::setup_scaffolding!();

static RT: LazyLock<Runtime> = LazyLock::new(|| {
    let built = Builder::new_multi_thread().worker_threads(2).thread_name("awake").enable_all().build();
    built.unwrap_or_else(|e| panic!("cannot start the runtime: {e:?}"))
});

pub const LEASE: &str = "/Users/Shared/de.memorici.awake/lease";

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThermalLevel {
    Nominal,
    Fair,
    Serious,
    Critical,
}

/// What Swift sees of the Mac.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacState {
    pub battery: Option<u8>,
    pub on_ac: bool,
    pub thermal: ThermalLevel,
    pub lid_closed: bool,
    pub display_asleep: bool,
    pub locked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum HostError {
    #[error("platform error {domain} {code}: {message}")]
    Platform { domain: String, code: i64, message: String },
    #[error("unexpected host failure: {reason}")]
    Unexpected { reason: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for HostError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Unexpected { reason: e.reason }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Phase {
    Idle,
    Running,
    Ended,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HolderView {
    pub pid: u32,
    pub process: String,
    pub what: String,
}

/// Everything the menu shows, already worded.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MenuState {
    pub phase: Phase,
    pub line: String,
    pub warning: Option<String>,
    pub holders: Vec<HolderView>,
}

/// Swift's half: observe the Mac, show a view.
#[uniffi::export(foreign)]
#[async_trait::async_trait]
pub trait Mac: Send + Sync {
    async fn observe(&self) -> Result<MacState, HostError>;
    fn render(&self, view: MenuState);
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AwakeError {
    #[error("{reason} (incident {incident})")]
    Refused { reason: String, incident: String },
    #[error("could not look at the Mac (incident {incident})")]
    Host { cause: HostError, incident: String },
    #[error("{what} failed: {reason} (incident {incident})")]
    Effect { what: String, reason: String, incident: String },
    #[error("internal defect (incident {incident})")]
    Defect { incident: String },
}

/// The effects Rust carries out. One native interpreter, one in tests.
pub trait Effects: Send + Sync + 'static {
    fn now(&self) -> u64;
    fn lock(&self) -> Result<(), String>;
    fn display_off(&self) -> Result<(), String>;
    /// Write the lease, or remove it with `None`.
    fn lease(&self, lease: Option<Lease>) -> Result<(), String>;
    fn sleep_disabled(&self) -> Result<bool, String>;
    fn assertions(&self) -> Result<String, String>;
    fn log(&self, line: &str);
}

struct Native {
    log: PathBuf,
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

/// The Lock Screen that the Apple menu and Ctrl-Cmd-Q use. It locks at once,
/// whatever the "Require password after screen saver" delay, and needs no
/// Accessibility. The screen saver tried before only locked after that delay,
/// so a nudged mouse dismissed it. The function is private to macOS, so it is
/// looked up when called and its absence is an error, never a silent no-op.
fn lock_screen() -> Result<(), String> {
    use std::ffi::{c_char, c_int, c_void};
    unsafe extern "C" {
        fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
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

impl Effects for Native {
    fn now(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
    }
    fn lock(&self) -> Result<(), String> {
        lock_screen()
    }
    fn display_off(&self) -> Result<(), String> {
        run("/usr/bin/pmset", &["displaysleepnow"]).map(drop)
    }
    fn lease(&self, lease: Option<Lease>) -> Result<(), String> {
        let path = std::path::Path::new(LEASE);
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
    fn sleep_disabled(&self) -> Result<bool, String> {
        awake_core::parse_sleep_disabled(&run("/usr/bin/pmset", &["-g"])?).ok_or_else(|| "pmset -g has no SleepDisabled".into())
    }
    fn assertions(&self) -> Result<String, String> {
        run("/usr/bin/pmset", &["-g", "assertions"])
    }
    fn log(&self, line: &str) {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.log) {
            let _ = writeln!(f, "{} {line}", self.now());
        }
    }
}

static NEXT: AtomicU64 = AtomicU64::new(1);

/// The one log. Returns the incident id.
fn record(fx: &dyn Effects, op: &str, level: &str, detail: &dyn Debug) -> String {
    let incident = format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed));
    fx.log(&format!("{level} op={op} incident={incident} detail={detail:?}"));
    incident
}

fn thermal(t: ThermalLevel) -> Thermal {
    match t {
        ThermalLevel::Nominal => Thermal::Nominal,
        ThermalLevel::Fair => Thermal::Fair,
        ThermalLevel::Serious => Thermal::Serious,
        ThermalLevel::Critical => Thermal::Critical,
    }
}

fn observation(now: u64, m: &MacState) -> Observation {
    Observation {
        now,
        battery: m.battery,
        on_ac: m.on_ac,
        thermal: thermal(m.thermal),
        lid_closed: m.lid_closed,
        display_asleep: m.display_asleep,
        locked: m.locked,
    }
}

fn holders(fx: &dyn Effects) -> Vec<HolderView> {
    let text = fx.assertions().unwrap_or_default();
    awake_core::parse_holders(&text)
        .into_iter()
        .filter(|h| h.pid != std::process::id())
        .map(|h| HolderView { pid: h.pid, process: h.process, what: format!("{} ({})", h.kind, h.name) })
        .collect()
}

/// How the loop is paced. The guard has this long to take hold.
#[derive(Clone, Copy)]
struct Pace {
    every: Duration,
    guard_grace: u32,
    lock_settle: Duration,
}

const NATIVE_PACE: Pace = Pace { every: Duration::from_secs(5), guard_grace: 3, lock_settle: Duration::from_secs(1) };

/// How many `lock_settle` waits a lock has to show up before the start fails.
const LOCK_CHECKS: u32 = 5;

#[derive(uniffi::Object)]
pub struct Awake {
    mac: Arc<dyn Mac>,
    fx: Arc<dyn Effects>,
    pace: Pace,
    running: Mutex<Option<JoinHandle<()>>>,
}

impl Awake {
    fn with(mac: Arc<dyn Mac>, fx: Arc<dyn Effects>, pace: Pace) -> Arc<Self> {
        Arc::new(Self { mac, fx, pace, running: Mutex::new(None) })
    }

    fn refused(&self, reason: String) -> AwakeError {
        let incident = record(&*self.fx, "start", "refused", &reason);
        AwakeError::Refused { reason, incident }
    }

    async fn look(&self) -> Result<Observation, AwakeError> {
        match self.mac.observe().await {
            Ok(m) => Ok(observation(self.fx.now(), &m)),
            Err(cause) => Err(AwakeError::Host { incident: record(&*self.fx, "observe", "error", &cause), cause }),
        }
    }
}

#[uniffi::export]
impl Awake {
    #[uniffi::constructor]
    pub fn new(mac: Arc<dyn Mac>) -> Arc<Self> {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        Self::with(mac, Arc::new(Native { log: home.join("Library/Logs/awake.log") }), NATIVE_PACE)
    }

    /// Start a session: lease, lock, darken, then watch every few seconds.
    pub async fn start(self: Arc<Self>, minutes: u32, floor: u8) -> Result<(), AwakeError> {
        let me = Arc::clone(&self);
        let task = RT.spawn(async move { me.start_inner(minutes, floor).await });
        match task.await {
            Ok(r) => r,
            Err(join) => Err(AwakeError::Defect { incident: record(&*self.fx, "start", "defect", &join) }),
        }
    }

    /// End the session from the menu: the Mac goes back to normal sleep, and is not put to sleep.
    pub async fn stop(&self) {
        if let Some(h) = self.running.lock().map(|mut r| r.take()).unwrap_or_default() {
            h.abort();
        }
        if let Err(e) = self.fx.lease(None) {
            record(&*self.fx, "stop", "error", &e);
        }
        record(&*self.fx, "stop", "info", &"stopped from the menu");
        self.mac.render(MenuState { phase: Phase::Idle, line: "Not running".into(), warning: None, holders: holders(&*self.fx) });
    }

    /// The idle view, with what currently holds the Mac or its display awake.
    pub async fn idle_menu(&self) -> MenuState {
        let fx = Arc::clone(&self.fx);
        let hs = RT.spawn(async move { holders(&*fx) }).await.unwrap_or_default();
        MenuState { phase: Phase::Idle, line: "Not running".into(), warning: None, holders: hs }
    }

    /// Check a request against the Mac now, without starting anything.
    pub async fn check(&self, minutes: u32, floor: u8) -> Result<String, AwakeError> {
        let o = self.look().await?;
        awake_core::start(&o, u64::from(minutes), floor)
            .map(|s| awake_core::describe(&s, &o))
            .map_err(|e| self.refused(e.to_string()))
    }
}

impl Awake {
    async fn start_inner(self: Arc<Self>, minutes: u32, floor: u8) -> Result<(), AwakeError> {
        if self.running.lock().map(|r| r.as_ref().is_some_and(|h| !h.is_finished())).unwrap_or(true) {
            return Err(self.refused("a session is already running".into()));
        }
        let o = self.look().await?;
        let session = awake_core::start(&o, u64::from(minutes), floor).map_err(|e| self.refused(e.to_string()))?;
        let lease = Lease { pid: std::process::id(), until: session.until, want: Want::Awake };
        self.fx.lease(Some(lease)).map_err(|reason| AwakeError::Effect {
            what: "writing the lease".into(),
            incident: record(&*self.fx, "start", "error", &reason),
            reason,
        })?;
        record(&*self.fx, "start", "info", &session);
        if let Err(reason) = self.lock_and_confirm().await {
            if let Err(e) = self.fx.lease(None) {
                record(&*self.fx, "start", "error", &e);
            }
            return Err(AwakeError::Effect {
                what: "locking the screen".into(),
                incident: record(&*self.fx, "lock", "error", &reason),
                reason,
            });
        }
        self.effect("display off", self.fx.display_off());
        let me = Arc::clone(&self);
        let handle = RT.spawn(async move { me.watch(session).await });
        if let Ok(mut r) = self.running.lock() {
            *r = Some(handle);
        }
        Ok(())
    }

    /// Lock, then wait until macOS reports the screen locked. A session never
    /// starts on a lock that did not take.
    async fn lock_and_confirm(&self) -> Result<(), String> {
        self.fx.lock()?;
        for _ in 0..LOCK_CHECKS {
            tokio::time::sleep(self.pace.lock_settle).await;
            if self.look().await.is_ok_and(|o| o.locked) {
                return Ok(());
            }
        }
        Err("macOS still reports the screen unlocked".into())
    }

    fn effect(&self, what: &str, r: Result<(), String>) -> Option<String> {
        r.err().map(|e| {
            record(&*self.fx, what, "error", &e);
            format!("{what} failed: {e}")
        })
    }

    async fn watch(self: Arc<Self>, session: Session) {
        let mut ticks: u32 = 0;
        let mut failures: u32 = 0;
        loop {
            tokio::time::sleep(self.pace.every).await;
            ticks += 1;
            let o = match self.look().await {
                Ok(o) => {
                    failures = 0;
                    o
                }
                Err(_) if failures < 3 => {
                    failures += 1;
                    continue;
                }
                Err(_) => return self.end(&session, "could not look at the Mac three times in a row".into(), true),
            };
            let guard_holds = self.fx.sleep_disabled().unwrap_or(false);
            if !guard_holds && ticks >= self.pace.guard_grace {
                return self.end(
                    &session,
                    "the guard is not keeping the Mac awake: allow Awake in System Settings > General > Login Items"
                        .into(),
                    false,
                );
            }
            match awake_core::tick(&session, &o) {
                Tick::End(reason) => return self.end(&session, ended(reason), true),
                Tick::Continue { lock, display_off } => {
                    let mut warning = None;
                    if lock {
                        warning = self.effect("lock", self.fx.lock());
                        if ticks > 1 {
                            warning = Some("the lid is closed but the screen did not lock".into());
                        }
                    }
                    if display_off {
                        warning = self.effect("display off", self.fx.display_off()).or(warning);
                    }
                    self.mac.render(MenuState {
                        phase: Phase::Running,
                        line: awake_core::describe(&session, &o),
                        warning,
                        holders: holders(&*self.fx),
                    });
                }
            }
        }
    }

    /// End a session: `sleep` asks the guard to restore and sleep now;
    /// otherwise the lease is removed and normal sleep returns.
    fn end(&self, session: &Session, why: String, sleep: bool) {
        let lease = sleep.then_some(Lease { pid: std::process::id(), until: session.until, want: Want::Sleep });
        if let Err(e) = self.fx.lease(lease) {
            record(&*self.fx, "end", "error", &e);
        }
        record(&*self.fx, "end", "info", &why);
        self.mac.render(MenuState { phase: Phase::Ended, line: format!("Ended: {why}"), warning: None, holders: Vec::new() });
    }
}

fn ended(r: EndReason) -> String {
    format!("{r}; the Mac goes to sleep")
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeMac {
        state: Mutex<MacState>,
        views: Mutex<Vec<MenuState>>,
    }
    #[async_trait::async_trait]
    impl Mac for FakeMac {
        async fn observe(&self) -> Result<MacState, HostError> {
            Ok(self.state.lock().map_err(|e| HostError::Unexpected { reason: e.to_string() })?.clone())
        }
        fn render(&self, view: MenuState) {
            if let Ok(mut v) = self.views.lock() {
                v.push(view);
            }
        }
    }

    #[derive(Default)]
    struct FakeFx {
        leases: Mutex<Vec<Option<Lease>>>,
        locks: AtomicU64,
        guard: std::sync::atomic::AtomicBool,
    }
    impl Effects for FakeFx {
        fn now(&self) -> u64 {
            1_000
        }
        fn lock(&self) -> Result<(), String> {
            self.locks.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        fn display_off(&self) -> Result<(), String> {
            Ok(())
        }
        fn lease(&self, lease: Option<Lease>) -> Result<(), String> {
            self.leases.lock().map_err(|e| e.to_string())?.push(lease);
            Ok(())
        }
        fn sleep_disabled(&self) -> Result<bool, String> {
            Ok(self.guard.load(Ordering::Relaxed))
        }
        fn assertions(&self) -> Result<String, String> {
            Ok(String::new())
        }
        fn log(&self, _: &str) {}
    }

    const FAST: Pace = Pace { every: Duration::from_millis(5), guard_grace: 3, lock_settle: Duration::from_millis(1) };

    fn mac(battery: u8) -> Arc<FakeMac> {
        Arc::new(FakeMac {
            state: Mutex::new(MacState {
                battery: Some(battery),
                on_ac: false,
                thermal: ThermalLevel::Nominal,
                lid_closed: true,
                display_asleep: true,
                locked: true,
            }),
            views: Mutex::new(Vec::new()),
        })
    }

    fn leases(fx: &FakeFx) -> Vec<Option<Lease>> {
        fx.leases.lock().map(|l| l.clone()).unwrap_or_default()
    }

    #[test]
    fn a_low_battery_ends_the_session_and_asks_the_guard_to_sleep() {
        let m = mac(80);
        let fx = Arc::new(FakeFx::default());
        fx.guard.store(true, Ordering::Relaxed);
        let a = Awake::with(m.clone(), fx.clone(), FAST);
        RT.block_on(Arc::clone(&a).start(30, 20)).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(fx.locks.load(Ordering::Relaxed), 1, "locked at start");
        if let Ok(mut s) = m.state.lock() {
            s.battery = Some(19);
        }
        std::thread::sleep(Duration::from_millis(100));
        let l = leases(&fx);
        assert!(matches!(l.first(), Some(Some(Lease { want: Want::Awake, .. }))));
        assert!(matches!(l.last(), Some(Some(Lease { want: Want::Sleep, .. }))), "{l:?}");
        let views = m.views.lock().map(|v| v.clone()).unwrap_or_default();
        assert_eq!(views.last().map(|v| v.phase), Some(Phase::Ended));
    }

    #[test]
    fn without_the_guard_the_session_ends_and_says_why() {
        let m = mac(80);
        let fx = Arc::new(FakeFx::default());
        let a = Awake::with(m.clone(), fx.clone(), FAST);
        RT.block_on(Arc::clone(&a).start(30, 20)).unwrap_or_else(|e| panic!("{e}"));
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(leases(&fx).last(), Some(&None), "lease removed, no sleep asked");
        let views = m.views.lock().map(|v| v.clone()).unwrap_or_default();
        assert!(views.last().is_some_and(|v| v.line.contains("Login Items")), "{views:?}");
    }

    #[test]
    fn a_lock_that_does_not_take_starts_nothing() {
        let m = mac(80);
        if let Ok(mut s) = m.state.lock() {
            s.locked = false;
        }
        let fx = Arc::new(FakeFx::default());
        fx.guard.store(true, Ordering::Relaxed);
        let a = Awake::with(m, fx.clone(), FAST);
        let r = RT.block_on(Arc::clone(&a).start(30, 20));
        assert!(matches!(r, Err(AwakeError::Effect { .. })), "{r:?}");
        assert_eq!(leases(&fx).last(), Some(&None), "the lease is taken back");
        let again = RT.block_on(Arc::clone(&a).start(30, 20));
        assert!(matches!(again, Err(AwakeError::Effect { .. })), "no session is left running: {again:?}");
    }

    #[test]
    fn refuses_below_the_floor_and_a_second_session() {
        let fx = Arc::new(FakeFx::default());
        fx.guard.store(true, Ordering::Relaxed);
        let low = Awake::with(mac(10), fx.clone(), FAST);
        assert!(matches!(RT.block_on(Arc::clone(&low).start(30, 20)), Err(AwakeError::Refused { .. })));
        assert!(leases(&fx).is_empty(), "nothing written for a refused start");
        let a = Awake::with(mac(80), fx.clone(), FAST);
        RT.block_on(Arc::clone(&a).start(30, 20)).unwrap_or_else(|e| panic!("{e}"));
        assert!(matches!(RT.block_on(Arc::clone(&a).start(30, 20)), Err(AwakeError::Refused { .. })));
        RT.block_on(a.stop());
        assert_eq!(leases(&fx).last(), Some(&None));
    }
}
