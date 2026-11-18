//! The floating picker: on the left, every zellij session in its colour, order
//! and folding (zellij-sessions) with its omp panes under it; on the right, the
//! selected pane's conversation. Enter jumps to the pane, or opens the session.

use std::cell::{Cell, RefCell};
use std::cmp::Reverse;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, SystemTime};

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, List, ListItem, ListState, Padding, Paragraph};
use ratatui::DefaultTerminal;

use crate::git;
use crate::markdown;
use crate::state::{now_ms, Group, Row, Status, Store};
use crate::transcript::{self, Entry};
use crate::zellij;
use zellij_sessions::{Registry, Swatch};

const REFRESH: Duration = Duration::from_secs(1);
const GIT_TTL: Duration = Duration::from_secs(5);
pub const ACCENT: Color = Color::Blue;
const DIM: Style = Style::new().fg(Color::DarkGray);

fn style(status: Status) -> (&'static str, Style) {
    match status {
        Status::Blocked => (
            "!",
            Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
        ),
        Status::Working => ("◐", Style::new().fg(Color::Yellow)),
        Status::Done => ("✓", Style::new().fg(Color::Green)),
        Status::Idle => ("○", Style::new().fg(Color::DarkGray)),
    }
}

fn age(since: u64, now: u64) -> String {
    let secs = now.saturating_sub(since) / 1000;
    match secs {
        0..60 => format!("{secs}s"),
        60..3600 => format!("{}m", secs / 60),
        3600..86400 => format!("{}h", secs / 3600),
        _ => format!("{}d", secs / 86400),
    }
}

/// A blocked pane's question, a working one's running tool, else the first
/// line of its last reply.
fn summary(row: &Row) -> Vec<Span<'static>> {
    match (row.status, &row.blocked_reason, &row.activity) {
        (Status::Blocked, Some(reason), _) => {
            let first = reason.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
            vec![Span::styled(
                first.trim().to_owned(),
                style(Status::Blocked).1,
            )]
        }
        (Status::Working, _, Some(activity)) => vec![
            Span::styled("▸ ", style(Status::Working).1),
            Span::raw(activity.clone()),
        ],
        _ => markdown::first_line(row.last_message.as_deref().unwrap_or("")).spans,
    }
}

fn git_spans(git: &git::Git) -> Vec<Span<'static>> {
    let mut spans = vec![Span::styled(
        format!("⎇ {}", git.branch.as_deref().unwrap_or("detached")),
        DIM,
    )];
    if git.ahead > 0 {
        spans.push(Span::styled(
            format!(" ↑{}", git.ahead),
            Style::new().fg(Color::Green),
        ));
    }
    if git.behind > 0 {
        spans.push(Span::styled(
            format!(" ↓{}", git.behind),
            Style::new().fg(Color::Red),
        ));
    }
    if git.dirty {
        spans.push(Span::styled(" *", Style::new().fg(Color::Yellow)));
    }
    spans
}

/// Model, context use, and whether a client shows the pane, each only when known.
fn meta(row: &Row) -> Vec<Span<'static>> {
    let mut parts = Vec::new();
    if let Some(model) = &row.model {
        parts.push(Span::styled(model.clone(), DIM));
    }
    if let Some(percent) = row.context_percent {
        let style = match percent {
            p if p >= 80.0 => Style::new().fg(Color::Red),
            p if p >= 60.0 => Style::new().fg(Color::Yellow),
            _ => DIM,
        };
        parts.push(Span::styled(format!("{percent:.0}% ctx"), style));
    }
    if row.focused {
        parts.push(Span::styled("on screen", DIM));
    }
    if parts.is_empty() {
        return Vec::new();
    }
    let mut spans = vec![Span::raw(" ")];
    for (i, part) in parts.into_iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(" · ", DIM));
        }
        spans.push(part);
    }
    spans.push(Span::raw(" "));
    spans
}

pub fn home_relative(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_owned(),
    }
}

/// How the list is laid out; kept across opens.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Sort {
    /// Under their session, by tab.
    Sessions,
    /// One list, most urgent first, the latest change first within a status.
    Priority,
}

impl Sort {
    fn path() -> PathBuf {
        std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
            })
            .unwrap_or_else(std::env::temp_dir)
            .join("omp-panel/sort")
    }

    fn load() -> Self {
        match fs::read_to_string(Self::path()).as_deref().map(str::trim) {
            Ok("priority") => Sort::Priority,
            _ => Sort::Sessions,
        }
    }

    fn save(self) {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let name = match self {
            Sort::Sessions => "sessions",
            Sort::Priority => "priority",
        };
        let _ = fs::write(path, name);
    }
}

/// What the detail pane was rendered from: the session file as it was on disk,
/// or the last reply when there is none yet.
#[derive(PartialEq)]
struct DetailKey {
    session_file: Option<(String, u64, Option<SystemTime>)>,
    last_message: Option<String>,
    width: u16,
}

struct Detail {
    key: DetailKey,
    lines: Vec<Line<'static>>,
    /// The line the last question starts on, shown first.
    anchor: u16,
}

fn render_conversation(entries: &[Entry], width: u16) -> (Vec<Line<'static>>, u16) {
    let mut lines = Vec::new();
    let mut anchor = 0;
    for entry in entries {
        if !lines.is_empty() {
            lines.push(Line::raw(""));
        }
        match entry {
            Entry::User(text) => {
                anchor = lines.len();
                let bar = Span::styled("▌ ", Style::new().fg(ACCENT));
                lines.extend(
                    markdown::render(text, width.saturating_sub(2) as usize, true)
                        .into_iter()
                        .map(|line| {
                            let mut spans = vec![bar.clone()];
                            spans.extend(line.spans);
                            Line::from(spans)
                        }),
                );
            }
            Entry::Assistant(text) => lines.extend(markdown::render(text, width as usize, true)),
            Entry::Tools { count: 1, last } => lines.push(Line::styled(format!("⚙ {last}"), DIM)),
            Entry::Tools { count, last } => {
                lines.push(Line::styled(format!("⚙ {count} tools · {last}"), DIM))
            }
        }
    }
    (lines, anchor as u16)
}

/// What the picker hands back: a pane to jump to, or a whole session to open.
pub enum Pick {
    Pane(String, u32),
    Session(String),
}

/// A row of the list: a session's header, or one of its omp panes.
#[derive(Clone, PartialEq, Eq, Debug)]
enum Item {
    Session(String),
    Pane(String, u32),
}

impl Item {
    fn session(&self) -> &str {
        match self {
            Item::Session(s) | Item::Pane(s, _) => s,
        }
    }
}

/// One refresh: the omp panes, and every live session, with or without one.
#[derive(Clone)]
struct Snapshot {
    groups: Vec<Group>,
    sessions: Vec<String>,
}

struct App {
    groups: Vec<Group>,
    /// Live sessions, in the registry's order.
    sessions: Vec<String>,
    looks: zellij_sessions::Store,
    registry: Registry,
    palette: Vec<Swatch>,
    sort: Sort,
    /// Kept by identity so a refresh that adds or drops rows does not move it.
    selected: Option<Item>,
    /// The selected conversation as last rendered: drawing runs several times a
    /// second and the session file changes far less often.
    detail: RefCell<Option<Detail>>,
    /// First line of the conversation shown, how many fit, and where the user
    /// scrolled to; unscrolled, it follows the last question.
    top: Cell<u16>,
    page: Cell<u16>,
    pinned: Cell<Option<u16>>,
    error: Option<String>,
}

impl App {
    fn new(sort: Sort) -> Self {
        let looks = zellij_sessions::Store::from_env();
        Self {
            groups: Vec::new(),
            sessions: Vec::new(),
            registry: looks.load(),
            palette: looks.palette(),
            looks,
            sort,
            selected: None,
            detail: RefCell::new(None),
            top: Cell::new(0),
            page: Cell::new(0),
            pinned: Cell::new(None),
            error: None,
        }
    }

    fn update(&mut self, snapshot: Snapshot) {
        self.registry = self.looks.load();
        self.groups = snapshot.groups;
        self.sessions = snapshot.sessions;
        self.arrange();
    }

    /// Sessions and their groups in the registry's order, then a selection that
    /// is still on screen.
    fn arrange(&mut self) {
        for group in &self.groups {
            if !self.sessions.contains(&group.session) {
                self.sessions.push(group.session.clone());
            }
        }
        self.registry.sort(&mut self.sessions);
        let place: HashMap<&str, usize> = self
            .sessions
            .iter()
            .enumerate()
            .map(|(i, s)| (s.as_str(), i))
            .collect();
        self.groups
            .sort_by_key(|g| place.get(g.session.as_str()).copied());

        let rows = self.rows();
        if self.selected.as_ref().is_some_and(|s| rows.contains(s)) {
            return;
        }
        // A pane that went or was folded away leaves the selection on its session.
        let header = self
            .selected
            .as_ref()
            .map(|s| Item::Session(s.session().to_owned()))
            .filter(|h| rows.contains(h));
        // Otherwise start on what most needs attention.
        let urgent = || {
            [Status::Blocked, Status::Done].iter().find_map(|want| {
                rows.iter()
                    .find(|item| self.status(item) == Some(*want))
                    .cloned()
            })
        };
        let next = header.or_else(urgent).or_else(|| rows.first().cloned());
        self.select(next);
    }

    fn collapsed(&self, session: &str) -> bool {
        self.registry.collapsed(session)
    }

    fn color(&self, session: &str) -> Option<Color> {
        let (r, g, b) = self.registry.swatch(session, &self.palette)?.rgb()?;
        Some(Color::Rgb(r, g, b))
    }

    /// The session's mark: a dot in its colour.
    fn dot(&self, session: &str) -> Span<'static> {
        match self.color(session) {
            Some(color) => Span::styled("● ", Style::new().fg(color)),
            None => Span::styled("○ ", DIM),
        }
    }

    fn group(&self, session: &str) -> Option<&Group> {
        self.groups.iter().find(|g| g.session == session)
    }

    fn pane(&self, session: &str, pane: u32) -> Option<(&Group, &Row)> {
        let group = self.group(session)?;
        Some((group, group.panes.iter().find(|r| r.pane_id == pane)?))
    }

    /// A pane's status; None for a session header.
    fn status(&self, item: &Item) -> Option<Status> {
        match item {
            Item::Pane(s, p) => self.pane(s, *p).map(|(_, row)| row.status),
            Item::Session(_) => None,
        }
    }

    /// The list in display order. By session: each session, then its panes unless
    /// folded. By priority: the panes alone, folded sessions' left out.
    fn rows(&self) -> Vec<Item> {
        match self.sort {
            Sort::Sessions => {
                let mut rows = Vec::new();
                for session in &self.sessions {
                    rows.push(Item::Session(session.clone()));
                    if self.collapsed(session) {
                        continue;
                    }
                    if let Some(group) = self.group(session) {
                        rows.extend(
                            group
                                .panes
                                .iter()
                                .map(|r| Item::Pane(session.clone(), r.pane_id)),
                        );
                    }
                }
                rows
            }
            Sort::Priority => {
                let mut panes: Vec<&Row> = Vec::new();
                let mut items = Vec::new();
                for group in self.groups.iter().filter(|g| !self.collapsed(&g.session)) {
                    for row in &group.panes {
                        panes.push(row);
                        items.push(Item::Pane(group.session.clone(), row.pane_id));
                    }
                }
                let mut order: Vec<usize> = (0..items.len()).collect();
                order.sort_by_key(|&i| (Reverse(panes[i].status), Reverse(panes[i].state_since)));
                order.into_iter().map(|i| items[i].clone()).collect()
            }
        }
    }

    fn select(&mut self, item: Option<Item>) {
        if item != self.selected {
            self.pinned.set(None);
        }
        self.selected = item;
    }

    fn step(&mut self, delta: isize) {
        let rows = self.rows();
        if rows.is_empty() {
            return;
        }
        let at = self
            .selected
            .as_ref()
            .and_then(|s| rows.iter().position(|r| r == s))
            .unwrap_or(0) as isize;
        let to = (at + delta).clamp(0, rows.len() as isize - 1) as usize;
        self.select(Some(rows[to].clone()));
    }

    /// The next blocked or done pane after the selection, wrapping around.
    fn next_needing_you(&mut self) {
        let rows = self.rows();
        let start = self
            .selected
            .as_ref()
            .and_then(|s| rows.iter().position(|r| r == s))
            .map_or(0, |at| at + 1);
        let next = (0..rows.len())
            .map(|i| &rows[(start + i) % rows.len()])
            .find(|item| matches!(self.status(item), Some(Status::Blocked | Status::Done)))
            .cloned();
        if next.is_some() {
            self.select(next);
        }
    }

    /// Left: from a pane to its session, from an open session to folding it.
    fn left(&mut self) {
        match self.selected.clone() {
            Some(Item::Pane(session, _)) if self.sort == Sort::Sessions => {
                self.select(Some(Item::Session(session)))
            }
            Some(Item::Session(session)) if !self.collapsed(&session) => self.toggle_collapsed(),
            _ => {}
        }
    }

    /// Right: unfold a folded session, or go into an open one's first pane.
    fn right(&mut self) {
        let Some(Item::Session(session)) = self.selected.clone() else {
            return;
        };
        if self.collapsed(&session) {
            self.toggle_collapsed();
        } else if let Some(row) = self.group(&session).and_then(|g| g.panes.first()) {
            let pane = Item::Pane(session, row.pane_id);
            self.select(Some(pane));
        }
    }

    /// Change the registry, then lay everything out again by it.
    fn change(&mut self, change: impl FnOnce(&mut Registry, &[Swatch], &[String])) {
        let sessions = self.sessions.clone();
        match self
            .looks
            .update(|registry, palette| change(registry, palette, &sessions))
        {
            Ok(()) => self.error = None,
            Err(e) => self.error = Some(format!("saving the sessions: {e}")),
        }
        self.registry = self.looks.load();
        self.arrange();
    }

    fn current_session(&self) -> Option<String> {
        self.selected.as_ref().map(|s| s.session().to_owned())
    }

    fn move_session(&mut self, delta: isize) {
        if let Some(name) = self.current_session() {
            self.change(|r, _, shown| r.move_among(&name, delta, shown));
        }
    }

    fn toggle_collapsed(&mut self) {
        if let Some(name) = self.current_session() {
            self.change(|r, _, _| r.toggle_collapsed(&name));
        }
    }

    fn cycle_color(&mut self, step: isize) {
        if let Some(name) = self.current_session() {
            self.change(|r, palette, _| r.cycle_color(&name, palette, step));
        }
    }

    fn toggle_sort(&mut self) {
        self.sort = match self.sort {
            Sort::Sessions => Sort::Priority,
            Sort::Priority => Sort::Sessions,
        };
        self.sort.save();
        self.arrange();
    }

    /// Scroll the conversation by half pages; drawing clamps it to the end.
    fn scroll_by(&self, halves: i32) {
        let step = i32::from(self.page.get() / 2).max(1) * halves;
        let next = (i32::from(self.top.get()) + step).clamp(0, i32::from(u16::MAX));
        self.pinned.set(Some(next as u16));
    }

    /// The pane whose conversation is shown: the selected one, or on a session
    /// header, that session's first.
    fn shown_pane(&self) -> Option<(&Group, &Row)> {
        match self.selected.as_ref()? {
            Item::Pane(s, p) => self.pane(s, *p),
            Item::Session(s) if !self.collapsed(s) => {
                let group = self.group(s)?;
                Some((group, group.panes.first()?))
            }
            Item::Session(_) => None,
        }
    }

    /// Panes by state, as herdr rolls them up: what needs you first.
    fn counts(&self) -> Line<'static> {
        let mut spans = vec![Span::raw(" ")];
        for (status, name) in [
            (Status::Blocked, "blocked"),
            (Status::Done, "done"),
            (Status::Working, "working"),
            (Status::Idle, "idle"),
        ] {
            let n = self
                .groups
                .iter()
                .flat_map(|g| &g.panes)
                .filter(|r| r.status == status)
                .count();
            if n > 0 {
                let (icon, st) = style(status);
                if spans.len() > 1 {
                    spans.push(Span::styled(" · ", DIM));
                }
                spans.push(Span::styled(format!("{icon} {n} {name}"), st));
            }
        }
        if spans.len() == 1 {
            spans.push(Span::raw("sessions"));
        }
        spans.push(Span::raw(" "));
        Line::from(spans)
    }

    /// A session header: fold mark, dot, name, and the rollup of its omps.
    fn session_item(&self, session: &str, selected: bool, width: usize) -> ListItem<'static> {
        let collapsed = self.collapsed(session);
        let bar = match selected {
            true => Span::styled("▌", Style::new().fg(ACCENT)),
            false => Span::raw(" "),
        };
        let group = self.group(session);
        let fold = match (group.is_some(), collapsed) {
            (_, true) => "▸ ",
            (true, false) => "▾ ",
            (false, false) => "  ",
        };
        let mut name = Style::new().add_modifier(Modifier::BOLD);
        if collapsed {
            name = name.patch(DIM);
        } else if selected {
            name = name.fg(ACCENT);
        }
        let rollup = group.map(|g| {
            let (icon, st) = style(g.status);
            let n = g.panes.len();
            Span::styled(
                if n > 1 {
                    format!("{icon}{n}")
                } else {
                    icon.to_owned()
                },
                st,
            )
        });
        // Bar, fold mark, dot, and a space before the rollup.
        let used = 1 + 2 + 2 + rollup.as_ref().map_or(0, |s| s.width() + 1);
        let room = width.saturating_sub(used);
        let mut shown: String = session.chars().take(room).collect();
        if session.chars().count() > room && room > 0 {
            shown.pop();
            shown.push('…');
        }
        let pad = room.saturating_sub(shown.chars().count());
        let mut spans = vec![
            bar,
            Span::styled(fold, DIM),
            self.dot(session),
            Span::styled(shown, name),
            Span::raw(" ".repeat(pad + 1)),
        ];
        spans.extend(rollup);
        ListItem::new(Line::from(spans))
    }

    /// An omp pane, on two lines: status, age and title; then where it is and
    /// what it last said. Under its session's header, or with its dot when
    /// there is none.
    fn pane_item(&self, group: &Group, row: &Row, selected: bool, now: u64) -> ListItem<'static> {
        // A bar down both lines rather than reversed video, which turns every
        // coloured span of a two-line entry into a block.
        let bar = || match selected {
            true => Span::styled("▌", Style::new().fg(ACCENT)),
            false => Span::raw(" "),
        };
        let lead = || match self.sort {
            Sort::Sessions => Span::raw("    "),
            Sort::Priority => Span::raw(" "),
        };
        let (icon, st) = style(row.status);
        let title = match row.title.as_deref() {
            Some(title) => {
                let mut style = Style::new();
                if selected {
                    style = style.fg(ACCENT).add_modifier(Modifier::BOLD);
                }
                Span::styled(title.to_owned(), style)
            }
            None => Span::styled("untitled", DIM.add_modifier(Modifier::ITALIC)),
        };
        let mut head = vec![bar(), lead()];
        if self.sort == Sort::Priority {
            head.push(self.dot(&group.session));
        }
        head.extend([
            Span::styled(format!("{icon} "), st),
            // How long it has been in its state.
            Span::styled(format!("{:>3} ", age(row.state_since, now)), DIM),
            title,
        ]);
        let place = match self.sort {
            Sort::Sessions => row.tab.clone(),
            Sort::Priority => format!("{} › {}", group.session, row.tab),
        };
        let mut body = vec![
            bar(),
            lead(),
            Span::raw(if self.sort == Sort::Priority {
                "    "
            } else {
                "  "
            }),
            Span::styled(format!("{place} · "), DIM),
        ];
        body.extend(summary(row));
        ListItem::new(vec![Line::from(head), Line::from(body)])
    }

    fn draw(&self, frame: &mut ratatui::Frame) {
        let [body, help_area] =
            Layout::vertical([Constraint::Min(4), Constraint::Length(1)]).areas(frame.area());
        let list_width = (body.width * 2 / 5).clamp(32.min(body.width), 64);
        let [list_area, detail_area] =
            Layout::horizontal([Constraint::Length(list_width), Constraint::Min(20)]).areas(body);
        self.draw_list(frame, list_area);
        self.draw_detail(frame, detail_area);

        let help = match &self.error {
            Some(error) => Line::styled(error.clone(), style(Status::Blocked).1),
            None => Line::styled(
                "enter jump · tab next needing you · space/h/l fold · J/K reorder · c/C colour · s sort · ^d/^u scroll · q quit",
                DIM,
            ),
        };
        frame.render_widget(Paragraph::new(help), help_area);
    }

    fn draw_list(&self, frame: &mut ratatui::Frame, area: Rect) {
        let now = now_ms();
        let sort_name = match self.sort {
            Sort::Sessions => " by session ",
            Sort::Priority => " by priority ",
        };
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(DIM)
            .title_style(Style::new().fg(Color::Reset))
            .title(self.counts())
            .title_bottom(Line::styled(sort_name, DIM).right_aligned());
        let width = block.inner(area).width as usize;
        let rows = self.rows();
        let highlight = self
            .selected
            .as_ref()
            .and_then(|s| rows.iter().position(|r| r == s));
        let items: Vec<ListItem> = rows
            .iter()
            .map(|item| {
                let selected = self.selected.as_ref() == Some(item);
                match item {
                    Item::Session(s) => self.session_item(s, selected, width),
                    Item::Pane(s, p) => match self.pane(s, *p) {
                        Some((group, row)) => self.pane_item(group, row, selected, now),
                        None => ListItem::new(""),
                    },
                }
            })
            .collect();
        if items.is_empty() {
            frame.render_widget(
                Paragraph::new("No zellij session.").style(DIM).block(block),
                area,
            );
            return;
        }
        // Selection only drives scrolling; it is drawn by the bar.
        let list = List::new(items).block(block);
        let mut state = ListState::default().with_selected(highlight);
        frame.render_stateful_widget(list, area, &mut state);
    }

    /// The shown pane's conversation, framed in its session's colour.
    fn draw_detail(&self, frame: &mut ratatui::Frame, area: Rect) {
        let framed = |title: Line<'static>, session: &str| {
            let border = self.color(session).map_or(DIM, |c| Style::new().fg(c));
            Block::bordered()
                .border_type(BorderType::Rounded)
                .border_style(border)
                .title_style(Style::new().fg(Color::Reset))
                .title(title)
                .padding(Padding::horizontal(1))
        };
        let Some((group, row)) = self.shown_pane() else {
            if let Some(session) = self.current_session() {
                let title = Line::from(vec![
                    Span::raw(" "),
                    self.dot(&session),
                    Span::styled(
                        format!("{session} "),
                        Style::new().add_modifier(Modifier::BOLD),
                    ),
                ]);
                let what = if self.collapsed(&session) {
                    "Folded: space or l shows its omps. Enter opens the session."
                } else {
                    "No omp in this session. Enter opens it."
                };
                frame.render_widget(
                    Paragraph::new(what)
                        .style(DIM)
                        .block(framed(title, &session)),
                    area,
                );
            }
            return;
        };
        let bold = Style::new().add_modifier(Modifier::BOLD);
        let mut title = vec![
            Span::raw(" "),
            self.dot(&group.session),
            Span::styled(
                format!(
                    "{} › {} · {} ",
                    group.session,
                    row.tab,
                    home_relative(&row.cwd)
                ),
                bold,
            ),
        ];
        if let Some(git) = &row.git {
            title.extend(git_spans(git));
            title.push(Span::raw(" "));
        }
        let mut block = framed(Line::from(title), &group.session)
            .title_bottom(Line::from(meta(row)).right_aligned());
        let inner = block.inner(area);
        let width = inner.width;
        let key = DetailKey {
            session_file: row.session_file.as_ref().and_then(|path| {
                let meta = fs::metadata(path).ok()?;
                Some((path.clone(), meta.len(), meta.modified().ok()))
            }),
            last_message: row.last_message.clone(),
            width,
        };
        let mut cache = self.detail.borrow_mut();
        if !cache.as_ref().is_some_and(|d| d.key == key) {
            let entries = key
                .session_file
                .as_ref()
                .and_then(|(path, ..)| transcript::read(path))
                .filter(|entries| !entries.is_empty())
                .unwrap_or_else(|| {
                    row.last_message
                        .iter()
                        .cloned()
                        .map(Entry::Assistant)
                        .collect()
                });
            let (lines, anchor) = render_conversation(&entries, width);
            *cache = Some(Detail { key, lines, anchor });
        }
        let detail = cache.as_ref().expect("filled above");
        let mut lines = detail.lines.clone();
        // What it waits on comes last, after what led to it, and is shown first.
        let blocked = row
            .blocked_reason
            .as_deref()
            .filter(|_| row.status == Status::Blocked);
        if let Some(reason) = blocked {
            if !lines.is_empty() {
                lines.push(Line::raw(""));
            }
            for line in reason.lines() {
                lines.push(Line::styled(line.to_owned(), style(Status::Blocked).1));
            }
        }
        let page = inner.height;
        let total = lines.len() as u16;
        let follow = if blocked.is_some() {
            total
        } else {
            detail.anchor
        };
        let top = self
            .pinned
            .get()
            .unwrap_or(follow)
            .min(total.saturating_sub(page));
        if self.pinned.get().is_some() {
            self.pinned.set(Some(top));
        }
        self.top.set(top);
        self.page.set(page);
        if total > page {
            let shown = format!(" {}-{}/{total} ", top + 1, (top + page).min(total));
            block = block.title(Line::styled(shown, DIM).right_aligned());
        }
        frame.render_widget(Paragraph::new(lines).block(block).scroll((top, 0)), area);
    }
}

/// Live sessions from listings that can leave one out now and then (see
/// `zellij::run`): one is only dropped once it misses a few in a row.
#[derive(Default)]
struct Seen(HashMap<String, u8>);

impl Seen {
    fn observe(&mut self, listed: impl IntoIterator<Item = String>) -> Vec<String> {
        for misses in self.0.values_mut() {
            *misses += 1;
        }
        for name in listed {
            self.0.insert(name, 0);
        }
        self.0.retain(|_, misses| *misses < 3);
        // By name: the registry appends sessions it lacks in this order.
        let mut names: Vec<String> = self.0.keys().cloned().collect();
        names.sort();
        names
    }
}

fn collect(seen: &mut Seen) -> Snapshot {
    let store = Store::from_env();
    let groups = store.collect(&zellij::live(&store.sessions()), now_ms());
    let sessions = seen.observe(
        zellij::live_sessions()
            .into_iter()
            .chain(groups.iter().map(|g| g.session.clone())),
    );
    // A session gets its colour as soon as it is seen: niri borders its windows
    // and the bar marks them from the registry.
    let _ = zellij_sessions::Store::from_env().update(|registry, palette| {
        let names: Vec<&str> = sessions.iter().map(String::as_str).collect();
        registry.ensure(&names, palette, &sessions)
    });
    Snapshot { groups, sessions }
}

/// Run the picker; what was picked, if anything, once the terminal is restored.
pub fn pick() -> Result<Option<Pick>> {
    // Refreshing shells out to zellij once or twice per session, so it stays off
    // the input loop.
    let (tx, rx) = mpsc::channel();
    let (poke_tx, poke_rx) = mpsc::channel::<()>();
    std::thread::spawn(markdown::warm);
    std::thread::spawn(move || {
        let mut git = git::Cache::new(GIT_TTL);
        let mut seen = Seen::default();
        // The first rows go out before git status, which takes a while on a stale index.
        let mut snapshot = collect(&mut seen);
        if tx.send(snapshot.clone()).is_err() {
            return;
        }
        loop {
            git.annotate(&mut snapshot.groups);
            if tx.send(snapshot).is_err() {
                return;
            }
            if let Err(mpsc::RecvTimeoutError::Disconnected) = poke_rx.recv_timeout(REFRESH) {
                return;
            }
            snapshot = collect(&mut seen);
        }
    });

    let mut app = App::new(Sort::load());
    // The first snapshot before drawing, so the picker does not open empty.
    if let Ok(snapshot) = rx.recv() {
        app.update(snapshot);
    }

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, &mut app, &rx, &poke_tx);
    ratatui::restore();
    result
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    app: &mut App,
    rx: &mpsc::Receiver<Snapshot>,
    poke: &mpsc::Sender<()>,
) -> Result<Option<Pick>> {
    loop {
        while let Ok(snapshot) = rx.try_recv() {
            app.update(snapshot);
        }
        terminal.draw(|frame| app.draw(frame))?;

        if !event::poll(Duration::from_millis(200))? {
            continue;
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
            KeyCode::Char('c') if ctrl => return Ok(None),
            KeyCode::Char('d') if ctrl => app.scroll_by(1),
            KeyCode::Char('u') if ctrl => app.scroll_by(-1),
            KeyCode::PageDown => app.scroll_by(2),
            KeyCode::PageUp => app.scroll_by(-2),
            KeyCode::Char('j') | KeyCode::Down => app.step(1),
            KeyCode::Char('k') | KeyCode::Up => app.step(-1),
            KeyCode::Char('g') | KeyCode::Home => app.step(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => app.step(isize::MAX / 2),
            KeyCode::Char('h') | KeyCode::Left => app.left(),
            KeyCode::Char('l') | KeyCode::Right => app.right(),
            KeyCode::Char(' ' | 'x') => app.toggle_collapsed(),
            KeyCode::Char('J') => app.move_session(1),
            KeyCode::Char('K') => app.move_session(-1),
            KeyCode::Char('c') => app.cycle_color(1),
            KeyCode::Char('C') => app.cycle_color(-1),
            KeyCode::Tab => app.next_needing_you(),
            KeyCode::Char('s') => app.toggle_sort(),
            KeyCode::Char('r') => {
                let _ = poke.send(());
            }
            KeyCode::Enter => match app.selected.clone() {
                Some(Item::Pane(session, pane)) => return Ok(Some(Pick::Pane(session, pane))),
                Some(Item::Session(session)) => return Ok(Some(Pick::Session(session))),
                None => {}
            },
            _ => {}
        }
    }
}
