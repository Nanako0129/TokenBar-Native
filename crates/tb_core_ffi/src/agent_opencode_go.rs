//! OpenCode Go subscription quota — ported from mana.bar's `OpenCodeGoProvider`.
//!
//! The OpenCode Go plan exposes a subscription quota at `/zen/go/v1/usage`,
//! reporting a rolling, weekly, and monthly window as used-percent snapshots
//! with a reset time. We authenticate with the API key OpenCode stored for its
//! "opencode-go" login (`~/.local/share/opencode/auth.json`, `type: "api"`), so
//! the card appears whenever the Go plan is signed in there. Each window maps to
//! one `UsageWindow`.
//!
//! Two contracts this file honors, both stricter than mana.bar's original:
//!
//! - **Out-of-range is invalid, not clamped.** `provider-quota-pace.md` classes
//!   a non-finite or out-of-bounds percentage as `invalid`: it must not be
//!   recorded. mana.bar clamps `140` to `100`; TokenBar drops the window instead
//!   so a malformed reading never becomes a plausible `100%` card.
//! - **Sibling isolation.** Each of the three windows is decoded independently
//!   (like `agent_copilot.rs`), so a wrong-typed percent or an object-valued
//!   `resetsAt` in one window drops only that window and never discards the
//!   valid siblings or fails the whole response.
//!
//! Windows carry no duration evidence: the endpoint reports only a percent and a
//! reset time, so the pace lifecycle learns the duration (learning-duration).

use crate::agent_account_scope::{self, AccountScope, AccountScopeError};
use crate::agent_usage::{
    parse_datetime, provider_http_client_builder, read_response_body,
    request_after_verified_binding, AgentIdentity, ProviderCacheBinding, ProviderFetchFailure,
    ResponseReadFailure, TransportErrorFacts, TransportPhase, UsageWindow,
};
use crate::opencode_integrations::OpenCodeGoCredential;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer};
use serde_json::{value::RawValue, Value};

const USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";

pub(crate) struct OpenCodeGoData {
    pub identity: Option<AgentIdentity>,
    pub account_scope: Result<AccountScope, AccountScopeError>,
    pub cache_binding: ProviderCacheBinding,
    pub windows: Vec<UsageWindow>,
}

#[derive(Debug, Deserialize)]
struct UsageResponse {
    #[serde(default)]
    usage: UsageWindows,
}

/// Each window is kept as a raw fragment so one malformed window cannot fail the
/// decode of its siblings. A window that is present but not an object, or whose
/// fields are wrong-typed, drops in `map_window`.
#[derive(Debug, Default, Deserialize)]
struct UsageWindows {
    #[serde(default)]
    rolling: Option<Box<RawValue>>,
    #[serde(default)]
    weekly: Option<Box<RawValue>>,
    #[serde(default)]
    monthly: Option<Box<RawValue>>,
}

#[derive(Debug, Deserialize)]
struct Window {
    #[serde(default)]
    percent: Option<f64>,
    // A non-string `resetsAt` (null, object, array) becomes `None` rather than
    // failing the row, matching `agent_copilot.rs`'s `quota_reset_date` handling.
    #[serde(
        default,
        rename = "resetsAt",
        deserialize_with = "deserialize_optional_string"
    )]
    resets_at: Option<String>,
}

fn deserialize_optional_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(
        Option::<Value>::deserialize(deserializer)?.and_then(|value| match value {
            Value::String(value) => Some(value),
            _ => None,
        }),
    )
}

pub(crate) async fn fetch(
    now: DateTime<Utc>,
    credential: OpenCodeGoCredential,
) -> Result<OpenCodeGoData, ProviderFetchFailure> {
    let verified = agent_account_scope::resolve_credential(
        "opencode",
        credential.semantic_source,
        &credential.canonical_location,
        &credential.marker,
    )
    .map(|account_scope| {
        let cache_binding = ProviderCacheBinding::primary(account_scope.clone());
        (account_scope, cache_binding)
    })
    .map_err(|_| {
        ProviderFetchFailure::terminal("OpenCode Go account identity could not be verified.")
    });
    let (account_scope, cache_binding, response) =
        request_after_verified_binding(verified, |(account_scope, cache_binding)| async move {
            let client = provider_http_client_builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .map_err(|_| {
                    ProviderFetchFailure::terminal("OpenCode Go usage client could not be created.")
                })?;
            let response = client
                .get(USAGE_URL)
                .header(
                    reqwest::header::AUTHORIZATION,
                    format!("Bearer {}", credential.request_token),
                )
                .header(reqwest::header::ACCEPT, "application/json")
                .send()
                .await
                .map_err(|error| {
                    ProviderFetchFailure::from_send_error(
                        "OpenCode Go usage request failed. Retrying automatically.",
                        Some(cache_binding.clone()),
                        &error,
                    )
                })?;
            Ok((account_scope, cache_binding, response))
        })
        .await?;
    let status = response.status().as_u16();
    let body = read_response_body(status, false, || async {
        response.text().await.map_err(|error| {
            TransportErrorFacts::from_reqwest(&error, TransportPhase::ResponseBody)
        })
    })
    .await
    .map_err(|failure| match failure {
        ResponseReadFailure::Transient(diagnostic) => ProviderFetchFailure::transient(
            "OpenCode Go usage request failed. Retrying automatically.",
            Some(cache_binding.clone()),
            diagnostic,
        ),
        ResponseReadFailure::Terminal(401 | 403) => {
            ProviderFetchFailure::terminal("OpenCode Go API key expired or lacks access.")
        }
        ResponseReadFailure::Terminal(status) => ProviderFetchFailure::terminal(format!(
            "OpenCode Go usage API rejected the request (status {status})."
        )),
    })?;
    let windows = decode_usage_response(&body, now)?;
    Ok(OpenCodeGoData {
        identity: Some(AgentIdentity {
            email: None,
            plan: Some("Go".to_string()),
        }),
        account_scope: Ok(account_scope),
        cache_binding,
        windows,
    })
}

pub(crate) fn decode_usage_response(
    body: &str,
    now: DateTime<Utc>,
) -> Result<Vec<UsageWindow>, ProviderFetchFailure> {
    let response: UsageResponse = serde_json::from_str(body).map_err(|_| {
        ProviderFetchFailure::terminal("OpenCode Go usage response could not be decoded.")
    })?;
    let windows = map_windows(&response.usage, now);
    if windows.is_empty() {
        // A 200 with no usable window is more likely a malformed payload than
        // real "zero usage"; do not present a healthy 0% card for it.
        return Err(ProviderFetchFailure::terminal(
            "OpenCode Go usage API returned no usable quota windows.",
        ));
    }
    Ok(windows)
}

/// Order matches mana.bar: shortest window first (rolling, weekly, monthly).
fn map_windows(usage: &UsageWindows, now: DateTime<Utc>) -> Vec<UsageWindow> {
    let mut windows = Vec::new();
    for (raw, label, card_id) in [
        (&usage.rolling, "Rolling", "rolling.v1"),
        (&usage.weekly, "Weekly", "weekly.v1"),
        (&usage.monthly, "Monthly", "monthly.v1"),
    ] {
        if let Some(window) = map_window(raw.as_deref(), label, card_id, now) {
            windows.push(window);
        }
    }
    windows
}

fn map_window(
    raw: Option<&RawValue>,
    label: &str,
    card_id: &str,
    now: DateTime<Utc>,
) -> Option<UsageWindow> {
    // Decode this window alone: a wrong-typed field drops only this window.
    let window: Window = serde_json::from_str(raw?.get()).ok()?;
    let percent = window.percent?;
    let resets_at = window.resets_at.as_deref().and_then(parse_datetime);
    // An expired reset (in the past) is invalid evidence, like a non-finite or
    // out-of-range percent (provider-quota-pace.md). Drop the window rather than
    // emit a stale card the pace layer marks unavailable and that would then
    // overwrite a previously good last-good reading. An absent or unparseable
    // reset stays `None` (learning duration) and keeps the window.
    if resets_at.is_some_and(|reset| reset <= now) {
        return None;
    }
    // Drop a non-finite or out-of-range percentage rather than clamp it: an
    // out-of-bounds reading is `invalid` (provider-quota-pace.md), not `100%`.
    UsageWindow::try_from_provider_used_percent(label.to_string(), percent, resets_at, now)
        .map(|window| window.with_identity(card_id, Some(card_id.to_string()), None, None))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_751_328_000, 0).single().unwrap()
    }

    #[test]
    fn maps_three_windows_in_shortest_first_order() {
        let body = r#"{
            "usage": {
                "rolling": {"status": "ok", "percent": 47.4, "resetsAt": "2026-09-02T18:00:00Z"},
                "weekly":  {"status": "ok", "percent": 63.0, "resetsAt": "2026-09-08T00:00:00Z"},
                "monthly": {"status": "ok", "percent": 28.0, "resetsAt": "2026-10-01T00:00:00Z"}
            }
        }"#;
        let windows = decode_usage_response(body, now()).unwrap();
        let labels: Vec<_> = windows.iter().map(|w| w.label_for_test()).collect();
        assert_eq!(labels, ["Rolling", "Weekly", "Monthly"]);
        // Used 47.4 -> remaining ~52.6.
        assert!((windows[0].remaining_for_test() - 52.6).abs() < 0.51);
        assert_eq!(windows[0].pace_window_key_for_test(), Some("rolling.v1"));
        assert_eq!(
            windows[0].resets_at_for_test(),
            Some("2026-09-02T18:00:00.000Z")
        );
        // No duration evidence -> pace learns the duration.
        assert_eq!(windows[0].window_minutes_for_test(), None);
    }

    #[test]
    fn drops_out_of_range_and_non_finite_percent_but_keeps_valid_siblings() {
        // Over 100, under 0, and null all drop; the weekly window survives.
        let body = r#"{
            "usage": {
                "rolling": {"percent": 140.0, "resetsAt": "2026-09-02T18:00:00Z"},
                "weekly":  {"percent": 63.0},
                "monthly": {"percent": -5.0}
            }
        }"#;
        let windows = decode_usage_response(body, now()).unwrap();
        let labels: Vec<_> = windows.iter().map(|w| w.label_for_test()).collect();
        assert_eq!(labels, ["Weekly"], "out-of-range windows drop, not clamp");
        assert!((windows[0].remaining_for_test() - 37.0).abs() < 0.01);
    }

    #[test]
    fn one_malformed_window_does_not_poison_valid_siblings() {
        // rolling: percent is a string -> that row fails and drops.
        // weekly: object-valued resetsAt -> reset drops to None, row survives.
        // monthly: overflowing number -> non-finite, drops.
        let body = r#"{
            "usage": {
                "rolling": {"percent": "oops", "resetsAt": "2026-09-02T18:00:00Z"},
                "weekly":  {"percent": 63.0, "resetsAt": {"unexpected": true}},
                "monthly": {"percent": 1e400}
            }
        }"#;
        let windows = decode_usage_response(body, now()).unwrap();
        let labels: Vec<_> = windows.iter().map(|w| w.label_for_test()).collect();
        assert_eq!(labels, ["Weekly"]);
        assert!((windows[0].remaining_for_test() - 37.0).abs() < 0.01);
        // The object resetsAt was dropped, not carried, and nothing leaked.
        assert_eq!(windows[0].resets_at_for_test(), None);
        assert!(!serde_json::to_string(&windows[0])
            .unwrap()
            .contains("unexpected"));
    }

    #[test]
    fn expired_reset_drops_the_window_but_keeps_valid_siblings() {
        // now() is 2025-07-01. rolling resets in the past (expired -> invalid,
        // dropped); weekly resets in the future (kept); monthly has no reset
        // (learning duration, kept).
        let body = r#"{
            "usage": {
                "rolling": {"percent": 47.0, "resetsAt": "2025-06-01T00:00:00Z"},
                "weekly":  {"percent": 63.0, "resetsAt": "2025-08-01T00:00:00Z"},
                "monthly": {"percent": 28.0}
            }
        }"#;
        let windows = decode_usage_response(body, now()).unwrap();
        let labels: Vec<_> = windows.iter().map(|w| w.label_for_test()).collect();
        assert_eq!(labels, ["Weekly", "Monthly"], "expired-reset rolling drops");
        assert_eq!(windows[1].resets_at_for_test(), None);
    }

    #[test]
    fn empty_or_all_invalid_usage_is_terminal() {
        for body in [
            r#"{"usage": {}}"#,
            r#"{"usage": {"rolling": {"percent": 200.0}, "weekly": {"percent": null}}}"#,
        ] {
            assert!(
                matches!(
                    decode_usage_response(body, now()),
                    Err(ProviderFetchFailure::Terminal { .. })
                ),
                "{body}"
            );
        }
    }
}
