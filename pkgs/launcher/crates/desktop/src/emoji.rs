//! Emoji: the fully-qualified ones of emoji-test.txt, without skin-tone variants, named and
//! keyworded by CLDR annotations.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};
use serde::Deserialize;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub emoji_test: Option<PathBuf>,
    #[serde(default)]
    pub annotations: Vec<PathBuf>,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Annotation {
    pub name: Option<String>,
    pub keywords: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Emoji {
    pub emoji: String,
    pub name: String,
    pub group: String,
    pub subgroup: String,
}

/// The fully-qualified emoji of emoji-test.txt, in its order, skin tones and components left out.
pub fn parse_test(text: &str) -> Vec<Emoji> {
    let mut out = Vec::new();
    let (mut group, mut subgroup) = ("", "");
    for line in text.lines() {
        if let Some(g) = line.strip_prefix("# group:") {
            group = g.trim();
            continue;
        }
        if let Some(s) = line.strip_prefix("# subgroup:") {
            subgroup = s.trim();
            continue;
        }
        let Some((codes, rest)) = line.split_once(';') else {
            continue;
        };
        let Some((status, comment)) = rest.split_once('#') else {
            continue;
        };
        if status.trim() != "fully-qualified" {
            continue;
        }
        let Some(cps) = codes
            .split_whitespace()
            .map(|c| u32::from_str_radix(c, 16).ok())
            .collect::<Option<Vec<u32>>>()
        else {
            continue;
        };
        if cps.is_empty() || cps.iter().any(|c| (0x1F3FB..=0x1F3FF).contains(c)) {
            continue;
        }
        let Some(emoji) = cps
            .iter()
            .map(|&c| char::from_u32(c))
            .collect::<Option<String>>()
        else {
            continue;
        };
        // `# 😀 E1.0 grinning face`
        let mut words = comment.trim().splitn(3, ' ');
        let name = match (words.next(), words.next(), words.next()) {
            (Some(_), Some(v), Some(name)) if v.starts_with('E') => name.trim(),
            _ => continue,
        };
        out.push(Emoji {
            emoji,
            name: name.to_owned(),
            group: group.to_owned(),
            subgroup: subgroup.to_owned(),
        });
    }
    out
}

fn xml_unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_owned();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';') else { break };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .map(|h| u32::from_str_radix(h, 16))
                .or_else(|| entity.strip_prefix('#').map(str::parse))
                .and_then(Result::ok)
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Adds a CLDR annotations file's names (`type="tts"`) and keywords to `into`.
pub fn parse_annotations(text: &str, into: &mut HashMap<String, Annotation>) {
    for line in text.lines() {
        let Some(rest) = line.trim().strip_prefix("<annotation cp=\"") else {
            continue;
        };
        let Some((cp, rest)) = rest.split_once('"') else {
            continue;
        };
        let Some((attrs, rest)) = rest.split_once('>') else {
            continue;
        };
        let Some(value) = rest.strip_suffix("</annotation>") else {
            continue;
        };
        let value = xml_unescape(value);
        let entry = into.entry(xml_unescape(cp)).or_default();
        if attrs.contains("type=\"tts\"") {
            entry.name = Some(value);
        } else {
            entry.keywords = value
                .split('|')
                .map(|k| k.trim().to_owned())
                .filter(|k| !k.is_empty())
                .collect();
        }
    }
}

pub fn build(
    emoji: Vec<Emoji>,
    annotations: &HashMap<String, Annotation>,
    actions: &Arc<[Action]>,
) -> Vec<Entry> {
    emoji
        .into_iter()
        .map(|e| {
            let annotation = annotations
                .get(&e.emoji)
                .or_else(|| annotations.get(&e.emoji.replace('\u{FE0F}', "")));
            let mut entry = Entry::new(e.emoji.clone(), e.name, actions.clone());
            let mut keywords = Vec::new();
            if let Some(a) = annotation {
                if let Some(name) = &a.name {
                    entry.title = name.clone();
                }
                keywords.extend(a.keywords.iter().cloned());
            }
            keywords.push(e.group.clone());
            keywords.push(e.subgroup);
            entry.keywords = keywords.join(" ");
            entry.icon = Icon::Emoji(e.emoji);
            entry.section = e.group;
            entry
        })
        .collect()
}

fn read(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))
}

fn load(config: &Config, actions: &Arc<[Action]>) -> Result<Vec<Entry>> {
    let test = config
        .emoji_test
        .as_deref()
        .context("emoji: no emoji_test file configured")?;
    let emoji = parse_test(&read(test)?);
    let mut annotations = HashMap::new();
    for path in &config.annotations {
        parse_annotations(&read(path)?, &mut annotations);
    }
    Ok(build(emoji, &annotations, actions))
}

#[derive(Default)]
struct State {
    entries: Arc<Vec<Entry>>,
    status: Option<Status>,
}

pub struct Emojis {
    state: Arc<Mutex<State>>,
}

impl Emojis {
    pub fn new(ctx: &Ctx) -> Result<Emojis> {
        let config: Config = ctx.section(Mode::Emoji)?;
        let state = Arc::new(Mutex::new(State {
            entries: Arc::default(),
            status: Some(Status::loading("Loading emoji…")),
        }));
        let actions: Arc<[Action]> = vec![
            Action::new("copy", "Copy", Some("Return")),
            Action::new("copy-name", "Copy name", None),
        ]
        .into();
        let (shared, ctx) = (state.clone(), ctx.clone());
        std::thread::spawn(move || {
            let loaded = load(&config, &actions);
            {
                let mut state = shared.lock().unwrap();
                match loaded {
                    Ok(entries) => {
                        state.entries = Arc::new(entries);
                        state.status = None;
                    }
                    Err(err) => state.status = Some(Status::error(format!("{err:#}"))),
                }
            }
            ctx.updated(Mode::Emoji);
        });
        Ok(Emojis { state })
    }
}

impl Source for Emojis {
    fn mode(&self) -> Mode {
        Mode::Emoji
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        self.state.lock().unwrap().status.clone()
    }

    fn frecency(&self) -> bool {
        true
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        let entries = self.entries();
        let Some(entry) = entries.iter().find(|e| e.id == id) else {
            return Outcome::Error(format!("no emoji {id}"));
        };
        match action {
            "copy-name" => ctx.clipboard.copy_text(&entry.title),
            _ => ctx.clipboard.copy_text(&entry.id),
        }
        Outcome::Close
    }
}
