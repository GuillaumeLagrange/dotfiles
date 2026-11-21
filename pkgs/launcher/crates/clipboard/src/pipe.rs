//! Reading and writing the pipes of a transfer without waiting forever on the other end.

use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::time::{Duration, Instant};

use rustix::event::{poll, PollFd, PollFlags, Timespec};
use rustix::fs::{fcntl_getfl, fcntl_setfl, OFlags};

pub const TIMEOUT: Duration = Duration::from_secs(5);

fn nonblocking(fd: &OwnedFd) -> io::Result<()> {
    let flags = fcntl_getfl(fd)?;
    fcntl_setfl(fd, flags | OFlags::NONBLOCK)?;
    Ok(())
}

/// Waits for `flags` on `fd` until `deadline`.
fn wait(fd: &OwnedFd, flags: PollFlags, deadline: Instant) -> io::Result<()> {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let timeout = Timespec {
            tv_sec: left.as_secs() as _,
            tv_nsec: left.subsec_nanos() as _,
        };
        let mut fds = [PollFd::new(fd, flags)];
        match poll(&mut fds, Some(&timeout)) {
            Ok(0) => {}
            Ok(_) => return Ok(()),
            Err(rustix::io::Errno::INTR) => {}
            Err(err) => return Err(err.into()),
        }
    }
}

/// Reads to end of file. None when there is more than `max` bytes.
pub fn read_capped(fd: OwnedFd, max: usize, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
    nonblocking(&fd)?;
    let deadline = Instant::now() + timeout;
    let mut out = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match rustix::io::read(fd.as_fd(), &mut buf) {
            Ok(0) => return Ok(Some(out)),
            Ok(n) => {
                if out.len() + n > max {
                    return Ok(None);
                }
                out.extend_from_slice(&buf[..n]);
            }
            Err(rustix::io::Errno::AGAIN) => wait(&fd, PollFlags::IN, deadline)?,
            Err(rustix::io::Errno::INTR) => {}
            Err(err) => return Err(err.into()),
        }
    }
}

pub fn write_all(fd: OwnedFd, mut data: &[u8], timeout: Duration) -> io::Result<()> {
    nonblocking(&fd)?;
    let deadline = Instant::now() + timeout;
    while !data.is_empty() {
        match rustix::io::write(fd.as_fd(), data) {
            Ok(n) => data = &data[n..],
            Err(rustix::io::Errno::AGAIN) => wait(&fd, PollFlags::OUT, deadline)?,
            Err(rustix::io::Errno::INTR) => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_caps_and_times_out() {
        let (r, w) = rustix::pipe::pipe().unwrap();
        std::thread::spawn(move || write_all(w, b"hello", TIMEOUT).unwrap());
        assert_eq!(
            read_capped(r, 5, TIMEOUT).unwrap().as_deref(),
            Some(&b"hello"[..])
        );

        let (r, w) = rustix::pipe::pipe().unwrap();
        std::thread::spawn(move || write_all(w, b"hello!", TIMEOUT).unwrap());
        assert_eq!(read_capped(r, 5, TIMEOUT).unwrap(), None);

        let (r, _w) = rustix::pipe::pipe().unwrap();
        let err = read_capped(r, 5, Duration::from_millis(50)).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
    }
}
