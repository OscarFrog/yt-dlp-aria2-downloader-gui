// SPDX-License-Identifier: MIT
//! Persistent qualification observer. Private, bounded requests over anonymous pipes.
mod linux;
mod observe;
use linux::{Dir, EINVAL, EIO, Fault, Result};
use observe::{Session, quiescent, rows_json, snapshot, stat, token};
use std::io::{self, BufRead, Read, Write};

fn invalid() -> Fault {
    Fault::new("protocol", EINVAL).in_scope("protocol", "unknown")
}
fn pid(text: &str) -> Result<u32> {
    text.parse::<u32>()
        .ok()
        .filter(|n| *n > 0 && *n <= i32::MAX as u32)
        .ok_or_else(invalid)
}
fn start(text: &str) -> Result<u64> {
    text.parse::<u64>().map_err(|_| invalid())
}
fn marker(hex: &str) -> Result<Vec<u8>> {
    if !hex.len().is_multiple_of(2)
        || hex.len() > 8192
        || !hex.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(invalid());
    }
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("checked hexadecimal"))
        .collect();
    let Some(eq) = bytes.iter().position(|b| *b == b'=') else {
        return Err(invalid());
    };
    if eq == 0 || eq + 1 == bytes.len() || bytes.contains(&0) {
        return Err(invalid());
    }
    Ok(bytes)
}
fn command(cmd: &[&str], root: &Dir, session: &mut Option<Session>) -> Result<String> {
    match cmd {
        ["INIT", key, allow @ ("0" | "1")] if session.is_none() => {
            *session = Some(Session::new(marker(key)?, *allow == "1"));
            Ok("true".into())
        }
        ["LEAF", label]
            if !label.is_empty()
                && label.len() <= 32
                && label
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-') =>
        {
            let session = session.as_mut().ok_or_else(invalid)?;
            if session.leaf.is_some() || session.has_scoped_known() {
                return Err(invalid());
            }
            session.leaf = Some((*label).to_owned());
            Ok("true".into())
        }
        ["KNOWN"] => Ok(session.as_ref().ok_or_else(invalid)?.known_json()),
        ["SAMPLE"] => session.as_mut().ok_or_else(invalid)?.sample(root),
        ["SNAPSHOT"] => Ok(format!("{{{}}}", rows_json(&snapshot(root)?))),
        ["STAT", group] | ["STAT", group, _] => {
            let id = pid(group)?;
            let tid = cmd.get(2).map(|v| pid(v)).transpose()?;
            match stat(root, id, tid) {
                Ok(row) => Ok(row.json()),
                Err(e) if e.vanished() => Ok("null".into()),
                Err(e) => Err(e.at(id, tid.unwrap_or(id), 0)),
            }
        }
        ["TOKEN", group, key] => {
            let id = pid(group)?;
            Ok(token(root, id, &marker(key)?)
                .map_err(|e| e.at(id, id, 0))?
                .to_string())
        }
        ["QUIESCENT", group, tick] => {
            let id = pid(group)?;
            let tick = start(tick)?;
            Ok(quiescent(root, id, tick)
                .map_err(|e| e.at(id, id, tick))?
                .to_string())
        }
        [verb @ ("REGISTER" | "ROOT" | "CHILD"), group, tick] => {
            let id = pid(group)?;
            let tick = start(tick)?;
            Ok(session
                .as_mut()
                .ok_or_else(invalid)?
                .register(root, id, tick, verb)
                .map_err(|e| e.at(id, id, tick))?
                .to_string())
        }
        _ => Err(invalid()),
    }
}
fn reply(result: Result<String>) -> String {
    match result {
        Ok(value) => format!("{{\"ok\":{value}}}"),
        Err(e) => format!(
            "{{\"error\":{{\"errno\":{},\"operation\":\"{}\",\"phase\":\"{}\",\"pid\":{},\"tid\":{},\"start\":{},\"task_start\":{},\"source\":\"{}\"}}}}",
            e.errno, e.op, e.phase, e.pid, e.tid, e.start, e.task_start, e.source
        ),
    }
}
fn serve() -> Result<()> {
    if !linux::platform() {
        return Err(invalid());
    }
    let root = Dir::root()?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut session = None;
    loop {
        let mut buf = Vec::new();
        let n = input
            .by_ref()
            .take(16385)
            .read_until(b'\n', &mut buf)
            .map_err(|e| Fault::io("protocol", e))?;
        if n == 0 {
            break;
        }
        if n > 16384 || buf.pop() != Some(b'\n') {
            return Err(invalid());
        }
        let line = std::str::from_utf8(&buf).map_err(|_| invalid())?;
        let cmd: Vec<_> = line.split_ascii_whitespace().collect();
        let quit = cmd == ["QUIT"];
        let response = if quit {
            linux::checked(
                session.take().map(Session::close).unwrap_or(Ok(())),
                root.close(),
            )
            .map(|()| "true".to_string())
        } else {
            let payload = reply(command(&cmd, &root, &mut session));
            writeln!(output, "{payload}")
                .and_then(|()| output.flush())
                .map_err(|_| Fault::new("protocol", EIO))?;
            continue;
        };
        writeln!(output, "{}", reply(response))
            .and_then(|()| output.flush())
            .map_err(|_| Fault::new("protocol", EIO))?;
        return Ok(());
    }
    linux::checked(
        session.take().map(Session::close).unwrap_or(Ok(())),
        root.close(),
    )
}
fn main() {
    if serve().is_err() {
        eprintln!("qualification observer: service stopped");
        std::process::exit(1);
    }
}
