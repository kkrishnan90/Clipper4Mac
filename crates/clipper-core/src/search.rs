//! Lightweight fuzzy ranking for the popup's search box.
//!
//! Scoring tiers (higher is better):
//! * exact case-insensitive substring in the title (bonus if at a word start)
//! * substring in the body / file names / source app
//! * every query token matches somewhere (AND semantics)
//! * ordered subsequence ("clp" ⊂ "clipper") as a last resort
//!
//! Recency is used as a tie-breaker by the caller.

use crate::model::{Item, ItemKind};

#[derive(Debug, Clone, Default)]
pub struct Haystack<'a> {
    pub title: &'a str,
    pub body: Option<&'a str>,
    pub extra: Vec<&'a str>,
}

/// Returns `None` if the query doesn't match at all.
pub fn score(query: &str, hay: &Haystack<'_>) -> Option<i32> {
    let q = query.trim();
    if q.is_empty() {
        return Some(0);
    }
    let ql = q.to_lowercase();
    let title = hay.title.to_lowercase();

    let mut best: Option<i32> = None;
    let mut bump = |s: i32| {
        best = Some(best.map_or(s, |b| b.max(s)));
    };

    if let Some(pos) = title.find(&ql) {
        let word_start = pos == 0
            || !title[..pos]
                .chars()
                .last()
                .is_some_and(|c| c.is_alphanumeric());
        bump(1000 - pos.min(500) as i32 + if word_start { 100 } else { 0 });
    }
    if let Some(body) = hay.body {
        if let Some(pos) = body.to_lowercase().find(&ql) {
            bump(600 - (pos / 16).min(300) as i32);
        }
    }
    for e in &hay.extra {
        if e.to_lowercase().contains(&ql) {
            bump(500);
        }
    }
    if best.is_some() {
        return best;
    }

    // Multi-token AND match across all fields.
    let tokens: Vec<&str> = ql.split_whitespace().collect();
    if tokens.len() > 1 {
        let mut all = title.clone();
        if let Some(b) = hay.body {
            all.push(' ');
            all.push_str(&b.to_lowercase());
        }
        for e in &hay.extra {
            all.push(' ');
            all.push_str(&e.to_lowercase());
        }
        if tokens.iter().all(|t| all.contains(t)) {
            return Some(300);
        }
    }

    // Subsequence on the title.
    if ql.chars().count() >= 2 {
        if let Some(gap) = subsequence_gap(&ql, &title) {
            return Some(200 - gap.min(150) as i32);
        }
    }
    None
}

/// If every char of `needle` appears in order in `hay`, returns the total gap
/// between matched characters (smaller = tighter match).
fn subsequence_gap(needle: &str, hay: &str) -> Option<usize> {
    let mut it = hay.char_indices();
    let mut gap = 0;
    let mut last: Option<usize> = None;
    for nc in needle.chars() {
        if nc.is_whitespace() {
            continue;
        }
        let (idx, _) = it.by_ref().find(|(_, hc)| *hc == nc)?;
        if let Some(l) = last {
            gap += idx - l - 1;
        }
        last = Some(idx);
    }
    Some(gap)
}

/// Builds the searchable haystack for an item. `body` is the (bounded) text
/// payload the caller has already loaded, if any.
pub fn haystack<'a>(item: &'a Item, body: Option<&'a str>) -> Haystack<'a> {
    let mut extra: Vec<&str> = Vec::new();
    for f in &item.files {
        extra.push(&f.name);
        extra.push(&f.path);
    }
    if let Some(src) = &item.source {
        extra.push(&src.name);
    }
    extra.push(kind_keyword(item.kind));
    Haystack {
        title: &item.title,
        body,
        extra,
    }
}

fn kind_keyword(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Text => "text",
        ItemKind::Link => "link url",
        ItemKind::Color => "color colour",
        ItemKind::Image => "image picture screenshot",
        ItemKind::Files => "file files",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(title: &str) -> Haystack<'_> {
        Haystack {
            title,
            body: None,
            extra: vec![],
        }
    }

    #[test]
    fn empty_query_matches_everything() {
        assert_eq!(score("", &h("anything")), Some(0));
    }

    #[test]
    fn prefix_beats_infix_beats_subsequence() {
        let a = score("clip", &h("clipper is great")).unwrap();
        let b = score("clip", &h("the clipper")).unwrap();
        let c = score("clip", &h("c-l-i-p")).unwrap();
        assert!(a > b && b > c, "{a} {b} {c}");
        assert!(score("zzz", &h("clipper")).is_none());
    }

    #[test]
    fn body_and_extra_fields_match() {
        let hay = Haystack {
            title: "Image · 10 × 10",
            body: None,
            extra: vec!["Safari", "screenshot"],
        };
        assert!(score("safari", &hay).is_some());
        assert!(score("screen", &hay).is_some());
        let hay = Haystack {
            title: "first line",
            body: Some("deep inside the body: needle"),
            extra: vec![],
        };
        assert!(score("needle", &hay).is_some());
    }

    #[test]
    fn multi_token_and_semantics() {
        let hay = Haystack {
            title: "Kotak Bank statement",
            body: Some("2026-09-14"),
            extra: vec![],
        };
        assert!(score("kotak 2026", &hay).is_some());
        assert!(score("kotak 1999", &hay).is_none());
    }
}
