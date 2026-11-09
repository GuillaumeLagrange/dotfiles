use anyhow::Result;
use serde_json::json;

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::Session;

pub fn run(cfg: &Config, json_out: bool) -> Result<()> {
    let (reg, _) = Registry::open(cfg)?;

    if json_out {
        let mut out = Vec::new();
        for (id, entry) in &reg.sessions {
            let session = Session::from_registry(&reg, id)?;
            let members: Vec<_> = session
                .members()?
                .into_iter()
                .map(|m| json!({ "repo": m.repo, "branch": m.branch }))
                .collect();
            out.push(json!({
                "id": id,
                "title": entry.title,
                "path": entry.path,
                "members": members,
            }));
        }
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(());
    }

    if reg.sessions.is_empty() {
        println!("no sessions");
        return Ok(());
    }

    for (id, entry) in &reg.sessions {
        let session = Session::from_registry(&reg, id)?;
        println!(
            "{id}{}",
            entry
                .title
                .as_ref()
                .map(|t| format!("  {t}"))
                .unwrap_or_default()
        );
        let members = session.members()?;
        if members.is_empty() {
            println!("  no members");
        }
        let width = members.iter().map(|m| m.repo.len()).max().unwrap_or(0);
        for member in members {
            println!(
                "  {:<width$}  {}",
                member.repo,
                member.branch.unwrap_or_else(|| "(detached)".into()),
                width = width
            );
        }
    }
    Ok(())
}
