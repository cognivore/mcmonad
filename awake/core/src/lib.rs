//! awake's pure core: every decision, no effects.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! AI-assisted update (mcmonad merge: the battery and heat readings, the
//! report lines mcmonad reads, and "session" for "app"): model Claude Opus
//! 5.5 (`claude-opus-5-5`); reasoning effort unavailable (not exposed by the
//! harness).
//!
//! Two programs live here. [`tick`] decides, from one observation of the Mac,
//! what a running session does next: go on (and lock or darken the display
//! if needed) or end. [`guard_step`] decides what the root guard does with
//! the Mac's sleep setting, from the lease a session wrote. The `awake`
//! program and the guard are interpreters: they observe, call these, and
//! carry out the answer. Parsers for the text `pmset` and `ioreg` print are
//! here too, so that what they accept is tested, and so is [`Report`], the
//! line `awake --json` prints for mcmonad.
#![cfg_attr(not(test), no_std)]
extern crate alloc;

use alloc::{format, string::String, vec::Vec};

/// macOS's thermal pressure, in `ProcessInfo.thermalState`'s words.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Thermal {
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl Thermal {
    /// From the state of the `kOSThermalNotificationPressureLevelName`
    /// notification (`OSThermalPressureLevel` on macOS: nominal 0, moderate
    /// 1, heavy 2, trapping 3, sleeping 4), mapped as `ProcessInfo` maps it.
    /// A level this does not know is taken as the worst.
    pub fn from_pressure_level(level: u64) -> Self {
        match level {
            0 => Self::Nominal,
            1 => Self::Fair,
            2 => Self::Serious,
            _ => Self::Critical,
        }
    }
}

/// One look at the Mac.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Observation {
    /// Seconds since the Unix epoch.
    pub now: u64,
    /// Charge, 0 to 100. `None` on a Mac without a battery.
    pub battery: Option<u8>,
    pub on_ac: bool,
    pub thermal: Thermal,
    pub lid_closed: bool,
    pub display_asleep: bool,
    pub locked: bool,
}

/// What the person asked for when they started.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Session {
    pub started: u64,
    /// When it ends by itself.
    pub until: u64,
    /// End when on battery at or below this charge.
    pub floor: u8,
}

/// How long a lease stays good past the moment it is about: the session
/// ends first (it looks every few seconds) and asks for sleep itself; the
/// guard's expiry is only the backstop for a session that hangs.
pub const LEASE_GRACE: u64 = 60;

impl Session {
    /// The lease this session holds, written at `now`. It outlives the
    /// session's end by [`LEASE_GRACE`], so a request to sleep made when
    /// time is up is still good when the guard reads it.
    pub fn lease(&self, pid: u32, want: Want, now: u64) -> Lease {
        Lease { pid, until: now.max(self.until) + LEASE_GRACE, want }
    }
}

/// No session is longer than this, whatever was asked.
pub const MAX_SECONDS: u64 = 12 * 60 * 60;
/// The default battery floor.
pub const DEFAULT_FLOOR: u8 = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartError {
    ZeroLength,
    TooLong { asked: u64, max: u64 },
    FloorOutOfRange(u8),
    /// The battery is already at or below the floor, on battery.
    BelowFloor { battery: u8, floor: u8 },
}

impl core::fmt::Display for StartError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::ZeroLength => f.write_str("a session needs at least one minute"),
            Self::TooLong { asked, max } => {
                write!(f, "{} minutes is longer than the {} allowed", asked / 60, max / 60)
            }
            Self::FloorOutOfRange(p) => write!(f, "a battery floor of {p}% is not between 5 and 95"),
            Self::BelowFloor { battery, floor } => {
                write!(f, "the battery is at {battery}%, already at or below the {floor}% floor")
            }
        }
    }
}

/// Check a request and make the session.
pub fn start(o: &Observation, minutes: u64, floor: u8) -> Result<Session, StartError> {
    let seconds = minutes.saturating_mul(60);
    if seconds == 0 {
        return Err(StartError::ZeroLength);
    }
    if seconds > MAX_SECONDS {
        return Err(StartError::TooLong { asked: seconds, max: MAX_SECONDS });
    }
    if !(5..=95).contains(&floor) {
        return Err(StartError::FloorOutOfRange(floor));
    }
    if let (false, Some(b)) = (o.on_ac, o.battery)
        && b <= floor
    {
        return Err(StartError::BelowFloor { battery: b, floor });
    }
    Ok(Session { started: o.now, until: o.now + seconds, floor })
}

/// Why a session ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    TimeUp,
    BatteryFloor { battery: u8 },
    Heat(Thermal),
}

impl core::fmt::Display for EndReason {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::TimeUp => f.write_str("time is up"),
            Self::BatteryFloor { battery } => write!(f, "the battery fell to {battery}%"),
            Self::Heat(t) => write!(f, "the Mac got hot ({t:?})"),
        }
    }
}

/// What a session does after one observation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tick {
    /// Go on. Lock first if asked, then darken the display if asked.
    Continue { lock: bool, display_off: bool },
    /// End, and put the Mac to sleep: it may be in a bag.
    End(EndReason),
}

/// The session's rule, applied every few seconds.
///
/// Safety first: time, battery and heat end it whatever else is true.
/// Otherwise, with the lid closed the Mac must be locked and dark; with the
/// lid open the person is at it, and nothing is forced on them.
pub fn tick(s: &Session, o: &Observation) -> Tick {
    if o.now >= s.until {
        return Tick::End(EndReason::TimeUp);
    }
    if let (false, Some(b)) = (o.on_ac, o.battery)
        && b <= s.floor
    {
        return Tick::End(EndReason::BatteryFloor { battery: b });
    }
    if o.thermal >= Thermal::Serious {
        return Tick::End(EndReason::Heat(o.thermal));
    }
    Tick::Continue {
        lock: o.lid_closed && !o.locked,
        display_off: o.lid_closed && !o.display_asleep,
    }
}

/// What a session asks of the guard, in the lease file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Want {
    /// Keep the Mac awake until `until`.
    Awake,
    /// The session ended for safety: restore, then sleep now.
    Sleep,
}

/// The lease a session writes and the guard reads: one line,
/// `awake1 <pid> <until> awake|sleep`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Lease {
    pub pid: u32,
    pub until: u64,
    pub want: Want,
}

const LEASE_TAG: &str = "awake1";

impl Lease {
    pub fn encode(&self) -> String {
        let want = match self.want {
            Want::Awake => "awake",
            Want::Sleep => "sleep",
        };
        format!("{LEASE_TAG} {} {} {want}\n", self.pid, self.until)
    }

    /// `None` for anything that is not exactly a lease of this version.
    pub fn decode(text: &str) -> Option<Self> {
        let mut parts = text.trim_end_matches('\n').split(' ');
        let (tag, pid, until, want) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        if tag != LEASE_TAG || parts.next().is_some() {
            return None;
        }
        let want = match want {
            "awake" => Want::Awake,
            "sleep" => Want::Sleep,
            _ => return None,
        };
        Some(Self { pid: pid.parse().ok()?, until: until.parse().ok()?, want })
    }
}

/// What the guard saw, apart from the clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GuardSight {
    pub now: u64,
    /// The lease, if a well-formed one is there.
    pub lease: Option<Lease>,
    /// The lease's pid is alive and runs the `awake` beside the guard.
    pub holder_is_awake: bool,
    /// `pmset -g` says SleepDisabled 1.
    pub sleep_disabled: bool,
    /// The guard set SleepDisabled itself, by its marker file. A setting
    /// someone else made is never changed.
    pub owned: bool,
    pub lid_closed: bool,
}

/// What the guard does now. Applied in field order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct GuardPlan {
    /// `pmset -a disablesleep 0|1`, and the marker written or removed.
    pub set_disabled: Option<bool>,
    pub remove_lease: bool,
    pub sleep_now: bool,
}

/// The guard's rule: SleepDisabled is 1 exactly while a live `awake` holds
/// an unexpired lease wanting it awake. Losing that restores normal sleep,
/// and sleeps at once when the session asked to, or when it was lost while
/// the lid is closed (a session that died in a bag must not leave it awake).
pub fn guard_step(g: &GuardSight) -> GuardPlan {
    let valid = g
        .lease
        .filter(|l| g.holder_is_awake && g.now < l.until && l.until <= g.now + MAX_SECONDS + 60);
    let keep_awake = matches!(valid, Some(Lease { want: Want::Awake, .. }));
    let asked_sleep = matches!(valid, Some(Lease { want: Want::Sleep, .. }));
    let mut plan = GuardPlan::default();
    if keep_awake {
        if !g.sleep_disabled || !g.owned {
            plan.set_disabled = Some(true);
        }
        return plan;
    }
    let ours = g.owned && g.sleep_disabled;
    if g.owned {
        plan.set_disabled = Some(false);
    }
    plan.remove_lease = g.lease.is_some();
    plan.sleep_now = asked_sleep || (ours && g.lid_closed);
    plan
}

/// `SleepDisabled` from `pmset -g`.
pub fn parse_sleep_disabled(pmset_g: &str) -> Option<bool> {
    pmset_g.lines().find_map(|l| {
        let mut w = l.split_whitespace();
        (w.next()? == "SleepDisabled").then(|| w.next()).flatten().map(|v| v == "1")
    })
}

/// `AppleClamshellState` from `ioreg -r -k AppleClamshellState -d 1`.
pub fn parse_clamshell(ioreg: &str) -> Option<bool> {
    ioreg.lines().find_map(|l| {
        let (_, v) = l.split_once("\"AppleClamshellState\" = ")?;
        Some(v.trim() == "Yes")
    })
}

/// The charge in percent (`None` without a battery) and whether the Mac
/// runs on mains power, from `pmset -g batt`. `None` when the text says
/// neither which source is in use nor anything about a battery.
pub fn parse_battery(pmset_batt: &str) -> Option<(Option<u8>, bool)> {
    let source = pmset_batt.lines().find_map(|l| l.split_once("Now drawing from '").map(|(_, rest)| rest))?;
    let on_ac = source.starts_with("AC Power");
    let charge = pmset_batt.lines().filter(|l| l.contains("InternalBattery")).find_map(|l| {
        let (_, rest) = l.split_once('\t')?;
        rest.split_once('%')?.0.trim().parse::<u8>().ok()
    });
    Some((charge, on_ac))
}

/// A process holding the display or the system awake, from
/// `pmset -g assertions`' "Listed by owning process" section.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Holder {
    pub pid: u32,
    pub process: String,
    pub kind: String,
    pub name: String,
}

const HELD_KINDS: [&str; 4] =
    ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "PreventSystemSleep", "PreventUserIdleSystemSleep"];

/// The holders worth showing: display and sleep prevention by processes
/// other than macOS's own power daemon.
pub fn parse_holders(assertions: &str) -> Vec<Holder> {
    let mut out: Vec<Holder> = Vec::new();
    for line in assertions.lines() {
        let Some(rest) = line.trim_start().strip_prefix("pid ") else { continue };
        let Some((pid, rest)) = rest.split_once('(') else { continue };
        let Some((process, rest)) = rest.split_once(')') else { continue };
        let Ok(pid) = pid.parse::<u32>() else { continue };
        let Some((_, rest)) = rest.split_once("] ") else { continue };
        let mut fields = rest.split_whitespace();
        let (Some(_age), Some(kind)) = (fields.next(), fields.next()) else { continue };
        if process == "powerd" || !HELD_KINDS.contains(&kind) {
            continue;
        }
        let name = rest.split_once("named: \"").and_then(|(_, n)| n.split_once('"')).map_or("", |(n, _)| n);
        let h = Holder { pid, process: process.into(), kind: kind.into(), name: name.into() };
        if !out.contains(&h) {
            out.push(h);
        }
    }
    out
}

/// The menu's one-line state.
pub fn describe(s: &Session, o: &Observation) -> String {
    let left = s.until.saturating_sub(o.now);
    let battery = match o.battery {
        Some(b) => format!("{b}%{}", if o.on_ac { " on power" } else { "" }),
        None => String::from("no battery"),
    };
    format!("{}:{:02} left · {battery} · floor {}%", left / 3600, (left % 3600) / 60, s.floor)
}

/// Where a session stands, as `awake --json` reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Keeping the Mac awake; `line` says for how long and on what charge.
    Running,
    /// Over; `line` says why and whether the Mac goes to sleep.
    Ended,
    /// Never started: the request or the Mac's state did not allow it.
    Refused,
    /// Never started: something it needed failed, such as the lock.
    Failed,
}

/// One line of `awake --json`, protocol 1, for mcmonad's menu:
/// `{"awake":1,"phase":"running","line":"…","warning":null|"…",
/// "holders":[{"pid":1,"process":"…","what":"…"}]}`. A reader refuses
/// any other `awake` version.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub phase: Phase,
    pub line: String,
    pub warning: Option<String>,
    /// Other processes keeping the Mac or its display awake.
    pub holders: Vec<Holder>,
}

/// The protocol version [`Report::encode`] writes.
pub const REPORT_PROTOCOL: u32 = 1;

impl Report {
    pub fn encode(&self) -> String {
        let phase = match self.phase {
            Phase::Running => "running",
            Phase::Ended => "ended",
            Phase::Refused => "refused",
            Phase::Failed => "failed",
        };
        let warning = self.warning.as_deref().map_or_else(|| String::from("null"), json_string);
        let holders: Vec<String> = self
            .holders
            .iter()
            .map(|h| {
                format!(
                    "{{\"pid\":{},\"process\":{},\"what\":{}}}",
                    h.pid,
                    json_string(&h.process),
                    json_string(&format!("{} ({})", h.kind, h.name))
                )
            })
            .collect();
        format!(
            "{{\"awake\":{REPORT_PROTOCOL},\"phase\":\"{phase}\",\"line\":{},\"warning\":{warning},\"holders\":[{}]}}",
            json_string(&self.line),
            holders.join(",")
        )
    }
}

/// `s` as a JSON string literal.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs() -> Observation {
        Observation {
            now: 1_000,
            battery: Some(80),
            on_ac: false,
            thermal: Thermal::Nominal,
            lid_closed: true,
            display_asleep: true,
            locked: true,
        }
    }
    fn session() -> Session {
        Session { started: 1_000, until: 1_000 + 3_600, floor: 20 }
    }

    #[test]
    fn start_refuses_what_cannot_be_safe() {
        assert_eq!(start(&obs(), 0, 20), Err(StartError::ZeroLength));
        assert!(matches!(start(&obs(), 13 * 60, 20), Err(StartError::TooLong { .. })));
        assert_eq!(start(&obs(), 60, 99), Err(StartError::FloorOutOfRange(99)));
        let low = Observation { battery: Some(15), ..obs() };
        assert_eq!(start(&low, 60, 20), Err(StartError::BelowFloor { battery: 15, floor: 20 }));
        let low_on_ac = Observation { on_ac: true, ..low };
        assert!(start(&low_on_ac, 60, 20).is_ok(), "on power the floor does not apply");
        assert_eq!(start(&obs(), 60, 20), Ok(session()));
    }

    #[test]
    fn time_battery_and_heat_end_it() {
        let s = session();
        assert_eq!(tick(&s, &Observation { now: s.until, ..obs() }), Tick::End(EndReason::TimeUp));
        assert_eq!(
            tick(&s, &Observation { battery: Some(20), ..obs() }),
            Tick::End(EndReason::BatteryFloor { battery: 20 })
        );
        assert_eq!(
            tick(&s, &Observation { battery: Some(20), on_ac: true, ..obs() }),
            Tick::Continue { lock: false, display_off: false }
        );
        assert_eq!(
            tick(&s, &Observation { thermal: Thermal::Serious, ..obs() }),
            Tick::End(EndReason::Heat(Thermal::Serious))
        );
        assert_eq!(
            tick(&s, &Observation { thermal: Thermal::Fair, ..obs() }),
            Tick::Continue { lock: false, display_off: false }
        );
    }

    #[test]
    fn closed_lid_means_locked_and_dark_open_lid_is_left_alone() {
        let s = session();
        let woke = Observation { display_asleep: false, ..obs() };
        assert_eq!(tick(&s, &woke), Tick::Continue { lock: false, display_off: true });
        let unlocked = Observation { locked: false, display_asleep: false, ..obs() };
        assert_eq!(tick(&s, &unlocked), Tick::Continue { lock: true, display_off: true });
        let at_desk = Observation { lid_closed: false, ..unlocked };
        assert_eq!(tick(&s, &at_desk), Tick::Continue { lock: false, display_off: false });
    }

    #[test]
    fn lease_round_trips_and_rejects_anything_else() {
        let l = Lease { pid: 42, until: 9_999, want: Want::Awake };
        assert_eq!(Lease::decode(&l.encode()), Some(l));
        let s = Lease { want: Want::Sleep, ..l };
        assert_eq!(Lease::decode(&s.encode()), Some(s));
        for bad in ["", "awake1 42 9999", "awake2 42 9999 awake", "awake1 x 9999 awake", "awake1 42 9999 nap", "awake1 42 9999 awake extra"] {
            assert_eq!(Lease::decode(bad), None, "{bad:?}");
        }
    }

    fn sight() -> GuardSight {
        GuardSight {
            now: 1_000,
            lease: Some(Lease { pid: 7, until: 2_000, want: Want::Awake }),
            holder_is_awake: true,
            sleep_disabled: false,
            owned: false,
            lid_closed: true,
        }
    }

    #[test]
    fn guard_keeps_awake_only_for_a_live_app_with_an_unexpired_lease() {
        assert_eq!(guard_step(&sight()).set_disabled, Some(true));
        let held = GuardSight { sleep_disabled: true, owned: true, ..sight() };
        assert_eq!(guard_step(&held), GuardPlan::default(), "already right: nothing to do");
    }

    #[test]
    fn guard_restores_and_sleeps_when_the_app_dies_in_a_bag() {
        let dead = GuardSight { holder_is_awake: false, sleep_disabled: true, owned: true, ..sight() };
        assert_eq!(guard_step(&dead), GuardPlan { set_disabled: Some(false), remove_lease: true, sleep_now: true });
        let at_desk = GuardSight { lid_closed: false, ..dead };
        assert_eq!(
            guard_step(&at_desk),
            GuardPlan { set_disabled: Some(false), remove_lease: true, sleep_now: false }
        );
        let expired = GuardSight { now: 2_000, sleep_disabled: true, owned: true, ..sight() };
        assert_eq!(guard_step(&expired).set_disabled, Some(false));
        let far = GuardSight {
            lease: Some(Lease { pid: 7, until: 1_000 + MAX_SECONDS + 3_600, want: Want::Awake }),
            ..sight()
        };
        assert_eq!(guard_step(&far).set_disabled, None, "a lease past the cap is not honoured");
    }

    #[test]
    fn a_session_ends_before_its_lease_and_its_sleep_request_is_honoured() {
        let s = session();
        let awake = s.lease(7, Want::Awake, s.started);
        let at_end = GuardSight { now: s.until, lease: Some(awake), sleep_disabled: true, owned: true, lid_closed: false, ..sight() };
        assert_eq!(guard_step(&at_end), GuardPlan::default(), "the guard still holds when time is up");
        assert_eq!(tick(&s, &Observation { now: s.until, ..obs() }), Tick::End(EndReason::TimeUp));
        let asked = s.lease(7, Want::Sleep, s.until + 4);
        let answer = GuardSight { now: s.until + 5, lease: Some(asked), ..at_end };
        assert_eq!(guard_step(&answer), GuardPlan { set_disabled: Some(false), remove_lease: true, sleep_now: true });
        let long = Session { until: s.started + MAX_SECONDS, ..s };
        let capped = GuardSight { now: s.started, lease: Some(long.lease(7, Want::Awake, s.started)), ..sight() };
        assert_eq!(guard_step(&capped).set_disabled, Some(true), "the longest session's lease is within the cap");
    }

    #[test]
    fn guard_sleeps_when_asked_and_never_touches_a_setting_it_did_not_make() {
        let asked = GuardSight {
            lease: Some(Lease { pid: 7, until: 2_000, want: Want::Sleep }),
            sleep_disabled: true,
            owned: true,
            lid_closed: false,
            ..sight()
        };
        assert_eq!(guard_step(&asked), GuardPlan { set_disabled: Some(false), remove_lease: true, sleep_now: true });
        let theirs = GuardSight { lease: None, sleep_disabled: true, owned: false, ..sight() };
        assert_eq!(guard_step(&theirs), GuardPlan::default());
        let crashed_after_reboot = GuardSight { lease: None, sleep_disabled: true, owned: true, ..sight() };
        assert_eq!(guard_step(&crashed_after_reboot).set_disabled, Some(false));
    }

    #[test]
    fn parsers_read_what_this_mac_prints() {
        let pmset = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1\n";
        assert_eq!(parse_sleep_disabled(pmset), Some(true));
        assert_eq!(parse_sleep_disabled(" SleepDisabled\t\t0\n"), Some(false));
        assert_eq!(parse_sleep_disabled("nothing"), None);
        assert_eq!(parse_clamshell("  | \"AppleClamshellState\" = Yes\n"), Some(true));
        assert_eq!(parse_clamshell("  | \"AppleClamshellState\" = No\n"), Some(false));
        let a = "Listed by owning process:\n   pid 75127(caffeinate): [0x000064230005a15f] 134:29:04 PreventUserIdleDisplaySleep named: \"caffeinate command-line tool\"  \n\tDetails: x\n   pid 391(powerd): [0x0007] 01:49:19 PreventUserIdleSystemSleep named: \"Powerd - Prevent sleep while display is on\"  \n   pid 406(mds): [0x0] 151:45:45 BackgroundTask named: \"com.apple.metadata.mds.power\"  \n";
        assert_eq!(
            parse_holders(a),
            [Holder {
                pid: 75127,
                process: "caffeinate".into(),
                kind: "PreventUserIdleDisplaySleep".into(),
                name: "caffeinate command-line tool".into()
            }]
        );
    }

    #[test]
    fn describes_the_session() {
        assert_eq!(describe(&session(), &obs()), "1:00 left · 80% · floor 20%");
    }

    #[test]
    fn battery_and_heat_are_read_as_this_mac_prints_them() {
        let on_battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=25624675)\t85%; discharging; 2:50 remaining present: true\n";
        assert_eq!(parse_battery(on_battery), Some((Some(85), false)));
        let on_ac = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=25624675)\t100%; charged; 0:00 remaining present: true\n";
        assert_eq!(parse_battery(on_ac), Some((Some(100), true)));
        assert_eq!(parse_battery("Now drawing from 'AC Power'\n"), Some((None, true)), "a Mac without a battery");
        assert_eq!(parse_battery(""), None);
        assert_eq!(Thermal::from_pressure_level(0), Thermal::Nominal);
        assert_eq!(Thermal::from_pressure_level(1), Thermal::Fair);
        assert_eq!(Thermal::from_pressure_level(2), Thermal::Serious);
        assert_eq!(Thermal::from_pressure_level(4), Thermal::Critical);
        assert_eq!(Thermal::from_pressure_level(77), Thermal::Critical, "unknown is the worst");
    }

    #[test]
    fn reports_are_one_line_of_escaped_json() {
        let r = Report {
            phase: Phase::Running,
            line: String::from("0:29 left · 85% · floor 20%"),
            warning: Some(String::from("a \"quote\"\nand a\tback\\slash")),
            holders: alloc::vec![Holder {
                pid: 7,
                process: String::from("caffeinate"),
                kind: String::from("PreventUserIdleSystemSleep"),
                name: String::from("caffeinate command-line tool"),
            }],
        };
        assert_eq!(
            r.encode(),
            "{\"awake\":1,\"phase\":\"running\",\"line\":\"0:29 left · 85% · floor 20%\",\"warning\":\"a \\\"quote\\\"\\nand a\\tback\\\\slash\",\"holders\":[{\"pid\":7,\"process\":\"caffeinate\",\"what\":\"PreventUserIdleSystemSleep (caffeinate command-line tool)\"}]}"
        );
        let ended = Report { phase: Phase::Ended, line: String::from("x\u{1}"), warning: None, holders: Vec::new() };
        assert_eq!(ended.encode(), "{\"awake\":1,\"phase\":\"ended\",\"line\":\"x\\u0001\",\"warning\":null,\"holders\":[]}");
    }
}
