// SPDX-License-Identifier: MIT
//! Fedora x86_64 kernel references. No interface for signaling or waiting.
use std::ffi::{CStr, CString, c_int, c_short};
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, OwnedFd};
use std::path::Path;

#[cfg(not(all(target_os = "linux", target_arch = "x86_64", target_env = "gnu")))]
compile_error!("qualification requires Fedora 45 x86_64");

const O_PATH_DIRECTORY: i32 = 0o10000000 | 0o200000;
const O_CLOEXEC: i32 = 0o2000000;
const O_NOFOLLOW: i32 = 0o400000;
const PIDFD_THREAD: u32 = 0x80; // linux/pidfd.h: O_EXCL on x86_64
pub const ESRCH: i32 = 3;
pub const ENOENT: i32 = 2;
pub const EIO: i32 = 5;
pub const EINVAL: i32 = 22;
const LIMIT: i32 = 75;
#[repr(C)]
struct PollFd {
    fd: c_int,
    events: c_short,
    revents: c_short,
}
#[repr(C)]
struct Timespec {
    sec: i64,
    nsec: i64,
}

unsafe extern "C" {
    fn openat(fd: c_int, name: *const i8, flags: c_int, ...) -> c_int;
    fn pidfd_open(pid: c_int, flags: u32) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn poll(fds: *mut PollFd, n: usize, timeout: c_int) -> c_int;
    fn clock_gettime(id: c_int, ts: *mut Timespec) -> c_int;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault {
    pub sequence: u64,
    pub errno: i32,
    pub op: &'static str,
    pub phase: &'static str,
    pub pid: u32,
    pub tid: u32,
    pub start: u64,
    pub task_start: u64,
    pub source: &'static str,
    pub secondary_close: bool,
}
pub type Result<T> = std::result::Result<T, Fault>;
impl Fault {
    pub fn new(op: &'static str, errno: i32) -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self {
            sequence: NEXT.fetch_add(1, Ordering::Relaxed),
            errno,
            op,
            phase: "query",
            pid: 0,
            tid: 0,
            start: 0,
            task_start: 0,
            source: "unknown",
            secondary_close: false,
        }
    }
    pub fn io(op: &'static str, e: io::Error) -> Self {
        Self::new(op, e.raw_os_error().unwrap_or(EIO))
    }
    pub fn vanished(&self) -> bool {
        matches!(self.errno, ENOENT | ESRCH)
    }
    pub fn at(mut self, pid: u32, tid: u32, start: u64) -> Self {
        self.pid = pid;
        self.tid = tid;
        self.start = start;
        if pid == tid {
            self.task_start = start;
        }
        self
    }
    pub fn in_scope(mut self, phase: &'static str, source: &'static str) -> Self {
        self.phase = phase;
        self.source = source;
        self
    }
}
fn rawfd(op: &'static str, value: i32) -> Result<OwnedFd> {
    if value < 0 {
        return Err(Fault::io(op, io::Error::last_os_error()));
    }
    // SAFETY: called only with a newly opened descriptor, exactly once.
    Ok(unsafe { OwnedFd::from_raw_fd(value) })
}
pub fn finish(fd: OwnedFd) -> Result<()> {
    // SAFETY: ownership moves out of OwnedFd exactly once. Linux close is not retried.
    if unsafe { close(fd.into_raw_fd()) } == 0 {
        Ok(())
    } else {
        Err(Fault::io("close", io::Error::last_os_error()))
    }
}
pub fn checked<T>(result: Result<T>, closed: Result<()>) -> Result<T> {
    match (result, closed) {
        (Err(mut first), Err(_)) => {
            first.secondary_close = true;
            Err(first)
        }
        (Err(first), _) => Err(first),
        (Ok(_), Err(close)) => Err(close),
        (Ok(value), Ok(())) => Ok(value),
    }
}
pub fn monotonic() -> Result<u64> {
    let mut t = Timespec { sec: 0, nsec: 0 };
    // SAFETY: t is a writable Linux timespec. CLOCK_MONOTONIC = 1.
    if unsafe { clock_gettime(1, &mut t) } != 0 {
        return Err(Fault::io("clock", io::Error::last_os_error()));
    }
    Ok(t.sec as u64 * 1_000_000_000 + t.nsec as u64)
}
pub struct Dir(OwnedFd);
impl Dir {
    pub fn root() -> Result<Self> {
        // SAFETY: absolute constant path, valid C string and no creation flags.
        rawfd("group_open", unsafe {
            openat(
                -100,
                c"/proc".as_ptr(),
                O_PATH_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            )
        })
        .map(Self)
    }
    fn open(&self, name: &CStr, flags: i32, op: &'static str) -> Result<OwnedFd> {
        // SAFETY: name is a non-NUL component, the parent fd remains borrowed.
        rawfd(op, unsafe {
            openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                flags | O_CLOEXEC | O_NOFOLLOW,
            )
        })
    }
    pub fn dir(&self, name: &CStr, op: &'static str) -> Result<Self> {
        self.open(name, O_PATH_DIRECTORY, op).map(Self)
    }
    pub fn id(&self, id: u32, op: &'static str) -> Result<Self> {
        self.dir(&CString::new(id.to_string()).expect("decimal pid"), op)
    }
    pub fn ids(&self) -> Result<Vec<u32>> {
        let path = format!("/proc/self/fd/{}", self.0.as_raw_fd());
        let mut ids = Vec::new();
        for entry in fs::read_dir(path).map_err(|e| Fault::io("inventory", e))? {
            let entry = entry.map_err(|e| Fault::io("inventory", e))?;
            if let Some(id) = entry
                .file_name()
                .to_str()
                .and_then(|v| v.parse::<u32>().ok())
            {
                ids.push(id);
            }
        }
        ids.sort_unstable();
        Ok(ids)
    }
    pub fn read(
        &self,
        path: &CStr,
        open_op: &'static str,
        read_op: &'static str,
        max: usize,
    ) -> Result<Vec<u8>> {
        let mut f = File::from(self.open(path, 0, open_op)?);
        let mut bytes = Vec::new();
        let result = f
            .by_ref()
            .take(max as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| Fault::io(read_op, e))
            .and_then(|n| {
                if n > max {
                    Err(Fault::new("limit", LIMIT))
                } else {
                    Ok(bytes)
                }
            });
        checked(result, finish(f.into()))
    }
    pub fn thread_membership(&self, pid: u32, tid: u32) -> Result<()> {
        let data = self.read(c"status", "status", "status", 16384)?;
        let field = |prefix: &[u8]| {
            let mut records = data
                .split(|&b| b == b'\n')
                .filter_map(|s| s.strip_prefix(prefix));
            let value = records
                .next()
                .and_then(|s| std::str::from_utf8(s).ok()?.trim().parse::<u32>().ok());
            (records.next().is_none()).then_some(value).flatten()
        };
        if field(b"Tgid:") == Some(pid) && field(b"Pid:") == Some(tid) {
            Ok(())
        } else {
            Err(Fault::new("identity", EIO))
        }
    }
    pub fn row(&self) -> Result<Row> {
        Row::parse(&self.read(c"stat", "stat", "stat", 16384)?)
    }
    pub fn close(self) -> Result<()> {
        finish(self.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Row {
    pub pid: u32,
    pub state: u8,
    pub parent: u32,
    pub group: u32,
    pub session: u32,
    pub start: u64,
    pub flags: u64,
}
impl Row {
    fn parse(bytes: &[u8]) -> Result<Self> {
        let parse = || -> Option<Self> {
            let p = bytes.iter().position(|b| *b == b' ')?;
            let end = bytes.iter().rposition(|b| *b == b')')?;
            if bytes.get(p + 1) != Some(&b'(') || end <= p + 1 {
                return None;
            }
            let pid = std::str::from_utf8(&bytes[..p]).ok()?.parse().ok()?;
            let tail = std::str::from_utf8(bytes.get(end + 1..)?).ok()?;
            let mut f = tail.split_ascii_whitespace();
            let state = f.next()?.as_bytes();
            if state.len() != 1 || !b"RSDTtWXxKPIwZ".contains(&state[0]) {
                return None;
            }
            let parent = f.next()?.parse().ok()?;
            let group = f.next()?.parse().ok()?;
            let session = f.next()?.parse().ok()?;
            let flags = f.nth(2)?.parse().ok()?;
            let _threads: u32 = f.nth(10)?.parse().ok()?;
            let start = f.nth(1)?.parse().ok()?;
            Some(Self {
                pid,
                state: state[0],
                parent,
                group,
                session,
                flags,
                start,
            })
        };
        parse().ok_or_else(|| Fault::new("stat", EIO))
    }
    pub fn zombie(self) -> bool {
        matches!(self.state, b'Z' | b'X' | b'x')
    }
    pub fn exiting(self) -> bool {
        self.flags & 4 != 0
    }
    pub fn json(self) -> String {
        format!(
            "{{\"start\":{},\"state\":\"{}\",\"parent\":{},\"group\":{},\"session\":{}}}",
            self.start, self.state as char, self.parent, self.group, self.session
        )
    }
}
pub struct PidFd(OwnedFd);
impl PidFd {
    pub fn bind(pid: u32, thread: bool) -> Result<Self> {
        // SAFETY: no pointers; the result is a new owned Linux pidfd.
        let fd = rawfd("pidfd_open", unsafe {
            pidfd_open(pid as c_int, if thread { PIDFD_THREAD } else { 0 })
        })?;
        let result = (|| {
            let mut s = Vec::new();
            let mut file = File::open(format!("/proc/self/fdinfo/{}", fd.as_raw_fd()))
                .map_err(|e| Fault::io("fdinfo", e))?;
            let content = file
                .by_ref()
                .take(4097)
                .read_to_end(&mut s)
                .map_err(|e| Fault::io("fdinfo", e));
            checked(content, finish(file.into()))?;
            match fdinfo_pid(&s)? {
                id if id == i64::from(pid) => Ok(()),
                // -1 is exposed after removal from this pid namespace. Readiness
                // alone never authenticates the requested numeric identity.
                -1 if events(fd.as_fd())? != PidEvent::Running => {
                    Err(Fault::new("pidfd_open", ESRCH))
                }
                _ => Err(Fault::new("fdinfo", EIO)),
            }
        })();
        if let Err(e) = result {
            return checked(Err(e), finish(fd));
        }
        Ok(Self(fd))
    }
    pub fn ready(&self) -> Result<bool> {
        Ok(self.event()? != PidEvent::Running)
    }
    pub fn event(&self) -> Result<PidEvent> {
        events(self.0.as_fd())
    }
    pub fn close(self) -> Result<()> {
        finish(self.0)
    }
}
fn fdinfo_pid(bytes: &[u8]) -> Result<i64> {
    let invalid = || Fault::new("fdinfo", EIO);
    if bytes.len() > 4096 || !bytes.ends_with(b"\n") {
        return Err(invalid());
    }
    let text = std::str::from_utf8(bytes).map_err(|_| invalid())?;
    let mut fields = text.lines().filter_map(|s| s.strip_prefix("Pid:"));
    let value = fields.next().and_then(|s| s.trim().parse::<i64>().ok());
    match (value, fields.next()) {
        (Some(id), None) if id == -1 || id > 0 => Ok(id),
        _ => Err(invalid()),
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PidEvent {
    Running,
    Exited,
    HungUp,
}
fn events(fd: BorrowedFd<'_>) -> Result<PidEvent> {
    let mut p = PollFd {
        fd: fd.as_raw_fd(),
        events: 1,
        revents: 0,
    };
    // SAFETY: one writable pollfd, borrowed live fd, zero timeout.
    let n = unsafe { poll(&mut p, 1, 0) };
    if n < 0 {
        return Err(Fault::io("poll", io::Error::last_os_error()));
    }
    poll_result(n, p.revents)
}
fn poll_result(n: i32, mask: i16) -> Result<PidEvent> {
    match (n, mask) {
        (0, 0) => Ok(PidEvent::Running),
        (1, 1) => Ok(PidEvent::Exited),  // POLLIN
        (1, 17) => Ok(PidEvent::HungUp), // POLLIN | POLLHUP
        _ => Err(Fault::new("poll", EIO)),
    }
}
pub fn platform() -> bool {
    fs::read_to_string(Path::new("/etc/os-release")).is_ok_and(|s| {
        let field = |key: &str| {
            s.lines()
                .filter_map(|l| l.strip_prefix(key))
                .next()
                .map(|v| v.trim_matches('"'))
        };
        field("ID=") == Some("fedora") && field("VERSION_ID=") == Some("45")
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fdinfo_refuses_aliases() {
        assert_eq!(fdinfo_pid(b"Pid:\t42\n"), Ok(42));
        assert_eq!(fdinfo_pid(b"Pid: -1\n"), Ok(-1));
        for x in [
            b"Pid: 0\n".as_slice(),
            b"Pid: 42",
            b"Pid: 42\nPid: 42\n",
            b"",
        ] {
            assert_eq!(fdinfo_pid(x).unwrap_err().errno, EIO);
        }
    }
    #[test]
    fn hangup_and_poll_faults_are_not_group_exit() {
        for mask in [0, 4, 8, 9, 16, 32] {
            assert_eq!(poll_result(1, mask).unwrap_err().errno, EIO);
        }
        assert_eq!(poll_result(1, 1), Ok(PidEvent::Exited));
        assert_eq!(poll_result(1, 17), Ok(PidEvent::HungUp));
        assert_eq!(poll_result(0, 0), Ok(PidEvent::Running));
    }
    #[test]
    fn actual_kernel_references() {
        let pid = std::process::id();
        let group = PidFd::bind(pid, false).unwrap();
        let fd = PidFd::bind(pid, true).unwrap();
        assert!(!group.ready().unwrap() && !fd.ready().unwrap());
        group.close().unwrap();
        fd.close().unwrap();
    }
    #[test]
    fn a_thread_becomes_ready_while_its_group_stays_alive() {
        use std::sync::mpsc;
        // SAFETY: gettid takes no argument and returns the calling task's TID.
        unsafe extern "C" {
            fn gettid() -> i32;
        }
        let (announce, tid) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            announce.send(unsafe { gettid() } as u32).unwrap();
            gate.recv().unwrap();
        });
        let tid = tid.recv().unwrap();
        let pid = std::process::id();
        assert_ne!(pid, tid);
        let root = Dir::root().unwrap();
        let task = root
            .id(pid, "group_open")
            .unwrap()
            .dir(c"task", "inventory")
            .unwrap()
            .id(tid, "thread_open")
            .unwrap();
        task.thread_membership(pid, tid).unwrap();
        assert_eq!(task.thread_membership(tid, pid).unwrap_err().errno, EIO);
        let group = PidFd::bind(pid, false).unwrap();
        let thread = PidFd::bind(tid, true).unwrap();
        assert_eq!(thread.ready(), Ok(false));
        release.send(()).unwrap();
        worker.join().unwrap();
        let mut p = PollFd {
            fd: thread.0.as_raw_fd(),
            events: 1,
            revents: 0,
        };
        // SAFETY: one writable pollfd borrowing a live test-owned reference.
        let n = unsafe { poll(&mut p, 1, 3000) };
        assert_ne!(poll_result(n, p.revents).unwrap(), PidEvent::Running);
        assert_eq!(group.ready(), Ok(false));
        thread.close().unwrap();
        group.close().unwrap();
        task.close().unwrap();
        root.close().unwrap();
    }
    #[test]
    fn incomplete_reads_and_denials_are_never_exit_open_gaps() {
        assert!(Fault::new("group_open", ESRCH).vanished());
        assert!(!Fault::new("cmdline_open", EIO).vanished());
    }
    #[test]
    fn first_error_survives_close() {
        let e = Fault::new("environ_read", 13);
        let error = checked::<()>(Err(e.clone()), Err(Fault::new("close", EIO))).unwrap_err();
        assert_eq!((error.errno, error.op), (e.errno, e.op));
        assert!(error.secondary_close);
        assert!(checked(Ok(()), Err(Fault::new("close", EIO))).is_err());
    }
}
