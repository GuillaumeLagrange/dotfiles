//! The handle sources copy through. The Wayland side (`launcher-clipboard`) implements `Sink`
//! and serves what it is given; tests use a recording sink (`crate::testing`).

use std::sync::Arc;

/// What goes on the clipboard: the same content under each MIME type it is offered as.
#[derive(Debug, Clone, PartialEq)]
pub struct Offer {
    pub mimes: Vec<(String, Arc<[u8]>)>,
}

/// The types text is offered as, the first being the one readers prefer.
pub const TEXT_MIMES: [&str; 5] = [
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
];

impl Offer {
    pub fn text(text: &str) -> Offer {
        let bytes: Arc<[u8]> = Arc::from(text.as_bytes());
        Offer {
            mimes: TEXT_MIMES
                .iter()
                .map(|m| (m.to_string(), bytes.clone()))
                .collect(),
        }
    }

    /// The content as text, when one of its types is text.
    pub fn as_text(&self) -> Option<&str> {
        self.mimes
            .iter()
            .find(|(m, _)| TEXT_MIMES.contains(&m.as_str()))
            .and_then(|(_, b)| std::str::from_utf8(b).ok())
    }
}

pub trait Sink: Send + Sync {
    /// Takes the selection and serves `offer` until another client takes it. A secret is
    /// marked so no clipboard manager records it, and cleared after the configured delay.
    fn copy(&self, offer: Offer, secret: bool);
}

#[derive(Clone)]
pub struct Clipboard(Arc<dyn Sink>);

impl Clipboard {
    pub fn new(sink: Arc<dyn Sink>) -> Clipboard {
        Clipboard(sink)
    }

    pub fn copy(&self, offer: Offer, secret: bool) {
        self.0.copy(offer, secret);
    }

    pub fn copy_text(&self, text: &str) {
        self.copy(Offer::text(text), false);
    }

    pub fn copy_secret(&self, text: &str) {
        self.copy(Offer::text(text), true);
    }
}
