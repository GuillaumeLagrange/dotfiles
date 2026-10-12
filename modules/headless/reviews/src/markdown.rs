//! A pull request's description laid out for the terminal: GitHub's markdown
//! (tables, task lists, alerts, and the HTML pasted in descriptions) wrapped
//! to the pane's width, with rows left blank for the images drawn over them.

use pulldown_cmark::{
    Alignment, BlockQuoteKind, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd,
};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::tui::{ACCENT, DIM};

const LINK: Style = Style::new().fg(ACCENT).add_modifier(Modifier::UNDERLINED);
const CODE: Style = Style::new().fg(Color::Yellow);
const BOLD: Style = Style::new().add_modifier(Modifier::BOLD);

pub enum ImageState {
    Loading,
    Failed,
    /// Pixel size.
    Ready(u32, u32),
}

/// An image over `rows` lines from `line`, `col` cells in.
#[derive(Debug, PartialEq)]
pub struct Placed {
    pub src: String,
    pub line: usize,
    pub col: u16,
    pub cols: u16,
    pub rows: u16,
}

pub struct Doc {
    pub lines: Vec<Line<'static>>,
    pub images: Vec<Placed>,
}

pub struct Ctx<'a> {
    pub width: u16,
    /// Pixels in a cell.
    pub font: (u16, u16),
    /// Tallest an image is drawn.
    pub max_rows: u16,
    pub image: &'a dyn Fn(&str) -> ImageState,
}

pub fn render(md: &str, ctx: &Ctx) -> Doc {
    let mut w = Writer::new(ctx);
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_GFM;
    for event in Parser::new_ext(md, options) {
        w.event(event);
    }
    w.flush();
    Doc {
        lines: w.lines,
        images: w.images,
    }
}

/// Sources of the images in `md`, in order, once each.
pub fn images(md: &str) -> Vec<String> {
    let found = std::cell::RefCell::new(Vec::<String>::new());
    let record = |src: &str| {
        let mut found = found.borrow_mut();
        if !found.iter().any(|s| s == src) {
            found.push(src.to_owned());
        }
        ImageState::Loading
    };
    render(
        md,
        &Ctx {
            width: 80,
            font: (10, 20),
            max_rows: 20,
            image: &record,
        },
    );
    found.into_inner()
}

/// What each line of a block starts with: `first` on its first line, `rest`
/// after; both as wide.
struct Level {
    first: Vec<Span<'static>>,
    rest: Vec<Span<'static>>,
    started: bool,
}

struct Table {
    aligns: Vec<Alignment>,
    rows: Vec<Vec<Vec<Span<'static>>>>,
    head: usize,
}

struct Writer<'a> {
    ctx: &'a Ctx<'a>,
    lines: Vec<Line<'static>>,
    images: Vec<Placed>,
    levels: Vec<Level>,
    /// The paragraph being written, wrapped when it ends.
    inline: Vec<Span<'static>>,
    styles: Vec<Style>,
    /// A blank line is due before the next block.
    gap: bool,
    /// The blank line before the block started, written with its first line:
    /// a block left empty (closing HTML tags) leaves none.
    pending: Option<Vec<Span<'static>>>,
    /// Next number of each open list, `None` for bullets.
    lists: Vec<Option<u64>>,
    /// Destination of the open link, and where its text starts in `inline`.
    link: Option<(String, usize)>,
    /// Source and alt text of the open markdown image.
    image: Option<(String, String)>,
    /// Language and text of the open code block.
    code: Option<(String, String)>,
    table: Option<Table>,
    in_comment: bool,
    /// Styles pushed by HTML tags, popped by their closing tags.
    html_styles: usize,
}

impl<'a> Writer<'a> {
    fn new(ctx: &'a Ctx<'a>) -> Self {
        Writer {
            ctx,
            lines: Vec::new(),
            images: Vec::new(),
            levels: Vec::new(),
            inline: Vec::new(),
            styles: Vec::new(),
            gap: false,
            pending: None,
            lists: Vec::new(),
            link: None,
            image: None,
            code: None,
            table: None,
            in_comment: false,
            html_styles: 0,
        }
    }

    fn style(&self) -> Style {
        self.styles
            .iter()
            .fold(Style::new(), |acc, s| acc.patch(*s))
    }

    fn indent(&self) -> usize {
        self.levels
            .iter()
            .map(|l| l.rest.iter().map(|s| s.width()).sum::<usize>())
            .sum()
    }

    fn room(&self) -> usize {
        usize::from(self.ctx.width)
            .saturating_sub(self.indent())
            .max(1)
    }

    fn open(&mut self) {
        if let Some(spans) = self.pending.take() {
            self.lines.push(Line::from(spans));
        }
    }

    fn emit(&mut self, content: Vec<Span<'static>>) {
        self.open();
        let mut spans = Vec::new();
        for level in &mut self.levels {
            spans.extend(if level.started {
                level.rest.clone()
            } else {
                level.first.clone()
            });
            level.started = true;
        }
        spans.extend(content);
        self.lines.push(Line::from(spans));
    }

    fn block_start(&mut self) {
        self.flush();
        if self.gap && self.pending.is_none() && !self.lines.is_empty() {
            let spans = self
                .levels
                .iter()
                .flat_map(|l| l.rest.iter().cloned())
                .collect();
            self.pending = Some(spans);
        }
        self.gap = false;
    }

    fn block_end(&mut self) {
        self.flush();
        self.gap = true;
    }

    fn flush(&mut self) {
        let inline = std::mem::take(&mut self.inline);
        if inline.iter().all(|s| s.content.trim().is_empty()) {
            return;
        }
        for line in wrap(&inline, self.room()) {
            self.emit(line);
        }
    }

    fn push(&mut self, text: impl Into<String>, style: Style) {
        let text = text.into();
        if let Some((_, alt)) = &mut self.image {
            alt.push_str(&text);
        } else if !text.is_empty() {
            self.inline.push(Span::styled(text, style));
        }
    }

    fn text(&mut self, text: &str) {
        if let Some((_, code)) = &mut self.code {
            code.push_str(text);
            return;
        }
        let style = self.style();
        if self.image.is_some() || self.link.is_some() {
            self.push(text, style);
            return;
        }
        for span in decorate(text, style) {
            self.inline.push(span);
        }
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text(&text),
            Event::Code(text) => {
                let style = self.style().patch(CODE);
                self.push(text.to_string(), style);
            }
            Event::InlineMath(text) | Event::DisplayMath(text) => {
                let style = self.style().patch(CODE);
                self.push(text.to_string(), style);
            }
            Event::Html(html) | Event::InlineHtml(html) => self.html(&html),
            Event::FootnoteReference(label) => self.push(format!("[{label}]"), DIM),
            Event::SoftBreak => {
                let style = self.style();
                self.push(" ", style);
            }
            Event::HardBreak => self.push("\n", Style::new()),
            Event::Rule => {
                self.block_start();
                let rule = "─".repeat(self.room());
                self.emit(vec![Span::styled(rule, DIM)]);
                self.gap = true;
            }
            Event::TaskListMarker(done) => {
                if let Some(level) = self.levels.last_mut().filter(|l| !l.started) {
                    level.first = vec![if done {
                        Span::styled("☑ ", Style::new().fg(Color::Green))
                    } else {
                        Span::styled("☐ ", DIM)
                    }];
                }
            }
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph | Tag::HtmlBlock | Tag::MetadataBlock(_) => self.block_start(),
            Tag::Heading { level, .. } => {
                self.block_start();
                self.styles.push(heading(level));
            }
            Tag::BlockQuote(kind) => {
                self.block_start();
                let (label, color) = match kind {
                    None => ("", Color::DarkGray),
                    Some(BlockQuoteKind::Note) => ("ⓘ Note", Color::Blue),
                    Some(BlockQuoteKind::Tip) => ("✦ Tip", Color::Green),
                    Some(BlockQuoteKind::Important) => ("❢ Important", Color::Magenta),
                    Some(BlockQuoteKind::Warning) => ("⚠ Warning", Color::Yellow),
                    Some(BlockQuoteKind::Caution) => ("⊘ Caution", Color::Red),
                };
                let bar = vec![Span::styled("▎ ", Style::new().fg(color))];
                self.levels.push(Level {
                    first: bar.clone(),
                    rest: bar,
                    started: false,
                });
                if !label.is_empty() {
                    self.emit(vec![Span::styled(label, BOLD.fg(color))]);
                }
            }
            Tag::CodeBlock(kind) => {
                self.block_start();
                let lang = match kind {
                    CodeBlockKind::Fenced(info) => {
                        info.split_whitespace().next().unwrap_or("").to_owned()
                    }
                    CodeBlockKind::Indented => String::new(),
                };
                self.code = Some((lang, String::new()));
            }
            Tag::List(start) => {
                self.block_start();
                self.lists.push(start);
            }
            Tag::Item => {
                self.block_start();
                let depth = self.lists.len().saturating_sub(1);
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        *n += 1;
                        format!("{}. ", *n - 1)
                    }
                    _ => ["• ", "◦ ", "▪ "][depth % 3].to_owned(),
                };
                let rest = " ".repeat(marker.width());
                self.levels.push(Level {
                    first: vec![Span::styled(marker, Style::new().fg(ACCENT))],
                    rest: vec![Span::raw(rest)],
                    started: false,
                });
            }
            Tag::FootnoteDefinition(label) => {
                self.block_start();
                self.push(format!("[{label}]: "), DIM);
            }
            Tag::DefinitionList => self.block_start(),
            Tag::DefinitionListTitle => {
                self.block_start();
                self.styles.push(BOLD);
            }
            Tag::DefinitionListDefinition => {
                self.block_start();
                self.levels.push(Level {
                    first: vec![Span::raw("    ")],
                    rest: vec![Span::raw("    ")],
                    started: false,
                });
            }
            Tag::Table(aligns) => {
                self.block_start();
                self.table = Some(Table {
                    aligns,
                    rows: Vec::new(),
                    head: 0,
                });
            }
            Tag::TableHead | Tag::TableRow => {
                if let Some(table) = &mut self.table {
                    table.rows.push(Vec::new());
                }
            }
            Tag::TableCell => self.inline.clear(),
            Tag::Emphasis => self
                .styles
                .push(Style::new().add_modifier(Modifier::ITALIC)),
            Tag::Strong => self.styles.push(BOLD),
            Tag::Strikethrough => self
                .styles
                .push(Style::new().add_modifier(Modifier::CROSSED_OUT)),
            Tag::Superscript | Tag::Subscript => self.styles.push(Style::new()),
            Tag::Link { dest_url, .. } => {
                self.link = Some((dest_url.to_string(), self.inline.len()));
                self.styles.push(LINK);
            }
            Tag::Image { dest_url, .. } => self.image = Some((dest_url.to_string(), String::new())),
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph | TagEnd::HtmlBlock | TagEnd::MetadataBlock(_) => self.block_end(),
            TagEnd::Heading(_) => {
                self.flush();
                self.styles.pop();
                self.gap = true;
            }
            TagEnd::BlockQuote(_) | TagEnd::DefinitionListDefinition => {
                self.flush();
                self.levels.pop();
                self.gap = true;
            }
            TagEnd::CodeBlock => {
                if let Some((lang, code)) = self.code.take() {
                    self.code_block(&lang, &code);
                }
                self.gap = true;
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
                // Tight nested lists run on into their parent's next item.
                self.gap = self.lists.is_empty() || self.gap;
            }
            TagEnd::Item => {
                self.flush();
                self.levels.pop();
            }
            TagEnd::FootnoteDefinition | TagEnd::DefinitionList => self.block_end(),
            TagEnd::DefinitionListTitle => {
                self.flush();
                self.styles.pop();
            }
            TagEnd::Table => {
                if let Some(table) = self.table.take() {
                    self.table(table);
                }
                self.gap = true;
            }
            TagEnd::TableHead => {
                if let Some(table) = &mut self.table {
                    table.head = table.rows.len();
                }
            }
            TagEnd::TableRow => {}
            TagEnd::TableCell => {
                let cell = std::mem::take(&mut self.inline);
                if let Some(row) = self.table.as_mut().and_then(|t| t.rows.last_mut()) {
                    row.push(cell);
                }
            }
            TagEnd::Emphasis
            | TagEnd::Strong
            | TagEnd::Strikethrough
            | TagEnd::Superscript
            | TagEnd::Subscript => {
                self.styles.pop();
            }
            TagEnd::Link => {
                self.styles.pop();
                if let Some((dest, at)) = self.link.take() {
                    let text: String = self.inline[at.min(self.inline.len())..]
                        .iter()
                        .map(|s| s.content.as_ref())
                        .collect();
                    if text == dest {
                        if let Some(short) = github_ref(&dest) {
                            self.inline.truncate(at);
                            self.inline
                                .push(Span::styled(short, self.style().patch(LINK)));
                        }
                    }
                }
            }
            TagEnd::Image => {
                if let Some((src, alt)) = self.image.take() {
                    self.image_at(&src, &alt, None);
                }
            }
        }
    }

    fn code_block(&mut self, lang: &str, code: &str) {
        let gutter = Span::styled("│ ", DIM);
        let room = self.room().saturating_sub(2).max(1);
        for line in code.trim_end_matches('\n').split('\n') {
            let line = line.replace('\t', "    ");
            let style = match (lang, line.chars().next()) {
                ("diff" | "patch", Some('+')) => Style::new().fg(Color::Green),
                ("diff" | "patch", Some('-')) => Style::new().fg(Color::Red),
                ("diff" | "patch", Some('@')) => Style::new().fg(Color::Cyan),
                _ => Style::new(),
            };
            let mut chunk = String::new();
            let mut used = 0;
            for c in line.chars() {
                let w = c.width().unwrap_or(0);
                if used + w > room {
                    self.emit(vec![gutter.clone(), Span::styled(chunk, style)]);
                    chunk = String::new();
                    used = 0;
                }
                chunk.push(c);
                used += w;
            }
            self.emit(vec![gutter.clone(), Span::styled(chunk, style)]);
        }
    }

    fn table(&mut self, table: Table) {
        let ncols = table.rows.iter().map(Vec::len).max().unwrap_or(0);
        if ncols == 0 {
            return;
        }
        let mut widths = vec![1usize; ncols];
        for row in &table.rows {
            for (c, cell) in row.iter().enumerate() {
                let w = wrap(cell, usize::MAX)
                    .iter()
                    .map(|l| l.iter().map(|s| s.width()).sum::<usize>())
                    .max()
                    .unwrap_or(0);
                widths[c] = widths[c].max(w);
            }
        }
        // Borders and padding: "│ a │ b │".
        let room = self.room().saturating_sub(3 * ncols + 1).max(ncols);
        while widths.iter().sum::<usize>() > room {
            let widest = (0..ncols).max_by_key(|&c| widths[c]).unwrap_or(0);
            if widths[widest] <= 1 {
                break;
            }
            widths[widest] -= 1;
        }

        let border = |left: &str, mid: &str, right: &str| {
            let parts: Vec<String> = widths.iter().map(|w| "─".repeat(w + 2)).collect();
            vec![Span::styled(
                format!("{left}{}{right}", parts.join(mid)),
                DIM,
            )]
        };
        self.emit(border("╭", "┬", "╮"));
        for (r, row) in table.rows.iter().enumerate() {
            if r == table.head && r > 0 {
                self.emit(border("├", "┼", "┤"));
            }
            let cells: Vec<Vec<Vec<Span<'static>>>> = (0..ncols)
                .map(|c| {
                    let cell = row.get(c).map(Vec::as_slice).unwrap_or(&[]);
                    let mut lines = wrap(cell, widths[c]);
                    if r < table.head {
                        for line in &mut lines {
                            for span in line {
                                span.style = span.style.patch(BOLD);
                            }
                        }
                    }
                    lines
                })
                .collect();
            let height = cells.iter().map(Vec::len).max().unwrap_or(0).max(1);
            for k in 0..height {
                let mut spans = vec![Span::styled("│", DIM)];
                for (c, lines) in cells.iter().enumerate() {
                    let content = lines.get(k).cloned().unwrap_or_default();
                    let used: usize = content.iter().map(|s| s.width()).sum();
                    let pad = widths[c].saturating_sub(used);
                    let (before, after) = match table.aligns.get(c) {
                        Some(Alignment::Right) => (pad, 0),
                        Some(Alignment::Center) => (pad / 2, pad - pad / 2),
                        _ => (0, pad),
                    };
                    spans.push(Span::raw(" ".repeat(before + 1)));
                    spans.extend(content);
                    spans.push(Span::raw(" ".repeat(after + 1)));
                    spans.push(Span::styled("│", DIM));
                }
                self.emit(spans);
            }
        }
        self.emit(border("╰", "┴", "╯"));
    }

    /// An image drawn when loaded, until then a line of text in its place.
    fn image_at(&mut self, src: &str, alt: &str, width: Option<u32>) {
        let alt = if alt.trim().is_empty() {
            "image"
        } else {
            alt.trim()
        };
        let (w, h) = match (self.ctx.image)(src) {
            ImageState::Ready(w, h) if w > 0 && h > 0 && self.table.is_none() => (w, h),
            ImageState::Ready(..) | ImageState::Failed => {
                self.push(format!("▣ {alt}"), DIM.add_modifier(Modifier::ITALIC));
                return;
            }
            ImageState::Loading => {
                self.push(format!("◌ {alt}"), DIM.add_modifier(Modifier::ITALIC));
                return;
            }
        };
        // A width set on <img> scales it, as on GitHub.
        let (w, h) = match width {
            Some(shown) if shown > 0 => (
                shown,
                (u64::from(h) * u64::from(shown) / u64::from(w)) as u32,
            ),
            _ => (w, h),
        };
        let (fw, fh) = (
            u32::from(self.ctx.font.0.max(1)),
            u32::from(self.ctx.font.1.max(1)),
        );
        let room = self.room() as u32;
        let mut cols = w.div_ceil(fw).clamp(1, room);
        let mut rows = (cols * fw * h / w).div_ceil(fh).max(1);
        let max_rows = u32::from(self.ctx.max_rows.max(1));
        if rows > max_rows {
            rows = max_rows;
            cols = (rows * fh * w / h / fw).clamp(1, room);
        }

        self.flush();
        self.open();
        self.images.push(Placed {
            src: src.to_owned(),
            line: self.lines.len(),
            col: self.indent() as u16,
            cols: cols as u16,
            rows: rows as u16,
        });
        for _ in 0..rows {
            self.emit(Vec::new());
        }
    }

    fn html(&mut self, html: &str) {
        let mut rest = html;
        loop {
            if self.in_comment {
                match rest.find("-->") {
                    Some(i) => {
                        rest = &rest[i + 3..];
                        self.in_comment = false;
                    }
                    None => return,
                }
            }
            let Some(i) = rest.find('<') else {
                self.html_text(rest);
                return;
            };
            self.html_text(&rest[..i]);
            rest = &rest[i..];
            if let Some(after) = rest.strip_prefix("<!--") {
                self.in_comment = true;
                rest = after;
                continue;
            }
            let Some(j) = rest.find('>') else {
                self.html_text(rest);
                return;
            };
            self.tag(&rest[1..j]);
            rest = &rest[j + 1..];
        }
    }

    fn html_text(&mut self, text: &str) {
        let text = entities(&text.replace(['\n', '\r'], " "));
        if text.trim().is_empty() && self.inline.is_empty() {
            return;
        }
        self.text(&text);
    }

    fn html_style(&mut self, closing: bool, style: Style) {
        if closing {
            if self.html_styles > 0 {
                self.html_styles -= 1;
                self.styles.pop();
            }
        } else {
            self.html_styles += 1;
            self.styles.push(style);
        }
    }

    fn tag(&mut self, tag: &str) {
        let closing = tag.starts_with('/');
        let name: String = tag
            .trim_start_matches('/')
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        match name.as_str() {
            "br" => self.push("\n", Style::new()),
            "img" => {
                if let Some(src) = attr(tag, "src") {
                    let alt = attr(tag, "alt").unwrap_or_default();
                    let width =
                        attr(tag, "width").and_then(|w| w.trim_end_matches("px").parse().ok());
                    self.image_at(&src, &alt, width);
                }
            }
            "hr" => self.event(Event::Rule),
            "summary" if !closing => {
                self.block_start();
                self.push("▸ ", Style::new().fg(ACCENT));
                self.html_style(false, BOLD);
            }
            "summary" => {
                self.html_style(true, BOLD);
                self.flush();
            }
            "details" | "p" | "div" | "table" | "ul" | "ol" | "pre" | "blockquote" | "picture" => {
                if closing {
                    self.block_end();
                } else {
                    self.block_start();
                }
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                if closing {
                    self.html_style(true, Style::new());
                    self.block_end();
                } else {
                    self.block_start();
                    let level = HeadingLevel::try_from(usize::from(name.as_bytes()[1] - b'0'))
                        .unwrap_or(HeadingLevel::H6);
                    self.html_style(false, heading(level));
                }
            }
            "li" if !closing => {
                self.flush();
                self.push("• ", Style::new().fg(ACCENT));
            }
            "li" | "tr" => self.flush(),
            "td" | "th" if closing => self.push("  ", Style::new()),
            "b" | "strong" => self.html_style(closing, BOLD),
            "i" | "em" => self.html_style(closing, Style::new().add_modifier(Modifier::ITALIC)),
            "code" | "kbd" | "samp" => self.html_style(closing, CODE),
            "s" | "del" | "strike" => {
                self.html_style(closing, Style::new().add_modifier(Modifier::CROSSED_OUT))
            }
            "a" => self.html_style(closing, LINK),
            _ => {}
        }
    }
}

fn heading(level: HeadingLevel) -> Style {
    match level {
        HeadingLevel::H1 => BOLD.fg(ACCENT).add_modifier(Modifier::UNDERLINED),
        HeadingLevel::H2 => BOLD.fg(ACCENT),
        HeadingLevel::H3 => BOLD,
        _ => BOLD.add_modifier(Modifier::ITALIC),
    }
}

/// Value of attribute `name` in the inside of a tag.
fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0;
    while let Some(i) = lower[from..].find(name) {
        let at = from + i;
        from = at + name.len();
        let before = lower[..at].chars().next_back();
        if !before.is_some_and(char::is_whitespace) {
            continue;
        }
        let Some(value) = tag[from..].trim_start().strip_prefix('=') else {
            continue;
        };
        let value = value.trim_start();
        let raw = match value.chars().next() {
            Some(q @ ('"' | '\'')) => value[1..].split(q).next().unwrap_or(""),
            _ => value
                .split(|c: char| c.is_whitespace() || c == '/')
                .next()
                .unwrap_or(""),
        };
        return Some(entities(raw));
    }
    None
}

fn entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    text.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

/// `owner/repo#n` for a link to a GitHub pull request or issue, as GitHub
/// shows it.
fn github_ref(url: &str) -> Option<String> {
    let path = url.strip_prefix("https://github.com/")?;
    let mut parts = path.splitn(5, '/');
    let (owner, repo, kind, rest) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || !matches!(kind, "pull" | "issues") {
        return None;
    }
    let number = rest.split('#').next()?;
    (!number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
        .then(|| format!("{owner}/{repo}#{number}"))
}

/// `text` with bare URLs, @mentions and #references picked out.
fn decorate(text: &str, style: Style) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    let mut plain = 0;
    let mut i = 0;
    let bytes = text.as_bytes();
    while i < text.len() {
        let boundary = i == 0 || {
            let prev = text[..i].chars().next_back().unwrap_or(' ');
            !prev.is_alphanumeric() && prev != '/' && prev != '@'
        };
        let found = if !boundary {
            None
        } else if text[i..].starts_with("https://") || text[i..].starts_with("http://") {
            let end = text[i..]
                .find(|c: char| c.is_whitespace() || c == '<' || c == '>')
                .map_or(text.len(), |n| i + n);
            let url = text[i..end].trim_end_matches(['.', ',', ';', ':', '!', '?', ')', '\'', '"']);
            let shown = github_ref(url).unwrap_or_else(|| url.to_owned());
            Some((i + url.len(), Span::styled(shown, style.patch(LINK))))
        } else if bytes[i] == b'@' {
            let len = text[i + 1..]
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '/'))
                .unwrap_or(text.len() - i - 1);
            let name = text[i + 1..i + 1 + len].trim_end_matches(['/', '-']);
            (!name.is_empty() && !name.starts_with('-')).then(|| {
                let end = i + 1 + name.len();
                (
                    end,
                    Span::styled(text[i..end].to_owned(), style.patch(BOLD)),
                )
            })
        } else if bytes[i] == b'#' {
            let len = text[i + 1..]
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(text.len() - i - 1);
            (len > 0).then(|| {
                let end = i + 1 + len;
                (end, Span::styled(text[i..end].to_owned(), style.fg(ACCENT)))
            })
        } else {
            None
        };
        match found {
            Some((end, span)) => {
                if plain < i {
                    spans.push(Span::styled(text[plain..i].to_owned(), style));
                }
                spans.push(span);
                i = end;
                plain = end;
            }
            None => i += text[i..].chars().next().map_or(1, char::len_utf8),
        }
    }
    if plain < text.len() {
        spans.push(Span::styled(text[plain..].to_owned(), style));
    }
    spans
}

enum Token {
    Word(Vec<Span<'static>>, usize),
    Space(Style),
    Break,
}

fn tokens(spans: &[Span<'static>]) -> Vec<Token> {
    let mut out = Vec::new();
    let mut word: Vec<Span<'static>> = Vec::new();
    let mut width = 0;
    let end_word = |out: &mut Vec<Token>, word: &mut Vec<Span<'static>>, width: &mut usize| {
        if !word.is_empty() {
            out.push(Token::Word(std::mem::take(word), *width));
            *width = 0;
        }
    };
    for span in spans {
        let mut piece = String::new();
        for c in span.content.chars() {
            if c == '\n' || c.is_whitespace() {
                if !piece.is_empty() {
                    word.push(Span::styled(std::mem::take(&mut piece), span.style));
                }
                end_word(&mut out, &mut word, &mut width);
                out.push(if c == '\n' {
                    Token::Break
                } else {
                    Token::Space(span.style)
                });
            } else {
                piece.push(c);
                width += c.width().unwrap_or(0);
            }
        }
        if !piece.is_empty() {
            word.push(Span::styled(piece, span.style));
        }
    }
    end_word(&mut out, &mut word, &mut width);
    out
}

/// `spans` word-wrapped to `width` columns, breaking at `\n`; runs of spaces
/// collapse and a word wider than a line is cut.
pub fn wrap(spans: &[Span<'static>], width: usize) -> Vec<Vec<Span<'static>>> {
    let width = width.max(1);
    let mut lines = Vec::new();
    let mut line: Vec<Span<'static>> = Vec::new();
    let mut used = 0;
    let mut space: Option<Style> = None;
    for token in tokens(spans) {
        match token {
            Token::Space(style) => space = space.or(Some(style)),
            Token::Break => {
                lines.push(std::mem::take(&mut line));
                used = 0;
                space = None;
            }
            Token::Word(word, w) => {
                let gap = usize::from(space.is_some() && used > 0);
                if used > 0 && used + gap + w > width {
                    lines.push(std::mem::take(&mut line));
                    used = 0;
                } else if gap == 1 {
                    line.push(Span::styled(" ", space.unwrap_or_default()));
                    used += 1;
                }
                space = None;
                if w <= width - used {
                    line.extend(word);
                    used += w;
                    continue;
                }
                for span in word {
                    for c in span.content.chars() {
                        let cw = c.width().unwrap_or(0);
                        if used + cw > width {
                            lines.push(std::mem::take(&mut line));
                            used = 0;
                        }
                        line.push(Span::styled(c.to_string(), span.style));
                        used += cw;
                    }
                }
            }
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(line: &Line) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    fn show(md: &str, width: u16) -> Vec<String> {
        let ctx = Ctx {
            width,
            font: (10, 20),
            max_rows: 10,
            image: &|_| ImageState::Ready(100, 40),
        };
        render(md, &ctx).lines.iter().map(text).collect()
    }

    #[test]
    fn wraps_with_hanging_indent_in_lists() {
        assert_eq!(
            show("- one two three four\n  - nested\n- next", 12),
            ["• one two", "  three four", "  ◦ nested", "• next"]
        );
    }

    #[test]
    fn loose_list_items_are_spaced_and_blocks_separated() {
        assert_eq!(
            show("# Title\npara\n\n1. a\n\n2. b\n\n> quoted", 20),
            ["Title", "", "para", "", "1. a", "", "2. b", "", "▎ quoted"]
        );
    }

    #[test]
    fn html_comments_and_tags_are_dropped() {
        assert_eq!(
            show(
                "<!-- template\nhint -->\n<details><summary>More</summary>\n\nbody\n</details>",
                20
            ),
            ["▸ More", "", "body"]
        );
    }

    #[test]
    fn table_fits_and_wraps_cells() {
        assert_eq!(
            show("| a | b |\n|---|--:|\n| long words here | 1 |", 16),
            [
                "╭──────────┬───╮",
                "│ a        │ b │",
                "├──────────┼───┤",
                "│ long     │ 1 │",
                "│ words    │   │",
                "│ here     │   │",
                "╰──────────┴───╯",
            ]
        );
    }

    #[test]
    fn image_reserves_rows_at_its_place() {
        let ctx = Ctx {
            width: 40,
            font: (10, 20),
            max_rows: 10,
            image: &|_| ImageState::Ready(100, 40),
        };
        let doc = render("above\n\n<img width=\"50\" src=\"x.png\">\n\nbelow", &ctx);
        assert_eq!(
            doc.images,
            [Placed {
                src: "x.png".to_owned(),
                line: 2,
                col: 0,
                cols: 5,
                rows: 1,
            }]
        );
        assert_eq!(text(&doc.lines[4]), "below");
    }

    #[test]
    fn github_links_are_shortened() {
        assert_eq!(
            show("see https://github.com/o/r/pull/12.", 40),
            ["see o/r#12."]
        );
    }

    #[test]
    fn finds_markdown_and_html_images() {
        assert_eq!(
            images("![a](one.png) <img alt=x src='two.png'/> ![b](one.png)"),
            ["one.png", "two.png"]
        );
    }
}
