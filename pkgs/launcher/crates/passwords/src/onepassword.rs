//! 1Password through op. Shape from `op item list --format json`
//! (https://developer.1password.com/docs/cli/reference/management-commands/item#item-list).

use serde::Deserialize;

use crate::{run, value, Item, Kind, Listing};

#[derive(Deserialize)]
struct Summary {
    id: String,
    title: String,
    vault: Vault,
    category: String,
    #[serde(default)]
    additional_information: Option<String>,
    #[serde(default)]
    urls: Vec<Url>,
}

#[derive(Deserialize)]
struct Vault {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct Url {
    href: String,
    #[serde(default)]
    primary: bool,
}

pub(crate) fn list(command: &str) -> Listing {
    let out = match run(
        command,
        &[
            "item",
            "list",
            "--categories",
            "Login,Password",
            "--format",
            "json",
        ],
    ) {
        Ok(out) => out,
        Err(err) => return Listing::Failed(err),
    };
    let summaries: Vec<Summary> = match serde_json::from_str(&out) {
        Ok(s) => s,
        Err(err) => return Listing::Failed(format!("item list: {err}")),
    };
    Listing::Items(
        summaries
            .into_iter()
            .map(|s| {
                let login = s.category == "LOGIN";
                let mut urls = s.urls;
                urls.sort_by_key(|u| !u.primary);
                Item {
                    kind: Kind::OnePassword,
                    container: s.vault.id,
                    item: s.id,
                    title: s.title,
                    username: s.additional_information.filter(|a| login && !a.is_empty()),
                    urls: urls.into_iter().map(|u| u.href).collect(),
                    vault: s.vault.name,
                    login,
                }
            })
            .collect(),
    )
}

pub(crate) fn fetch(command: &str, item: &Item, action: &str) -> Result<String, String> {
    let base = [
        "item",
        "get",
        item.item.as_str(),
        "--vault",
        item.container.as_str(),
    ];
    let out = match action {
        "password" => run(
            command,
            &[&base[..], &["--fields", "label=password", "--reveal"]].concat(),
        )?,
        "username" => run(
            command,
            &[&base[..], &["--fields", "label=username"]].concat(),
        )?,
        "totp" => run(command, &[&base[..], &["--otp"]].concat())?,
        _ => return Err(format!("unknown action {action}")),
    };
    value(out, action)
}
