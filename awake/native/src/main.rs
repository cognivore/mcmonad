//! `awake`: keep the Mac awake, locked and dark with the lid closed, for a
//! while; then it goes to sleep.
//!
//! AI-generated module: model Claude Opus 5.5 (`claude-opus-5-5`); reasoning
//! effort unavailable (not exposed by the harness).
//!
//! ```text
//! awake <minutes> [--floor <percent>] [--json]
//! awake check [<minutes>] [--floor <percent>]
//! awake stop
//! ```
//!
//! A session runs in the foreground until time, the battery floor (default
//! 20%) or the heat ends it, and then puts the Mac to sleep. Ctrl-C, or
//! `awake stop` from elsewhere, ends it early without sleeping. With
//! `--json` it prints protocol-1 report lines for mcmonad and also ends
//! when stdin closes. `awake check` prints what it sees of the Mac and what
//! a session would do, and changes nothing. The root guard beside this program in
//! MCMonadCore.app is what actually holds sleep off; it honours only the
//! `awake` beside it.

use awake_core::DEFAULT_FLOOR;
use awake_native::{
    NATIVE_PACE, Native, Output, check, read_lease, run_session, runs, stop_on_signals, stop_when_stdin_closes, this_exe,
};

const USAGE: &str = "usage: awake <minutes> [--floor <percent>] [--json] | awake check [<minutes>] [--floor <percent>] | awake stop";

enum Command {
    Session { minutes: u32, floor: u8, json: bool },
    Check { minutes: u32, floor: u8 },
    Stop,
}

fn parse(args: &[String]) -> Result<Command, String> {
    let mut it = args.iter();
    let first = it.next().ok_or("say how many minutes")?;
    if first == "stop" {
        return if it.next().is_none() { Ok(Command::Stop) } else { Err("`stop` takes nothing more".into()) };
    }
    let checking = first == "check";
    let mut rest: Vec<&String> = it.collect();
    let minutes_word = if checking {
        if rest.first().is_some_and(|w| !w.starts_with("--")) { Some(rest.remove(0)) } else { None }
    } else {
        Some(first)
    };
    let minutes = match minutes_word {
        Some(w) => w.parse::<u32>().map_err(|_| format!("{w:?} is not a number of minutes"))?,
        None => 30,
    };
    let (mut floor, mut json) = (DEFAULT_FLOOR, false);
    let mut it = rest.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--json" if !checking => json = true,
            "--floor" => {
                let p = it.next().ok_or("--floor needs a percent")?;
                floor = p.parse::<u8>().map_err(|_| format!("{p:?} is not a percent"))?;
            }
            other => return Err(format!("{other:?} is not an option")),
        }
    }
    Ok(if checking { Command::Check { minutes, floor } } else { Command::Session { minutes, floor, json } })
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
    match command {
        Command::Stop => std::process::exit(stop()),
        Command::Check { minutes, floor } => match check(&Native::new(Output::Words), minutes, floor) {
            Ok(text) => println!("{text}"),
            Err(e) => {
                eprintln!("awake: {e}");
                std::process::exit(1);
            }
        },
        Command::Session { minutes, floor, json } => {
            stop_on_signals();
            if json {
                stop_when_stdin_closes();
            }
            let host = Native::new(if json { Output::Json } else { Output::Words });
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
