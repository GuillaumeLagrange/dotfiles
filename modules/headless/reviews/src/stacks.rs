//! A list's pull requests with each GitHub stack gathered under a heading, the
//! layout both the picker and `reviews --json` show.

use crate::github::Pr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    Alone,
    Child { last: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    /// Heads a stack; `pr` is one of its members, for the stack's details.
    Stack {
        pr: usize,
    },
    Pr {
        pr: usize,
        place: Place,
    },
}

/// Past this without an update, a pull request is hidden until asked for.
pub const STALE_DAYS: u64 = 60;

/// Whether `prs[i]` is hidden as stale: not updated in `STALE_DAYS`, and
/// neither is any member of its stack, which shows whole or not at all.
pub fn stale(prs: &[Pr], i: usize, now: u64) -> bool {
    let old = |pr: &Pr| now.saturating_sub(pr.updated_at) > STALE_DAYS * 86400;
    let pr = &prs[i];
    match &pr.stack {
        None => old(pr),
        Some(stack) => prs
            .iter()
            .filter(|p| {
                p.repo_full == pr.repo_full
                    && p.stack.as_ref().is_some_and(|s| s.number == stack.number)
            })
            .all(old),
    }
}

/// `shown` (indices into `prs`) with each GitHub stack gathered under a
/// heading at the place of its first member, top of the stack first. A stack
/// with nothing listed shown is dropped.
pub fn stacks(prs: &[Pr], shown: Vec<usize>) -> Vec<Row> {
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

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::github::{Stack, State};

    /// `stack`: (number, position) in a stack of 3.
    pub fn pr(number: u64, stack: Option<(u64, u64)>, listed: bool, state: State) -> Pr {
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
            linear: Vec::new(),
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
    fn a_stack_is_stale_only_when_every_member_is() {
        let day = 86400;
        let now = 100 * day;
        let at = |mut p: Pr, days_ago: u64| {
            p.updated_at = now - days_ago * day;
            p
        };
        let prs = [
            at(pr(1, Some((9, 1)), true, State::Open), 90),
            at(pr(2, Some((9, 2)), true, State::Open), 3),
            at(pr(3, None, true, State::Open), 61),
            at(pr(4, None, true, State::Open), 60),
            at(pr(5, Some((8, 1)), true, State::Open), 70),
        ];
        let stale: Vec<bool> = (0..prs.len()).map(|i| stale(&prs, i, now)).collect();
        assert_eq!(stale, [false, false, true, false, true]);
    }
}
