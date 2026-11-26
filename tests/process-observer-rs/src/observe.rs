// SPDX-License-Identifier: MIT
//! Kernel-bound group membership, memory inspections and nonterminal exit observations.
use crate::linux::{Dir, EIO, Fault, PidEvent, PidFd, Result, Row, checked};
use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};

pub type Identity = (u32, u64);
pub type Census = BTreeMap<u32, Row>;
const MEMORY_MAX: usize = 8 * 1024 * 1024;

pub fn snapshot(root: &Dir) -> Result<Census> {
    let mut rows = Census::new();
    for pid in root.ids()? {
        match stat(root, pid, None) {
            Ok(row) => {
                rows.insert(pid, row);
            }
            Err(e) if e.vanished() => {
                // A stale stat read is not an absence proof. Resolve the numeric
                // entry once, without replacing the missing observation.
                match root.id(pid, "group_open") {
                    Err(gone) if gone.vanished() => (),
                    Ok(dir) => {
                        let _ = dir.close();
                        return Err(e.at(pid, pid, 0));
                    }
                    Err(_) => return Err(e.at(pid, pid, 0)),
                }
            }
            Err(e) => return Err(e.at(pid, pid, 0)),
        }
    }
    if !rows.contains_key(&std::process::id()) {
        return Err(Fault::new("inventory", EIO));
    }
    Ok(rows)
}
pub fn stat(root: &Dir, pid: u32, tid: Option<u32>) -> Result<Row> {
    let group = root.id(pid, "group_open")?;
    let r = match tid {
        None => group.row(),
        Some(tid) => (|| {
            let tasks = group.dir(c"task", "inventory")?;
            let result = (|| {
                let dir = tasks.id(tid, "thread_open")?;
                checked(dir.row(), dir.close())
            })();
            checked(result, tasks.close())
        })(),
    };
    checked(r, group.close()).and_then(|r| {
        if r.pid == tid.unwrap_or(pid) {
            Ok(r)
        } else {
            Err(Fault::new("identity", EIO))
        }
    })
}
#[derive(Clone, Copy)]
enum Field<'a> {
    Marker(&'a [u8]),
    Arguments,
}

#[derive(Debug)]
struct Seen {
    found: bool,
    external: bool,
}

impl Field<'_> {
    fn read(self, dir: &Dir) -> Result<Seen> {
        match self {
            Self::Marker(marker) => {
                let bytes = dir.read(c"environ", "environ_open", "environ_read", MEMORY_MAX)?;
                let found = bytes.split(|b| *b == 0).any(|item| item == marker);
                let external = found
                    && bytes
                        .split(|b| *b == 0)
                        .any(|item| item == b"YTDLP_QUALIFICATION_EXTERNAL=1");
                Ok(Seen { found, external })
            }
            Self::Arguments => {
                let bytes = dir.read(c"cmdline", "cmdline_open", "cmdline_read", MEMORY_MAX)?;
                Ok(Seen {
                    found: bytes.windows(7).any(|v| v.eq_ignore_ascii_case(b"http://"))
                        || bytes
                            .windows(8)
                            .any(|v| v.eq_ignore_ascii_case(b"https://")),
                    external: false,
                })
            }
        }
    }
}

// Only a disappearance at the named operation may use an authenticated
// exit proof. One live-generation recheck is shared by the whole sample.
fn recheck<T>(
    mut first: Fault,
    operations: &[&str],
    retried: &Cell<bool>,
    ended: impl Fn() -> Result<bool>,
    read: impl FnOnce() -> Result<T>,
) -> Result<Option<T>> {
    let eligible = |e: &Fault| e.vanished() && !e.secondary_close && operations.contains(&e.op);
    if !eligible(&first) {
        return Err(first);
    }
    match ended() {
        Ok(true) => return Ok(None),
        Ok(false) if !retried.replace(true) => (),
        Ok(false) => return Err(first),
        Err(e) => {
            first.secondary_close |= e.secondary_close || e.op == "close";
            return Err(first);
        }
    }
    match read() {
        Ok(value) => Ok(Some(value)),
        Err(e) if eligible(&e) && ended() == Ok(true) => Ok(None),
        Err(e) => {
            first.secondary_close |= e.secondary_close || e.op == "close";
            Err(first)
        }
    }
}

struct Group {
    dir: Dir,
    fd: PidFd,
    key: Identity,
    source: &'static str,
    external: bool,
}
#[derive(Clone, Copy)]
enum State {
    Live(Row),
    Exiting(Row),
    LeaderZombie(Row),
    Terminated,
    Gone,
}
impl Group {
    fn bind(root: &Dir, row: Row, source: &'static str) -> Result<Self> {
        let dir = root.id(row.pid, "group_open")?;
        Self::from_dir(dir, row, source)
    }
    fn from_dir(dir: Dir, row: Row, source: &'static str) -> Result<Self> {
        let before = dir.row()?;
        if row.start != before.start || row.pid != before.pid {
            return Err(Fault::new("identity", EIO));
        }
        let fd = PidFd::bind(row.pid, false)?;
        let after = dir.row()?;
        if row.start != after.start || row.pid != after.pid {
            return Err(Fault::new("identity", EIO));
        }
        Ok(Self {
            dir,
            fd,
            key: (row.pid, row.start),
            source,
            external: false,
        })
    }
    fn row(&self) -> Result<Row> {
        let r = self.dir.row()?;
        if self.key != (r.pid, r.start) {
            return Err(Fault::new("identity", EIO));
        }
        Ok(r)
    }
    fn exit_state(&self) -> Result<Option<State>> {
        // Group pidfds become readable only after the last thread exits.
        // HUP distinguishes removal; neither event supplies a wait status.
        Ok(match self.fd.event()? {
            PidEvent::Running => None,
            PidEvent::Exited => Some(State::Terminated),
            PidEvent::HungUp => Some(State::Gone),
        })
    }
    fn close(self) -> Result<()> {
        checked(self.dir.close(), self.fd.close())
    }

    fn children(&self) -> Result<BTreeSet<u32>> {
        let tasks = self.dir.dir(c"task", "inventory")?;
        let result = (|| {
            let mut children = BTreeSet::new();
            for tid in tasks.ids()? {
                let task = match tasks.id(tid, "thread_open") {
                    Err(e) if e.vanished() => continue,
                    other => other?,
                };
                let data = checked(
                    task.read(c"children", "inventory", "inventory", MEMORY_MAX),
                    task.close(),
                );
                let bytes = match data {
                    Err(e) if e.vanished() && !e.secondary_close => continue,
                    other => other?,
                };
                let text = std::str::from_utf8(&bytes).map_err(|_| Fault::new("inventory", EIO))?;
                for word in text.split_whitespace() {
                    children.insert(word.parse().map_err(|_| Fault::new("inventory", EIO))?);
                }
            }
            Ok(children)
        })();
        checked(result, tasks.close())
    }
    // Called only with a directory and references already bound to the sampled
    // generation. A missing command line is never a negative URL observation.
    fn after_open_error(
        &self,
        first: Fault,
        task: &Dir,
        sampled: Row,
        thread: Option<&PidFd>,
        retried: &Cell<bool>,
    ) -> Result<Option<Seen>> {
        if first.op != "cmdline_open"
            || (thread.is_none() && self.key != (sampled.pid, sampled.start))
        {
            return Err(first);
        }
        let exited = || -> Result<bool> {
            if self.fd.ready()? {
                return Ok(true);
            }
            if let Some(fd) = thread {
                return fd.ready();
            }
            // A zombie leader can no longer supply argv while its group lives.
            match self.row() {
                Ok(row) => Ok(row.zombie()),
                Err(e) if e.vanished() && !e.secondary_close => self.fd.ready(),
                Err(e) => Err(e),
            }
        };
        let reevaluate = || {
            let current = task.row()?;
            if (current.pid, current.start) != (sampled.pid, sampled.start) {
                return Err(Fault::new("identity", EIO));
            }
            if thread.is_some() {
                task.thread_membership(self.key.0, sampled.pid)?;
            }
            Field::Arguments.read(task)
        };
        recheck(
            first,
            &["cmdline_open", "stat", "status"],
            retried,
            exited,
            reevaluate,
        )
    }

    fn inspect(
        &self,
        mut field: impl FnMut(&Dir) -> Result<Seen>,
    ) -> Result<(State, Option<Seen>, bool)> {
        if let Some(state) = self.exit_state()? {
            return Ok((state, None, false));
        }
        let mut missed = None;
        let retried = Cell::new(false);
        let mut observe = |missed: &mut Option<Fault>| {
            self.inspect_live(
                |dir: &Dir, row: Row, fd: Option<&PidFd>| -> Result<Option<Seen>> {
                    match field(dir) {
                        Ok(seen) => Ok(Some(seen)),
                        Err(e) => {
                            let mut e = e.at(self.key.0, row.pid, self.key.1);
                            e.task_start = row.start;
                            let available =
                                self.after_open_error(e.clone(), dir, row, fd, &retried)?;
                            if available.is_none() {
                                missed.get_or_insert(e);
                            }
                            Ok(available)
                        }
                    }
                },
            )
        };
        let observed = match observe(&mut missed) {
            Err(first) if missed.is_none() => {
                // Before a field was available, leader stat or task inventory
                // may have raced group exit. Recheck only this pinned group.
                match recheck(
                    first.clone(),
                    &["stat", "inventory"],
                    &retried,
                    || self.fd.ready(),
                    || observe(&mut missed),
                )? {
                    Some(report) => Ok(report),
                    None => {
                        return Ok((self.exit_state().ok().flatten().ok_or(first)?, None, true));
                    }
                }
            }
            other => other,
        };
        let gap = missed.is_some();
        match (observed, missed) {
            (Ok((state, seen)), _) => {
                let gap = gap || seen.is_none();
                Ok((state, seen, gap))
            }
            (Err(e), Some(mut first)) => {
                if e.vanished()
                    && !e.secondary_close
                    && matches!(e.op, "inventory" | "stat")
                    && let Ok(Some(state)) = self.exit_state()
                {
                    return Ok((state, None, true));
                }
                // A sibling with a required unreadable attribute remains a
                // refusal of its own. Retain the first gap on failed cleanup.
                if e.op == "close" || e.secondary_close {
                    first.secondary_close = true;
                    return Err(first);
                }
                Err(if e.op == "inventory" && e.errno == EIO {
                    first
                } else {
                    e
                })
            }
            (Err(e), None) => Err(e),
        }
    }

    fn inspect_live(
        &self,
        mut read: impl FnMut(&Dir, Row, Option<&PidFd>) -> Result<Option<Seen>>,
    ) -> Result<(State, Option<Seen>)> {
        let mut row = self.row()?;
        if !row.zombie() {
            if let Some(seen) = read(&self.dir, row, None)? {
                return Ok((
                    if row.exiting() {
                        State::Exiting(row)
                    } else {
                        State::Live(row)
                    },
                    Some(seen),
                ));
            }
            if let Some(state) = self.exit_state()? {
                return Ok((state, None));
            }
            row = self.row()?;
        }
        let tasks = self.dir.dir(c"task", "inventory")?;
        let inspect = (|| {
            for tid in tasks.ids()? {
                if tid == row.pid {
                    continue;
                }
                let task = match tasks.id(tid, "thread_open") {
                    Err(e) if e.vanished() => continue,
                    other => other?,
                };
                let result = (|| {
                    let thread = task.row()?;
                    if thread.pid != tid {
                        return Err(Fault::new("identity", EIO));
                    }
                    if thread.zombie() {
                        return Ok(None);
                    }
                    let fd = PidFd::bind(tid, true)?;
                    let result = (|| {
                        task.thread_membership(row.pid, tid)?;
                        let current = task.row()?;
                        if (current.pid, current.start) != (tid, thread.start) {
                            return Err(Fault::new("identity", EIO));
                        }
                        if fd.ready()? {
                            return Ok(None);
                        }
                        read(&task, thread, Some(&fd))
                    })();
                    checked(result, fd.close())
                })();
                match checked(result, task.close()) {
                    Ok(Some(seen)) => return Ok(Some(seen)),
                    Ok(None) => continue,
                    Err(e)
                        if e.vanished()
                            && !e.secondary_close
                            && matches!(e.op, "stat" | "status" | "pidfd_open") =>
                    {
                        continue;
                    }
                    Err(e) => return Err(e),
                }
            }
            Ok(None)
        })();
        let seen = checked(inspect, tasks.close())?;
        if let Some(seen) = seen {
            Ok((State::LeaderZombie(row), Some(seen)))
        } else if let Some(state) = self.exit_state()? {
            Ok((state, None))
        } else {
            Err(Fault::new("inventory", EIO))
        }
    }
}

#[derive(Default)]
pub struct Session {
    marker: Vec<u8>,
    pub leaf: Option<String>,
    allow_external: bool,
    groups: BTreeMap<u32, Group>,
    known: BTreeSet<Identity>,
    externals: BTreeSet<Identity>,
    leaks: BTreeSet<Identity>,
    argv_exit_gaps: u64,
    pub failure: Option<Fault>,
}
pub fn pairs(entries: &BTreeSet<Identity>) -> String {
    entries
        .iter()
        .map(|(p, s)| format!("[{p},{s}]"))
        .collect::<Vec<_>>()
        .join(",")
}
pub fn rows_json(rows: &Census) -> String {
    rows.iter()
        .map(|(p, r)| format!("\"{p}\":{}", r.json()))
        .collect::<Vec<_>>()
        .join(",")
}
impl Session {
    pub fn new(marker: Vec<u8>, allow_external: bool) -> Self {
        Self {
            marker,
            allow_external,
            ..Default::default()
        }
    }
    pub fn known_json(&self) -> String {
        let scoped = self.known.difference(&self.externals).copied().collect();
        format!("[{}]", pairs(&scoped))
    }
    pub fn close(mut self) -> Result<()> {
        let mut result = Ok(());
        for (_, g) in std::mem::take(&mut self.groups) {
            result = checked(result, g.close());
        }
        result
    }
    pub fn register(&mut self, root: &Dir, pid: u32, start: u64, admission: &str) -> Result<bool> {
        let row = match stat(root, pid, None) {
            Err(e) if e.vanished() => return Ok(false),
            r => r?,
        };
        if row.start != start || pid == 1 || pid == std::process::id() {
            return Ok(false);
        }
        let mut g = Group::bind(root, row, "registered")?;
        let allowed = if admission == "CHILD" {
            let owner = stat(root, std::process::id(), None)?.parent;
            g.row()?.parent == owner
                && (match &self.leaf {
                    Some(label) => members(label)?.contains(&pid),
                    None => true,
                })
        } else if admission == "ROOT" {
            // Walk from our real parent with pinned parent rows. A changed
            // edge confers no authority even when its numerical PID recurs.
            let mut child = stat(root, std::process::id(), None)?;
            let mut yes = false;
            while child.parent > 1 {
                let p = stat(root, child.parent, None)?;
                let c = stat(root, child.pid, None)?;
                if (c.parent, c.start) != (p.pid, child.start) || p.start > child.start {
                    break;
                }
                if (p.pid, p.start) == g.key {
                    yes = true;
                    break;
                }
                child = p;
            }
            yes && !g.fd.ready()?
        } else {
            let m = g
                .inspect(|dir| Field::Marker(&self.marker).read(dir))
                .map_err(|e| {
                    let source = if self.known.contains(&g.key) {
                        "known_identity"
                    } else {
                        "registered"
                    };
                    e.at(pid, pid, start).in_scope("attribution", source)
                })?
                .1;
            g.external = self.allow_external && m.as_ref().is_some_and(|m| m.external);
            m.is_some_and(|m| m.found)
        };
        if allowed {
            self.known.insert(g.key);
            if let Some(old) = self.groups.insert(pid, g) {
                old.close()?;
            }
        } else {
            g.close()?;
        }
        Ok(allowed)
    }
    fn auth_parent(&self, g: &Group, row: Row) -> Result<bool> {
        let Some(parent) = self.groups.get(&row.parent) else {
            return Ok(false);
        };
        if parent.fd.ready()? || parent.key.1 > row.start {
            return Ok(false);
        }
        let current = g.row()?;
        Ok(current.parent == row.parent && !parent.fd.ready()?)
    }
    pub fn sample(&mut self, root: &Dir) -> Result<String> {
        if let Some(e) = &self.failure {
            return Err(e.clone());
        }
        let result = self.collect(root);
        if let Err(e) = &result {
            self.failure = Some(e.clone());
        }
        result
    }
    fn collect(&mut self, root: &Dir) -> Result<String> {
        let context = |mut e: Fault, pid, start, source, phase| {
            if e.pid == 0 {
                e = e.at(pid, pid, start);
            }
            e.in_scope(phase, source)
        };
        // A pinned group stays in scope after reparenting. Only the kernel or
        // a private fixture barrier supplies additional candidate identities.
        let mut pending: Vec<u32> = self.groups.keys().copied().collect();
        if let Some(label) = &self.leaf {
            for pid in members(label)? {
                if self.groups.contains_key(&pid) {
                    continue;
                }
                let candidate =
                    stat(root, pid, None).and_then(|r| Group::bind(root, r, "registered"));
                match candidate {
                    Ok(g) if members(label)?.contains(&pid) => {
                        self.groups.insert(pid, g);
                        pending.push(pid);
                    }
                    Ok(g) => g.close()?,
                    Err(e)
                        if e.vanished()
                            && !e.secondary_close
                            && !members(label)?.contains(&pid) => {}
                    Err(e) => return Err(context(e, pid, 0, "registered", "attribution")),
                }
            }
        } else {
            let mut index = 0;
            while index < pending.len() {
                let pid = pending[index];
                index += 1;
                let parent = &self.groups[&pid];
                if parent.fd.ready()? {
                    continue;
                }
                let external = parent.external;
                let candidates = match parent.children() {
                    Err(e) if e.vanished() && !e.secondary_close && parent.fd.ready()? => continue,
                    result => result
                        .map_err(|e| context(e, pid, parent.key.1, parent.source, "attribution"))?,
                };
                for child in candidates {
                    if child == std::process::id() || self.groups.contains_key(&child) {
                        continue;
                    }
                    let bind: Result<Option<Group>> = (|| {
                        let row = stat(root, child, None)?;
                        if row.parent != pid {
                            return Ok(None);
                        }
                        let mut group = Group::bind(root, row, "descendant")?;
                        if self.auth_parent(&group, row)? {
                            group.external = external;
                            Ok(Some(group))
                        } else {
                            group.close()?;
                            Ok(None)
                        }
                    })();
                    match bind {
                        Ok(Some(group)) => {
                            self.groups.insert(child, group);
                            pending.push(child);
                        }
                        Ok(None) => (),
                        Err(e) if e.vanished() && !e.secondary_close => (),
                        Err(e) => return Err(context(e, child, 0, "descendant", "attribution")),
                    }
                }
            }
        }
        let mut reports = BTreeMap::new();
        for (&pid, g) in &mut self.groups {
            if g.external {
                continue;
            }
            let report = g
                .inspect(|dir| Field::Arguments.read(dir))
                .map_err(|e| context(e, pid, g.key.1, g.source, "sample"));
            if let Ok((_, seen, gap)) = &report {
                if seen.as_ref().is_some_and(|seen| seen.found) {
                    self.leaks.insert(g.key);
                }
                self.argv_exit_gaps += u64::from(*gap);
            }
            reports.insert(pid, report);
        }
        for (&pid, g) in &self.groups {
            if g.external {
                self.externals.insert(g.key);
            } else if !self.allow_external || reports.get(&pid).is_some_and(Result::is_ok) {
                self.known.insert(g.key);
            }
        }
        // Discovery failures can predate a later group's lower-numbered PID.
        // Select by operation order after exclusion, never by report iteration.
        let first = reports
            .iter()
            .filter(|(pid, _)| !self.groups[pid].external)
            .filter_map(|(_, r)| r.as_ref().err())
            .min_by_key(|e| e.sequence);
        if let Some(first) = first {
            return Err(first.clone());
        }
        let mut live = Census::new();
        let mut zombies = Vec::new();
        let mut gone = Vec::new();
        for (&pid, g) in &mut self.groups {
            if g.external {
                self.externals.insert(g.key);
                if g.fd.ready()? {
                    gone.push(pid);
                }
                continue;
            }
            let Some(report) = reports.remove(&pid) else {
                continue;
            };
            let (state, _, _) = report?;
            match state {
                State::Live(row) | State::Exiting(row) | State::LeaderZombie(row) => {
                    live.insert(pid, row);
                }
                State::Terminated => zombies.push(pid),
                State::Gone => gone.push(pid),
            }
            g.source = "known_identity";
        }
        for pid in gone {
            self.groups.remove(&pid).unwrap().close()?;
        }
        let coverage = if self.leaf.is_some() {
            format!(",\"argv_exit_gaps\":{}", self.argv_exit_gaps)
        } else {
            String::new()
        };
        let now = crate::linux::monotonic()?;
        Ok(format!(
            "{{\"monotonic_ns\":{now},\"live\":{{{}}},\"zombies\":{zombies:?},\"url_in_argv\":[{}],\"known\":[{}],\"external\":[{}]{coverage}}}",
            rows_json(&live),
            pairs(&self.leaks),
            pairs(&self.known),
            pairs(&self.externals)
        ))
    }
}
pub fn token(root: &Dir, pid: u32, marker: &[u8]) -> Result<bool> {
    let get = || -> Result<bool> {
        let row = stat(root, pid, None)?;
        let g = Group::bind(root, row, "registered")?;
        let report = g.inspect(|dir| Field::Marker(marker).read(dir));
        let ok = checked(report, g.close())?;
        Ok(matches!(
            ok.0,
            State::Live(_) | State::LeaderZombie(_) | State::Exiting(_)
        ) && ok.1.is_some_and(|m| m.found))
    };
    match get() {
        Err(e)
            if matches!(e.op, "group_open" | "stat" | "pidfd_open" | "identity")
                && e.vanished() =>
        {
            Ok(false)
        }
        r => r,
    }
}
pub fn quiescent(root: &Dir, pid: u32, start: u64) -> Result<bool> {
    let row = match stat(root, pid, None) {
        Err(e) if e.vanished() => return Ok(true),
        r => r?,
    };
    if row.start != start {
        return Ok(true);
    }
    let g = match Group::bind(root, row, "registered") {
        Err(e) if e.vanished() && stat(root, pid, None).is_err_and(|f| f.vanished()) => {
            return Ok(true);
        }
        r => r?,
    };
    checked(g.fd.ready(), g.close())
}

// Mounted by the native launcher from one delegated application leaf. The
// qualification namespace exposes no other cgroup membership control.
fn members(label: &str) -> Result<BTreeSet<u32>> {
    let content = std::fs::read_to_string(format!("/qualification/trials/{label}/members"))
        .map_err(|e| Fault::io("inventory", e))?;
    content
        .split_whitespace()
        .map(|word| {
            word.parse::<u32>()
                .ok()
                .filter(|p| *p > 0)
                .ok_or_else(|| Fault::new("inventory", EIO))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::{ENOENT, ESRCH};
    use std::process::{Child, Command, Stdio};

    fn fixture() -> (Dir, Group, Child) {
        let child = Command::new("/usr/bin/sh")
            .env_clear()
            .args(["-c", "read -r gate; exit 37", "https://fixture.invalid/"])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        let root = Dir::root().unwrap();
        let row = stat(&root, child.id(), None).unwrap();
        let group = Group::bind(&root, row, "registered").unwrap();
        (root, group, child)
    }

    #[test]
    fn cmdline_open_esrch_requires_a_bound_exit_or_an_actual_read() {
        let (root, group, mut child) = fixture();
        let first = Fault::new("cmdline_open", ESRCH);
        let mut wrong = group.row().unwrap();
        wrong.start += 1;
        assert_eq!(
            group
                .after_open_error(first.clone(), &group.dir, wrong, None, &Cell::new(false))
                .unwrap_err(),
            first
        );
        for (operation, errno) in [
            ("cmdline_open", 13),
            ("cmdline_open", 1),
            ("cmdline_open", EIO),
            ("cmdline_read", ESRCH),
            ("environ_open", ESRCH),
        ] {
            let refusal = Fault::new(operation, errno);
            let error = group.inspect(|_| Err(refusal.clone())).err().unwrap();
            assert_eq!(
                (error.sequence, error.op, error.errno),
                (refusal.sequence, operation, errno)
            );
        }
        let (state, seen, gap) = group.inspect(|_| Err(first.clone())).unwrap();
        assert!(matches!(state, State::Live(_)));
        assert!(seen.unwrap().found);
        assert!(!gap);

        // Only the fixture owner releases and reaps. The known pidfd was
        // acquired before this injected first-open error.
        let (state, seen, gap) = group
            .inspect(|_| {
                drop(child.stdin.take());
                assert_eq!(child.wait().unwrap().code(), Some(37));
                Err(first.clone())
            })
            .unwrap();
        assert!(matches!(state, State::Gone));
        assert!(seen.is_none() && gap);
        group.close().unwrap();
        root.close().unwrap();
    }

    #[test]
    fn stat_disappearance_requires_bound_exit_or_one_complete_recheck() {
        let (root, group, mut child) = fixture();
        let ops = &["stat", "inventory"];
        let retried = Cell::new(false);
        let ready = || group.fd.ready();
        let first = Fault::new("stat", ENOENT);
        let observed = recheck(first.clone(), ops, &retried, ready, || group.row()).unwrap();
        assert_eq!(observed.unwrap().start, group.key.1);
        assert!(retried.get());
        let unresolved = recheck::<Row>(first.clone(), ops, &retried, ready, || unreachable!());
        assert_eq!(unresolved.err().unwrap(), first);

        for errno in [1, 13, EIO] {
            let error = Fault::new("stat", errno);
            let result = recheck::<Row>(
                error.clone(),
                ops,
                &Cell::new(false),
                || unreachable!(),
                || unreachable!(),
            );
            assert_eq!(result.err().unwrap(), error);
        }
        // Put the owner-controlled exit between this sample's first poll and a
        // stat access on the pinned directory. The errno comes from procfs.
        let sampled = group
            .inspect(|dir| {
                drop(child.stdin.take());
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
                while !ready().unwrap() {
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::yield_now();
                }
                assert!(matches!(
                    group.inspect(|_| unreachable!()).unwrap(),
                    (State::Terminated, None, false)
                ));
                assert_eq!(child.wait().unwrap().code(), Some(37));
                let failure = dir.row().err().unwrap();
                assert_eq!(failure.op, "stat");
                assert!(failure.vanished());
                Err(failure)
            })
            .unwrap();
        assert!(matches!(sampled, (State::Gone, None, true)));
        assert!(matches!(
            group.inspect(|_| unreachable!()).unwrap(),
            (State::Gone, None, false)
        ));
        group.close().unwrap();
        root.close().unwrap();
    }

    #[test]
    fn observed_url_and_first_refusal_survive_later_group_exit() {
        let (root, group, mut child) = fixture();
        let mut session = Session::default();
        let identity = group.key;
        session.groups.insert(identity.0, group);
        session.sample(&root).unwrap();
        assert!(session.leaks.contains(&identity));
        // An incorrect generation must fail even after a previous good sample.
        session.groups.get_mut(&identity.0).unwrap().key.1 += 1;
        let first = session.sample(&root).unwrap_err();
        assert_eq!((first.op, first.errno), ("identity", EIO));
        drop(child.stdin.take());
        assert_eq!(child.wait().unwrap().code(), Some(37));
        assert_eq!(session.sample(&root).unwrap_err(), first);
        assert!(session.leaks.contains(&identity));
        session.close().unwrap();
        root.close().unwrap();
    }
}
