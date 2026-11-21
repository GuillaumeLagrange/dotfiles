//! Desktop entries (the freedesktop Desktop Entry spec): parsing, Exec expansion and the scan of
//! the XDG data dirs.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq)]
pub struct DesktopAction {
    pub id: String,
    pub name: String,
    pub exec: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct App {
    /// The desktop id, e.g. `org.gnome.Nautilus.desktop`.
    pub id: String,
    pub path: PathBuf,
    pub name: String,
    pub generic_name: String,
    pub comment: String,
    pub icon: String,
    pub exec: String,
    pub terminal: bool,
    pub working_dir: String,
    pub keywords: Vec<String>,
    pub categories: Vec<String>,
    pub startup_wm_class: String,
    pub actions: Vec<DesktopAction>,
    /// Listed in the launcher: not NoDisplay, and shown in the current desktop.
    pub visible: bool,
}

/// The data dirs whose `applications` are scanned, most important first.
pub fn data_dirs_from_env() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    let dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    std::iter::once(data_home)
        .chain(std::env::split_paths(&dirs).filter(|p| p.is_absolute()))
        .collect()
}

pub fn desktops_from_env() -> Vec<String> {
    std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .split(':')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Every Application entry, first id wins; Hidden ones and those of other types are left out.
pub fn scan(data_dirs: &[PathBuf], desktops: &[String]) -> Vec<App> {
    let mut seen = HashMap::new();
    let mut apps = Vec::new();
    for dir in data_dirs {
        let root = dir.join("applications");
        let mut files = Vec::new();
        walk(&root, &mut files);
        files.sort();
        for path in files {
            let Ok(rel) = path.strip_prefix(&root) else {
                continue;
            };
            let id = rel.to_string_lossy().replace('/', "-");
            if seen.contains_key(&id) {
                continue;
            }
            // A Hidden entry still shadows the same id further down.
            seen.insert(id.clone(), ());
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            if let Some(app) = parse(&id, &path, &text, desktops) {
                apps.push(app);
            }
        }
    }
    apps
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk(&path, out);
        } else if path.extension().is_some_and(|e| e == "desktop") {
            out.push(path);
        }
    }
}

/// The unlocalised keys of each group.
fn groups(text: &str) -> HashMap<&str, HashMap<&str, &str>> {
    let mut groups: HashMap<&str, HashMap<&str, &str>> = HashMap::new();
    let mut current = None;
    for line in text.lines() {
        let line = line.trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(name) = line
            .strip_prefix('[')
            .and_then(|l| l.trim_end().strip_suffix(']'))
        {
            current = Some(name);
            groups.entry(name).or_default();
            continue;
        }
        let (Some(group), Some((key, value))) = (current, line.split_once('=')) else {
            continue;
        };
        let key = key.trim_end();
        if key.contains('[') {
            continue;
        }
        groups
            .entry(group)
            .or_default()
            .entry(key)
            .or_insert(value.trim_start());
    }
    groups
}

/// A `string` value's escapes: `\s \n \t \r \\`.
fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// A `;`-separated list, `\;` escaping a separator.
fn list(value: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut item = String::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some(';') => item.push(';'),
                Some(other) => {
                    item.push('\\');
                    item.push(other);
                }
                None => {}
            },
            ';' => items.push(std::mem::take(&mut item)),
            _ => item.push(c),
        }
    }
    items.push(item);
    items
        .into_iter()
        .map(|i| unescape(&i))
        .filter(|i| !i.is_empty())
        .collect()
}

pub fn parse(id: &str, path: &Path, text: &str, desktops: &[String]) -> Option<App> {
    let groups = groups(text);
    let main = groups.get("Desktop Entry")?;
    let get = |key: &str| main.get(key).map(|v| unescape(v)).unwrap_or_default();
    let flag = |key: &str| main.get(key).is_some_and(|v| v.trim() == "true");
    let lst = |key: &str| main.get(key).map(|v| list(v)).unwrap_or_default();
    if get("Type") != "Application" || flag("Hidden") {
        return None;
    }
    let only = lst("OnlyShowIn");
    let not = lst("NotShowIn");
    let shown = (only.is_empty() || only.iter().any(|d| desktops.contains(d)))
        && !not.iter().any(|d| desktops.contains(d));
    let actions = lst("Actions")
        .into_iter()
        .filter_map(|action| {
            let group = groups.get(format!("Desktop Action {action}").as_str())?;
            Some(DesktopAction {
                name: group.get("Name").map(|v| unescape(v))?,
                exec: group.get("Exec").map(|v| unescape(v))?,
                id: action,
            })
        })
        .collect();
    Some(App {
        id: id.to_owned(),
        path: path.to_owned(),
        name: get("Name"),
        generic_name: get("GenericName"),
        comment: get("Comment"),
        icon: get("Icon"),
        exec: get("Exec"),
        terminal: flag("Terminal"),
        working_dir: get("Path"),
        keywords: lst("Keywords"),
        categories: lst("Categories"),
        startup_wm_class: get("StartupWMClass"),
        actions,
        visible: shown && !flag("NoDisplay"),
    })
}

/// Splits an (already unescaped) Exec value into arguments per the spec's quoting rules: double
/// quotes group, and within them `\"`, `` \` ``, `\$` and `\\` are escapes.
pub fn split_exec(exec: &str) -> Option<Vec<String>> {
    let mut args = Vec::new();
    let mut arg = String::new();
    let mut in_arg = false;
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                in_arg = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => match chars.next()? {
                            e @ ('"' | '`' | '$' | '\\') => arg.push(e),
                            other => {
                                arg.push('\\');
                                arg.push(other);
                            }
                        },
                        other => arg.push(other),
                    }
                }
            }
            ' ' | '\t' | '\n' => {
                if in_arg {
                    args.push(std::mem::take(&mut arg));
                    in_arg = false;
                }
            }
            _ => {
                in_arg = true;
                arg.push(c);
            }
        }
    }
    if in_arg {
        args.push(arg);
    }
    Some(args)
}

/// The argv `exec` runs, field codes expanded: files and URLs dropped (nothing is passed),
/// `%i` the icon, `%c` the name, `%k` the entry's path.
pub fn expand_exec(exec: &str, app: &App) -> Option<Vec<String>> {
    let mut argv = Vec::new();
    for arg in split_exec(exec)? {
        if arg == "%i" {
            if !app.icon.is_empty() {
                argv.push("--icon".to_owned());
                argv.push(app.icon.clone());
            }
            continue;
        }
        let mut out = String::with_capacity(arg.len());
        let mut chars = arg.chars();
        let mut code_only = arg.len() == 2 && arg.starts_with('%');
        while let Some(c) = chars.next() {
            if c != '%' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('%') => {
                    out.push('%');
                    code_only = false;
                }
                Some('c') => out.push_str(&app.name),
                Some('k') => out.push_str(&app.path.to_string_lossy()),
                _ => {}
            }
        }
        if !(code_only && out.is_empty()) {
            argv.push(out);
        }
    }
    (!argv.is_empty()).then_some(argv)
}

/// The full argv to spawn: the terminal prefix for Terminal entries, `env -C` for Path.
pub fn launch_argv(exec: &str, app: &App, terminal: &[String]) -> Option<Vec<String>> {
    let mut argv = expand_exec(exec, app)?;
    if app.terminal {
        argv.splice(0..0, terminal.iter().cloned());
    }
    if !app.working_dir.is_empty() {
        argv.splice(
            0..0,
            ["env".to_owned(), "-C".to_owned(), app.working_dir.clone()],
        );
    }
    Some(argv)
}

/// The basename of the program Exec runs.
pub fn program(app: &App) -> Option<String> {
    let first = split_exec(&app.exec)?.into_iter().next()?;
    Some(first.rsplit('/').next().unwrap_or(&first).to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(text: &str) -> App {
        parse(
            "t.desktop",
            Path::new("/apps/t.desktop"),
            text,
            &["niri".into()],
        )
        .unwrap()
    }

    #[test]
    fn exec_quoting_and_escapes() {
        // In the file: "a\\\\b" is a string-escaped `\\` which quoting turns into one `\`.
        let a = app("[Desktop Entry]\nType=Application\nName=T\nExec=prog \"two words\" \"q\\\\\"x\\\\$y\" \"a\\\\\\\\b\" plain\n");
        assert_eq!(
            expand_exec(&a.exec, &a).unwrap(),
            ["prog", "two words", "q\"x$y", "a\\b", "plain"]
        );
    }

    #[test]
    fn field_codes() {
        let a = app("[Desktop Entry]\nType=Application\nName=My App\nIcon=my-icon\nExec=prog %U --name=%c %i 100%% %k %f\n");
        assert_eq!(
            expand_exec(&a.exec, &a).unwrap(),
            [
                "prog",
                "--name=My App",
                "--icon",
                "my-icon",
                "100%",
                "/apps/t.desktop"
            ]
        );
        let no_icon = app("[Desktop Entry]\nType=Application\nName=X\nExec=prog %i %F\n");
        assert_eq!(expand_exec(&no_icon.exec, &no_icon).unwrap(), ["prog"]);
    }

    #[test]
    fn lists_and_localised_keys() {
        let a = app("[Desktop Entry]\nType=Application\nName[fr]=Bonjour\nName=Hello\nKeywords=a;b\\;c;;\nExec=x\n");
        assert_eq!(a.name, "Hello");
        assert_eq!(a.keywords, ["a", "b;c"]);
    }

    #[test]
    fn unterminated_quote_is_rejected() {
        assert_eq!(split_exec("prog \"open"), None);
    }
}
