//! Icons X11 windows publish themselves, for the windows no desktop entry names.
//!
//! A game started from its launcher under Wine (World of Warcraft from
//! Battle.net) has no entry and no themed icon, but Wine fills `_NET_WM_ICON`
//! from the `.exe`'s icon resource, which is where GNOME and KDE get it too.
//! niri does not pass that on, so the icon is read from the X server
//! (xwayland-satellite's, on `DISPLAY`) and written once as a PNG.

use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{Atom, AtomEnum, ConnectionExt};
use x11rb::rust_connection::RustConnection;

/// A window may set its icon after it maps, so a miss is retried, at most this
/// often.
const RETRY: Duration = Duration::from_secs(2);

type Error = Box<dyn std::error::Error>;

struct Link {
    conn: RustConnection,
    root: u32,
    net_wm_icon: Atom,
    net_wm_name: Atom,
    utf8_string: Atom,
}

impl Link {
    fn open() -> Result<Link, Error> {
        let (conn, screen) = x11rb::connect(None)?;
        let root = conn.setup().roots[screen].root;
        let atom = |name: &[u8]| conn.intern_atom(false, name);
        let (icon, name, utf8) = (
            atom(b"_NET_WM_ICON")?,
            atom(b"_NET_WM_NAME")?,
            atom(b"UTF8_STRING")?,
        );
        Ok(Link {
            net_wm_icon: icon.reply()?.atom,
            net_wm_name: name.reply()?.atom,
            utf8_string: utf8.reply()?.atom,
            conn,
            root,
        })
    }

    /// The largest icon of the first top-level window of this class and title
    /// that has one, as (width, height, ARGB pixels).
    fn icon(&self, class: &str, title: &str) -> Result<Option<Icon>, Error> {
        let conn = &self.conn;
        let windows = conn.query_tree(self.root)?.reply()?.children;
        // Every request goes out before the first reply is read: a few hundred
        // windows cost one round trip, not one each.
        let cookies = windows
            .iter()
            .map(|&w| {
                let class =
                    conn.get_property(false, w, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256)?;
                let name =
                    conn.get_property(false, w, self.net_wm_name, self.utf8_string, 0, 1024)?;
                Ok((w, class, name))
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let mut matching = Vec::new();
        for (w, class_cookie, name_cookie) in cookies {
            let classes = class_cookie.reply()?.value;
            let name = name_cookie.reply()?.value;
            let same_class = classes
                .split(|&b| b == 0)
                .any(|c| c.eq_ignore_ascii_case(class.as_bytes()));
            if same_class && name == title.as_bytes() {
                matching.push(w);
            }
        }
        for w in matching {
            let data = conn
                .get_property(false, w, self.net_wm_icon, AtomEnum::CARDINAL, 0, 1 << 22)?
                .reply()?;
            if let Some(icon) = data.value32().and_then(|v| largest(&v.collect::<Vec<_>>())) {
                return Ok(Some(icon));
            }
        }
        Ok(None)
    }
}

#[derive(Debug, PartialEq)]
struct Icon {
    width: u32,
    height: u32,
    argb: Vec<u32>,
}

/// `_NET_WM_ICON` is a run of `width, height, pixels...` images.
fn largest(data: &[u32]) -> Option<Icon> {
    let mut best: Option<Icon> = None;
    let mut rest = data;
    while let [width, height, tail @ ..] = rest {
        let len = (*width as usize).checked_mul(*height as usize)?;
        if len == 0 || len > tail.len() {
            break;
        }
        if best
            .as_ref()
            .is_none_or(|b| width * height > b.width * b.height)
        {
            best = Some(Icon {
                width: *width,
                height: *height,
                argb: tail[..len].to_vec(),
            });
        }
        rest = &tail[len..];
    }
    best
}

fn encode(icon: &Icon, out: impl std::io::Write) -> Result<(), Error> {
    let mut encoder = png::Encoder::new(out, icon.width, icon.height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let rgba: Vec<u8> = icon
        .argb
        .iter()
        .flat_map(|p| [(p >> 16) as u8, (p >> 8) as u8, *p as u8, (p >> 24) as u8])
        .collect();
    encoder.write_header()?.write_image_data(&rgba)?;
    Ok(())
}

#[derive(Default)]
pub struct XIcons {
    /// Where the PNGs go; empty disables the lookup.
    dir: PathBuf,
    link: Option<Link>,
    /// Whether a pid is xwayland-satellite's, the pid niri reports for every
    /// X11 window.
    x_pids: BTreeMap<u32, bool>,
    found: BTreeMap<(String, String), String>,
    tried: BTreeMap<(String, String), Instant>,
}

impl XIcons {
    pub fn new(dir: PathBuf) -> XIcons {
        XIcons {
            dir,
            ..XIcons::default()
        }
    }

    /// PNG of the icon an X11 window of this class and title publishes, or an
    /// empty string.
    pub fn path_for(&mut self, pid: u32, class: &str, title: &str) -> String {
        if self.dir.as_os_str().is_empty() || !self.is_x(pid) {
            return String::new();
        }
        let key = (class.to_string(), title.to_string());
        if let Some(path) = self.found.get(&key) {
            return path.clone();
        }
        self.tried.retain(|_, at| at.elapsed() < RETRY);
        if self.tried.contains_key(&key) {
            return String::new();
        }
        self.tried.insert(key.clone(), Instant::now());
        match self.fetch(class, title) {
            Ok(Some(path)) => {
                self.found.insert(key, path.clone());
                path
            }
            Ok(None) => String::new(),
            Err(_) => {
                // Reconnect next time: the X server may have restarted.
                self.link = None;
                String::new()
            }
        }
    }

    fn is_x(&mut self, pid: u32) -> bool {
        *self.x_pids.entry(pid).or_insert_with(|| {
            // The nix wrapper renames the binary `.xwayland-satellite-wrapped`,
            // and comm keeps 15 bytes of it.
            std::fs::read_to_string(format!("/proc/{pid}/comm"))
                .is_ok_and(|comm| comm.contains("xwayland-sate"))
        })
    }

    fn fetch(&mut self, class: &str, title: &str) -> Result<Option<String>, Error> {
        if self.link.is_none() {
            self.link = Some(Link::open()?);
        }
        let Some(icon) = self.link.as_ref().unwrap().icon(class, title)? else {
            return Ok(None);
        };
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (icon.width, icon.height, &icon.argb).hash(&mut hasher);
        let path = self.dir.join(format!("{:016x}.png", hasher.finish()));
        if !path.exists() {
            std::fs::create_dir_all(&self.dir)?;
            let tmp = path.with_extension("tmp");
            encode(&icon, std::io::BufWriter::new(std::fs::File::create(&tmp)?))?;
            std::fs::rename(&tmp, &path)?;
        }
        Ok(path.to_str().map(str::to_string))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_largest_image_wins_and_a_truncated_one_ends_the_list() {
        let mut data = vec![1, 1, 0xff00_0000];
        data.extend([2, 2, 1, 2, 3, 4]);
        data.extend([1, 2, 9]);
        assert_eq!(
            largest(&data),
            Some(Icon {
                width: 2,
                height: 2,
                argb: vec![1, 2, 3, 4]
            })
        );
        assert_eq!(largest(&[4, 4, 0]), None);
    }

    #[test]
    fn pixels_are_written_as_straight_rgba() {
        let icon = Icon {
            width: 2,
            height: 1,
            argb: vec![0x80ff_0000, 0xff00_80ff],
        };
        let mut png_bytes = Vec::new();
        encode(&icon, &mut png_bytes).unwrap();
        let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes))
            .read_info()
            .unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        reader.next_frame(&mut buf).unwrap();
        assert_eq!(buf, [0xff, 0, 0, 0x80, 0, 0x80, 0xff, 0xff]);
    }
}
