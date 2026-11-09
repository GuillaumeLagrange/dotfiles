//! The pane finder: every pane of every session with the command running in it,
//! filtered as you type, Enter to jump.

use std::sync::mpsc;
use std::time::Duration;

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Position};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, List, ListItem, ListState, Paragraph};
use ratatui::DefaultTerminal;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::panes::{self, PaneRow};
use crate::tui::{home_relative, ACCENT};

const REFRESH: Duration = Duration::from_secs(2);
/// Longer commands are cut, so the cwd column stays in view.
const COMMAND_WIDTH: usize = 50;

fn cut(text: &str, max: usize) -> String {
    if text.width() <= max {
        return text.to_owned();
    }
    let mut out = String::new();
    let mut width = 0;
    for c in text.chars() {
        let w = c.width().unwrap_or(0);
        if width + w + 1 > max {
            break;
        }
        width += w;
        out.push(c);
    }
    out.push('…');
    out
}

fn pad(text: &str, width: usize) -> String {
    format!("{text}{}", " ".repeat(width.saturating_sub(text.width())))
}

struct App {
    rows: Vec<PaneRow>,
    query: String,
    /// Kept by identity so a refresh or a keystroke does not move it.
    selected: Option<(String, u32)>,
}

impl App {
    fn visible(&self) -> Vec<&PaneRow> {
        self.rows
            .iter()
            .filter(|r| r.matches(&self.query))
            .collect()
    }

    fn position(&self, visible: &[&PaneRow]) -> Option<usize> {
        let (session, pane) = self.selected.as_ref()?;
        visible
            .iter()
            .position(|r| &r.session == session && r.pane_id == *pane)
    }

    /// Keep the selected pane while it is shown, else take the first one.
    fn reselect(&mut self) {
        let visible = self.visible();
        if self.position(&visible).is_none() {
            self.selected = visible.first().map(|r| (r.session.clone(), r.pane_id));
        }
    }

    /// A new query starts on its first match, as in fzf.
    fn refilter(&mut self) {
        self.selected = None;
        self.reselect();
    }

    fn step(&mut self, delta: isize) {
        let visible = self.visible();
        if visible.is_empty() {
            return;
        }
        let at = self.position(&visible).unwrap_or(0) as isize;
        let row = visible[(at + delta).clamp(0, visible.len() as isize - 1) as usize];
        self.selected = Some((row.session.clone(), row.pane_id));
    }

    fn draw(&self, frame: &mut ratatui::Frame) {
        let [input_area, list_area, help_area] = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .areas(frame.area());
        let visible = self.visible();
        let boxed = || {
            Block::bordered()
                .border_type(BorderType::Rounded)
                .border_style(Style::new().fg(Color::DarkGray))
                .title_style(Style::new().fg(Color::Reset))
        };

        let count = format!(" {}/{} ", visible.len(), self.rows.len());
        let input = boxed()
            .title(Line::raw(" panes "))
            .title(Line::styled(count, Style::new().fg(Color::DarkGray)).right_aligned());
        let inner = input.inner(input_area);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("› ", Style::new().fg(ACCENT)),
                Span::raw(self.query.clone()),
            ]))
            .block(input),
            input_area,
        );
        frame.set_cursor_position(Position::new(
            inner.x + 2 + self.query.width() as u16,
            inner.y,
        ));

        let widest = |field: fn(&PaneRow) -> &str| {
            visible.iter().map(|r| field(r).width()).max().unwrap_or(0)
        };
        let session_width = widest(|r| &r.session);
        let tab_width = widest(|r| &r.tab);
        let command_width = widest(|r| &r.command).min(COMMAND_WIDTH);
        let selected = self.position(&visible);
        let items: Vec<ListItem> = visible
            .iter()
            .enumerate()
            .map(|(i, row)| {
                let is_selected = selected == Some(i);
                let mut command = Style::new().add_modifier(Modifier::BOLD);
                if row.idle {
                    command = Style::new().fg(Color::DarkGray);
                }
                if is_selected {
                    command = command.fg(ACCENT);
                }
                ListItem::new(Line::from(vec![
                    match is_selected {
                        true => Span::styled("▌ ", Style::new().fg(ACCENT)),
                        false => Span::raw("  "),
                    },
                    Span::raw(pad(&row.session, session_width + 2)),
                    Span::raw(pad(&row.tab, tab_width + 2)),
                    Span::styled(
                        pad(&cut(&row.command, COMMAND_WIDTH), command_width + 2),
                        command,
                    ),
                    Span::styled(home_relative(&row.cwd), Style::new().fg(Color::DarkGray)),
                ]))
            })
            .collect();
        if items.is_empty() {
            frame.render_widget(
                Paragraph::new("No pane matches.").style(Style::new().fg(Color::DarkGray)),
                list_area,
            );
        } else {
            let mut state = ListState::default().with_selected(selected);
            frame.render_stateful_widget(List::new(items), list_area, &mut state);
        }

        frame.render_widget(
            Paragraph::new("type to filter · enter jump · ↑/↓ ^p/^n move · ^u clear · esc quit")
                .style(Style::new().fg(Color::DarkGray)),
            help_area,
        );
    }
}

/// Run the finder; the chosen pane, if any, once the terminal is restored.
pub fn pick() -> Result<Option<(String, u32)>> {
    // Listing shells out to zellij once per session, so it stays off the input loop.
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || loop {
        if tx.send(panes::collect()).is_err() {
            return;
        }
        std::thread::sleep(REFRESH);
    });

    let mut app = App {
        rows: Vec::new(),
        query: String::new(),
        selected: None,
    };
    // The first listing before drawing, so the finder does not open empty.
    if let Ok(rows) = rx.recv() {
        app.rows = rows;
        app.reselect();
    }

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, &mut app, &rx);
    ratatui::restore();
    result
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    app: &mut App,
    rx: &mpsc::Receiver<Vec<PaneRow>>,
) -> Result<Option<(String, u32)>> {
    loop {
        while let Ok(rows) = rx.try_recv() {
            app.rows = rows;
            app.reselect();
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
            KeyCode::Esc => return Ok(None),
            KeyCode::Char('c') if ctrl => return Ok(None),
            KeyCode::Enter => {
                if app.selected.is_some() {
                    return Ok(app.selected.take());
                }
            }
            KeyCode::Up => app.step(-1),
            KeyCode::Down => app.step(1),
            KeyCode::Char('p' | 'k') if ctrl => app.step(-1),
            KeyCode::Char('n' | 'j') if ctrl => app.step(1),
            KeyCode::PageUp => app.step(-10),
            KeyCode::PageDown => app.step(10),
            KeyCode::Char('u') if ctrl => {
                app.query.clear();
                app.refilter();
            }
            KeyCode::Char('w') if ctrl => {
                let kept = app.query.trim_end().rfind(' ').map_or(0, |i| i + 1);
                app.query.truncate(kept);
                app.refilter();
            }
            KeyCode::Backspace => {
                app.query.pop();
                app.refilter();
            }
            KeyCode::Char(c) if !ctrl && !key.modifiers.contains(KeyModifiers::ALT) => {
                app.query.push(c);
                app.refilter();
            }
            _ => {}
        }
    }
}
