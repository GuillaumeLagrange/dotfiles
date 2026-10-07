//! Kitty graphics through direct placements. ratatui-image only places kitty
//! images with unicode placeholders (`U=1`), which zellij rejects
//! (zellij-org/zellij#5530); a placement at the cursor works in both.

use std::io::{self, Write};

use base64::Engine;
use image::RgbaImage;

/// Responses would arrive as key events.
const QUIET: &str = "q=2";

pub fn upload(out: &mut impl Write, id: u32, image: &RgbaImage) -> io::Result<()> {
    let data = base64::engine::general_purpose::STANDARD.encode(image.as_raw());
    let chunks: Vec<&[u8]> = data.as_bytes().chunks(4096).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        if i == 0 {
            let (w, h) = image.dimensions();
            write!(out, "\x1b_Ga=t,i={id},f=32,s={w},v={h},{QUIET},m={more};")?;
        } else {
            write!(out, "\x1b_Gm={more};")?;
        }
        out.write_all(chunk)?;
        out.write_all(b"\x1b\\")?;
    }
    Ok(())
}

/// Show image `id` over `cols`×`rows` cells from (`x`, `y`), leaving the
/// cursor where it was.
pub fn place(
    out: &mut impl Write,
    id: u32,
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
) -> io::Result<()> {
    write!(
        out,
        "\x1b[{};{}H\x1b_Ga=p,i={id},c={cols},r={rows},C=1,{QUIET}\x1b\\",
        y + 1,
        x + 1
    )
}

/// Remove every placement, keeping the uploaded images.
pub fn clear(out: &mut impl Write) -> io::Result<()> {
    write!(out, "\x1b_Ga=d,d=a,{QUIET}\x1b\\")
}

/// Remove the placements and free the images.
pub fn forget(out: &mut impl Write) -> io::Result<()> {
    write!(out, "\x1b_Ga=d,d=A,{QUIET}\x1b\\")
}
