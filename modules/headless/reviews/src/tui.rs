//! The picker: pull requests awaiting my review, newest activity first, the
//! selected one's description below, Enter to check it out.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::io::{self, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::Result;
use image::{DynamicImage, Rgba, RgbaImage};
use ratatui::crossterm::event::{
    self, Event, KeyCode, KeyEventKind, KeyModifiers, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::execute;
use ratatui::layout::{Constraint, Layout, Rect, Size};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph, Wrap};
use ratatui::{DefaultTerminal, Frame};
use ratatui_image::picker::{Picker, ProtocolType};
use ratatui_image::protocol::Protocol;
use ratatui_image::{FilterType, Image, Resize};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::github::{self, Cache, Checks, Decision, Pr, Snapshot, State};
use crate::kitty;

const ACCENT: Color = Color::Blue;
const DIM: Style = Style::new().fg(Color::DarkGray);
/// Cells an avatar takes, inline before the author's login.
const AVATAR: Size = Size::new(2, 1);
/// Widest the picker gets: past it, centered.
const MAX_WIDTH: u16 = 100;

enum Msg {
    Prs(Result<Vec<Pr>, String>),
    Avatar(String, DynamicImage),
}

enum Avatar {
    /// Uploaded under this id, placed after each frame.
    Kitty(u32),
    /// Drawn into the cells by ratatui-image: sixel, halfblocks.
    Cells(Protocol),
}

fn age(at: u64, now: u64) -> String {
    let secs = now.saturating_sub(at);
    match secs {
        0..60 => "now".to_owned(),
        60..3600 => format!("{}m", secs / 60),
        3600..86400 => format!("{}h", secs / 3600),
        86400..604800 => format!("{}d", secs / 86400),
        604800..2592000 => format!("{}w", secs / 604800),
        2592000..31536000 => format!("{}mo", secs / 2592000),
        _ => format!("{}y", secs / 31536000),
    }
}

/// `text` cut to `width` columns, with an ellipsis when something was cut.
fn truncate(text: &str, width: usize) -> String {
    if text.width() <= width {
        return text.to_owned();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = c.width().unwrap_or(0);
        if used + w + 1 > width {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('…');
    out
}

fn checks_span(checks: Option<Checks>) -> Span<'static> {
    match checks {
        Some(Checks::Success) => Span::styled("✓", Style::new().fg(Color::Green)),
        Some(Checks::Failure) => Span::styled("✗", Style::new().fg(Color::Red)),
        Some(Checks::Pending) => Span::styled("◐", Style::new().fg(Color::Yellow)),
        None => Span::raw(" "),
    }
}

fn decision_span(decision: Option<Decision>) -> Option<Span<'static>> {
    match decision? {
        Decision::Approved => Some(Span::styled("approved", Style::new().fg(Color::Green))),
        Decision::ChangesRequested => Some(Span::styled(
            "changes requested",
            Style::new().fg(Color::Red),
        )),
        Decision::ReviewRequired => None,
    }
}

/// Frame of a spinner turning with the clock; the event loop redraws every 100ms.
fn spinner() -> char {
    const FRAMES: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    FRAMES[(ms / 100 % FRAMES.len() as u128) as usize]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Place {
    Alone,
    Child { last: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Row {
    /// Heads a stack; `pr` is one of its members, for the stack's details.
    Stack {
        pr: usize,
    },
    Pr {
        pr: usize,
        place: Place,
    },
}

/// `shown` (indices into `prs`) with each GitHub stack gathered under a
/// heading at the place of its first member, top of the stack first. A stack
/// with nothing requested shown is dropped.
fn stacks(prs: &[Pr], shown: Vec<usize>) -> Vec<Row> {
    let key = |i: usize| {
        prs[i]
            .stack
            .as_ref()
            .map(|s| (prs[i].repo_full.as_str(), s.number))
    };
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for i in shown {
        match groups
            .iter_mut()
            .find(|g| key(i).is_some() && key(g[0]) == key(i))
        {
            Some(members) => members.push(i),
            None => groups.push(vec![i]),
        }
    }
    let mut rows = Vec::new();
    for mut members in groups {
        if !members.iter().any(|&i| prs[i].requested) {
            continue;
        }
        if key(members[0]).is_none() {
            rows.push(Row::Pr {
                pr: members[0],
                place: Place::Alone,
            });
            continue;
        }
        members.sort_by_key(|&i| std::cmp::Reverse(prs[i].stack.as_ref().map(|s| s.position)));
        rows.push(Row::Stack { pr: members[0] });
        let n = members.len();
        rows.extend(members.into_iter().enumerate().map(|(k, pr)| Row::Pr {
            pr,
            place: Place::Child { last: k + 1 == n },
        }));
    }
    rows
}

struct App {
    prs: Vec<Pr>,
    fetched_at: Option<u64>,
    refreshing: bool,
    error: Option<String>,
    filter: String,
    filtering: bool,
    /// Kept by URL so a refresh that reorders the list does not move it.
    selected: Option<String>,
    picker: Picker,
    avatars: HashMap<String, Avatar>,
    /// Kitty placements the last frame asked for, and those on screen.
    wanted: RefCell<Vec<(u32, Rect)>>,
    placed: Vec<(u32, Rect)>,
    /// First item drawn in the list, kept between frames so moving the
    /// selection only scrolls when it leaves the window.
    offset: Cell<usize>,
    scroll: Cell<u16>,
    page: Cell<u16>,
}

impl App {
    fn visible(&self) -> Vec<Row> {
        let filter = self.filter.to_lowercase();
        let terms: Vec<&str> = filter.split_whitespace().collect();
        let shown = self
            .prs
            .iter()
            .enumerate()
            .filter(|(_, pr)| {
                let hay = format!(
                    "{} {}#{} {} {}",
                    pr.title, pr.repo, pr.number, pr.author, pr.branch
                )
                .to_lowercase();
                terms.iter().all(|t| hay.contains(t))
            })
            .map(|(i, _)| i)
            .collect();
        stacks(&self.prs, shown)
    }

    /// Rows that take the selection: open pull requests.
    fn selectable(&self, row: &Row) -> bool {
        matches!(row, Row::Pr { pr, .. } if self.prs[*pr].state == State::Open)
    }

    fn position(&self, visible: &[Row]) -> Option<usize> {
        let url = self.selected.as_ref()?;
        visible.iter().position(|row| {
            self.selectable(row) && matches!(row, Row::Pr { pr, .. } if &self.prs[*pr].url == url)
        })
    }

    /// Keep the selection on something shown.
    fn settle(&mut self) {
        let visible = self.visible();
        if self.position(&visible).is_none() {
            self.selected = visible.iter().find_map(|row| match row {
                Row::Pr { pr, .. } if self.selectable(row) => Some(self.prs[*pr].url.clone()),
                _ => None,
            });
            self.scroll.set(0);
        }
    }

    fn step(&mut self, delta: isize) {
        let visible = self.visible();
        let choices: Vec<usize> = visible
            .iter()
            .filter(|row| self.selectable(row))
            .filter_map(|row| match row {
                Row::Pr { pr, .. } => Some(*pr),
                Row::Stack { .. } => None,
            })
            .collect();
        if choices.is_empty() {
            return;
        }
        let at = self
            .selected
            .as_ref()
            .and_then(|url| choices.iter().position(|&i| &self.prs[i].url == url))
            .unwrap_or(0) as isize;
        let next = (at + delta).clamp(0, choices.len() as isize - 1) as usize;
        let url = self.prs[choices[next]].url.clone();
        if self.selected.as_ref() != Some(&url) {
            self.scroll.set(0);
        }
        self.selected = Some(url);
    }

    fn scroll_by(&self, halves: i32) {
        let step = i32::from(self.page.get() / 2).max(1) * halves;
        let next = (i32::from(self.scroll.get()) + step).clamp(0, i32::from(u16::MAX));
        self.scroll.set(next as u16);
    }

    fn selected_pr(&self) -> Option<&Pr> {
        let url = self.selected.as_ref()?;
        self.prs.iter().find(|pr| &pr.url == url)
    }

    fn add_avatar(&mut self, login: String, image: DynamicImage) -> io::Result<()> {
        let font = self.picker.font_size();
        let pixels = round(
            &image,
            u32::from(AVATAR.width * font.width),
            u32::from(AVATAR.height * font.height),
        );
        if self.picker.protocol_type() != ProtocolType::Kitty {
            let resize = Resize::Scale(Some(FilterType::Triangle));
            let image = DynamicImage::ImageRgba8(pixels);
            if let Ok(protocol) = self.picker.new_protocol(image, AVATAR, resize) {
                self.avatars.insert(login, Avatar::Cells(protocol));
            }
            return Ok(());
        }
        // Ids from the pid, so another program in the window keeps its own.
        let next =
            (std::process::id().wrapping_mul(1000)).wrapping_add(self.avatars.len() as u32 + 1);
        let id = match self.avatars.get(&login) {
            Some(Avatar::Kitty(id)) => *id,
            _ => next,
        };
        let mut out = io::stdout().lock();
        kitty::upload(&mut out, id, &pixels)?;
        out.flush()?;
        self.avatars.insert(login, Avatar::Kitty(id));
        // A replaced image is shown again by placing it anew.
        self.placed.clear();
        Ok(())
    }

    /// Bring the kitty placements in line with the frame just drawn.
    fn place_avatars(&mut self) -> io::Result<()> {
        let wanted = self.wanted.take();
        if wanted == self.placed {
            return Ok(());
        }
        let mut out = io::stdout().lock();
        kitty::clear(&mut out)?;
        for &(id, area) in &wanted {
            kitty::place(&mut out, id, area.x, area.y, area.width, area.height)?;
        }
        out.flush()?;
        self.placed = wanted;
        Ok(())
    }

    fn status(&self, now: u64) -> Line<'static> {
        if let Some(err) = &self.error {
            return Line::styled(
                format!(" {} ", truncate(err, 60)),
                Style::new().fg(Color::Red),
            );
        }
        let shown = match self.fetched_at {
            Some(at) if now.saturating_sub(at) < 60 => "updated just now".to_owned(),
            Some(at) => format!("updated {} ago", age(at, now)),
            None => String::new(),
        };
        if !self.refreshing {
            return Line::styled(format!(" {shown} "), DIM);
        }
        let mut line = Line::from(Span::styled(
            format!(" {} fetching ", spinner()),
            Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ));
        if !shown.is_empty() {
            line.push_span(Span::styled(format!("· {shown} "), DIM));
        }
        line
    }
    fn draw(&self, frame: &mut Frame) {
        let now = github::now();
        let visible = self.visible();
        let full = frame.area();
        let width = full.width.min(MAX_WIDTH);
        let area = Rect::new(
            full.x + (full.width - width) / 2,
            full.y,
            width,
            full.height,
        );
        // The list only as tall as its items, up to 60%: the description below
        // is what there is to read.
        let list_height = (2 * visible.len().max(1) as u16 + 2).min(area.height * 3 / 5);
        let [list_area, detail_area, help_area] = Layout::vertical([
            Constraint::Length(list_height),
            Constraint::Min(4),
            Constraint::Length(1),
        ])
        .areas(area);
        let boxed = |title: Line<'static>| {
            Block::bordered()
                .border_type(BorderType::Rounded)
                .border_style(DIM)
                .title_style(Style::new().fg(Color::Reset))
                .title(title)
        };

        let requested = visible
            .iter()
            .filter(|row| matches!(row, Row::Pr { pr, .. } if self.prs[*pr].requested))
            .count();
        let list_block = boxed(Line::styled(
            format!(" needs your review · {requested} "),
            Style::new().add_modifier(Modifier::BOLD),
        ))
        .title(self.status(now).right_aligned());
        let inner = list_block.inner(list_area);
        frame.render_widget(list_block, list_area);
        if visible.is_empty() {
            let text = match (
                self.prs.is_empty(),
                self.refreshing || self.fetched_at.is_none(),
            ) {
                (true, true) => format!("{} Loading…", spinner()),
                (true, false) => "Nothing awaits your review.".to_owned(),
                (false, _) => "No pull request matches the filter.".to_owned(),
            };
            frame.render_widget(Paragraph::new(text).style(DIM), inner);
        } else {
            self.draw_list(frame, inner, &visible, now);
        }

        if let Some(pr) = self.selected_pr() {
            self.draw_detail(frame, detail_area, pr, &boxed);
        }

        let help = if self.filtering || !self.filter.is_empty() {
            Line::from(vec![
                Span::styled("/", Style::new().fg(ACCENT)),
                Span::raw(self.filter.clone()),
                Span::styled(
                    if self.filtering {
                        "▏ enter keep · esc clear"
                    } else {
                        "  esc clear"
                    },
                    DIM,
                ),
            ])
        } else {
            Line::styled(
                "enter checkout · shift+enter open · / filter · r refresh · j/k move · ^d/^u scroll · q quit",
                DIM,
            )
        };
        frame.render_widget(Paragraph::new(help), help_area);
    }

    fn draw_list(&self, frame: &mut Frame, area: Rect, visible: &[Row], now: u64) {
        let fit = usize::from(area.height / 2).max(1);
        let selected = self.position(visible);
        let at = selected.unwrap_or(0);
        let mut offset = self.offset.get().min(visible.len().saturating_sub(fit));
        if at < offset {
            offset = at;
            // with the heading and merged rows above it, when they fit
            while offset > 0 && !self.selectable(&visible[offset - 1]) && at - offset + 1 < fit {
                offset -= 1;
            }
        } else if at >= offset + fit {
            offset = at + 1 - fit;
        }
        self.offset.set(offset);

        for (line, row) in visible.iter().skip(offset).take(fit).enumerate() {
            let item = Rect::new(area.x, area.y + 2 * line as u16, area.width, 2);
            match *row {
                Row::Stack { pr } => self.draw_stack(frame, item, &self.prs[pr]),
                Row::Pr { pr, place } => {
                    let is_selected = selected == Some(line + offset);
                    self.draw_pr(frame, item, &self.prs[pr], place, is_selected, now)
                }
            }
        }
    }

    fn draw_stack(&self, frame: &mut Frame, item: Rect, member: &Pr) {
        let Some(stack) = &member.stack else {
            return;
        };
        let [lead, text] =
            Layout::horizontal([Constraint::Length(4), Constraint::Min(1)]).areas(item);
        frame.render_widget(
            Paragraph::new(vec![
                Line::styled("  ≡ ", Style::new().fg(Color::Magenta)),
                Line::styled("  │ ", DIM),
            ]),
            lead,
        );
        frame.render_widget(
            Paragraph::new(vec![
                Line::styled(
                    format!("Stack of {}", stack.size),
                    Style::new().add_modifier(Modifier::BOLD),
                ),
                Line::styled(format!("{} → {}", member.repo, stack.base), DIM),
            ]),
            text,
        );
    }

    fn draw_pr(
        &self,
        frame: &mut Frame,
        item: Rect,
        pr: &Pr,
        place: Place,
        selected: bool,
        now: u64,
    ) {
        let open = pr.state == State::Open;
        let lead_width = if place == Place::Alone { 4 } else { 6 };
        // bar, tree and icon, text, gap, age/checks
        let [lead, text, _, meta] = Layout::horizontal([
            Constraint::Length(lead_width),
            Constraint::Min(1),
            Constraint::Length(1),
            Constraint::Length(4),
        ])
        .areas(item);

        let bar = if selected {
            Span::styled("▌ ", Style::new().fg(ACCENT))
        } else {
            Span::raw("  ")
        };
        // GitHub's colors: merged purple, closed red
        let state_style = match pr.state {
            State::Open => Style::new().fg(Color::Green),
            State::Merged => Style::new().fg(Color::Magenta),
            State::Closed => Style::new().fg(Color::Red),
        };
        let icon = if pr.draft && open {
            Span::styled("◌ ", DIM)
        } else {
            Span::styled("⇅ ", state_style)
        };
        let (top, bottom) = match place {
            Place::Alone => ("", ""),
            Place::Child { last: false } => ("├╴", "│   "),
            Place::Child { last: true } => ("╰╴", "    "),
        };
        frame.render_widget(
            Paragraph::new(vec![
                Line::from(vec![bar.clone(), Span::styled(top, DIM), icon]),
                Line::from(vec![bar, Span::styled(bottom, DIM)]),
            ]),
            lead,
        );

        let mut title_style = Style::new();
        if pr.requested {
            title_style = title_style.add_modifier(Modifier::BOLD);
        }
        if !open {
            // faint, not gray: still readable
            title_style = title_style.add_modifier(Modifier::DIM);
        }
        if selected {
            title_style = title_style.fg(ACCENT);
        }
        let width = usize::from(text.width);
        let repo = format!("{}#{}  ", pr.repo, pr.number);
        let avatar = self.avatars.get(&pr.author).and_then(|a| {
            let x = text.x + repo.width() as u16;
            (x + AVATAR.width < text.right())
                .then(|| (a, Rect::new(x, text.y + 1, AVATAR.width, AVATAR.height)))
        });
        let mut sub = vec![Span::styled(repo, DIM)];
        if avatar.is_some() {
            sub.push(Span::raw(" ".repeat(usize::from(AVATAR.width) + 1)));
        }
        sub.push(Span::styled(pr.author.clone(), DIM));
        if let Some(decision) = decision_span(pr.decision).filter(|_| open) {
            sub.push(Span::raw("  "));
            sub.push(decision);
        }
        match pr.state {
            State::Merged => sub.push(Span::styled("  merged", state_style)),
            State::Closed => sub.push(Span::styled("  closed", state_style)),
            State::Open if !pr.requested => sub.push(Span::styled(
                "  not requested",
                DIM.add_modifier(Modifier::ITALIC),
            )),
            State::Open => {}
        }
        frame.render_widget(
            Paragraph::new(vec![
                Line::styled(truncate(&pr.title, width.saturating_sub(1)), title_style),
                Line::from(sub),
            ]),
            text,
        );

        match avatar {
            Some((Avatar::Cells(protocol), slot)) => {
                frame.render_widget(Image::new(protocol), slot)
            }
            Some((Avatar::Kitty(id), slot)) => self.wanted.borrow_mut().push((*id, slot)),
            None => {}
        }

        frame.render_widget(
            Paragraph::new(vec![
                Line::styled(format!("{:>4}", age(pr.updated_at, now)), DIM),
                Line::from(vec![Span::raw("   "), checks_span(pr.checks)]),
            ]),
            meta,
        );
    }

    fn draw_detail(
        &self,
        frame: &mut Frame,
        area: Rect,
        pr: &Pr,
        boxed: &dyn Fn(Line<'static>) -> Block<'static>,
    ) {
        let mut meta = vec![
            Span::styled(pr.branch.clone(), Style::new().fg(Color::Magenta)),
            Span::raw("  "),
            Span::styled(format!("+{}", pr.additions), Style::new().fg(Color::Green)),
            Span::raw(" "),
            Span::styled(format!("−{}", pr.deletions), Style::new().fg(Color::Red)),
            Span::styled(format!("  {} files", pr.files), DIM),
        ];
        if pr.draft {
            meta.push(Span::styled("  draft", DIM));
        }
        if let Some(decision) = decision_span(pr.decision) {
            meta.push(Span::raw("  "));
            meta.push(decision);
        }
        let mut lines = vec![
            Line::styled(pr.title.clone(), Style::new().add_modifier(Modifier::BOLD)),
            Line::from(meta),
            Line::raw(""),
        ];
        let body = pr.body.replace('\r', "");
        if body.trim().is_empty() {
            lines.push(Line::styled(
                "No description.",
                DIM.add_modifier(Modifier::ITALIC),
            ));
        } else {
            lines.extend(body.lines().map(|l| Line::raw(l.to_owned())));
        }

        let block = boxed(Line::styled(
            format!(" {}#{} ", pr.repo_full, pr.number),
            Style::new().add_modifier(Modifier::BOLD),
        ))
        .padding(Padding::horizontal(1));
        let page = block.inner(area).height;
        // Wrapped lines are not counted: scrolling stops at the last source
        // line rather than the last screen line.
        let scroll = self
            .scroll
            .get()
            .min((lines.len() as u16).saturating_sub(1));
        self.scroll.set(scroll);
        self.page.set(page);
        frame.render_widget(
            Paragraph::new(lines)
                .block(block)
                .wrap(Wrap { trim: false })
                .scroll((scroll, 0)),
            area,
        );
    }
}

fn decode(bytes: &[u8]) -> Option<DynamicImage> {
    image::load_from_memory(bytes).ok()
}

/// `image` as a disc filling the height of a `width`×`height` canvas,
/// transparent around it, with an antialiased edge.
fn round(image: &DynamicImage, width: u32, height: u32) -> RgbaImage {
    let side = width.min(height).max(1);
    let square = image
        .resize_to_fill(side, side, FilterType::Triangle)
        .to_rgba8();
    let (dx, dy) = ((width - side) / 2, (height - side) / 2);
    let r = side as f32 / 2.0;
    RgbaImage::from_fn(width, height, |x, y| {
        let (Some(sx), Some(sy)) = (x.checked_sub(dx), y.checked_sub(dy)) else {
            return Rgba([0; 4]);
        };
        if sx >= side || sy >= side {
            return Rgba([0; 4]);
        }
        let dist = ((sx as f32 + 0.5 - r).powi(2) + (sy as f32 + 0.5 - r).powi(2)).sqrt();
        let coverage = (r - dist + 0.5).clamp(0.0, 1.0);
        let mut px = *square.get_pixel(sx, sy);
        px[3] = (f32::from(px[3]) * coverage).round() as u8;
        px
    })
}

/// Avatars for each batch of (login, url): the cached one at once, then a
/// fresh one when the cached is missing or old. Each login once per run.
fn avatar_worker(rx: mpsc::Receiver<Vec<(String, String)>>, tx: mpsc::Sender<Msg>) {
    let cache = Cache::from_env();
    let mut seen = HashSet::new();
    for batch in rx {
        let fresh: Vec<_> = batch
            .into_iter()
            .filter(|(login, _)| seen.insert(login.clone()))
            .collect();
        let mut due = Vec::new();
        for (login, url) in fresh {
            let (bytes, stale) = cache.avatar(&login);
            if let Some(image) = bytes.as_deref().and_then(decode) {
                if tx.send(Msg::Avatar(login.clone(), image)).is_err() {
                    return;
                }
            }
            if stale {
                due.push((login, url));
            }
        }
        for (login, url) in due {
            if let Some(image) = cache
                .fetch_avatar(&login, &url)
                .ok()
                .as_deref()
                .and_then(decode)
            {
                if tx.send(Msg::Avatar(login, image)).is_err() {
                    return;
                }
            }
        }
    }
}

fn authors(prs: &[Pr]) -> Vec<(String, String)> {
    prs.iter()
        .filter_map(|pr| Some((pr.author.clone(), pr.avatar_url.clone()?)))
        .collect()
}

/// Run the picker; the chosen pull request, once the terminal is restored.
pub fn pick(query: String) -> Result<Option<Pr>> {
    let cache = Cache::from_env();
    let cached = cache.load();

    let (tx, rx) = mpsc::channel();
    let (avatar_tx, avatar_rx) = mpsc::channel();
    let (poke_tx, poke_rx) = mpsc::channel::<()>();
    {
        let tx = tx.clone();
        std::thread::spawn(move || avatar_worker(avatar_rx, tx));
    }
    if let Some(snapshot) = &cached {
        let _ = avatar_tx.send(authors(&snapshot.prs));
    }
    std::thread::spawn(move || {
        for () in poke_rx {
            let result = github::fetch();
            if let Ok(prs) = &result {
                let _ = cache.store(&Snapshot {
                    fetched_at: github::now(),
                    prs: prs.clone(),
                });
                let _ = avatar_tx.send(authors(prs));
            }
            if tx
                .send(Msg::Prs(result.map_err(|e| format!("{e:#}"))))
                .is_err()
            {
                return;
            }
        }
    });
    let _ = poke_tx.send(());

    let mut terminal = ratatui::init();
    // Asks the terminal what it can draw; must come after entering the
    // alternate screen and before reading events.
    let picker = Picker::from_query_stdio().unwrap_or_else(|_| Picker::halfblocks());
    // Shift+Enter tells itself apart from Enter only under the kitty protocol
    // (zellij forwards it once asked); Alt+Enter works without.
    let enhanced = execute!(
        io::stdout(),
        PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    )
    .is_ok();
    let (prs, fetched_at) = match cached {
        Some(s) => (s.prs, Some(s.fetched_at)),
        None => (Vec::new(), None),
    };
    let mut app = App {
        prs,
        fetched_at,
        refreshing: true,
        error: None,
        filter: query,
        filtering: false,
        selected: None,
        picker,
        avatars: HashMap::new(),
        wanted: RefCell::new(Vec::new()),
        placed: Vec::new(),
        offset: Cell::new(0),
        scroll: Cell::new(0),
        page: Cell::new(0),
    };
    app.settle();
    let result = event_loop(&mut terminal, &mut app, &rx, &poke_tx);
    if app.picker.protocol_type() == ProtocolType::Kitty {
        let mut out = io::stdout().lock();
        let _ = kitty::forget(&mut out).and_then(|()| out.flush());
    }
    if enhanced {
        let _ = execute!(io::stdout(), PopKeyboardEnhancementFlags);
    }
    ratatui::restore();
    result
}

fn handle(app: &mut App, msg: Msg) -> io::Result<()> {
    match msg {
        Msg::Prs(Ok(prs)) => {
            app.prs = prs;
            app.fetched_at = Some(github::now());
            app.refreshing = false;
            app.error = None;
            app.settle();
        }
        Msg::Prs(Err(err)) => {
            app.refreshing = false;
            app.error = Some(err);
        }
        Msg::Avatar(login, image) => app.add_avatar(login, image)?,
    }
    Ok(())
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    app: &mut App,
    rx: &mpsc::Receiver<Msg>,
    poke: &mpsc::Sender<()>,
) -> Result<Option<Pr>> {
    loop {
        while let Ok(msg) = rx.try_recv() {
            handle(app, msg)?;
        }
        terminal.draw(|frame| app.draw(frame))?;
        app.place_avatars()?;

        if !event::poll(Duration::from_millis(100))? {
            continue;
        }
        let key = match event::read()? {
            Event::Key(key) => key,
            // A resize clears the screen, and the placements with it.
            Event::Resize(..) => {
                app.placed.clear();
                continue;
            }
            _ => continue,
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('c') if ctrl => return Ok(None),
            KeyCode::Char('d') if ctrl => app.scroll_by(1),
            KeyCode::Char('u') if ctrl => app.scroll_by(-1),
            KeyCode::Char('n') if ctrl => app.step(1),
            KeyCode::Char('p') if ctrl => app.step(-1),
            KeyCode::Down => app.step(1),
            KeyCode::Up => app.step(-1),
            KeyCode::PageDown => app.scroll_by(2),
            KeyCode::PageUp => app.scroll_by(-2),
            KeyCode::Enter
                if key
                    .modifiers
                    .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) =>
            {
                open_web(app.selected_pr())
            }
            KeyCode::Enter if app.filtering => app.filtering = false,
            KeyCode::Enter => return Ok(app.selected_pr().cloned()),
            KeyCode::Esc if app.filtering || !app.filter.is_empty() => {
                app.filtering = false;
                app.filter.clear();
                app.settle();
            }
            KeyCode::Backspace if app.filtering => {
                app.filter.pop();
                app.settle();
            }
            KeyCode::Char(c) if app.filtering => {
                app.filter.push(c);
                app.settle();
            }
            KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
            KeyCode::Char('/') => app.filtering = true,
            KeyCode::Char('j') => app.step(1),
            KeyCode::Char('k') => app.step(-1),
            KeyCode::Char('g') | KeyCode::Home => app.step(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => app.step(isize::MAX / 2),
            KeyCode::Char('r') if !app.refreshing => {
                app.refreshing = true;
                let _ = poke.send(());
            }
            KeyCode::Char('o') => open_web(app.selected_pr()),
            _ => {}
        }
    }
}

fn open_web(pr: Option<&Pr>) {
    if let Some(pr) = pr {
        let _ = Command::new("gh")
            .args(["pr", "view", "--web", &pr.url])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::github::Stack;

    /// `stack`: (number, position) in a stack of 3.
    fn pr(number: u64, stack: Option<(u64, u64)>, requested: bool, state: State) -> Pr {
        Pr {
            number,
            title: String::new(),
            url: number.to_string(),
            body: String::new(),
            state,
            draft: false,
            updated_at: 0,
            branch: String::new(),
            requested,
            stack: stack.map(|(number, position)| Stack {
                number,
                size: 3,
                base: "main".to_owned(),
                position,
            }),
            additions: 0,
            deletions: 0,
            files: 0,
            repo: "r".to_owned(),
            repo_full: "o/r".to_owned(),
            author: String::new(),
            avatar_url: None,
            decision: None,
            checks: None,
        }
    }

    #[test]
    fn stack_gathers_at_its_first_member_top_first() {
        let prs = [
            pr(2, Some((9, 2)), true, State::Open),
            pr(4, None, true, State::Open),
            pr(3, Some((9, 3)), false, State::Open),
            pr(1, Some((9, 1)), false, State::Merged),
        ];
        let child = |pr, last| Row::Pr {
            pr,
            place: Place::Child { last },
        };
        assert_eq!(
            stacks(&prs, vec![0, 1, 2, 3]),
            [
                Row::Stack { pr: 2 },
                child(2, false),
                child(0, false),
                child(3, true),
                Row::Pr {
                    pr: 1,
                    place: Place::Alone
                },
            ]
        );
    }

    #[test]
    fn stack_without_a_requested_member_shown_is_dropped() {
        let prs = [
            pr(2, Some((9, 2)), true, State::Open),
            pr(1, Some((9, 1)), false, State::Merged),
        ];
        assert!(stacks(&prs, vec![1]).is_empty());
    }
}
