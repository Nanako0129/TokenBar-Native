//! Discover the Bearer token Kiro stored for the signed-in account.
//!
//! Kiro keeps a credential in two places, and a user can have either or both:
//!
//! - **kiro-cli** writes it into a SQLite store (`auth_kv`, key
//!   `kirocli:social:token`), the value a JSON object with `access_token`,
//!   `profile_arn` and `expires_at`. We read it through the `sqlite3` binary
//!   (read-only) on macOS and Linux, the same subprocess approach
//!   `agent_antigravity.rs` uses for the Antigravity CLI; there is no SQLite
//!   dependency in the crate. Other targets have no `sqlite3` at a known path,
//!   so this source is unavailable there and only the IDE token file is read.
//! - **Kiro IDE** writes a plain JSON token file under `~/.aws/sso/cache`.
//!
//! We collect every source that holds a token, then pick the freshest: a valid
//! IDE token wins over an expired CLI token and the reverse. When every source
//! is present but expired we return `Terminal` so the user sees a reauth prompt
//! rather than a silently missing card. This mirrors mana.bar's `KiroProvider`
//! discovery, narrowed to the single account TokenBar shows one card for.
//!
//! Absent vs Terminal follows the Copilot loader's rule: a source that is
//! simply not signed in is `Absent`, while a present-but-broken token entry, or
//! an unreadable/undecodable IDE file, is `Terminal` and must not be hidden as a
//! signed-out state. A SQLite store that cannot be read (locked, or `sqlite3`
//! missing) is treated as unavailable — `Absent` — never a hard error.

use crate::agent_account_scope::canonical_file_location;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::path::{Path, PathBuf};

const CLI_TOKEN_QUERY: &str = "select value from auth_kv where key='kirocli:social:token' limit 1;";
const SQLITE3_BIN: &str = "/usr/bin/sqlite3";

pub(crate) struct KiroCredential {
    pub(crate) request_token: String,
    pub(crate) profile_arn: Option<String>,
    pub(crate) marker: Vec<u8>,
    pub(crate) semantic_source: &'static str,
    pub(crate) canonical_location: String,
}

pub(crate) enum KiroCredentialLoad {
    Absent,
    Present(KiroCredential),
    Terminal(String),
}

/// One token found in a source, before the freshest is chosen.
struct Candidate {
    access_token: String,
    profile_arn: Option<String>,
    expires_at_ms: Option<i64>,
    semantic_source: &'static str,
    canonical_location: String,
}

/// A single source's result: not signed in, a token, or a hard error that must
/// not be hidden as signed-out.
enum SourceOutcome {
    Absent,
    Candidate(Candidate),
    Terminal(String),
}

/// The token fields a source's JSON can carry, once parsed.
enum TokenParse {
    /// The source is present but names no access token (signed out).
    Missing,
    /// The source is present but broken (not an object, wrong-typed token).
    Malformed,
    Token {
        access_token: String,
        profile_arn: Option<String>,
        expires_at_ms: Option<i64>,
    },
}

pub(crate) async fn kiro_credential(now: DateTime<Utc>) -> KiroCredentialLoad {
    let mut candidates = Vec::new();
    let mut terminal: Option<String> = None;
    for outcome in [load_cli_candidate().await, load_ide_candidate()] {
        match outcome {
            SourceOutcome::Candidate(candidate) => candidates.push(candidate),
            // Keep the first hard error, but do not return on it yet: a broken
            // store in one source must not hide a valid token in the other. The
            // error is surfaced only if no source yields a usable candidate.
            SourceOutcome::Terminal(display) => {
                if terminal.is_none() {
                    terminal = Some(display);
                }
            }
            SourceOutcome::Absent => {}
        }
    }
    select_with_fallback(candidates, terminal, now.timestamp_millis())
}

/// Select the freshest candidate; a sibling source's hard error is surfaced only
/// when no candidate is usable, so a broken store never hides a valid token.
fn select_with_fallback(
    candidates: Vec<Candidate>,
    terminal: Option<String>,
    now_ms: i64,
) -> KiroCredentialLoad {
    match select_candidate(candidates, now_ms) {
        KiroCredentialLoad::Absent => match terminal {
            Some(display) => KiroCredentialLoad::Terminal(display),
            None => KiroCredentialLoad::Absent,
        },
        selected => selected,
    }
}

/// Prefer a non-expired token (freshest expiry wins). When a source is present
/// but every token found is expired, that is a reauth-required Terminal, not a
/// missing card.
fn select_candidate(candidates: Vec<Candidate>, now_ms: i64) -> KiroCredentialLoad {
    if candidates.is_empty() {
        return KiroCredentialLoad::Absent;
    }
    let best_fresh = candidates
        .into_iter()
        .filter(|candidate| candidate.expires_at_ms.is_none_or(|expiry| expiry > now_ms))
        .max_by_key(|candidate| {
            // Prefer a token we can prove is fresh (a known future expiry) over
            // one whose expiry is unknown, since an unknown expiry could in fact
            // be past. Among known-fresh tokens the latest expiry wins; a token
            // with no expiry is used only when it is the sole fresh candidate.
            (
                candidate.expires_at_ms.is_some(),
                candidate.expires_at_ms.unwrap_or(i64::MIN),
            )
        });
    match best_fresh {
        Some(candidate) => KiroCredentialLoad::Present(KiroCredential {
            request_token: candidate.access_token.clone(),
            profile_arn: candidate.profile_arn,
            marker: candidate.access_token.into_bytes(),
            semantic_source: candidate.semantic_source,
            canonical_location: candidate.canonical_location,
        }),
        None => KiroCredentialLoad::Terminal(
            "Kiro credentials have expired. Sign in again in Kiro CLI or Kiro IDE.".to_string(),
        ),
    }
}

fn load_ide_candidate() -> SourceOutcome {
    let Some(path) = ide_token_path() else {
        return SourceOutcome::Absent;
    };
    load_ide_candidate_at(&path)
}

fn load_ide_candidate_at(path: &Path) -> SourceOutcome {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return SourceOutcome::Absent;
        }
        Err(_) => {
            return SourceOutcome::Terminal("Kiro IDE token file could not be read.".to_string());
        }
    };
    let json = match serde_json::from_str::<Value>(&raw) {
        Ok(json) => json,
        Err(_) => {
            return SourceOutcome::Terminal(
                "Kiro IDE token file could not be decoded.".to_string(),
            );
        }
    };
    candidate_from_parse(
        parse_ide_token_json(&json),
        "kiro-ide-token",
        path,
        "kiro-auth-token",
        "Kiro IDE token entry is malformed.",
    )
}

async fn load_cli_candidate() -> SourceOutcome {
    let Some(path) = cli_db_path() else {
        return SourceOutcome::Absent;
    };
    if !path.exists() {
        return SourceOutcome::Absent;
    }
    // A store that cannot be read (locked, or `sqlite3` missing) is unavailable,
    // not a hard error; only a present-but-broken token value is Terminal.
    let Some(value) = read_cli_sqlite_value(&path).await else {
        return SourceOutcome::Absent;
    };
    candidate_from_parse(
        parse_cli_token_value(&value),
        "kiro-cli-sqlite",
        &path,
        "kirocli:social:token",
        "Kiro CLI token entry is malformed.",
    )
}

fn candidate_from_parse(
    parse: TokenParse,
    semantic_source: &'static str,
    path: &Path,
    record: &str,
    malformed_display: &str,
) -> SourceOutcome {
    let (access_token, profile_arn, expires_at_ms) = match parse {
        TokenParse::Missing => return SourceOutcome::Absent,
        TokenParse::Malformed => return SourceOutcome::Terminal(malformed_display.to_string()),
        TokenParse::Token {
            access_token,
            profile_arn,
            expires_at_ms,
        } => (access_token, profile_arn, expires_at_ms),
    };
    let canonical_location = match canonical_file_location(path, Some(record)) {
        Ok(location) => location,
        Err(_) => {
            return SourceOutcome::Terminal(
                "Kiro token location could not be verified.".to_string(),
            );
        }
    };
    SourceOutcome::Candidate(Candidate {
        access_token,
        profile_arn,
        expires_at_ms,
        semantic_source,
        canonical_location,
    })
}

/// The kiro-cli value is `snake_case` (`access_token`, `profile_arn`,
/// `expires_at`), matching what the CLI writes into SQLite.
fn parse_cli_token_value(raw: &str) -> TokenParse {
    let Ok(json) = serde_json::from_str::<Value>(raw) else {
        return TokenParse::Malformed;
    };
    parse_token_object(&json, "access_token", "profile_arn", "expires_at")
}

/// The Kiro IDE file is `camelCase` (`accessToken`, `profileArn`, `expiresAt`).
fn parse_ide_token_json(json: &Value) -> TokenParse {
    parse_token_object(json, "accessToken", "profileArn", "expiresAt")
}

fn parse_token_object(
    json: &Value,
    token_key: &str,
    arn_key: &str,
    expiry_key: &str,
) -> TokenParse {
    let Some(object) = json.as_object() else {
        return TokenParse::Malformed;
    };
    let access_token = match object.get(token_key) {
        Some(Value::String(value)) if !value.trim().is_empty() => value.trim().to_string(),
        // No token, or an explicitly empty one, is a signed-out source.
        None | Some(Value::Null) => return TokenParse::Missing,
        Some(Value::String(_)) => return TokenParse::Missing,
        // A non-string token field is a broken entry, not a signed-out one.
        Some(_) => return TokenParse::Malformed,
    };
    let profile_arn = match object.get(arn_key) {
        Some(Value::String(value)) if !value.trim().is_empty() => Some(value.trim().to_string()),
        _ => None,
    };
    let expires_at_ms = object.get(expiry_key).and_then(parse_expires_at_ms);
    TokenParse::Token {
        access_token,
        profile_arn,
        expires_at_ms,
    }
}

/// Normalize the shapes an expiry field can take into epoch milliseconds:
/// numeric seconds (below 1e12) or milliseconds, or an ISO-8601 string. An
/// unparseable value yields `None`, which is treated as "no known expiry".
fn parse_expires_at_ms(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => {
            let millis = number.as_f64().filter(|value| value.is_finite())?;
            let millis = if millis < 1e12 {
                millis * 1000.0
            } else {
                millis
            };
            // Bound the value before the `as i64` cast: that cast saturates, so
            // an absurd expiry would become `i64::MAX` and, under the
            // freshest-token ranking, outrank every real token. An out-of-range
            // value reads as "unknown expiry" (None) instead, which ranks below
            // any provably-fresh token.
            (0.0..i64::MAX as f64)
                .contains(&millis)
                .then_some(millis as i64)
        }
        Value::String(text) if !text.trim().is_empty() => DateTime::parse_from_rfc3339(text.trim())
            .ok()
            .map(|parsed| parsed.with_timezone(&Utc).timestamp_millis()),
        _ => None,
    }
}

async fn read_cli_sqlite_value(db_path: &Path) -> Option<String> {
    let future = tokio::process::Command::new(SQLITE3_BIN)
        // `-init /dev/null` stops sqlite3 from sourcing the user's ~/.sqliterc,
        // whose `.mode`/`.headers` commands would corrupt the raw value we parse
        // and whose `.shell`/`.system` commands would otherwise run on every
        // quota refresh. This source is macOS/Linux only, so /dev/null is valid.
        .arg("-init")
        .arg("/dev/null")
        .arg("-readonly")
        .arg(db_path)
        .arg(CLI_TOKEN_QUERY)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(std::time::Duration::from_secs(5), future)
        .await
        .ok()?
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!value.is_empty()).then_some(value)
}

fn ide_token_path() -> Option<PathBuf> {
    Some(
        crate::user_home_dir()?
            .join(".aws")
            .join("sso")
            .join("cache")
            .join("kiro-auth-token.json"),
    )
}

#[cfg(target_os = "macos")]
fn cli_db_path() -> Option<PathBuf> {
    Some(
        crate::user_home_dir()?
            .join("Library")
            .join("Application Support")
            .join("kiro-cli")
            .join("data.sqlite3"),
    )
}

#[cfg(target_os = "linux")]
fn cli_db_path() -> Option<PathBuf> {
    let root = match std::env::var("XDG_DATA_HOME") {
        Ok(root) if !root.is_empty() => PathBuf::from(root),
        _ => crate::user_home_dir()?.join(".local").join("share"),
    };
    Some(root.join("kiro-cli").join("data.sqlite3"))
}

// Other targets (Windows included) have no `sqlite3` at a known absolute path
// to read the kiro-cli store, so the CLI source is unavailable and a signed-in
// user falls through to the Kiro IDE token file. Returning `None` here keeps
// `load_cli_candidate` from launching a reader that cannot run, and from
// advertising a store path it could never query.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn cli_db_path() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_source_shapes() {
        // kiro-cli value: snake_case, expires_at in epoch seconds.
        match parse_cli_token_value(
            r#"{"access_token":"  tok-cli  ","profile_arn":"arn:aws:x","expires_at":1788912000}"#,
        ) {
            TokenParse::Token {
                access_token,
                profile_arn,
                expires_at_ms,
            } => {
                assert_eq!(access_token, "tok-cli");
                assert_eq!(profile_arn.as_deref(), Some("arn:aws:x"));
                assert_eq!(expires_at_ms, Some(1_788_912_000_000));
            }
            _ => panic!("expected a token"),
        }
        // Kiro IDE file: camelCase, expiresAt as an ISO string.
        match parse_ide_token_json(&serde_json::json!({
            "accessToken": "tok-ide",
            "profileArn": "arn:aws:y",
            "expiresAt": "2026-09-08T00:00:00Z"
        })) {
            TokenParse::Token {
                access_token,
                expires_at_ms,
                ..
            } => {
                assert_eq!(access_token, "tok-ide");
                assert_eq!(expires_at_ms, Some(1_788_825_600_000));
            }
            _ => panic!("expected a token"),
        }
    }

    #[test]
    fn distinguishes_missing_from_malformed() {
        // Missing: object present, no usable token -> signed out.
        for missing in [
            serde_json::json!({}),
            serde_json::json!({ "accessToken": "" }),
            serde_json::json!({ "accessToken": null }),
        ] {
            assert!(matches!(
                parse_ide_token_json(&missing),
                TokenParse::Missing
            ));
        }
        // Malformed: not an object, or a wrong-typed token field.
        assert!(matches!(
            parse_cli_token_value("not json"),
            TokenParse::Malformed
        ));
        for malformed in [
            serde_json::json!("a string"),
            serde_json::json!({ "accessToken": 42 }),
            serde_json::json!({ "accessToken": { "nested": true } }),
        ] {
            assert!(matches!(
                parse_ide_token_json(&malformed),
                TokenParse::Malformed
            ));
        }
    }

    #[test]
    fn expiry_accepts_seconds_millis_and_iso() {
        assert_eq!(
            parse_expires_at_ms(&serde_json::json!(1_788_912_000_i64)),
            Some(1_788_912_000_000)
        );
        assert_eq!(
            parse_expires_at_ms(&serde_json::json!(1_788_912_000_000_i64)),
            Some(1_788_912_000_000)
        );
        assert_eq!(
            parse_expires_at_ms(&serde_json::json!("2026-09-08T00:00:00Z")),
            Some(1_788_825_600_000)
        );
        for bad in [
            serde_json::json!("not-a-date"),
            serde_json::json!(null),
            serde_json::json!(-5),
            serde_json::json!(true),
            // An oversized value must read as unknown (None), not saturate to
            // i64::MAX on the cast and outrank every real token.
            serde_json::json!(1e30),
            serde_json::json!(9.3e18),
        ] {
            assert_eq!(parse_expires_at_ms(&bad), None, "{bad}");
        }
    }

    fn candidate(expires_at_ms: Option<i64>, token: &str) -> Candidate {
        Candidate {
            access_token: token.to_string(),
            profile_arn: None,
            expires_at_ms,
            semantic_source: "kiro-cli-sqlite",
            canonical_location: format!("/loc/{token}"),
        }
    }

    #[test]
    fn selection_prefers_the_freshest_non_expired_token() {
        let now = 1_000_000;
        // A valid IDE token wins over an expired CLI token.
        let load = select_candidate(
            vec![
                candidate(Some(now - 10), "expired"),
                candidate(Some(now + 10_000), "fresh"),
            ],
            now,
        );
        match load {
            KiroCredentialLoad::Present(credential) => {
                assert_eq!(credential.request_token, "fresh");
                assert_eq!(credential.marker, b"fresh");
            }
            _ => panic!("expected a present credential"),
        }
        // A provably-fresh token (known future expiry) beats one with an
        // unknown expiry, and among known ones the latest expiry wins.
        let load = select_candidate(
            vec![
                candidate(Some(now + 100), "soon"),
                candidate(Some(now + 9_000), "later"),
                candidate(None, "unknown-expiry"),
            ],
            now,
        );
        match load {
            KiroCredentialLoad::Present(credential) => {
                assert_eq!(credential.request_token, "later");
            }
            _ => panic!("expected a present credential"),
        }
        // An unknown-expiry token is used only when it is the sole fresh one.
        let load = select_candidate(vec![candidate(None, "only-unknown")], now);
        match load {
            KiroCredentialLoad::Present(credential) => {
                assert_eq!(credential.request_token, "only-unknown");
            }
            _ => panic!("expected a present credential"),
        }
    }

    #[test]
    fn a_valid_token_in_one_source_overrides_a_broken_other_source() {
        // `kiro_credential` returns Terminal only when no source yields a usable
        // token: a candidate must win over a sibling source's hard error, and the
        // error is surfaced only when there is no candidate at all.
        let now = 1_000_000;
        let broken = Some("Kiro CLI token entry is malformed.".to_string());
        // A valid candidate wins even though the other source errored.
        let selected = select_with_fallback(
            vec![candidate(Some(now + 5_000), "good")],
            broken.clone(),
            now,
        );
        assert!(
            matches!(selected, KiroCredentialLoad::Present(credential) if credential.request_token == "good"),
            "a collected candidate is selected regardless of another source's error"
        );
        // No candidate and a source errored -> surface that error, not Absent.
        assert!(matches!(
            select_with_fallback(vec![], broken, now),
            KiroCredentialLoad::Terminal(_)
        ));
        // No candidate and no error -> Absent (simply not signed in).
        assert!(matches!(
            select_with_fallback(vec![], None, now),
            KiroCredentialLoad::Absent
        ));
        // Every collected token expired -> the reauth Terminal from selection,
        // regardless of whether another source also errored.
        assert!(matches!(
            select_with_fallback(vec![candidate(Some(now - 1), "stale")], None, now),
            KiroCredentialLoad::Terminal(_)
        ));
    }

    #[test]
    fn selection_is_absent_with_no_candidates_and_terminal_when_all_expired() {
        assert!(matches!(
            select_candidate(vec![], 1_000_000),
            KiroCredentialLoad::Absent
        ));
        assert!(matches!(
            select_candidate(vec![candidate(Some(500_000), "old")], 1_000_000),
            KiroCredentialLoad::Terminal(_)
        ));
    }

    #[test]
    fn ide_file_loader_treats_missing_as_absent_and_io_or_json_as_terminal() {
        let root =
            std::env::temp_dir().join(format!("tokenbar-kiro-loader-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        // A missing file is a signed-out Absent.
        assert!(matches!(
            load_ide_candidate_at(&root.join("missing.json")),
            SourceOutcome::Absent
        ));
        // An unreadable path (a directory) is Terminal, not hidden as signed-out.
        assert!(matches!(
            load_ide_candidate_at(&root),
            SourceOutcome::Terminal(_)
        ));
        // Undecodable content is Terminal.
        let invalid = root.join("invalid.json");
        std::fs::write(&invalid, "not json").unwrap();
        assert!(matches!(
            load_ide_candidate_at(&invalid),
            SourceOutcome::Terminal(_)
        ));
        // A present entry with no token is Absent (signed out).
        let logged_out = root.join("logged-out.json");
        std::fs::write(&logged_out, r#"{"accessToken":""}"#).unwrap();
        assert!(matches!(
            load_ide_candidate_at(&logged_out),
            SourceOutcome::Absent
        ));
        // A broken token entry is Terminal.
        let broken = root.join("broken.json");
        std::fs::write(&broken, r#"{"accessToken":42}"#).unwrap();
        assert!(matches!(
            load_ide_candidate_at(&broken),
            SourceOutcome::Terminal(_)
        ));
        // A valid token file yields a candidate carrying the account record.
        let present = root.join("present.json");
        std::fs::write(
            &present,
            r#"{"accessToken":"tok","profileArn":"arn","expiresAt":1788912000}"#,
        )
        .unwrap();
        match load_ide_candidate_at(&present) {
            SourceOutcome::Candidate(candidate) => {
                assert_eq!(candidate.access_token, "tok");
                assert_eq!(candidate.profile_arn.as_deref(), Some("arn"));
                assert_eq!(candidate.semantic_source, "kiro-ide-token");
                assert!(candidate.canonical_location.contains("kiro-auth-token"));
            }
            _ => panic!("expected a candidate"),
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
