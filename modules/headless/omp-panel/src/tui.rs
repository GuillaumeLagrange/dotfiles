//! The floating picker: sessions and their omp panes, the selected pane's last
//! message below, Enter to jump.

use std::cell::{Cell, RefCell};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, List, ListItem, ListState, Padding, Paragraph};
use ratatui::DefaultTerminal;

use crate::markdown;
use crate::state::{now_ms, Group, Row, Status, Store};
use crate::zellij;

const REFRESH: Duration = Duration::from_secs(1);
const ACCENT: Color = Color::Blue;

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

fn age(updated_at: u64, now: u64) -> String {
    let secs = now.saturating_sub(updated_at) / 1000;
    match secs {
        0..60 => format!("{secs}s"),
        60..3600 => format!("{}m", secs / 60),
        3600..86400 => format!("{}h", secs / 3600),
        _ => format!("{}d", secs / 86400),
    }
}

/// A blocked pane's question, else the first line of its last reply.
fn summary(row: &Row) -> Vec<Span<'static>> {
    match row.blocked_reason.as_deref() {
        Some(reason) if row.status == Status::Blocked => {
            let first = reason.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
            vec![Span::raw(first.trim().to_owned())]
        }
        _ => markdown::first_line(row.last_message.as_deref().unwrap_or("")).spans,
    }
}

fn home_relative(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_owned(),
    }
}

/// Selectable panes in display order, as (group, row) indexes.
fn pane_indexes(groups: &[Group]) -> Vec<(usize, usize)> {
    groups
        .iter()
        .enumerate()
        .flat_map(|(g, group)| (0..group.panes.len()).map(move |r| (g, r)))
        .collect()
}

struct App {
    groups: Vec<Group>,
    /// Kept by identity so a refresh that adds or drops panes does not move it.
    selected: Option<(String, u32)>,
    /// The selected reply as last rendered, with the width it was wrapped to:
    /// drawing runs several times a second and the text rarely changes.
    detail: RefCell<Option<(String, u16, Vec<Line<'static>>)>>,
    /// First line of the reply shown, and how many fit; set by drawing.
    scroll: Cell<u16>,
    page: Cell<u16>,
}

impl App {
    fn update(&mut self, groups: Vec<Group>) {
        let keep = self.selected.as_ref().is_some_and(|(s, p)| {
            groups
                .iter()
                .any(|g| &g.session == s && g.panes.iter().any(|r| r.pane_id == *p))
        });
        if !keep {
            // Start on what most needs attention.
            self.selected = [Status::Blocked, Status::Done]
                .iter()
                .find_map(|want| {
                    groups.iter().find_map(|g| {
                        g.panes
                            .iter()
                            .find(|r| r.status == *want)
                            .map(|r| (g.session.clone(), r.pane_id))
                    })
                })
                .or_else(|| {
                    groups
                        .iter()
                        .find_map(|g| g.panes.first().map(|r| (g.session.clone(), r.pane_id)))
                });
        }
        self.groups = groups;
    }

    fn position(&self) -> Option<usize> {
        let (session, pane) = self.selected.as_ref()?;
        pane_indexes(&self.groups).iter().position(|&(g, r)| {
            &self.groups[g].session == session && self.groups[g].panes[r].pane_id == *pane
        })
    }

    fn step(&mut self, delta: isize) {
        let panes = pane_indexes(&self.groups);
        if panes.is_empty() {
            return;
        }
        let at = self.position().unwrap_or(0) as isize;
        let (g, r) = panes[(at + delta).clamp(0, panes.len() as isize - 1) as usize];
        let next = Some((
            self.groups[g].session.clone(),
            self.groups[g].panes[r].pane_id,
        ));
        if next != self.selected {
            self.scroll.set(0);
        }
        self.selected = next;
    }

    /// Scroll the reply by half pages; drawing clamps it to the end.
    fn scroll_by(&self, halves: i32) {
        let step = i32::from(self.page.get() / 2).max(1) * halves;
        let next = (i32::from(self.scroll.get()) + step).clamp(0, i32::from(u16::MAX));
        self.scroll.set(next as u16);
    }

    fn selected_row(&self) -> Option<(&Group, &Row)> {
        let (session, pane) = self.selected.as_ref()?;
        let group = self.groups.iter().find(|g| &g.session == session)?;
        Some((group, group.panes.iter().find(|r| r.pane_id == *pane)?))
    }

    fn draw(&self, frame: &mut ratatui::Frame) {
        let now = now_ms();
        // The list only as tall as its rows, up to half: the reply below is what
        // there is to read. A session header is one row, a pane two.
        let rows: usize = self.groups.iter().map(|g| 1 + 2 * g.panes.len()).sum();
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
                .border_style(Style::new().fg(Color::DarkGray))
                // Otherwise the title takes the border's grey.
                .title_style(Style::new().fg(Color::Reset))
                .title(title)
        };

        let mut items = Vec::new();
        let mut highlight = None;
        let current = self
            .selected_row()
            .map(|(g, r)| (g.session.as_str(), r.pane_id));
        for group in &self.groups {
            let (icon, st) = style(group.status);
            items.push(ListItem::new(Line::from(vec![
                Span::styled(format!("{icon} "), st),
                Span::styled(
                    group.session.clone(),
                    Style::new().add_modifier(Modifier::BOLD),
                ),
            ])));
            let tab_width = group
                .panes
                .iter()
                .map(|r| r.tab.chars().count())
                .max()
                .unwrap_or(0);
            for row in &group.panes {
                let selected = current == Some((group.session.as_str(), row.pane_id));
                if selected {
                    highlight = Some(items.len());
                }
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
                    None => Span::styled(
                        "untitled",
                        Style::new()
                            .fg(Color::DarkGray)
                            .add_modifier(Modifier::ITALIC),
                    ),
                };
                let head = vec![
                    bar(),
                    Span::styled(format!("{icon} "), st),
                    Span::raw(format!("{:<tab_width$}  ", row.tab)),
                    Span::styled(
                        format!("{:>3}  ", age(row.updated_at, now)),
                        Style::new().fg(Color::DarkGray),
                    ),
                    title,
                ];
                // The reply's first line, under the title.
                let indent = 2 + tab_width + 2 + 3 + 2;
                let mut body = vec![bar(), Span::raw(" ".repeat(indent))];
                body.extend(summary(row));
                items.push(ListItem::new(vec![Line::from(head), Line::from(body)]));
            }
        }
        let list_block = boxed(Line::raw(" sessions "));
        if items.is_empty() {
            frame.render_widget(
                Paragraph::new("No omp running in any zellij session.")
                    .style(Style::new().fg(Color::DarkGray))
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
            let mut lines = Vec::new();
            if let Some(reason) = row
                .blocked_reason
                .as_deref()
                .filter(|_| row.status == Status::Blocked)
            {
                lines.push(Line::styled(reason.to_owned(), style(Status::Blocked).1));
                lines.push(Line::raw(""));
            }
            let title = format!(
                " {} › {} · {} ",
                group.session,
                row.tab,
                home_relative(&row.cwd)
            );
            let mut block = boxed(Line::styled(
                title,
                Style::new().add_modifier(Modifier::BOLD),
            ))
            .padding(Padding::horizontal(1));
            let inner = block.inner(detail_area);
            let message = row.last_message.as_deref().unwrap_or("");
            let width = inner.width;
            let mut cache = self.detail.borrow_mut();
            if !cache
                .as_ref()
                .is_some_and(|(text, w, _)| text == message && *w == width)
            {
                let rendered = markdown::render(message, width as usize, true);
                *cache = Some((message.to_owned(), width, rendered));
            }
            lines.extend(
                cache
                    .as_ref()
                    .map(|(_, _, l)| l.clone())
                    .unwrap_or_default(),
            );
            let page = inner.height;
            let total = lines.len() as u16;
            let scroll = self.scroll.get().min(total.saturating_sub(page));
            self.scroll.set(scroll);
            self.page.set(page);
            if total > page {
                let shown = format!(" {}-{}/{total} ", scroll + 1, (scroll + page).min(total));
                block = block
                    .title(Line::styled(shown, Style::new().fg(Color::DarkGray)).right_aligned());
            }
            frame.render_widget(
                Paragraph::new(lines).block(block).scroll((scroll, 0)),
                detail_area,
            );
        }

        frame.render_widget(
            Paragraph::new("enter jump · j/k move · ^d/^u scroll · r refresh · q quit")
                .style(Style::new().fg(Color::DarkGray)),
            help_area,
        );
    }
}

fn snapshot() -> Vec<Group> {
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
    std::thread::spawn(move || loop {
        if tx.send(snapshot()).is_err() {
            return;
        }
        if let Err(mpsc::RecvTimeoutError::Disconnected) = poke_rx.recv_timeout(REFRESH) {
            return;
        }
    });

    let mut app = App {
        groups: Vec::new(),
        selected: None,
        detail: RefCell::new(None),
        scroll: Cell::new(0),
        page: Cell::new(0),
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
