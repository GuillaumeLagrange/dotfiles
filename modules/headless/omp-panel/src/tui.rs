//! The floating picker: sessions and their omp panes, the selected pane's
//! conversation below, Enter to jump.

use std::cell::{Cell, RefCell};
use std::cmp::Reverse;
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, SystemTime};

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, List, ListItem, ListState, Padding, Paragraph};
use ratatui::DefaultTerminal;

use crate::git;
use crate::markdown;
use crate::state::{now_ms, Group, Row, Status, Store};
use crate::transcript::{self, Entry};
use crate::zellij;

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

/// Branch, model, context use, and whether a client shows the pane: after the
/// title, each part only when known.
fn meta(row: &Row) -> Vec<Span<'static>> {
    let mut parts = Vec::new();
    if let Some(git) = &row.git {
        parts.push(git_spans(git));
    }
    if let Some(model) = &row.model {
        parts.push(vec![Span::styled(model.clone(), DIM)]);
    }
    if let Some(percent) = row.context_percent {
        let style = match percent {
            p if p >= 80.0 => Style::new().fg(Color::Red),
            p if p >= 60.0 => Style::new().fg(Color::Yellow),
            _ => DIM,
        };
        parts.push(vec![Span::styled(format!("{percent:.0}% ctx"), style)]);
    }
    if row.focused {
        parts.push(vec![Span::styled("on screen", DIM)]);
    }
    let mut spans = Vec::new();
    for (i, part) in parts.into_iter().enumerate() {
        spans.push(Span::styled(if i == 0 { "  " } else { " · " }, DIM));
        spans.extend(part);
    }
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

/// Selectable panes in display order, as (group, row) indexes.
fn order(groups: &[Group], sort: Sort) -> Vec<(usize, usize)> {
    let mut panes: Vec<(usize, usize)> = groups
        .iter()
        .enumerate()
        .flat_map(|(g, group)| (0..group.panes.len()).map(move |r| (g, r)))
        .collect();
    if sort == Sort::Priority {
        panes.sort_by_key(|&(g, r)| {
            let row = &groups[g].panes[r];
            (Reverse(row.status), Reverse(row.state_since))
        });
    }
    panes
}

struct App {
    groups: Vec<Group>,
    sort: Sort,
    /// Kept by identity so a refresh that adds or drops panes does not move it.
    selected: Option<(String, u32)>,
    /// The selected conversation as last rendered: drawing runs several times a
    /// second and the session file changes far less often.
    detail: RefCell<Option<Detail>>,
    /// First line of the conversation shown, how many fit, and where the user
    /// scrolled to; unscrolled, it follows the last question.
    top: Cell<u16>,
    page: Cell<u16>,
    pinned: Cell<Option<u16>>,
}

impl App {
    fn update(&mut self, groups: Vec<Group>) {
        let keep = self.selected.as_ref().is_some_and(|(s, p)| {
            groups
                .iter()
                .any(|g| &g.session == s && g.panes.iter().any(|r| r.pane_id == *p))
        });
        self.groups = groups;
        if !keep {
            // Start on what most needs attention.
            let panes = order(&self.groups, self.sort);
            let start = [Status::Blocked, Status::Done]
                .iter()
                .find_map(|want| {
                    panes
                        .iter()
                        .find(|&&(g, r)| self.groups[g].panes[r].status == *want)
                })
                .or(panes.first())
                .copied();
            self.selected = start.map(|(g, r)| self.id(g, r));
        }
    }

    fn id(&self, g: usize, r: usize) -> (String, u32) {
        (
            self.groups[g].session.clone(),
            self.groups[g].panes[r].pane_id,
        )
    }

    fn select(&mut self, g: usize, r: usize) {
        let next = Some(self.id(g, r));
        if next != self.selected {
            self.pinned.set(None);
        }
        self.selected = next;
    }

    fn position(&self, panes: &[(usize, usize)]) -> Option<usize> {
        let (session, pane) = self.selected.as_ref()?;
        panes.iter().position(|&(g, r)| {
            &self.groups[g].session == session && self.groups[g].panes[r].pane_id == *pane
        })
    }

    fn step(&mut self, delta: isize) {
        let panes = order(&self.groups, self.sort);
        if panes.is_empty() {
            return;
        }
        let at = self.position(&panes).unwrap_or(0) as isize;
        let (g, r) = panes[(at + delta).clamp(0, panes.len() as isize - 1) as usize];
        self.select(g, r);
    }

    /// The next blocked or done pane after the selection, wrapping around.
    fn next_needing_you(&mut self) {
        let panes = order(&self.groups, self.sort);
        let start = self.position(&panes).map_or(0, |at| at + 1);
        let next = (0..panes.len())
            .map(|i| panes[(start + i) % panes.len()])
            .find(|&(g, r)| {
                matches!(
                    self.groups[g].panes[r].status,
                    Status::Blocked | Status::Done
                )
            });
        if let Some((g, r)) = next {
            self.select(g, r);
        }
    }

    fn toggle_sort(&mut self) {
        self.sort = match self.sort {
            Sort::Sessions => Sort::Priority,
            Sort::Priority => Sort::Sessions,
        };
        self.sort.save();
    }

    /// Scroll the conversation by half pages; drawing clamps it to the end.
    fn scroll_by(&self, halves: i32) {
        let step = i32::from(self.page.get() / 2).max(1) * halves;
        let next = (i32::from(self.top.get()) + step).clamp(0, i32::from(u16::MAX));
        self.pinned.set(Some(next as u16));
    }

    fn selected_row(&self) -> Option<(&Group, &Row)> {
        let (session, pane) = self.selected.as_ref()?;
        let group = self.groups.iter().find(|g| &g.session == session)?;
        Some((group, group.panes.iter().find(|r| r.pane_id == *pane)?))
    }

    /// Where a pane is: its tab, prefixed by its session when no header says it.
    fn label(&self, group: &Group, row: &Row) -> String {
        match self.sort {
            Sort::Sessions => row.tab.clone(),
            Sort::Priority => format!("{} › {}", group.session, row.tab),
        }
    }

    fn pane_item(
        &self,
        group: &Group,
        row: &Row,
        label_width: usize,
        selected: bool,
        now: u64,
    ) -> ListItem<'static> {
        // A bar down both lines rather than reversed video, which turns every
        // coloured span of a two-line entry into a block.
        let bar = || match selected {
            true => Span::styled("▌ ", Style::new().fg(ACCENT)),
            false => Span::raw("  "),
        };
        let (icon, st) = style(row.status);
        let title = match row.title.as_deref() {
            Some(title) => {
                let mut style = Style::new().add_modifier(Modifier::BOLD);
                if selected {
                    style = style.fg(ACCENT);
                }
                Span::styled(title.to_owned(), style)
            }
            None => Span::styled("untitled", DIM.add_modifier(Modifier::ITALIC)),
        };
        let label = self.label(group, row);
        let pad = label_width.saturating_sub(label.chars().count());
        let mut head = vec![
            bar(),
            Span::styled(format!("{icon} "), st),
            Span::raw(format!("{label}{}  ", " ".repeat(pad))),
            // How long it has been in its state.
            Span::styled(format!("{:>3}  ", age(row.state_since, now)), DIM),
            title,
        ];
        head.extend(meta(row));
        let indent = 2 + label_width + 2 + 3 + 2;
        let mut body = vec![bar(), Span::raw(" ".repeat(indent))];
        body.extend(summary(row));
        ListItem::new(vec![Line::from(head), Line::from(body)])
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
            spans.push(Span::raw("agents"));
        }
        spans.push(Span::raw(" "));
        Line::from(spans)
    }

    fn draw(&self, frame: &mut ratatui::Frame) {
        let now = now_ms();
        let panes = order(&self.groups, self.sort);
        // The list only as tall as its rows, up to half: the reply below is what
        // there is to read. A session header is one row, a pane two.
        let headers = match self.sort {
            Sort::Sessions => self.groups.len(),
            Sort::Priority => 0,
        };
        let rows = headers + 2 * panes.len();
        let list_height = (rows.max(1) as u16 + 2).min(frame.area().height / 2);
        let [list_area, detail_area, help_area] = Layout::vertical([
            Constraint::Length(list_height),
            Constraint::Min(4),
            Constraint::Length(1),
        ])
        .areas(frame.area());
        let boxed = |title: Line<'static>| {
            Block::bordered()
                .border_type(BorderType::Rounded)
                .border_style(DIM)
                // Otherwise the title takes the border's grey.
                .title_style(Style::new().fg(Color::Reset))
                .title(title)
        };

        let current = self
            .selected_row()
            .map(|(g, r)| (g.session.as_str(), r.pane_id));
        let is_selected =
            |group: &Group, row: &Row| current == Some((group.session.as_str(), row.pane_id));
        let mut items = Vec::new();
        let mut highlight = None;
        match self.sort {
            Sort::Sessions => {
                for group in &self.groups {
                    let (icon, st) = style(group.status);
                    items.push(ListItem::new(Line::from(vec![
                        Span::styled(format!("{icon} "), st),
                        Span::styled(
                            group.session.clone(),
                            Style::new().add_modifier(Modifier::BOLD),
                        ),
                    ])));
                    let width = group
                        .panes
                        .iter()
                        .map(|r| self.label(group, r).chars().count())
                        .max()
                        .unwrap_or(0);
                    for row in &group.panes {
                        let selected = is_selected(group, row);
                        if selected {
                            highlight = Some(items.len());
                        }
                        items.push(self.pane_item(group, row, width, selected, now));
                    }
                }
            }
            Sort::Priority => {
                let width = panes
                    .iter()
                    .map(|&(g, r)| {
                        let group = &self.groups[g];
                        self.label(group, &group.panes[r]).chars().count()
                    })
                    .max()
                    .unwrap_or(0);
                for &(g, r) in &panes {
                    let (group, row) = (&self.groups[g], &self.groups[g].panes[r]);
                    let selected = is_selected(group, row);
                    if selected {
                        highlight = Some(items.len());
                    }
                    items.push(self.pane_item(group, row, width, selected, now));
                }
            }
        }
        let sort_name = match self.sort {
            Sort::Sessions => " by session ",
            Sort::Priority => " by priority ",
        };
        let list_block = boxed(self.counts()).title(Line::styled(sort_name, DIM).right_aligned());
        if items.is_empty() {
            frame.render_widget(
                Paragraph::new("No omp running in any zellij session.")
                    .style(DIM)
                    .block(list_block),
                list_area,
            );
        } else {
            // Selection only drives scrolling; it is drawn by the bar.
            let list = List::new(items).block(list_block);
            let mut state = ListState::default().with_selected(highlight);
            frame.render_stateful_widget(list, list_area, &mut state);
        }

        if let Some((group, row)) = self.selected_row() {
            let bold = Style::new().add_modifier(Modifier::BOLD);
            let mut title = vec![Span::styled(
                format!(
                    " {} › {} · {} ",
                    group.session,
                    row.tab,
                    home_relative(&row.cwd)
                ),
                bold,
            )];
            if let Some(git) = &row.git {
                title.extend(git_spans(git));
                title.push(Span::raw(" "));
            }
            let mut block = boxed(Line::from(title)).padding(Padding::horizontal(1));
            let inner = block.inner(detail_area);
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
            frame.render_widget(
                Paragraph::new(lines).block(block).scroll((top, 0)),
                detail_area,
            );
        }

        frame.render_widget(
            Paragraph::new(
                "enter jump · tab next needing you · s sort · j/k move · ^d/^u scroll · r refresh · q quit",
            )
            .style(DIM),
            help_area,
        );
    }
}

fn collect() -> Vec<Group> {
    let store = Store::from_env();
    store.collect(&zellij::live(&store.sessions()), now_ms())
}

/// Run the picker; the chosen pane, if any, once the terminal is restored.
pub fn pick() -> Result<Option<(String, u32)>> {
    // Refreshing shells out to zellij once or twice per session, so it stays off
    // the input loop.
    let (tx, rx) = mpsc::channel();
    let (poke_tx, poke_rx) = mpsc::channel::<()>();
    std::thread::spawn(markdown::warm);
    std::thread::spawn(move || {
        let mut git = git::Cache::new(GIT_TTL);
        // The first rows go out before git status, which takes a while on a stale index.
        let mut groups = collect();
        if tx.send(groups.clone()).is_err() {
            return;
        }
        loop {
            git.annotate(&mut groups);
            if tx.send(groups).is_err() {
                return;
            }
            if let Err(mpsc::RecvTimeoutError::Disconnected) = poke_rx.recv_timeout(REFRESH) {
                return;
            }
            groups = collect();
        }
    });

    let mut app = App {
        groups: Vec::new(),
        sort: Sort::load(),
        selected: None,
        detail: RefCell::new(None),
        top: Cell::new(0),
        page: Cell::new(0),
        pinned: Cell::new(None),
    };
    // The first snapshot before drawing, so the picker does not open empty.
    if let Ok(groups) = rx.recv() {
        app.update(groups);
    }

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, &mut app, &rx, &poke_tx);
    ratatui::restore();
    result
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    app: &mut App,
    rx: &mpsc::Receiver<Vec<Group>>,
    poke: &mpsc::Sender<()>,
) -> Result<Option<(String, u32)>> {
    loop {
        while let Ok(groups) = rx.try_recv() {
            app.update(groups);
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
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => return Ok(None),
            KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => app.scroll_by(1),
            KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.scroll_by(-1)
            }
            KeyCode::PageDown => app.scroll_by(2),
            KeyCode::PageUp => app.scroll_by(-2),
            KeyCode::Char('j') | KeyCode::Down => app.step(1),
            KeyCode::Char('k') | KeyCode::Up => app.step(-1),
            KeyCode::Char('g') | KeyCode::Home => app.step(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => app.step(isize::MAX / 2),
            KeyCode::Tab => app.next_needing_you(),
            KeyCode::Char('s') => app.toggle_sort(),
            KeyCode::Char('r') => {
                let _ = poke.send(());
            }
            KeyCode::Enter => {
                if let Some((group, row)) = app.selected_row() {
                    return Ok(Some((group.session.clone(), row.pane_id)));
                }
            }
            _ => {}
        }
    }
}
