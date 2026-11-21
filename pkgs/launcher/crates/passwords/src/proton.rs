//! Proton Pass through pass-cli. Shapes from pass-cli's `vault list` (`VaultList`) and
//! `item list` (`ItemSummary`, which carries no username or URL) JSON output.

use serde::Deserialize;

use crate::{run, value, Item, Kind, Listing};

#[derive(Deserialize)]
struct Vaults {
    vaults: Vec<Vault>,
}

#[derive(Deserialize)]
struct Vault {
    name: String,
    share_id: String,
}

#[derive(Deserialize)]
struct Items {
    items: Vec<Summary>,
}

#[derive(Deserialize)]
struct Summary {
    id: String,
    share_id: String,
    title: String,
}

fn logged_out(err: &str) -> bool {
    let err = err.to_lowercase();
    err.contains("authenticated client") || err.contains("log in") || err.contains("not logged in")
}

pub(crate) fn list(command: &str) -> Listing {
    let vaults = match run(command, &["vault", "list", "--output", "json"]) {
        Ok(out) => match serde_json::from_str::<Vaults>(&out) {
            Ok(v) => v.vaults,
            Err(err) => return Listing::Failed(format!("vault list: {err}")),
        },
        Err(err) if logged_out(&err) => return Listing::LoggedOut,
        Err(err) => return Listing::Failed(err),
    };
    let lists: Vec<Result<Vec<Item>, String>> = std::thread::scope(|s| {
        let handles: Vec<_> = vaults
            .iter()
            .map(|vault| s.spawn(move || items(command, vault)))
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    let mut all = Vec::new();
    for list in lists {
        match list {
            Ok(items) => all.extend(items),
            Err(err) if logged_out(&err) => return Listing::LoggedOut,
            Err(err) => return Listing::Failed(err),
        }
    }
    Listing::Items(all)
}

fn items(command: &str, vault: &Vault) -> Result<Vec<Item>, String> {
    let out = run(
        command,
        &[
            "item",
            "list",
            // `=`: Proton ids can start with `-`, which pass-cli would take for a flag.
            &format!("--share-id={}", vault.share_id),
            "--filter-type",
            "login",
            "--filter-state",
            "active",
            "--output",
            "json",
        ],
    )?;
    let items: Items = serde_json::from_str(&out).map_err(|err| format!("item list: {err}"))?;
    Ok(items
        .items
        .into_iter()
        .map(|s| Item {
            kind: Kind::Proton,
            container: s.share_id,
            item: s.id,
            title: s.title,
            username: None,
            urls: Vec::new(),
            vault: vault.name.clone(),
            login: true,
        })
        .collect())
}

fn field(command: &str, item: &Item, field: &str) -> Result<String, String> {
    let out = run(
        command,
        &[
            "item",
            "view",
            &format!("--share-id={}", item.container),
            &format!("--item-id={}", item.item),
            "--field",
            field,
        ],
    )?;
    value(out, field)
}

pub(crate) fn fetch(command: &str, item: &Item, action: &str) -> Result<String, String> {
    match action {
        "password" => field(command, item, "password"),
        // Proton logins carry an email and an optional username.
        "username" => field(command, item, "username").or_else(|_| field(command, item, "email")),
        "totp" => field(command, item, "totp"),
        _ => Err(format!("unknown action {action}")),
    }
}
