//! The selection through `ext-data-control-v1`: watching what other clients copy and serving
//! what the daemon copies.

use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use launcher_core::clipboard::{Offer, Sink, TEXT_MIMES};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat::WlSeat};
use wayland_client::{event_created_child, Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_device_v1::{
    self, ExtDataControlDeviceV1,
};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_manager_v1::ExtDataControlManagerV1;
use wayland_protocols::ext::data_control::v1::client::ext_data_control_offer_v1::{
    self, ExtDataControlOfferV1,
};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_source_v1::{
    self, ExtDataControlSourceV1,
};

use crate::history::History;
use crate::pipe;
use crate::store::{Content, IMAGE_MIMES, URI_LIST};

/// Offered with everything the daemon copies, so its watcher skips its own selections.
pub const MARKER: &str = "application/x-launcher-origin";
/// What password managers mark their copies with; no clipboard manager records them.
pub const PASSWORD_HINT: &str = "x-kde-passwordManagerHint";

pub struct Limits {
    pub max_text_bytes: usize,
    pub max_image_bytes: usize,
    pub secret_clear: Duration,
}

/// The daemon's end of the selection. Copies go straight to the compositor from the calling
/// thread; the event loop thread answers transfers.
pub struct Wayland {
    conn: Connection,
    qh: QueueHandle<State>,
    manager: ExtDataControlManagerV1,
    device: ExtDataControlDeviceV1,
    /// The source the daemon serves the selection from, with its generation.
    active: Mutex<Option<(u64, ExtDataControlSourceV1)>>,
    next: AtomicU64,
    history: Option<Arc<History>>,
    limits: Limits,
    /// False only for the test client playing another application.
    mark: bool,
}

struct Served {
    generation: u64,
    mimes: HashMap<String, Arc<[u8]>>,
}

struct State {
    wayland: Option<Arc<Wayland>>,
    reader: Option<Sender<(ExtDataControlOfferV1, Vec<String>)>>,
    finished: bool,
}

/// Connects to the compositor's socket and runs the event loop on its own thread. With a
/// history, other clients' selections are recorded in it. Losing the connection is sent on
/// `lost`: the daemon exits then, to be restarted against the compositor.
pub fn connect(
    socket: &Path,
    history: Option<Arc<History>>,
    limits: Limits,
    mark: bool,
    lost: Option<Sender<String>>,
) -> Result<Arc<Wayland>> {
    let stream = UnixStream::connect(socket)
        .with_context(|| format!("connecting to {}", socket.display()))?;
    let conn = Connection::from_socket(stream)?;
    let (globals, mut queue) =
        registry_queue_init::<State>(&conn).context("listing Wayland globals")?;
    let qh = queue.handle();
    let manager: ExtDataControlManagerV1 = globals
        .bind(&qh, 1..=1, ())
        .context("the compositor does not offer ext_data_control_manager_v1")?;
    let seat: WlSeat = globals.bind(&qh, 1..=1, ()).context("no wl_seat")?;
    let device = manager.get_data_device(&seat, &qh, ());
    let wayland = Arc::new(Wayland {
        conn: conn.clone(),
        qh,
        manager,
        device,
        active: Mutex::new(None),
        next: AtomicU64::new(0),
        history,
        limits,
        mark,
    });
    let reader = wayland.history.is_some().then(|| {
        let (tx, rx) = mpsc::channel::<(ExtDataControlOfferV1, Vec<String>)>();
        let w = wayland.clone();
        std::thread::Builder::new()
            .name("clipboard-read".into())
            .spawn(move || {
                for (offer, mimes) in rx {
                    w.record(&offer, &mimes);
                    offer.destroy();
                }
            })
            .expect("spawning the clipboard reader");
        tx
    });
    let mut state = State {
        wayland: Some(wayland.clone()),
        reader,
        finished: false,
    };
    queue.roundtrip(&mut state).context("Wayland roundtrip")?;
    std::thread::Builder::new()
        .name("clipboard-wayland".into())
        .spawn(move || {
            while !state.finished {
                if let Err(err) = queue.blocking_dispatch(&mut state) {
                    if let Some(lost) = &lost {
                        let _ = lost.send(format!("clipboard connection lost: {err}"));
                    }
                    break;
                }
            }
            // Ends the reader.
            drop(state);
        })
        .context("spawning the Wayland thread")?;
    Ok(wayland)
}

impl Wayland {
    /// Reads the offer as the content it is worth keeping, and records it.
    fn record(&self, offer: &ExtDataControlOfferV1, mimes: &[String]) {
        let Some(history) = &self.history else { return };
        if mimes.iter().any(|m| m == MARKER || m == PASSWORD_HINT) {
            return;
        }
        let has = |m: &str| mimes.iter().any(|x| x == m);
        let text_mime = TEXT_MIMES.iter().copied().find(|m| has(m));
        let content = if text_mime.is_some() || has(URI_LIST) {
            let max = self.limits.max_text_bytes;
            let read_text = |m: &str| {
                self.read(offer, m, max)
                    .and_then(|b| String::from_utf8(b).ok())
            };
            let text = text_mime.and_then(read_text);
            let uri_list = if has(URI_LIST) {
                read_text(URI_LIST)
            } else {
                None
            };
            match text.or_else(|| uri_list.clone()) {
                Some(text) => Content::Text { text, uri_list },
                None => return,
            }
        } else if let Some(mime) = IMAGE_MIMES.iter().copied().find(|m| has(m)) {
            match self.read(offer, mime, self.limits.max_image_bytes) {
                Some(bytes) => Content::Image {
                    mime: mime.to_owned(),
                    bytes,
                },
                None => return,
            }
        } else {
            return;
        };
        history.add(content);
    }

    fn read(&self, offer: &ExtDataControlOfferV1, mime: &str, max: usize) -> Option<Vec<u8>> {
        let (r, w) = rustix::pipe::pipe_with(rustix::pipe::PipeFlags::CLOEXEC).ok()?;
        offer.receive(mime.to_owned(), std::os::fd::AsFd::as_fd(&w));
        self.conn.flush().ok()?;
        drop(w);
        match pipe::read_capped(r, max, pipe::TIMEOUT) {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!("launcher: reading the clipboard as {mime}: {err}");
                None
            }
        }
    }

    fn serve(self: &Arc<Self>, offer: Offer, secret: bool) -> Result<()> {
        let generation = self.next.fetch_add(1, Ordering::Relaxed);
        let mut mimes: HashMap<String, Arc<[u8]>> = offer.mimes.into_iter().collect();
        if self.mark {
            mimes.insert(MARKER.into(), Arc::from(&b"1"[..]));
        }
        if secret {
            mimes.insert(PASSWORD_HINT.into(), Arc::from(&b"secret"[..]));
        }
        let names: Vec<String> = mimes.keys().cloned().collect();
        let source = self
            .manager
            .create_data_source(&self.qh, Arc::new(Served { generation, mimes }));
        for name in names {
            source.offer(name);
        }
        {
            let mut active = self.active.lock().unwrap();
            self.device.set_selection(Some(&source));
            *active = Some((generation, source));
        }
        self.conn.flush()?;
        if secret {
            let this = self.clone();
            let delay = self.limits.secret_clear;
            std::thread::spawn(move || {
                std::thread::sleep(delay);
                this.clear_if(generation);
            });
        }
        Ok(())
    }

    /// Clears the selection if it is still the one `generation` set.
    fn clear_if(&self, generation: u64) {
        let mut active = self.active.lock().unwrap();
        if let Some((g, source)) = active.take_if(|(g, _)| *g == generation) {
            debug_assert_eq!(g, generation);
            self.device.set_selection(None);
            source.destroy();
            let _ = self.conn.flush();
        }
    }
}

/// The sink sources copy through.
pub struct WaylandSink(pub Arc<Wayland>);

impl Sink for WaylandSink {
    fn copy(&self, offer: Offer, secret: bool) {
        if !secret {
            if let (Some(history), Some(content)) = (&self.0.history, Content::from_offer(&offer)) {
                history.add(content);
            }
        }
        if let Err(err) = self.0.serve(offer, secret) {
            eprintln!("launcher: setting the clipboard: {err:#}");
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlSeat, ()> for State {
    fn event(
        _: &mut Self,
        _: &WlSeat,
        _: <WlSeat as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtDataControlManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ExtDataControlManagerV1,
        _: <ExtDataControlManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

type OfferMimes = Mutex<Vec<String>>;

impl Dispatch<ExtDataControlDeviceV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &ExtDataControlDeviceV1,
        event: ext_data_control_device_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_device_v1::Event::Selection { id: Some(offer) } => {
                let mimes = offer
                    .data::<OfferMimes>()
                    .map(|m| m.lock().unwrap().clone())
                    .unwrap_or_default();
                match &state.reader {
                    Some(reader) => {
                        if let Err(mpsc::SendError((offer, _))) = reader.send((offer, mimes)) {
                            offer.destroy();
                        }
                    }
                    None => offer.destroy(),
                }
            }
            ext_data_control_device_v1::Event::PrimarySelection { id: Some(offer) } => {
                offer.destroy()
            }
            ext_data_control_device_v1::Event::Finished => {
                eprintln!("launcher: the compositor ended the clipboard device");
                state.finished = true;
            }
            _ => {}
        }
    }

    event_created_child!(State, ExtDataControlDeviceV1, [
        ext_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ExtDataControlOfferV1, OfferMimes::default()),
    ]);
}

impl Dispatch<ExtDataControlOfferV1, OfferMimes> for State {
    fn event(
        _: &mut Self,
        _: &ExtDataControlOfferV1,
        event: ext_data_control_offer_v1::Event,
        mimes: &OfferMimes,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            mimes.lock().unwrap().push(mime_type);
        }
    }
}

impl Dispatch<ExtDataControlSourceV1, Arc<Served>> for State {
    fn event(
        state: &mut Self,
        source: &ExtDataControlSourceV1,
        event: ext_data_control_source_v1::Event,
        served: &Arc<Served>,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_source_v1::Event::Send { mime_type, fd } => {
                let Some(bytes) = served.mimes.get(&mime_type).cloned() else {
                    return;
                };
                std::thread::spawn(move || {
                    if let Err(err) = pipe::write_all(fd, &bytes, pipe::TIMEOUT) {
                        eprintln!("launcher: serving the clipboard as {mime_type}: {err}");
                    }
                });
            }
            ext_data_control_source_v1::Event::Cancelled => {
                if let Some(wayland) = &state.wayland {
                    let mut active = wayland.active.lock().unwrap();
                    active.take_if(|(g, _)| *g == served.generation);
                }
                source.destroy();
            }
            _ => {}
        }
    }
}
