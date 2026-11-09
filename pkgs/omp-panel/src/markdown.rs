//! omp's replies are markdown: render them to terminal lines, wrapped to a width,
//! with code blocks highlighted.
//!
//! Colours are the terminal's 16 ANSI slots rather than RGB, so the panel follows
//! whatever palette the terminal has (stylix's), like the rest of the TUI.

use std::str::FromStr;
use std::sync::LazyLock;

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use syntect::easy::HighlightLines;
use syntect::highlighting::{
    self as hl, FontStyle, ScopeSelectors, StyleModifier, Theme, ThemeItem, ThemeSettings,
};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const CODE: Style = Style::new().fg(Color::Yellow);
const MUTED: Style = Style::new().fg(Color::DarkGray);
const LINK: Style = Style::new()
    .fg(Color::Blue)
    .add_modifier(Modifier::UNDERLINED);
const BULLETS: [&str; 3] = ["•", "◦", "▪"];

/// Marks "no colour" in the theme: syntect always resolves one, and alpha 0 is
/// taken by the ANSI encoding.
const DEFAULT_FG: hl::Color = hl::Color {
    r: 0,
    g: 0,
    b: 0,
    a: 1,
};

// bat's set: syntect's own lacks TypeScript, TOML, Nix and more.
static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(two_face::syntax::extra_newlines);

static THEME: LazyLock<Theme> = LazyLock::new(|| {
    {
        // bat's `ansi` trick: alpha 0 means the red channel is an ANSI index.
        let item = |scope: &str, ansi: u8, font_style: FontStyle| ThemeItem {
            scope: ScopeSelectors::from_str(scope).expect("valid scope selector"),
            style: StyleModifier {
                foreground: Some(hl::Color {
                    r: ansi,
                    g: 0,
                    b: 0,
                    a: 0,
                }),
                background: None,
                font_style: Some(font_style),
            },
        };
        let plain = FontStyle::empty();
        Theme {
            settings: ThemeSettings {
                foreground: Some(DEFAULT_FG),
                ..ThemeSettings::default()
            },
            scopes: vec![
                item("comment, punctuation.definition.comment", 8, FontStyle::ITALIC),
                item("string, punctuation.definition.string", 2, plain),
                item(
                    "constant.numeric, constant.language, constant.character, constant.other, support.constant",
                    6,
                    plain,
                ),
                item("keyword, storage, keyword.operator.word", 5, plain),
                item(
                    "entity.name.function, support.function, variable.function, meta.function-call",
                    4,
                    plain,
                ),
                item(
                    "entity.name.type, entity.name.class, entity.name.struct, entity.name.enum, support.type, support.class, storage.type",
                    3,
                    plain,
                ),
                item("entity.name.tag", 4, plain),
                item("entity.other.attribute-name, variable.other.member", 3, plain),
                item("markup.heading, entity.name.section", 4, FontStyle::BOLD),
                item("markup.inserted", 2, plain),
                item("markup.deleted, invalid", 1, plain),
                item("markup.changed, meta.diff.range, meta.diff.header", 6, plain),
            ],
            ..Theme::default()
        }
    }
});

/// Load the syntaxes ahead of the first code block, which would otherwise stall
/// a frame.
pub fn warm() {
    LazyLock::force(&SYNTAXES);
}

fn to_style(style: hl::Style) -> Style {
    let mut out = Style::new();
    if style.foreground.a == 0 {
        out = out.fg(Color::Indexed(style.foreground.r));
    }
    for (font, modifier) in [
        (FontStyle::BOLD, Modifier::BOLD),
        (FontStyle::ITALIC, Modifier::ITALIC),
        (FontStyle::UNDERLINE, Modifier::UNDERLINED),
    ] {
        if style.font_style.contains(font) {
            out = out.add_modifier(modifier);
        }
    }
    out
}

/// A block that indents what it holds: its first line gets `first` (a list
/// marker), the rest `rest` (as wide, so text hangs under the marker).
struct Container {
    first: Span<'static>,
    rest: Span<'static>,
    used: bool,
}

#[derive(Default)]
struct Table {
    alignments: Vec<Alignment>,
    rows: Vec<Vec<Vec<Span<'static>>>>,
    cell: Vec<Span<'static>>,
    header_rows: usize,
}

struct Renderer {
    width: usize,
    highlight: bool,
    out: Vec<Line<'static>>,
    inline: Vec<Span<'static>>,
    styles: Vec<Style>,
    containers: Vec<Container>,
    lists: Vec<Option<u64>>,
    gap: bool,
    code: Option<(String, String)>,
    table: Option<Table>,
}

impl Renderer {
    fn style(&self) -> Style {
        self.styles
            .iter()
            .fold(Style::new(), |acc, s| acc.patch(*s))
    }

    fn push(&mut self, text: &str, style: Style) {
        if let Some((_, code)) = &mut self.code {
            code.push_str(text);
        } else if let Some(table) = &mut self.table {
            table.cell.push(Span::styled(text.to_owned(), style));
        } else {
            self.inline.push(Span::styled(text.to_owned(), style));
        }
    }

    /// Prefixes for a block's first line and the lines after it, and their width.
    fn prefixes(&mut self) -> (Vec<Span<'static>>, Vec<Span<'static>>, usize) {
        let mut first = Vec::new();
        let mut rest = Vec::new();
        for c in &mut self.containers {
            first.push(if c.used {
                c.rest.clone()
            } else {
                c.first.clone()
            });
            rest.push(c.rest.clone());
            c.used = true;
        }
        let width = rest.iter().map(|s| s.content.width()).sum();
        (first, rest, width)
    }

    fn start_block(&mut self) {
        if self.gap && !self.out.is_empty() {
            self.out.push(Line::default());
        }
        self.gap = false;
    }

    fn emit(&mut self, lines: Vec<Vec<Span<'static>>>) {
        self.start_block();
        let (first, rest, _) = self.prefixes();
        for (i, line) in lines.into_iter().enumerate() {
            let mut spans = if i == 0 { first.clone() } else { rest.clone() };
            spans.extend(line);
            self.out.push(Line::from(spans));
        }
    }

    fn flush(&mut self) {
        let inline = std::mem::take(&mut self.inline);
        if inline.iter().all(|s| s.content.trim().is_empty()) {
            return;
        }
        let indent: usize = self.containers.iter().map(|c| c.rest.content.width()).sum();
        let lines = wrap(inline, self.width.saturating_sub(indent).max(1));
        self.emit(lines);
    }

    fn code_block(&mut self) {
        let Some((lang, text)) = self.code.take() else {
            return;
        };
        let text = text.replace('\t', "    ");
        let gutter = Span::styled("│ ", MUTED);
        let lines: Vec<Vec<Span<'static>>> = if self.highlight {
            let set = &*SYNTAXES;
            let syntax = set
                .find_syntax_by_token(&lang)
                .unwrap_or_else(|| set.find_syntax_plain_text());
            let mut highlighter = HighlightLines::new(syntax, &THEME);
            LinesWithEndings::from(&text)
                .map(|line| {
                    let pieces = highlighter.highlight_line(line, set).unwrap_or_default();
                    let mut spans = vec![gutter.clone()];
                    spans.extend(pieces.into_iter().filter_map(|(style, piece)| {
                        let piece = piece.trim_end_matches(['\n', '\r']);
                        (!piece.is_empty()).then(|| Span::styled(piece.to_owned(), to_style(style)))
                    }));
                    spans
                })
                .collect()
        } else {
            text.lines()
                .map(|line| vec![gutter.clone(), Span::raw(line.to_owned())])
                .collect()
        };
        self.emit(lines);
    }

    fn table(&mut self) {
        let Some(table) = self.table.take() else {
            return;
        };
        let cols = table.rows.iter().map(Vec::len).max().unwrap_or(0);
        let width_of = |cell: &[Span]| cell.iter().map(|s| s.content.width()).sum::<usize>();
        let widths: Vec<usize> = (0..cols)
            .map(|c| {
                table
                    .rows
                    .iter()
                    .filter_map(|row| row.get(c))
                    .map(|cell| width_of(cell))
                    .max()
                    .unwrap_or(0)
            })
            .collect();

        let mut lines = Vec::new();
        for (r, row) in table.rows.into_iter().enumerate() {
            let header = r < table.header_rows;
            let mut line = Vec::new();
            for (c, width) in widths.iter().enumerate() {
                if c > 0 {
                    line.push(Span::styled(" │ ", MUTED));
                }
                let cell = row.get(c).cloned().unwrap_or_default();
                let pad = width - width_of(&cell);
                let (before, after) = match table.alignments.get(c) {
                    Some(Alignment::Right) => (pad, 0),
                    Some(Alignment::Center) => (pad / 2, pad - pad / 2),
                    // The last column's padding would only be trailing blanks.
                    _ if c + 1 == cols => (0, 0),
                    _ => (0, pad),
                };
                line.push(Span::raw(" ".repeat(before)));
                line.extend(cell.into_iter().map(|s| {
                    if header {
                        s.patch_style(Modifier::BOLD)
                    } else {
                        s
                    }
                }));
                line.push(Span::raw(" ".repeat(after)));
            }
            line.retain(|s| !s.content.is_empty());
            lines.push(line);
            if header && r + 1 == table.header_rows {
                let rule: Vec<String> = widths.iter().map(|w| "─".repeat(*w)).collect();
                lines.push(vec![Span::styled(rule.join("─┼─"), MUTED)]);
            }
        }
        self.emit(lines);
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => {
                let style = self.style();
                self.push(&text, style);
            }
            Event::Code(text) => {
                let style = self.style().patch(CODE);
                self.push(&text, style);
            }
            Event::Html(text) | Event::InlineHtml(text) => {
                let style = self.style();
                self.push(text.trim_end_matches('\n'), style);
            }
            Event::SoftBreak => {
                let style = self.style();
                self.push(" ", style);
            }
            Event::HardBreak => self.flush(),
            Event::Rule => {
                self.flush();
                let indent: usize = self.containers.iter().map(|c| c.rest.content.width()).sum();
                let rule = "─".repeat(self.width.saturating_sub(indent));
                self.emit(vec![vec![Span::styled(rule, MUTED)]]);
                self.gap = true;
            }
            Event::TaskListMarker(done) => {
                self.push(if done { "☑ " } else { "☐ " }, MUTED);
            }
            _ => {}
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph => self.flush(),
            Tag::Heading { level, .. } => {
                self.flush();
                let color = match level {
                    HeadingLevel::H1 | HeadingLevel::H2 => Color::Magenta,
                    _ => Color::Cyan,
                };
                self.styles
                    .push(Style::new().fg(color).add_modifier(Modifier::BOLD));
            }
            Tag::BlockQuote(_) => {
                self.flush();
                let bar = Span::styled("▎ ", MUTED);
                self.containers.push(Container {
                    first: bar.clone(),
                    rest: bar,
                    used: false,
                });
                self.styles
                    .push(Style::new().add_modifier(Modifier::ITALIC));
            }
            Tag::CodeBlock(kind) => {
                self.flush();
                let lang = match kind {
                    CodeBlockKind::Fenced(info) => {
                        info.split([',', ' ']).next().unwrap_or("").to_owned()
                    }
                    CodeBlockKind::Indented => String::new(),
                };
                self.code = Some((lang, String::new()));
            }
            Tag::List(start) => {
                self.flush();
                self.lists.push(start);
            }
            Tag::Item => {
                self.flush();
                let depth = self.lists.len().saturating_sub(1);
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        *n += 1;
                        format!("{}. ", *n - 1)
                    }
                    _ => format!("{} ", BULLETS[depth % BULLETS.len()]),
                };
                let rest = " ".repeat(marker.width());
                self.containers.push(Container {
                    first: Span::styled(marker, MUTED),
                    rest: Span::raw(rest),
                    used: false,
                });
            }
            Tag::Emphasis => self
                .styles
                .push(Style::new().add_modifier(Modifier::ITALIC)),
            Tag::Strong => self.styles.push(Style::new().add_modifier(Modifier::BOLD)),
            Tag::Strikethrough => self
                .styles
                .push(Style::new().add_modifier(Modifier::CROSSED_OUT)),
            Tag::Link { .. } | Tag::Image { .. } => self.styles.push(LINK),
            Tag::Table(alignments) => {
                self.flush();
                self.table = Some(Table {
                    alignments,
                    ..Table::default()
                });
            }
            Tag::TableRow | Tag::TableHead => {
                if let Some(table) = &mut self.table {
                    table.rows.push(Vec::new());
                }
            }
            Tag::TableCell => {
                if let Some(table) = &mut self.table {
                    table.cell.clear();
                }
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                self.flush();
                self.gap = true;
            }
            TagEnd::Heading(_) => {
                self.flush();
                self.styles.pop();
                self.gap = true;
            }
            TagEnd::BlockQuote(_) => {
                self.flush();
                self.containers.pop();
                self.styles.pop();
                self.gap = true;
            }
            TagEnd::CodeBlock => {
                self.code_block();
                self.gap = true;
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
                if self.lists.is_empty() {
                    self.gap = true;
                }
            }
            TagEnd::Item => {
                self.flush();
                self.containers.pop();
            }
            TagEnd::Emphasis
            | TagEnd::Strong
            | TagEnd::Strikethrough
            | TagEnd::Link
            | TagEnd::Image => {
                self.styles.pop();
            }
            TagEnd::TableHead => {
                if let Some(table) = &mut self.table {
                    table.header_rows = table.rows.len();
                }
            }
            TagEnd::TableCell => {
                if let Some(table) = &mut self.table {
                    let cell = std::mem::take(&mut table.cell);
                    if let Some(row) = table.rows.last_mut() {
                        row.push(cell);
                    }
                }
            }
            TagEnd::Table => {
                self.table();
                self.gap = true;
            }
            _ => {}
        }
    }
}

const OPTIONS: Options = Options::ENABLE_TABLES
    .union(Options::ENABLE_STRIKETHROUGH)
    .union(Options::ENABLE_TASKLISTS);

fn render_events<'a>(
    events: impl Iterator<Item = Event<'a>>,
    width: usize,
    highlight: bool,
) -> Vec<Line<'static>> {
    let mut renderer = Renderer {
        width,
        highlight,
        out: Vec::new(),
        inline: Vec::new(),
        styles: Vec::new(),
        containers: Vec::new(),
        lists: Vec::new(),
        gap: false,
        code: None,
        table: None,
    };
    for event in events {
        renderer.event(event);
    }
    renderer.flush();
    renderer.out
}

/// Render markdown to lines no wider than `width`, except code blocks and
/// tables, which are cut by the pane rather than wrapped out of shape.
pub fn render(markdown: &str, width: usize, highlight: bool) -> Vec<Line<'static>> {
    render_events(Parser::new_ext(markdown, OPTIONS), width, highlight)
}

/// The first line of text, styled but unhighlighted, for a one-line summary.
/// Headings are skipped: a reply opening on "Summary" says nothing about itself.
pub fn first_line(markdown: &str) -> Line<'static> {
    let mut in_heading = false;
    let body = Parser::new_ext(markdown, OPTIONS).filter(|event| match event {
        Event::Start(Tag::Heading { .. }) => {
            in_heading = true;
            false
        }
        Event::End(TagEnd::Heading(_)) => {
            in_heading = false;
            false
        }
        _ => !in_heading,
    });
    let first = |lines: Vec<Line<'static>>| {
        lines
            .into_iter()
            .find(|line| line.spans.iter().any(|s| !s.content.trim().is_empty()))
    };
    first(render_events(body, 1000, false))
        .or_else(|| first(render(markdown, 1000, false)))
        .unwrap_or_default()
}

fn append(line: &mut Vec<Span<'static>>, text: &str, style: Style) {
    match line.last_mut() {
        Some(last) if last.style == style => last.content.to_mut().push_str(text),
        _ => line.push(Span::styled(text.to_owned(), style)),
    }
}

fn trim_end(line: &mut Vec<Span<'static>>) {
    while let Some(last) = line.last_mut() {
        let trimmed = last.content.trim_end().len();
        if trimmed > 0 {
            last.content.to_mut().truncate(trimmed);
            return;
        }
        line.pop();
    }
}

/// Greedy word wrap across styled spans. Runs of whitespace collapse to one
/// space and vanish at a break; a word wider than the line is cut.
fn wrap(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let mut lines: Vec<Vec<Span<'static>>> = vec![Vec::new()];
    let mut used = 0;
    for span in spans {
        let style = span.style;
        let mut rest = span.content.as_ref();
        while let Some(c) = rest.chars().next() {
            let space = c.is_whitespace();
            let end = rest
                .find(|ch: char| ch.is_whitespace() != space)
                .unwrap_or(rest.len());
            let (token, tail) = rest.split_at(end);
            rest = tail;

            if space {
                if used > 0 && used < width {
                    append(lines.last_mut().unwrap(), " ", style);
                    used += 1;
                }
                continue;
            }
            let w = token.width();
            if used > 0 && used + w > width {
                trim_end(lines.last_mut().unwrap());
                lines.push(Vec::new());
                used = 0;
            }
            if w <= width {
                append(lines.last_mut().unwrap(), token, style);
                used += w;
                continue;
            }
            for ch in token.chars() {
                let cw = ch.width().unwrap_or(0);
                if used + cw > width && used > 0 {
                    lines.push(Vec::new());
                    used = 0;
                }
                append(
                    lines.last_mut().unwrap(),
                    ch.encode_utf8(&mut [0; 4]),
                    style,
                );
                used += cw;
            }
        }
    }
    for line in &mut lines {
        trim_end(line);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    fn span<'a>(lines: &'a [Line<'static>], content: &str) -> &'a Span<'static> {
        lines
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content.contains(content))
            .unwrap_or_else(|| panic!("no span with {content:?} in {:?}", text(lines)))
    }

    #[test]
    fn markers_become_styles() {
        let lines = render("Use **bold**, *slanted* and `code`.", 80, true);
        assert_eq!(text(&lines), ["Use bold, slanted and code."]);
        assert!(span(&lines, "bold")
            .style
            .add_modifier
            .contains(Modifier::BOLD));
        assert!(span(&lines, "slanted")
            .style
            .add_modifier
            .contains(Modifier::ITALIC));
        assert_eq!(span(&lines, "code").style.fg, Some(Color::Yellow));
    }

    #[test]
    fn blocks_are_separated_by_one_blank_line_and_tight_lists_by_none() {
        let lines = render(
            "# Title\n\ntext\n\n- one\n- two\n  1. nested\n\nend",
            80,
            true,
        );
        assert_eq!(
            text(&lines),
            [
                "Title",
                "",
                "text",
                "",
                "• one",
                "• two",
                "  1. nested",
                "",
                "end"
            ]
        );
    }

    #[test]
    fn wrapped_list_text_hangs_under_its_marker() {
        let lines = render("- alpha beta gamma\n\n> quoted words here", 10, true);
        assert_eq!(
            text(&lines),
            [
                "• alpha",
                "  beta",
                "  gamma",
                "",
                "▎ quoted",
                "▎ words",
                "▎ here"
            ]
        );
    }

    #[test]
    fn a_word_wider_than_the_line_is_cut() {
        assert_eq!(
            text(&render("abcdefgh ij", 3, true)),
            ["abc", "def", "gh", "ij"]
        );
    }

    #[test]
    fn code_blocks_keep_their_lines_and_are_highlighted() {
        let md = "```rust\nlet s = \"a long string that would wrap\";\n```\nafter";
        let lines = render(md, 20, true);
        assert_eq!(
            text(&lines),
            ["│ let s = \"a long string that would wrap\";", "", "after"]
        );
        assert_eq!(span(&lines, "a long").style.fg, Some(Color::Indexed(2)));
    }

    #[test]
    fn tables_align_their_columns() {
        let md = "| a | bb |\n|---|---:|\n| ccc | d |";
        let lines = render(md, 80, true);
        assert_eq!(text(&lines), ["a   │ bb", "────┼───", "ccc │  d"]);
        assert!(span(&lines, "bb")
            .style
            .add_modifier
            .contains(Modifier::BOLD));
    }

    #[test]
    fn the_summary_is_the_first_line_of_text() {
        let line = first_line("## Summary\n\n**Done**: all `good`\n\nmore");
        assert_eq!(text(&[line]), ["Done: all good"]);
    }
}
