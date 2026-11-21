//! Ranking a mode's entries against the query with nucleo-matcher, fzf's algorithm and query
//! syntax. The haystacks are prepared once per entries vector, not per keystroke.

use std::sync::Arc;

use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32String};
use unicode_segmentation::UnicodeSegmentation;

use crate::source::Entry;

/// A hit on title, subtitle and keywords together, rather than on the title alone, is worth this
/// much of its score.
const ALL_FIELDS: f64 = 0.7;
/// Above this many entries, scoring is split across threads.
const PARALLEL: usize = 20_000;
const SEPARATOR: &str = "  ";

pub struct Prepared {
    pub entries: Arc<Vec<Entry>>,
    title: Vec<Utf32String>,
    all: Vec<Utf32String>,
}

impl Prepared {
    pub fn new(entries: Arc<Vec<Entry>>) -> Prepared {
        let title = entries
            .iter()
            .map(|e| Utf32String::from(e.title.as_str()))
            .collect();
        let all = entries
            .iter()
            .map(|e| Utf32String::from(joined(e).as_str()))
            .collect();
        Prepared {
            entries,
            title,
            all,
        }
    }

    /// Whether these haystacks were prepared from `entries`.
    pub fn is(&self, entries: &Arc<Vec<Entry>>) -> bool {
        Arc::ptr_eq(&self.entries, entries)
    }
}

fn joined(e: &Entry) -> String {
    let mut s = String::with_capacity(e.title.len() + e.subtitle.len() + e.keywords.len() + 4);
    s.push_str(&e.title);
    s.push_str(SEPARATOR);
    s.push_str(&e.subtitle);
    s.push_str(SEPARATOR);
    s.push_str(&e.keywords);
    s
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ranked {
    pub index: usize,
    pub score: f64,
    /// Title ranges matched, UTF-16 offsets, end exclusive.
    pub hl: Vec<[u32; 2]>,
    pub shl: Vec<[u32; 2]>,
}

#[derive(Clone, Copy, PartialEq)]
enum Field {
    Title,
    All,
}

/// The frecency bonus added to a match score: grows with the log of the points, capped so that a
/// clearly better match still wins.
fn bonus_points(frecency: f64) -> f64 {
    (frecency.ln_1p() * 6.0).min(30.0)
}

fn matcher(paths: bool) -> Matcher {
    Matcher::new(if paths {
        Config::DEFAULT.match_paths()
    } else {
        Config::DEFAULT
    })
}

/// The best `limit` entries for `query`, and how many matched in all. An empty query keeps the
/// entries' order, those with frecency first, most frecent first.
pub fn rank(
    p: &Prepared,
    query: &str,
    paths: bool,
    frecency: &(dyn Fn(&Entry) -> f64 + Sync),
    limit: usize,
) -> (Vec<Ranked>, usize) {
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
    if pattern.atoms.is_empty() {
        return (unfiltered(p, frecency, limit), p.entries.len());
    }

    let n = p.entries.len();
    let mut hits: Vec<(usize, f64, Field)> = if n > PARALLEL {
        let threads = std::thread::available_parallelism().map_or(4, |t| t.get());
        let chunk = n.div_ceil(threads);
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..n)
                .step_by(chunk)
                .map(|start| {
                    let pattern = &pattern;
                    scope.spawn(move || {
                        score_range(p, pattern, paths, frecency, start..(start + chunk).min(n))
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap())
                .collect()
        })
    } else {
        score_range(p, &pattern, paths, frecency, 0..n)
    };

    let total = hits.len();
    // fzf's tiebreak: on equal scores the shorter title, then the source's order.
    let better = |a: &(usize, f64, Field), b: &(usize, f64, Field)| {
        b.1.total_cmp(&a.1)
            .then(p.entries[a.0].title.len().cmp(&p.entries[b.0].title.len()))
            .then(a.0.cmp(&b.0))
    };
    if hits.len() > limit {
        hits.select_nth_unstable_by(limit, better);
        hits.truncate(limit);
    }
    hits.sort_by(better);

    let mut m = matcher(paths);
    let mut indices = Vec::new();
    let ranked = hits
        .into_iter()
        .map(|(index, score, field)| {
            let e = &p.entries[index];
            indices.clear();
            let (hl, shl) = match field {
                Field::Title => {
                    pattern.indices(p.title[index].slice(..), &mut m, &mut indices);
                    indices.sort_unstable();
                    indices.dedup();
                    (
                        ranges_with(&e.title, &indices, e.title.is_ascii()),
                        Vec::new(),
                    )
                }
                Field::All => {
                    pattern.indices(p.all[index].slice(..), &mut m, &mut indices);
                    indices.sort_unstable();
                    indices.dedup();
                    let ascii = joined(e).is_ascii();
                    let t = units(&e.title, ascii).len() as u32;
                    let s = units(&e.subtitle, ascii).len() as u32;
                    let sep = SEPARATOR.len() as u32;
                    let title: Vec<u32> = indices.iter().copied().filter(|&i| i < t).collect();
                    let sub: Vec<u32> = indices
                        .iter()
                        .copied()
                        .filter(|&i| i >= t + sep && i < t + sep + s)
                        .map(|i| i - t - sep)
                        .collect();
                    (
                        ranges_with(&e.title, &title, ascii),
                        ranges_with(&e.subtitle, &sub, ascii),
                    )
                }
            };
            Ranked {
                index,
                score,
                hl,
                shl,
            }
        })
        .collect();
    (ranked, total)
}

fn score_range(
    p: &Prepared,
    pattern: &Pattern,
    paths: bool,
    frecency: &(dyn Fn(&Entry) -> f64 + Sync),
    range: std::ops::Range<usize>,
) -> Vec<(usize, f64, Field)> {
    let mut m = matcher(paths);
    range
        .filter_map(|i| {
            let e = &p.entries[i];
            let (base, field) = match pattern.score(p.title[i].slice(..), &mut m) {
                Some(s) => (s as f64, Field::Title),
                None => (
                    pattern.score(p.all[i].slice(..), &mut m)? as f64 * ALL_FIELDS,
                    Field::All,
                ),
            };
            Some((i, base * e.boost + bonus_points(frecency(e)), field))
        })
        .collect()
}

fn unfiltered(
    p: &Prepared,
    frecency: &(dyn Fn(&Entry) -> f64 + Sync),
    limit: usize,
) -> Vec<Ranked> {
    let mut order: Vec<(usize, f64)> = p
        .entries
        .iter()
        .enumerate()
        .map(|(i, e)| (i, frecency(e)))
        .collect();
    // Stable: entries without frecency keep the source's order after the frecent ones.
    order.sort_by(|a, b| b.1.total_cmp(&a.1));
    order
        .into_iter()
        .take(limit)
        .map(|(index, _)| Ranked {
            index,
            score: 0.0,
            hl: Vec::new(),
            shl: Vec::new(),
        })
        .collect()
}

/// The UTF-16 span of each unit the matcher indexes `s` by: bytes of an ASCII haystack, grapheme
/// clusters of any other (nucleo keeps a cluster's first code point).
fn units(s: &str, ascii: bool) -> Vec<(u32, u32)> {
    if ascii {
        return (0..s.len() as u32).map(|i| (i, i + 1)).collect();
    }
    let mut at = 0u32;
    s.graphemes(true)
        .map(|g| {
            let len = g.encode_utf16().count() as u32;
            let span = (at, at + len);
            at += len;
            span
        })
        .collect()
}

/// Matched unit indices of `s` as merged UTF-16 ranges.
fn ranges_with(s: &str, indices: &[u32], ascii: bool) -> Vec<[u32; 2]> {
    let spans = units(s, ascii);
    let mut out: Vec<[u32; 2]> = Vec::new();
    for &i in indices {
        let Some(&(start, end)) = spans.get(i as usize) else {
            continue;
        };
        match out.last_mut() {
            Some(last) if last[1] == start => last[1] = end,
            _ => out.push([start, end]),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::Action;

    fn entries(titles: &[(&str, &str)]) -> Arc<Vec<Entry>> {
        let actions: Arc<[Action]> = Arc::from(vec![Action::new("open", "Open", Some("Return"))]);
        Arc::new(
            titles
                .iter()
                .map(|(t, s)| {
                    let mut e = Entry::new(*t, *t, actions.clone());
                    e.subtitle = s.to_string();
                    e
                })
                .collect(),
        )
    }

    fn titles(p: &Prepared, ranked: &[Ranked]) -> Vec<String> {
        ranked
            .iter()
            .map(|r| p.entries[r.index].title.clone())
            .collect()
    }

    const NONE: &(dyn Fn(&Entry) -> f64 + Sync) = &|_| 0.0;

    #[test]
    fn ranks_like_fzf() {
        let p = Prepared::new(entries(&[
            ("Fire Alarm Simulator", ""),
            ("Files", ""),
            ("Firefox", ""),
            ("Thunderbird", ""),
        ]));
        let (ranked, total) = rank(&p, "fire", false, NONE, 10);
        assert_eq!(total, 2);
        // Equal prefix matches: the shorter one first.
        assert_eq!(titles(&p, &ranked), ["Firefox", "Fire Alarm Simulator"]);
        assert_eq!(ranked[0].hl, vec![[0, 4]]);
        let (ranked, _) = rank(&p, "fas", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Fire Alarm Simulator"]);
        assert_eq!(ranked[0].hl, vec![[0, 1], [5, 6], [11, 12]]);
    }

    #[test]
    fn query_syntax_is_fzfs() {
        let p = Prepared::new(entries(&[
            ("Firefox", ""),
            ("Firefox Developer", ""),
            ("Developer Tools", ""),
        ]));
        let (ranked, _) = rank(&p, "fire !dev", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Firefox"]);
        let (ranked, _) = rank(&p, "^dev", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Developer Tools"]);
        let (ranked, _) = rank(&p, "'fox", false, NONE, 10);
        assert_eq!(ranked.len(), 2);
    }

    #[test]
    fn subtitle_and_keywords_match_at_a_discount() {
        let mut e = (*entries(&[("Kitty", "Terminal emulator"), ("Terminal Tools", "")])).clone();
        e[0].keywords = "shell console".into();
        let p = Prepared::new(Arc::new(e));
        let (ranked, _) = rank(&p, "terminal", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Terminal Tools", "Kitty"]);
        assert_eq!(ranked[1].hl, Vec::<[u32; 2]>::new());
        assert_eq!(ranked[1].shl, vec![[0, 8]]);
        let (ranked, _) = rank(&p, "console", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Kitty"]);
        // Terms can hit different fields.
        let (ranked, _) = rank(&p, "kitty emulator", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Kitty"]);
        assert_eq!(ranked[0].hl, vec![[0, 5]]);
        assert_eq!(ranked[0].shl, vec![[9, 17]]);
    }

    #[test]
    fn boost_and_frecency_reorder_equal_matches() {
        let mut e = (*entries(&[("GitHub", "bookmark"), ("GitHub", "tab")])).clone();
        e[1].boost = 1.5;
        let p = Prepared::new(Arc::new(e));
        let (ranked, _) = rank(&p, "github", false, NONE, 10);
        assert_eq!(p.entries[ranked[0].index].subtitle, "tab");

        let p = Prepared::new(entries(&[("Slack", ""), ("Signal", "")]));
        let signal: &(dyn Fn(&Entry) -> f64 + Sync) =
            &|e| if e.title == "Signal" { 20.0 } else { 0.0 };
        let (ranked, _) = rank(&p, "s", false, signal, 10);
        assert_eq!(titles(&p, &ranked), ["Signal", "Slack"]);
    }

    #[test]
    fn an_empty_query_keeps_order_with_frecent_first() {
        let p = Prepared::new(entries(&[("a", ""), ("b", ""), ("c", ""), ("d", "")]));
        let f: &(dyn Fn(&Entry) -> f64 + Sync) = &|e| match e.title.as_str() {
            "c" => 3.0,
            "d" => 1.0,
            _ => 0.0,
        };
        let (ranked, total) = rank(&p, "  ", false, f, 3);
        assert_eq!(total, 4);
        assert_eq!(titles(&p, &ranked), ["c", "d", "a"]);
    }

    #[test]
    fn highlights_are_utf16_offsets() {
        let p = Prepared::new(entries(&[("😀 grinning face", ""), ("Café crème", "")]));
        let (ranked, _) = rank(&p, "face", false, NONE, 10);
        // The emoji is two UTF-16 units; "face" starts at 12.
        assert_eq!(ranked[0].hl, vec![[12, 16]]);
        let (ranked, _) = rank(&p, "creme", false, NONE, 10);
        assert_eq!(titles(&p, &ranked), ["Café crème"]);
        assert_eq!(ranked[0].hl, vec![[5, 10]]);
    }

    #[test]
    fn many_entries_are_scored_in_parallel_with_the_same_result() {
        let names: Vec<(String, String)> = (0..50_000)
            .map(|i| (format!("file{i}.txt"), String::new()))
            .collect();
        let refs: Vec<(&str, &str)> = names
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        let p = Prepared::new(entries(&refs));
        let (ranked, total) = rank(&p, "file4242.txt", true, NONE, 5);
        assert!(total >= 1);
        assert_eq!(p.entries[ranked[0].index].title, "file4242.txt");
    }
}
