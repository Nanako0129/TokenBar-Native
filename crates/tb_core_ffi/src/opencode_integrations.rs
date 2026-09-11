//! Detect which subscription-type providers opencode is authenticated against.
//!
//! opencode can sign in to providers via OAuth (a shared subscription, e.g.
//! "Sign in with ChatGPT" = the Codex/ChatGPT plan) or via API keys (metered).
//! Its `auth.json` under the XDG data root records each provider with a `type`.
//! We surface the `type: "oauth"` providers so the user can see which agent
//! subscriptions opencode also draws on (its usage counts against those plans).

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
struct AuthEntry {
    #[serde(default)]
    r#type: Option<String>,
}

/// Friendly subscription labels for opencode's OAuth providers, in a stable order.
pub fn detect_subscriptions() -> Vec<String> {
    let Some(path) = auth_path() else {
        return Vec::new();
    };
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(entries) = serde_json::from_str::<BTreeMap<String, AuthEntry>>(&raw) else {
        return Vec::new();
    };
    let mut labels: Vec<String> = entries
        .into_iter()
        .filter(|(_, entry)| {
            entry
                .r#type
                .as_deref()
                .is_some_and(|t| t.eq_ignore_ascii_case("oauth"))
        })
        .map(|(provider, _)| subscription_label(&provider))
        .collect();
    labels.sort();
    labels.dedup();
    labels
}

fn subscription_label(provider: &str) -> String {
    match provider.to_lowercase().as_str() {
        "openai" => "Codex".to_string(),
        "anthropic" => "Claude".to_string(),
        "github-copilot" | "copilot" => "Copilot".to_string(),
        "google" | "gemini" => "Gemini".to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str()),
                None => provider.to_string(),
            }
        }
    }
}

fn auth_path() -> Option<PathBuf> {
    auth_path_from(
        std::env::var("XDG_DATA_HOME"),
        crate::user_home_dir().as_deref(),
    )
}

fn auth_path_from(
    xdg_data_home: Result<String, std::env::VarError>,
    user_home: Option<&std::path::Path>,
) -> Option<PathBuf> {
    let root = match xdg_data_home {
        Ok(root) if !root.is_empty() => root,
        Ok(_) | Err(_) => format!("{}/.local/share", user_home?.to_string_lossy()),
    };
    Some(PathBuf::from(format!("{root}/opencode/auth.json")))
}

pub(crate) struct GitHubCopilotCredential {
    pub(crate) request_token: String,
    pub(crate) marker: Vec<u8>,
    pub(crate) semantic_source: &'static str,
    pub(crate) canonical_location: String,
}

pub(crate) enum GitHubCopilotCredentialLoad {
    Absent,
    Present(GitHubCopilotCredential),
    Terminal(String),
}

/// Load only the durable GitHub OAuth credential used by Copilot. A missing
/// file/entry or explicit logout is `Absent`; storage, syntax, canonicalization,
/// or a present malformed OAuth entry is `Terminal` and must not be hidden as a
/// signed-out state.
pub(crate) fn github_copilot_credential() -> GitHubCopilotCredentialLoad {
    let Some(path) = auth_path() else {
        return GitHubCopilotCredentialLoad::Terminal(
            "OpenCode auth location could not be resolved.".to_string(),
        );
    };
    github_copilot_credential_at(&path)
}

fn github_copilot_credential_at(path: &std::path::Path) -> GitHubCopilotCredentialLoad {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return GitHubCopilotCredentialLoad::Absent;
        }
        Err(_) => {
            return GitHubCopilotCredentialLoad::Terminal(
                "OpenCode auth file could not be read.".to_string(),
            );
        }
    };
    let json = match serde_json::from_str::<serde_json::Value>(&raw) {
        Ok(json) => json,
        Err(_) => {
            return GitHubCopilotCredentialLoad::Terminal(
                "OpenCode auth file could not be decoded.".to_string(),
            );
        }
    };
    github_copilot_credential_from(path, &json)
}

fn github_copilot_credential_from(
    path: &std::path::Path,
    json: &serde_json::Value,
) -> GitHubCopilotCredentialLoad {
    let Some(entry) = json.get("github-copilot") else {
        return GitHubCopilotCredentialLoad::Absent;
    };
    let Some(entry) = entry.as_object() else {
        return GitHubCopilotCredentialLoad::Terminal(
            "OpenCode Copilot OAuth entry is malformed.".to_string(),
        );
    };
    match entry.get("type") {
        Some(serde_json::Value::String(kind)) if kind.eq_ignore_ascii_case("oauth") => {}
        Some(serde_json::Value::String(_)) => return GitHubCopilotCredentialLoad::Absent,
        _ => {
            return GitHubCopilotCredentialLoad::Terminal(
                "OpenCode Copilot OAuth entry is malformed.".to_string(),
            );
        }
    }

    let mut token = None;
    let mut saw_token_field = false;
    for key in ["refresh", "access"] {
        match entry.get(key) {
            None => {}
            Some(serde_json::Value::Null) => saw_token_field = true,
            Some(serde_json::Value::String(value)) if value.trim().is_empty() => {
                saw_token_field = true;
            }
            Some(serde_json::Value::String(value)) if token.is_none() => {
                saw_token_field = true;
                token = Some(value.trim().to_string());
            }
            Some(serde_json::Value::String(_)) => saw_token_field = true,
            Some(_) => {
                return GitHubCopilotCredentialLoad::Terminal(
                    "OpenCode Copilot OAuth entry is malformed.".to_string(),
                );
            }
        }
    }
    let Some(token) = token else {
        return if saw_token_field {
            GitHubCopilotCredentialLoad::Absent
        } else {
            GitHubCopilotCredentialLoad::Terminal(
                "OpenCode Copilot OAuth entry is malformed.".to_string(),
            )
        };
    };
    let canonical_location =
        match crate::agent_account_scope::canonical_file_location(path, Some("github-copilot")) {
            Ok(location) => location,
            Err(_) => {
                return GitHubCopilotCredentialLoad::Terminal(
                    "OpenCode Copilot auth location could not be verified.".to_string(),
                );
            }
        };
    GitHubCopilotCredentialLoad::Present(GitHubCopilotCredential {
        request_token: token.clone(),
        marker: token.into_bytes(),
        semantic_source: "opencode-auth-json",
        canonical_location,
    })
}

pub(crate) struct OpenCodeGoCredential {
    pub(crate) request_token: String,
    pub(crate) marker: Vec<u8>,
    pub(crate) semantic_source: &'static str,
    pub(crate) canonical_location: String,
}

pub(crate) enum OpenCodeGoCredentialLoad {
    Absent,
    Present(OpenCodeGoCredential),
    Terminal(String),
}

/// Load the OpenCode Go API key. The Go plan is stored as the `opencode-go`
/// entry with `type: "api"` and a `key`. A missing file/entry, a non-`api`
/// entry, or an empty key is `Absent`; storage, syntax, canonicalization, or a
/// present malformed entry is `Terminal` and must not be hidden as signed-out.
/// This mirrors mana.bar's `OpenCodeGoProvider.loadApiKey`, minus the env-var
/// key override, which TokenBar does not use.
pub(crate) fn opencode_go_credential() -> OpenCodeGoCredentialLoad {
    let Some(path) = auth_path() else {
        return OpenCodeGoCredentialLoad::Terminal(
            "OpenCode auth location could not be resolved.".to_string(),
        );
    };
    opencode_go_credential_at(&path)
}

fn opencode_go_credential_at(path: &std::path::Path) -> OpenCodeGoCredentialLoad {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return OpenCodeGoCredentialLoad::Absent;
        }
        Err(_) => {
            return OpenCodeGoCredentialLoad::Terminal(
                "OpenCode auth file could not be read.".to_string(),
            );
        }
    };
    let json = match serde_json::from_str::<serde_json::Value>(&raw) {
        Ok(json) => json,
        Err(_) => {
            return OpenCodeGoCredentialLoad::Terminal(
                "OpenCode auth file could not be decoded.".to_string(),
            );
        }
    };
    opencode_go_credential_from(path, &json)
}

fn opencode_go_credential_from(
    path: &std::path::Path,
    json: &serde_json::Value,
) -> OpenCodeGoCredentialLoad {
    let Some(entry) = json.get("opencode-go") else {
        return OpenCodeGoCredentialLoad::Absent;
    };
    let Some(entry) = entry.as_object() else {
        return OpenCodeGoCredentialLoad::Terminal(
            "OpenCode Go auth entry is malformed.".to_string(),
        );
    };
    match entry.get("type") {
        Some(serde_json::Value::String(kind)) if kind.eq_ignore_ascii_case("api") => {}
        Some(serde_json::Value::String(_)) => return OpenCodeGoCredentialLoad::Absent,
        _ => {
            return OpenCodeGoCredentialLoad::Terminal(
                "OpenCode Go auth entry is malformed.".to_string(),
            );
        }
    }
    let key = match entry.get("key") {
        Some(serde_json::Value::String(value)) => value.trim().to_string(),
        None | Some(serde_json::Value::Null) => return OpenCodeGoCredentialLoad::Absent,
        Some(_) => {
            return OpenCodeGoCredentialLoad::Terminal(
                "OpenCode Go auth entry is malformed.".to_string(),
            );
        }
    };
    if key.is_empty() {
        return OpenCodeGoCredentialLoad::Absent;
    }
    let canonical_location =
        match crate::agent_account_scope::canonical_file_location(path, Some("opencode-go")) {
            Ok(location) => location,
            Err(_) => {
                return OpenCodeGoCredentialLoad::Terminal(
                    "OpenCode Go auth location could not be verified.".to_string(),
                );
            }
        };
    OpenCodeGoCredentialLoad::Present(OpenCodeGoCredential {
        request_token: key.clone(),
        marker: key.into_bytes(),
        semantic_source: "opencode-auth-json",
        canonical_location,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opencode_go_key_present_absent_and_terminal() {
        let path = std::env::temp_dir().join("fixture-opencode-auth.json");
        // Present: an api entry with a non-empty key.
        let present = serde_json::json!({
            "opencode-go": { "type": "api", "key": "  sk-go-secret  " }
        });
        match opencode_go_credential_from(&path, &present) {
            OpenCodeGoCredentialLoad::Present(credential) => {
                assert_eq!(credential.request_token, "sk-go-secret");
                assert_eq!(credential.marker, b"sk-go-secret");
                assert_eq!(credential.semantic_source, "opencode-auth-json");
            }
            _ => panic!("expected present credential"),
        }
        // Absent: missing entry, non-api type, or empty/absent key.
        for json in [
            serde_json::json!({}),
            serde_json::json!({ "opencode-go": { "type": "oauth", "key": "x" } }),
            serde_json::json!({ "opencode-go": { "type": "api", "key": "  " } }),
            serde_json::json!({ "opencode-go": { "type": "api" } }),
        ] {
            assert!(matches!(
                opencode_go_credential_from(&path, &json),
                OpenCodeGoCredentialLoad::Absent
            ));
        }
        // Terminal: a present but malformed entry.
        for json in [
            serde_json::json!({ "opencode-go": "api" }),
            serde_json::json!({ "opencode-go": { "type": "api", "key": 42 } }),
            serde_json::json!({ "opencode-go": { "key": "x" } }),
        ] {
            assert!(matches!(
                opencode_go_credential_from(&path, &json),
                OpenCodeGoCredentialLoad::Terminal(_)
            ));
        }
    }

    #[test]
    fn opencode_go_file_loader_treats_missing_as_absent_and_io_or_json_as_terminal() {
        // Mirrors the Copilot file-loader matrix: a missing file is a signed-out
        // Absent, while an unreadable path (a directory) or undecodable content
        // is Terminal and must not be hidden as signed-out.
        let root = std::env::temp_dir().join(format!(
            "tokenbar-opencode-go-loader-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        assert!(matches!(
            opencode_go_credential_at(&root.join("missing.json")),
            OpenCodeGoCredentialLoad::Absent
        ));
        assert!(matches!(
            opencode_go_credential_at(&root),
            OpenCodeGoCredentialLoad::Terminal(_)
        ));

        let invalid = root.join("invalid.json");
        std::fs::write(&invalid, "not json").unwrap();
        assert!(matches!(
            opencode_go_credential_at(&invalid),
            OpenCodeGoCredentialLoad::Terminal(_)
        ));

        let present = root.join("present.json");
        std::fs::write(&present, r#"{"opencode-go":{"type":"api","key":"sk-go"}}"#).unwrap();
        assert!(matches!(
            opencode_go_credential_at(&present),
            OpenCodeGoCredentialLoad::Present(_)
        ));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn labels_oauth_providers_only() {
        assert_eq!(subscription_label("openai"), "Codex");
        assert_eq!(subscription_label("github-copilot"), "Copilot");
        assert_eq!(subscription_label("anthropic"), "Claude");
        assert_eq!(
            subscription_label("minimax-coding-plan"),
            "Minimax-coding-plan"
        );
    }

    #[test]
    fn auth_path_uses_nonempty_xdg_data_root() {
        assert_eq!(
            auth_path_from(Ok("configured-xdg-data".to_string()), None),
            Some(PathBuf::from("configured-xdg-data/opencode/auth.json"))
        );
    }

    #[test]
    fn auth_path_preserves_whitespace_only_xdg_data_root() {
        assert_eq!(
            auth_path_from(Ok("   ".to_string()), None),
            Some(PathBuf::from("   /opencode/auth.json"))
        );
    }

    #[test]
    fn auth_path_falls_back_for_empty_xdg_data_root() {
        let home = PathBuf::from("resolved-home");
        assert_eq!(
            auth_path_from(Ok(String::new()), Some(&home)),
            Some(PathBuf::from(
                "resolved-home/.local/share/opencode/auth.json"
            ))
        );
    }

    #[test]
    fn auth_path_falls_back_on_environment_errors() {
        let home = PathBuf::from("resolved-home");
        let fallback = Some(PathBuf::from(
            "resolved-home/.local/share/opencode/auth.json",
        ));
        for error in [
            std::env::VarError::NotPresent,
            std::env::VarError::NotUnicode(std::ffi::OsString::new()),
        ] {
            assert_eq!(auth_path_from(Err(error), Some(&home)), fallback);
        }
    }

    #[test]
    fn copilot_lineage_marker_uses_first_valid_refresh_or_access() {
        let path = std::env::temp_dir().join("fixture-opencode-auth.json");
        let cases = [
            (
                "refresh preferred",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": " refresh-marker ",
                        "access": "access-marker"
                    }
                }),
                Some("refresh-marker"),
            ),
            (
                "refresh missing",
                serde_json::json!({
                    "github-copilot": { "type": "oauth", "access": " access-marker " }
                }),
                Some("access-marker"),
            ),
            (
                "refresh null",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": null,
                        "access": "access-marker"
                    }
                }),
                Some("access-marker"),
            ),
            (
                "refresh empty",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": "",
                        "access": "access-marker"
                    }
                }),
                Some("access-marker"),
            ),
            (
                "refresh whitespace",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": " \t\n ",
                        "access": "access-marker"
                    }
                }),
                Some("access-marker"),
            ),
            (
                "refresh non-string",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": { "unexpected": true },
                        "access": "access-marker"
                    }
                }),
                None,
            ),
            (
                "both invalid",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": false,
                        "access": "   "
                    }
                }),
                None,
            ),
        ];

        for (label, json, expected) in cases {
            let credential = github_copilot_credential_from(&path, &json);
            match expected {
                Some(expected) => match credential {
                    GitHubCopilotCredentialLoad::Present(credential) => {
                        assert_eq!(credential.request_token, expected, "{label}");
                        assert_eq!(credential.marker, expected.as_bytes(), "{label}");
                    }
                    GitHubCopilotCredentialLoad::Absent => panic!("{label}: unexpectedly absent"),
                    GitHubCopilotCredentialLoad::Terminal(display) => {
                        panic!("{label}: unexpectedly terminal: {display}")
                    }
                },
                None => assert!(
                    matches!(credential, GitHubCopilotCredentialLoad::Terminal(_)),
                    "{label}"
                ),
            }
        }
    }

    #[test]
    fn copilot_loader_distinguishes_absent_from_terminal_evidence() {
        let path = std::env::temp_dir().join("fixture-opencode-auth.json");
        for (label, json) in [
            ("missing entry", serde_json::json!({})),
            (
                "non-oauth entry",
                serde_json::json!({ "github-copilot": { "type": "api" } }),
            ),
            (
                "logged out entry",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": null,
                        "access": "  "
                    }
                }),
            ),
        ] {
            assert!(
                matches!(
                    github_copilot_credential_from(&path, &json),
                    GitHubCopilotCredentialLoad::Absent
                ),
                "{label}"
            );
        }

        for (label, json) in [
            (
                "non-object entry",
                serde_json::json!({ "github-copilot": "oauth" }),
            ),
            (
                "oauth entry without token fields",
                serde_json::json!({ "github-copilot": { "type": "oauth" } }),
            ),
            (
                "missing type",
                serde_json::json!({ "github-copilot": { "access": "token" } }),
            ),
            (
                "malformed token sibling",
                serde_json::json!({
                    "github-copilot": {
                        "type": "oauth",
                        "refresh": false,
                        "access": "token"
                    }
                }),
            ),
        ] {
            assert!(
                matches!(
                    github_copilot_credential_from(&path, &json),
                    GitHubCopilotCredentialLoad::Terminal(_)
                ),
                "{label}"
            );
        }
    }

    #[test]
    fn copilot_file_loader_treats_missing_as_absent_and_io_or_json_as_terminal() {
        let root =
            std::env::temp_dir().join(format!("tokenbar-copilot-loader-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        assert!(matches!(
            github_copilot_credential_at(&root.join("missing.json")),
            GitHubCopilotCredentialLoad::Absent
        ));
        assert!(matches!(
            github_copilot_credential_at(&root),
            GitHubCopilotCredentialLoad::Terminal(_)
        ));

        let invalid = root.join("invalid.json");
        std::fs::write(&invalid, "not json").unwrap();
        assert!(matches!(
            github_copilot_credential_at(&invalid),
            GitHubCopilotCredentialLoad::Terminal(_)
        ));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn copilot_loader_rejects_non_utf8_canonical_location() {
        use std::os::unix::ffi::OsStringExt;

        let path = std::path::PathBuf::from(std::ffi::OsString::from_vec(vec![0xff]));
        let json = serde_json::json!({
            "github-copilot": { "type": "oauth", "access": "token" }
        });
        assert!(matches!(
            github_copilot_credential_from(&path, &json),
            GitHubCopilotCredentialLoad::Terminal(_)
        ));
    }
}
