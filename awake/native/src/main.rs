//! `awake`: keep the Mac awake, locked and dark with the lid closed, for a
//! while; then it goes to sleep.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! AI-assisted update (lengths such as 2h and 1h30m, and `check --json` for
//! mcmonad's launcher): model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! ```text
//! awake <length> [--floor <percent>] [--json]
//! awake check [<length>] [--floor <percent>] [--json]
//! awake stop
//! ```
//!
//! A length is minutes (`90`), hours (`2h`) or both (`1h30m`); it may span
//! words (`1h 30m`). A session runs in the foreground until time, the
//! battery floor (default 20%) or the heat ends it, and then puts the Mac to
//! sleep. Ctrl-C, or `awake stop` from elsewhere, ends it early without
//! sleeping. With `--json` it prints protocol-1 report lines for mcmonad and
//! also ends when stdin closes. `awake check` says what it sees of the Mac
//! and what a session would do (with `--json`, one report in phase `ready`,
//! `refused` or `failed`), and changes nothing. The root guard beside this
//! program in MCMonadCore.app is what actually holds sleep off; it honours
//! only the `awake` beside it.

use awake_core::{DEFAULT_FLOOR, Phase, Report};
use awake_native::{
    Host as _, NATIVE_PACE, Native, Output, check, read_lease, run_session, runs, stop_on_signals, stop_when_stdin_closes,
    this_exe,
};

const USAGE: &str = "usage: awake <length> [--floor <percent>] [--json] | awake check [<length>] [--floor <percent>] [--json] | awake stop\n       a length is minutes (90), hours (2h) or both (1h30m)";

/// What `awake check` plans when no length is given.
const CHECK_LENGTH: &str = "30";

enum Command {
    Session { length: String, floor: u8, json: bool },
    Check { length: String, floor: u8, json: bool },
    Stop,
}

fn parse(args: &[String]) -> Result<Command, String> {
    let (checking, rest) = match args.split_first() {
        Some((first, rest)) if first == "check" => (true, rest),
        Some((first, rest)) if first == "stop" => {
            return if rest.is_empty() { Ok(Command::Stop) } else { Err("`stop` takes nothing more".into()) };
        }
        Some(_) => (false, args),
        None => return Err("say how long, for example `awake 90` or `awake 2h`".into()),
    };
    let mut length: Vec<&str> = Vec::new();
    let (mut floor, mut json) = (DEFAULT_FLOOR, false);
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--json" => json = true,
            "--floor" => {
                let p = it.next().ok_or("--floor needs a percent")?;
                floor = p.parse::<u8>().map_err(|_| format!("{p:?} is not a percent"))?;
            }
            option if option.starts_with("--") => return Err(format!("{option:?} is not an option")),
            word => length.push(word),
        }
    }
    let length = length.join(" ");
    Ok(match (checking, length.is_empty()) {
        (true, true) => Command::Check { length: CHECK_LENGTH.into(), floor, json },
        (true, false) => Command::Check { length, floor, json },
        (false, true) => return Err("say how long, for example `awake 90` or `awake 2h`".into()),
        (false, false) => Command::Session { length, floor, json },
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if matches!(args.first().map(String::as_str), Some("-h" | "--help")) {
        println!("{USAGE}");
        return;
    }
    let command = match parse(&args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("awake: {e}\n{USAGE}");
            std::process::exit(64);
        }
    };
    let output = |json| if json { Output::Json } else { Output::Words };
    match command {
        Command::Stop => std::process::exit(stop()),
        Command::Check { length, floor, json } => {
            let host = Native::new(output(json));
            let c = check(&host, &length, floor);
            if !json && let Some(seen) = &c.seen {
                println!("{seen}");
            }
            host.report(&c.report);
            std::process::exit(if c.report.phase == Phase::Ready { 0 } else { 2 });
        }
        Command::Session { length, floor, json } => {
            let host = Native::new(output(json));
            let minutes = match awake_core::parse_minutes(&length) {
                Ok(m) => m,
                Err(e) => {
                    host.report(&Report { phase: Phase::Refused, line: e.to_string(), warning: None, holders: Vec::new() });
                    std::process::exit(2);
                }
            };
            stop_on_signals();
            if json {
                stop_when_stdin_closes();
            }
            std::process::exit(run_session(&host, NATIVE_PACE, minutes, floor).code());
        }
    }
}

/// Ask the running session, if any, to stop.
fn stop() -> i32 {
    let (Some(lease), Some(exe)) = (read_lease(), this_exe()) else {
        println!("awake: no session is running");
        return 0;
    };
    if !runs(lease.pid, &exe) {
        println!("awake: no session is running");
        return 0;
    }
    let Ok(pid) = i32::try_from(lease.pid) else { return 1 };
    // SAFETY: plain kill(2) on a pid just seen to run this program.
    if unsafe { libc::kill(pid, libc::SIGTERM) } == 0 {
        println!("awake: asked the session (pid {pid}) to stop; normal sleep comes back");
        0
    } else {
        eprintln!("awake: could not signal pid {pid}: {}", std::io::Error::last_os_error());
        1
    }
}
