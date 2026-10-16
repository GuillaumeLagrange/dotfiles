//! The picker: pull requests awaiting my review, or those I reviewed lately,
//! newest activity first, the selected one's description below, Enter to check
//! it out.

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
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use ratatui::{DefaultTerminal, Frame};
use ratatui_image::picker::{Picker, ProtocolType};
use ratatui_image::protocol::Protocol;
use ratatui_image::{FilterType, Image, Resize};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::github::{self, Cache, Checks, Decision, Lists, Pr, Query, Snapshot, State};
use crate::kitty;
use crate::markdown::{self, ImageState};

pub const ACCENT: Color = Color::Blue;
pub const DIM: Style = Style::new().fg(Color::DarkGray);
/// Cells an avatar takes, inline before the author's login.
const AVATAR: Size = Size::new(2, 1);
/// Widest the picker gets: past it, centered.
const MAX_WIDTH: u16 = 100;
/// Largest side an image from a description is kept at.
const IMAGE_PIXELS: u32 = 1600;

enum Msg {
    Prs(Tab, Result<Vec<Pr>, String>),
    Avatar(String, DynamicImage),
    /// `None` when it could not be fetched or decoded.
    Image(String, Option<DynamicImage>),
}

enum Avatar {
    /// Uploaded under this id, placed after each frame.
    Kitty(u32),
    /// Drawn into the cells by ratatui-image: sixel, halfblocks.
    Cells(Protocol),
}

enum Img {
    Loading,
    Failed,
    Ready(DynamicImage),
}

/// A description's image as uploaded to kitty, at its size in cells.
struct KittyImage {
    id: u32,
    cols: u16,
    rows: u16,
}

/// A description's image drawn into cells: its size, and the rows of it shown.
struct CellImage {
    key: [u16; 4],
    protocol: Protocol,
}

/// Image id, cells, and the part of the image shown there, in pixels.
type Placement = (u32, Rect, Option<[u32; 4]>);

struct ImageRequest {
    repo_full: String,
    number: u64,
    srcs: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tab {
    Requested,
    Reviewed,
}

const TABS: [Tab; 2] = [Tab::Requested, Tab::Reviewed];

impl Tab {
    fn index(self) -> usize {
        self as usize
    }

    fn query(self) -> Query {
        match self {
            Tab::Requested => Query::Requested,
            Tab::Reviewed => Query::Reviewed,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Tab::Requested => "needs your review",
            Tab::Reviewed => "reviewed",
        }
    }
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
    Some(match decision? {
        Decision::Approved => Span::styled("approved", Style::new().fg(Color::Green)),
        Decision::ChangesRequested => {
            Span::styled("changes requested", Style::new().fg(Color::Red))
        }
    })
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
/// with nothing listed shown is dropped.
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
        if !members.iter().any(|&i| prs[i].listed) {
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
    lists: Lists,
    tab: Tab,
    fetched_at: Option<u64>,
    /// Per tab, its search is in flight.
    refreshing: [bool; 2],
    errors: [Option<String>; 2],
    filter: String,
    filtering: bool,
    /// Per tab, kept by URL so a refresh that reorders the list does not move it.
    selected: [Option<String>; 2],
    picker: Picker,
    avatars: HashMap<String, Avatar>,
    images: HashMap<String, Img>,
    image_tx: mpsc::Sender<ImageRequest>,
    kitty_images: RefCell<HashMap<String, KittyImage>>,
    cell_images: RefCell<HashMap<String, CellImage>>,
    /// Kitty images the last frame needs uploaded.
    uploads: RefCell<Vec<(u32, RgbaImage)>>,
    next_id: Cell<u32>,
    /// Kitty placements the last frame asked for, and those on screen.
    wanted: RefCell<Vec<Placement>>,
    placed: Vec<Placement>,
    /// First item drawn in each tab's list, kept between frames so moving the
    /// selection only scrolls when it leaves the window.
    offset: [Cell<usize>; 2],
    scroll: Cell<u16>,
    page: Cell<u16>,
}

impl App {
    fn list(&self, tab: Tab) -> &[Pr] {
        self.lists.get(tab.query())
    }

    fn prs(&self) -> &[Pr] {
        self.list(self.tab)
    }

    fn rows(&self, tab: Tab) -> Vec<Row> {
        let filter = self.filter.to_lowercase();
        let terms: Vec<&str> = filter.split_whitespace().collect();
        let prs = self.list(tab);
        let shown = prs
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
        stacks(prs, shown)
    }

    fn visible(&self) -> Vec<Row> {
        self.rows(self.tab)
    }

    /// Rows that take the selection: those the tab's search found, and open
    /// pull requests of their stacks.
    fn selectable(prs: &[Pr], row: &Row) -> bool {
        matches!(row, Row::Pr { pr, .. } if prs[*pr].listed || prs[*pr].state == State::Open)
    }

    fn position(&self, tab: Tab, visible: &[Row]) -> Option<usize> {
        let url = self.selected[tab.index()].as_ref()?;
        let prs = self.list(tab);
        visible.iter().position(|row| {
            Self::selectable(prs, row) && matches!(row, Row::Pr { pr, .. } if &prs[*pr].url == url)
        })
    }

    /// Keep each tab's selection on something shown.
    fn settle(&mut self) {
        for tab in TABS {
            let visible = self.rows(tab);
            if self.position(tab, &visible).is_some() {
                continue;
            }
            let prs = self.list(tab);
            let first = visible.iter().find_map(|row| match row {
                Row::Pr { pr, .. } if Self::selectable(prs, row) => Some(prs[*pr].url.clone()),
                _ => None,
            });
            self.selected[tab.index()] = first;
            if tab == self.tab {
                self.scroll.set(0);
            }
        }
    }

    fn switch(&mut self) {
        self.tab = match self.tab {
            Tab::Requested => Tab::Reviewed,
            Tab::Reviewed => Tab::Requested,
        };
        self.scroll.set(0);
    }

    fn step(&mut self, delta: isize) {
        let visible = self.visible();
        let prs = self.prs();
        let choices: Vec<usize> = visible
            .iter()
            .filter(|row| Self::selectable(prs, row))
            .filter_map(|row| match row {
                Row::Pr { pr, .. } => Some(*pr),
                Row::Stack { .. } => None,
            })
            .collect();
        if choices.is_empty() {
            return;
        }
        let selected = &self.selected[self.tab.index()];
        let at = selected
            .as_ref()
            .and_then(|url| choices.iter().position(|&i| &prs[i].url == url))
            .unwrap_or(0) as isize;
        let next = (at + delta).clamp(0, choices.len() as isize - 1) as usize;
        let url = prs[choices[next]].url.clone();
        if selected.as_ref() != Some(&url) {
            self.scroll.set(0);
        }
        self.selected[self.tab.index()] = Some(url);
    }

    fn scroll_by(&self, halves: i32) {
        let step = i32::from(self.page.get() / 2).max(1) * halves;
        let next = (i32::from(self.scroll.get()) + step).clamp(0, i32::from(u16::MAX));
        self.scroll.set(next as u16);
    }

    fn selected_pr(&self) -> Option<&Pr> {
        let url = self.selected[self.tab.index()].as_ref()?;
        self.prs().iter().find(|pr| &pr.url == url)
    }

    /// A kitty image id; from the pid, so another program in the window keeps
    /// its own.
    fn new_id(&self) -> u32 {
        let id = self.next_id.get();
        self.next_id.set(id.wrapping_add(1));
        id
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
        let id = match self.avatars.get(&login) {
            Some(Avatar::Kitty(id)) => *id,
            _ => self.new_id(),
        };
        let mut out = io::stdout().lock();
        kitty::upload(&mut out, id, &pixels)?;
        out.flush()?;
        self.avatars.insert(login, Avatar::Kitty(id));
        // A replaced image is shown again by placing it anew.
        self.placed.clear();
        Ok(())
    }

    /// Ask for the selected description's images not asked for yet.
    fn request_images(&mut self) {
        let Some(pr) = self.selected_pr() else {
            return;
        };
        let srcs: Vec<String> = markdown::images(&pr.body)
            .into_iter()
            .filter(|src| !self.images.contains_key(src))
            .collect();
        if srcs.is_empty() {
            return;
        }
        let request = ImageRequest {
            repo_full: pr.repo_full.clone(),
            number: pr.number,
            srcs: srcs.clone(),
        };
        for src in srcs {
            self.images.insert(src, Img::Loading);
        }
        let _ = self.image_tx.send(request);
    }

    /// Bring kitty in line with the frame just drawn: upload what it needs,
    /// then place.
    fn place_images(&mut self) -> io::Result<()> {
        let uploads = self.uploads.take();
        let wanted = self.wanted.take();
        if uploads.is_empty() && wanted == self.placed {
            return Ok(());
        }
        let mut out = io::stdout().lock();
        for (id, pixels) in &uploads {
            kitty::upload(&mut out, *id, pixels)?;
        }
        kitty::clear(&mut out)?;
        for &(id, area, crop) in &wanted {
            kitty::place(&mut out, id, area, crop)?;
        }
        out.flush()?;
        self.placed = wanted;
        Ok(())
    }

    fn status(&self, now: u64) -> Line<'static> {
        if let Some(err) = self.errors.iter().flatten().next() {
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
        if !self.refreshing.contains(&true) {
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

    /// The tabs, each with how many pull requests it lists.
    fn tabs(&self) -> Line<'static> {
        let mut line = Line::default();
        for tab in TABS {
            let prs = self.list(tab);
            let count = self
                .rows(tab)
                .iter()
                .filter(|row| matches!(row, Row::Pr { pr, .. } if prs[*pr].listed))
                .count();
            let style = if tab == self.tab {
                Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)
            } else {
                DIM
            };
            line.push_span(Span::styled(format!(" {} · {count} ", tab.label()), style));
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

        let list_block = boxed(self.tabs()).title(self.status(now).right_aligned());
        let inner = list_block.inner(list_area);
        frame.render_widget(list_block, list_area);
        if visible.is_empty() {
            let text = match (
                self.prs().is_empty(),
                self.refreshing[self.tab.index()],
                self.tab,
            ) {
                (true, true, _) => format!("{} Loading…", spinner()),
                (true, false, Tab::Requested) => "Nothing awaits your review.".to_owned(),
                (true, false, Tab::Reviewed) => format!(
                    "Nothing reviewed in the last {} days.",
                    github::REVIEWED_DAYS
                ),
                (false, _, _) => "No pull request matches the filter.".to_owned(),
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
                "enter checkout · shift+enter open · tab switch · / filter · r refresh · j/k move · ^d/^u scroll · q quit",
                DIM,
            )
        };
        frame.render_widget(Paragraph::new(help), help_area);
    }

    fn draw_list(&self, frame: &mut Frame, area: Rect, visible: &[Row], now: u64) {
        let prs = self.prs();
        let fit = usize::from(area.height / 2).max(1);
        let selected = self.position(self.tab, visible);
        let at = selected.unwrap_or(0);
        let kept = &self.offset[self.tab.index()];
        let mut offset = kept.get().min(visible.len().saturating_sub(fit));
        if at < offset {
            offset = at;
            // with the heading and merged rows above it, when they fit
            while offset > 0
                && !Self::selectable(prs, &visible[offset - 1])
                && at - offset + 1 < fit
            {
                offset -= 1;
            }
        } else if at >= offset + fit {
            offset = at + 1 - fit;
        }
        kept.set(offset);

        for (line, row) in visible.iter().skip(offset).take(fit).enumerate() {
            let item = Rect::new(area.x, area.y + 2 * line as u16, area.width, 2);
            match *row {
                Row::Stack { pr } => self.draw_stack(frame, item, &prs[pr]),
                Row::Pr { pr, place } => {
                    let is_selected = selected == Some(line + offset);
                    self.draw_pr(frame, item, &prs[pr], place, is_selected, now)
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
        if pr.listed {
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
        let unlisted = match self.tab {
            Tab::Requested => "  not requested",
            Tab::Reviewed => "  not reviewed",
        };
        match pr.state {
            State::Merged => sub.push(Span::styled("  merged", state_style)),
            State::Closed => sub.push(Span::styled("  closed", state_style)),
            State::Open if !pr.listed => {
                sub.push(Span::styled(unlisted, DIM.add_modifier(Modifier::ITALIC)))
            }
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
            Some((Avatar::Kitty(id), slot)) => self.wanted.borrow_mut().push((*id, slot, None)),
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
        let block = boxed(Line::styled(
            format!(" {}#{} ", pr.repo_full, pr.number),
            Style::new().add_modifier(Modifier::BOLD),
        ))
        .padding(Padding::horizontal(1));
        let inner = block.inner(area);
        frame.render_widget(block, area);
        let width = usize::from(inner.width);

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
        let title = [Span::styled(
            pr.title.clone(),
            Style::new().add_modifier(Modifier::BOLD),
        )];
        let mut lines: Vec<Line<'static>> = markdown::wrap(&title, width)
            .into_iter()
            .chain(markdown::wrap(&meta, width))
            .map(Line::from)
            .collect();
        lines.push(Line::raw(""));
        let header = lines.len();

        let body = pr.body.replace('\r', "");
        let font = self.picker.font_size();
        let state = |src: &str| match self.images.get(src) {
            Some(Img::Ready(image)) => ImageState::Ready(image.width(), image.height()),
            Some(Img::Failed) => ImageState::Failed,
            Some(Img::Loading) | None => ImageState::Loading,
        };
        let doc = markdown::render(
            &body,
            &markdown::Ctx {
                width: inner.width,
                font: (font.width, font.height),
                max_rows: inner.height.saturating_sub(2).max(3),
                image: &state,
            },
        );
        if body.trim().is_empty() {
            lines.push(Line::styled(
                "No description.",
                DIM.add_modifier(Modifier::ITALIC),
            ));
        }
        lines.extend(doc.lines);

        let page = inner.height;
        let scroll = self
            .scroll
            .get()
            .min((lines.len() as u16).saturating_sub(page));
        self.scroll.set(scroll);
        self.page.set(page);
        frame.render_widget(Paragraph::new(lines).scroll((scroll, 0)), inner);

        let (top, bottom) = (usize::from(scroll), usize::from(scroll) + usize::from(page));
        for placed in &doc.images {
            let start = header + placed.line;
            let end = start + usize::from(placed.rows);
            let (from, to) = (start.max(top), end.min(bottom));
            if from >= to {
                continue;
            }
            let Some(Img::Ready(image)) = self.images.get(&placed.src) else {
                continue;
            };
            let slot = Rect::new(
                inner.x + placed.col,
                inner.y + (from - top) as u16,
                placed.cols,
                (to - from) as u16,
            );
            self.draw_image(
                frame,
                &placed.src,
                image,
                placed,
                (from - start) as u16,
                slot,
            );
        }
    }

    /// Rows `skip..` of a description's image, into `slot`.
    fn draw_image(
        &self,
        frame: &mut Frame,
        src: &str,
        image: &DynamicImage,
        placed: &markdown::Placed,
        skip: u16,
        slot: Rect,
    ) {
        let font = self.picker.font_size();
        let (fw, fh) = (u32::from(font.width), u32::from(font.height));
        let (cols, rows) = (placed.cols, placed.rows);
        let (width, height) = (u32::from(cols) * fw, u32::from(rows) * fh);
        if self.picker.protocol_type() == ProtocolType::Kitty {
            let mut kitty = self.kitty_images.borrow_mut();
            let entry = kitty.entry(src.to_owned()).or_insert_with(|| KittyImage {
                id: self.new_id(),
                cols: 0,
                rows: 0,
            });
            if (entry.cols, entry.rows) != (cols, rows) {
                self.uploads
                    .borrow_mut()
                    .push((entry.id, fit(image, width, height)));
                (entry.cols, entry.rows) = (cols, rows);
            }
            let crop = [0, u32::from(skip) * fh, width, u32::from(slot.height) * fh];
            self.wanted.borrow_mut().push((entry.id, slot, Some(crop)));
            return;
        }
        let key = [cols, rows, skip, slot.height];
        let mut cells = self.cell_images.borrow_mut();
        if cells.get(src).is_none_or(|c| c.key != key) {
            let shown = image::imageops::crop_imm(
                &fit(image, width, height),
                0,
                u32::from(skip) * fh,
                width,
                u32::from(slot.height) * fh,
            )
            .to_image();
            let resize = Resize::Scale(Some(FilterType::Triangle));
            let size = Size::new(slot.width, slot.height);
            match self
                .picker
                .new_protocol(DynamicImage::ImageRgba8(shown), size, resize)
            {
                Ok(protocol) => {
                    cells.insert(src.to_owned(), CellImage { key, protocol });
                }
                Err(_) => return,
            }
        }
        if let Some(cell) = cells.get(src) {
            frame.render_widget(Image::new(&cell.protocol), slot);
        }
    }
}

fn decode(bytes: &[u8]) -> Option<DynamicImage> {
    image::load_from_memory(bytes).ok()
}

/// `image` scaled into a `width`×`height` canvas, top left, transparent around.
fn fit(image: &DynamicImage, width: u32, height: u32) -> RgbaImage {
    let scaled = image
        .resize(width.max(1), height.max(1), FilterType::Triangle)
        .to_rgba8();
    let mut canvas = RgbaImage::new(width.max(1), height.max(1));
    image::imageops::overlay(&mut canvas, &scaled, 0, 0);
    canvas
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

/// The images of descriptions, from the cache or fetched; uploads to GitHub
/// through the signed URLs of the rendered description, asked for once per
/// request.
fn image_worker(rx: mpsc::Receiver<ImageRequest>, tx: mpsc::Sender<Msg>) {
    let cache = Cache::from_env();
    cache.prune_images();
    for request in rx {
        let mut signed: Option<Vec<String>> = None;
        for src in &request.srcs {
            let image = load_image(&cache, &request, src, &mut signed).map(|image| {
                if image.width().max(image.height()) > IMAGE_PIXELS {
                    image.resize(IMAGE_PIXELS, IMAGE_PIXELS, FilterType::Triangle)
                } else {
                    image
                }
            });
            if tx.send(Msg::Image(src.clone(), image)).is_err() {
                return;
            }
        }
    }
}

fn load_image(
    cache: &Cache,
    request: &ImageRequest,
    src: &str,
    signed: &mut Option<Vec<String>>,
) -> Option<DynamicImage> {
    if let Some(image) = cache.image(src).as_deref().and_then(decode) {
        return Some(image);
    }
    let url = if github::needs_signing(src) {
        let signed = signed.get_or_insert_with(|| {
            github::signed_images(&request.repo_full, request.number).unwrap_or_default()
        });
        let id = github::asset_id(src)?;
        signed.iter().find(|s| s.contains(id))?.clone()
    } else {
        src.to_owned()
    };
    let bytes = github::curl(&url).ok()?;
    let image = decode(&bytes)?;
    let _ = cache.store_image(src, &bytes);
    Some(image)
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
    let (image_tx, image_rx) = mpsc::channel();
    let (poke_tx, poke_rx) = mpsc::channel::<()>();
    {
        let tx = tx.clone();
        std::thread::spawn(move || avatar_worker(avatar_rx, tx));
    }
    {
        let tx = tx.clone();
        std::thread::spawn(move || image_worker(image_rx, tx));
    }
    if let Some(snapshot) = &cached {
        let _ = avatar_tx.send(authors(&snapshot.lists.requested));
        let _ = avatar_tx.send(authors(&snapshot.lists.reviewed));
    }
    std::thread::spawn(move || {
        for () in poke_rx {
            // Each tab shows as soon as its search is in.
            let fetch = |tab: Tab| match github::fetch(tab.query()) {
                Ok(prs) => {
                    let _ = avatar_tx.send(authors(&prs));
                    let _ = tx.send(Msg::Prs(tab, Ok(prs.clone())));
                    Some(prs)
                }
                Err(err) => {
                    let _ = tx.send(Msg::Prs(tab, Err(format!("{err:#}"))));
                    None
                }
            };
            let (requested, reviewed) = std::thread::scope(|s| {
                let reviewed = s.spawn(|| fetch(Tab::Reviewed));
                (fetch(Tab::Requested), reviewed.join().ok().flatten())
            });
            if let (Some(requested), Some(reviewed)) = (requested, reviewed) {
                let mut lists = Lists::default();
                lists.set(Query::Requested, requested);
                lists.set(Query::Reviewed, reviewed);
                let _ = cache.store(&Snapshot {
                    fetched_at: github::now(),
                    lists,
                });
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
    let (lists, fetched_at) = match cached {
        Some(s) => (s.lists, Some(s.fetched_at)),
        None => (Lists::default(), None),
    };
    let mut app = App {
        lists,
        tab: Tab::Requested,
        fetched_at,
        refreshing: [true; 2],
        errors: [None, None],
        filter: query,
        filtering: false,
        selected: [None, None],
        picker,
        avatars: HashMap::new(),
        images: HashMap::new(),
        image_tx,
        kitty_images: RefCell::new(HashMap::new()),
        cell_images: RefCell::new(HashMap::new()),
        uploads: RefCell::new(Vec::new()),
        next_id: Cell::new(std::process::id().wrapping_mul(1000).wrapping_add(1)),
        wanted: RefCell::new(Vec::new()),
        placed: Vec::new(),
        offset: [Cell::new(0), Cell::new(0)],
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
        Msg::Prs(tab, result) => {
            app.refreshing[tab.index()] = false;
            match result {
                Ok(prs) => {
                    app.lists.set(tab.query(), prs);
                    app.errors[tab.index()] = None;
                    app.fetched_at = Some(github::now());
                    app.settle();
                }
                Err(err) => {
                    app.errors[tab.index()] = Some(match tab {
                        Tab::Requested => err,
                        Tab::Reviewed => format!("reviewed: {err}"),
                    })
                }
            }
        }
        Msg::Avatar(login, image) => app.add_avatar(login, image)?,
        Msg::Image(src, image) => {
            app.images
                .insert(src, image.map_or(Img::Failed, Img::Ready));
        }
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
        app.request_images();
        terminal.draw(|frame| app.draw(frame))?;
        app.place_images()?;

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
            KeyCode::Tab | KeyCode::BackTab => app.switch(),
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
            KeyCode::Char('r') if !app.refreshing.contains(&true) => {
                app.refreshing = [true; 2];
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
    fn pr(number: u64, stack: Option<(u64, u64)>, listed: bool, state: State) -> Pr {
        Pr {
            number,
            title: String::new(),
            url: number.to_string(),
            body: String::new(),
            state,
            draft: false,
            updated_at: 0,
            branch: String::new(),
            listed,
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
    fn stack_without_a_listed_member_shown_is_dropped() {
        let prs = [
            pr(2, Some((9, 2)), true, State::Open),
            pr(1, Some((9, 1)), false, State::Merged),
        ];
        assert!(stacks(&prs, vec![1]).is_empty());
    }

    #[test]
    fn listed_merged_pull_requests_take_the_selection_unlike_merged_stack_members() {
        let prs = [
            pr(1, None, true, State::Merged),
            pr(2, Some((9, 1)), false, State::Merged),
            pr(3, Some((9, 2)), false, State::Open),
        ];
        let row = |pr| Row::Pr {
            pr,
            place: Place::Alone,
        };
        assert!(App::selectable(&prs, &row(0)));
        assert!(!App::selectable(&prs, &row(1)));
        assert!(App::selectable(&prs, &row(2)));
    }
}
