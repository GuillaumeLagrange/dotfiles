//! A JSON reader and writer for the shapes niri's IPC sends and the bar reads.
//! Hand-rolled so the crate has no dependencies to vendor.

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> &Json {
        match self {
            Json::Obj(fields) => fields
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v)
                .unwrap_or(&Json::Null),
            _ => &Json::Null,
        }
    }

    pub fn at(&self, index: usize) -> &Json {
        match self {
            Json::Arr(items) => items.get(index).unwrap_or(&Json::Null),
            _ => &Json::Null,
        }
    }

    pub fn num(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn u64(&self) -> Option<u64> {
        self.num().map(|n| n as u64)
    }

    pub fn str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn truthy(&self) -> bool {
        matches!(self, Json::Bool(true))
    }

    pub fn items(&self) -> &[Json] {
        match self {
            Json::Arr(items) => items,
            _ => &[],
        }
    }

    pub fn fields(&self) -> &[(String, Json)] {
        match self {
            Json::Obj(fields) => fields,
            _ => &[],
        }
    }
}

pub struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    pub fn parse(text: &'a str) -> Option<Json> {
        let mut p = Parser {
            bytes: text.as_bytes(),
            pos: 0,
        };
        let value = p.value()?;
        p.space();
        Some(value)
    }

    fn space(&mut self) {
        while matches!(self.bytes.get(self.pos), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.bytes.get(self.pos) == Some(&byte) {
            self.pos += 1;
            return true;
        }
        false
    }

    fn literal(&mut self, word: &str) -> bool {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            return true;
        }
        false
    }

    fn value(&mut self) -> Option<Json> {
        self.space();
        match *self.bytes.get(self.pos)? {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => self.string().map(Json::Str),
            b't' => self.literal("true").then_some(Json::Bool(true)),
            b'f' => self.literal("false").then_some(Json::Bool(false)),
            b'n' => self.literal("null").then_some(Json::Null),
            _ => self.number(),
        }
    }

    fn object(&mut self) -> Option<Json> {
        self.pos += 1;
        let mut fields = Vec::new();
        loop {
            self.space();
            if self.eat(b'}') {
                return Some(Json::Obj(fields));
            }
            let key = self.string()?;
            self.space();
            if !self.eat(b':') {
                return None;
            }
            fields.push((key, self.value()?));
            self.space();
            if !self.eat(b',') && self.bytes.get(self.pos) != Some(&b'}') {
                return None;
            }
        }
    }

    fn array(&mut self) -> Option<Json> {
        self.pos += 1;
        let mut items = Vec::new();
        loop {
            self.space();
            if self.eat(b']') {
                return Some(Json::Arr(items));
            }
            items.push(self.value()?);
            self.space();
            if !self.eat(b',') && self.bytes.get(self.pos) != Some(&b']') {
                return None;
            }
        }
    }

    fn string(&mut self) -> Option<String> {
        if !self.eat(b'"') {
            return None;
        }
        let mut out = String::new();
        loop {
            match *self.bytes.get(self.pos)? {
                b'"' => {
                    self.pos += 1;
                    return Some(out);
                }
                b'\\' => {
                    self.pos += 1;
                    let escape = *self.bytes.get(self.pos)?;
                    self.pos += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return None,
                    }
                }
                _ => {
                    // Multi-byte UTF-8 passes through untouched.
                    let start = self.pos;
                    while !matches!(self.bytes.get(self.pos), Some(b'"' | b'\\') | None) {
                        self.pos += 1;
                    }
                    out.push_str(std::str::from_utf8(&self.bytes[start..self.pos]).ok()?);
                }
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let hex = std::str::from_utf8(self.bytes.get(self.pos..self.pos + 4)?).ok()?;
        self.pos += 4;
        u32::from_str_radix(hex, 16).ok()
    }

    fn unicode_escape(&mut self) -> Option<char> {
        let first = self.hex4()?;
        // Astral-plane characters (emoji in titles) arrive as a surrogate pair.
        if (0xD800..0xDC00).contains(&first) {
            if !(self.eat(b'\\') && self.eat(b'u')) {
                return None;
            }
            let second = self.hex4()?;
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
            return char::from_u32(combined);
        }
        char::from_u32(first)
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.pos;
        while matches!(
            self.bytes.get(self.pos),
            Some(b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
        ) {
            self.pos += 1;
        }
        std::str::from_utf8(&self.bytes[start..self.pos])
            .ok()?
            .parse()
            .ok()
            .map(Json::Num)
    }
}

pub fn push_str_escaped(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_round_trips_titles() {
        // Window titles are the only untrusted text on this path.
        let parsed = Parser::parse(r#"{"t":"a \"b\" \\ \n \u00e9 \ud83d\ude00 z"}"#).unwrap();
        let title = parsed.get("t").str().unwrap();
        assert_eq!(title, "a \"b\" \\ \n é 😀 z");
        let mut out = String::new();
        push_str_escaped(&mut out, title);
        assert_eq!(out, "\"a \\\"b\\\" \\\\ \\n é 😀 z\"");
        assert_eq!(Parser::parse(&out).unwrap().str().unwrap(), title);
    }

    #[test]
    fn json_parses_the_shapes_niri_sends() {
        let value = Parser::parse(
            r#"{"Ok":{"Outputs":{"eDP-1":{"logical":{"width":1920.0,"height":1200},
               "modes":[],"serial":null,"vrr":false}}}}"#,
        )
        .unwrap();
        assert_eq!(
            value
                .get("Ok")
                .get("Outputs")
                .get("eDP-1")
                .get("logical")
                .get("width")
                .num(),
            Some(1920.0)
        );
        assert_eq!(
            value.get("Ok").get("Outputs").get("eDP-1").get("serial"),
            &Json::Null
        );
        assert!(!value
            .get("Ok")
            .get("Outputs")
            .get("eDP-1")
            .get("vrr")
            .truthy());
        assert!(Parser::parse("{\"broken\":").is_none());
    }
}
