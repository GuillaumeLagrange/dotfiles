//! The conversation omp records in its session file, for the picker's detail
//! pane: what was asked, what was answered, and the tools run in between.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use serde::Deserialize;
use serde_json::Value;

/// Only the end of a session file is read: tool results make it megabytes long,
/// and the panel shows the latest turns.
const TAIL: u64 = 1 << 20;

#[derive(Debug, PartialEq)]
pub enum Entry {
    User(String),
    Assistant(String),
    /// A run of tool calls with no text between them, by the last one's intent.
    Tools {
        count: usize,
        last: String,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    id: Option<String>,
    parent_id: Option<String>,
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    role: String,
    #[serde(default)]
    content: Value,
}

fn text(content: &Value) -> String {
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|p| p["type"] == "text")
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    };
    text.trim().to_owned()
}

fn tool_label(call: &Value) -> String {
    call["arguments"]["i"]
        .as_str()
        .or_else(|| call["name"].as_str())
        .unwrap_or("tool")
        .to_owned()
}

fn push_tool(entries: &mut Vec<Entry>, label: String) {
    if let Some(Entry::Tools { count, last }) = entries.last_mut() {
        *count += 1;
        *last = label;
    } else {
        entries.push(Entry::Tools {
            count: 1,
            last: label,
        });
    }
}

/// The current branch of the session, oldest first: the last record and its
/// ancestors, so turns rewound past are left out.
pub fn read(path: &str) -> Option<Vec<Entry>> {
    let mut file = File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;
    let buf = String::from_utf8_lossy(&buf);
    // A tail read starts mid-line.
    let body = match start {
        0 => &buf[..],
        _ => buf.split_once('\n').map_or("", |(_, rest)| rest),
    };
    Some(parse(body))
}

fn parse(jsonl: &str) -> Vec<Entry> {
    let records: Vec<Record> = jsonl
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    let by_id: HashMap<&str, usize> = records
        .iter()
        .enumerate()
        .filter_map(|(i, r)| Some((r.id.as_deref()?, i)))
        .collect();
    let mut branch = Vec::new();
    let mut at = records.iter().rposition(|r| r.id.is_some());
    while let Some(i) = at {
        branch.push(i);
        at = records[i]
            .parent_id
            .as_deref()
            .and_then(|p| by_id.get(p).copied());
    }

    let mut entries = Vec::new();
    for message in branch
        .into_iter()
        .rev()
        .filter_map(|i| records[i].message.as_ref())
    {
        match message.role.as_str() {
            "user" => {
                let text = text(&message.content);
                if !text.is_empty() {
                    entries.push(Entry::User(text));
                }
            }
            "assistant" => {
                let text = text(&message.content);
                if !text.is_empty() {
                    entries.push(Entry::Assistant(text));
                }
                for call in message
                    .content
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|p| p["type"] == "toolCall")
                {
                    push_tool(&mut entries, tool_label(call));
                }
            }
            _ => {}
        }
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, parent: Option<&str>, role: &str, content: Value) -> String {
        serde_json::json!({
            "type": "message", "id": id, "parentId": parent,
            "message": { "role": role, "content": content },
        })
        .to_string()
    }

    #[test]
    fn follows_the_current_branch_and_folds_tool_runs() {
        let lines = [
            r#"{"type":"session","id":"s"}"#.to_owned(),
            record("u1", None, "user", "first".into()),
            record(
                "a1",
                Some("u1"),
                "assistant",
                serde_json::json!([
                    {"type": "thinking", "thinking": "hidden"},
                    {"type": "toolCall", "name": "read", "arguments": {"i": "Reading a"}},
                ]),
            ),
            record(
                "r1",
                Some("a1"),
                "toolResult",
                serde_json::json!([{"type": "text", "text": "out"}]),
            ),
            record(
                "a2",
                Some("r1"),
                "assistant",
                serde_json::json!([
                    {"type": "toolCall", "name": "bash", "arguments": {}},
                ]),
            ),
            record(
                "a3",
                Some("a2"),
                "assistant",
                serde_json::json!([{"type": "text", "text": "answer"}]),
            ),
            // Rewound: asked again from the first answer, the old follow-up dropped.
            record(
                "u2",
                Some("a3"),
                "user",
                serde_json::json!([{"type": "text", "text": "abandoned"}]),
            ),
            record(
                "u3",
                Some("a3"),
                "user",
                serde_json::json!([{"type": "text", "text": "again"}]),
            ),
        ];
        assert_eq!(
            parse(&lines.join("\n")),
            vec![
                Entry::User("first".into()),
                Entry::Tools {
                    count: 2,
                    last: "bash".into()
                },
                Entry::Assistant("answer".into()),
                Entry::User("again".into()),
            ]
        );
    }

    #[test]
    fn a_tail_read_drops_the_cut_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let big = record("u0", None, "user", "x".repeat(TAIL as usize).into());
        let last = record("u1", Some("u0"), "user", "kept".into());
        std::fs::write(&path, format!("{big}\n{last}\n")).unwrap();
        assert_eq!(
            read(path.to_str().unwrap()),
            Some(vec![Entry::User("kept".into())])
        );
    }
}
