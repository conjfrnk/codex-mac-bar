// Keep the complete app-server payload shape even when the current UI only presents a subset.
#![allow(dead_code)]

use chrono::{DateTime, Local, Utc};
use serde::Deserialize;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DailyUsageBucket {
    pub start_date: String,
    #[serde(deserialize_with = "deserialize_i64")]
    pub tokens: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    pub lifetime_tokens: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    pub peak_daily_tokens: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    pub longest_running_turn_sec: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    pub current_streak_days: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_i64")]
    pub longest_streak_days: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountTokenUsageResponse {
    #[serde(default)]
    pub summary: UsageSummary,
    pub daily_usage_buckets: Option<Vec<DailyUsageBucket>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitWindow {
    pub used_percent: f64,
    pub window_duration_mins: Option<i64>,
    pub resets_at: Option<f64>,
}

impl RateLimitWindow {
    pub fn reset_date(&self) -> Option<DateTime<Local>> {
        let raw = self.resets_at?;
        if !raw.is_finite() {
            return None;
        }
        let seconds = if raw > 10_000_000_000.0 {
            raw / 1_000.0
        } else {
            raw
        };
        DateTime::<Utc>::from_timestamp(seconds as i64, 0).map(|date| date.with_timezone(&Local))
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreditsSnapshot {
    pub remaining: Option<f64>,
    pub total: Option<f64>,
    pub used: Option<f64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendControlLimitSnapshot {
    pub used_percent: Option<f64>,
    pub resets_at: Option<f64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitSnapshot {
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    pub primary: Option<RateLimitWindow>,
    pub secondary: Option<RateLimitWindow>,
    pub credits: Option<CreditsSnapshot>,
    pub individual_limit: Option<SpendControlLimitSnapshot>,
    pub plan_type: Option<String>,
    pub rate_limit_reached_type: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitResetCreditsSummary {
    #[serde(deserialize_with = "deserialize_i64")]
    pub available_count: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRateLimitsResponse {
    pub rate_limits: Option<RateLimitSnapshot>,
    pub rate_limits_by_limit_id: Option<std::collections::HashMap<String, RateLimitSnapshot>>,
    pub rate_limit_reset_credits: Option<RateLimitResetCreditsSummary>,
}

impl AccountRateLimitsResponse {
    pub fn preferred_codex_limit(&self) -> Option<&RateLimitSnapshot> {
        if let Some(limit) = self
            .rate_limits_by_limit_id
            .as_ref()
            .and_then(|limits| limits.get("codex"))
        {
            return Some(limit);
        }
        if let Some(limit) = self.rate_limits_by_limit_id.as_ref().and_then(|limits| {
            limits
                .values()
                .find(|limit| limit.limit_id.as_deref() == Some("codex"))
        }) {
            return Some(limit);
        }
        self.rate_limits.as_ref()
    }
}

#[derive(Clone, Debug)]
pub struct UsageSnapshot {
    pub fetched_at: DateTime<Local>,
    pub usage: AccountTokenUsageResponse,
    pub rate_limits: Option<AccountRateLimitsResponse>,
}

impl UsageSnapshot {
    pub fn buckets(&self) -> &[DailyUsageBucket] {
        self.usage
            .daily_usage_buckets
            .as_deref()
            .unwrap_or_default()
    }
}

fn deserialize_i64<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    value_to_i64(&value)
        .ok_or_else(|| serde::de::Error::custom("expected an integer-compatible value"))
}

fn deserialize_optional_i64<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    value
        .map(|value| {
            value_to_i64(&value)
                .ok_or_else(|| serde::de::Error::custom("expected an integer-compatible value"))
        })
        .transpose()
}

fn value_to_i64(value: &serde_json::Value) -> Option<i64> {
    match value {
        serde_json::Value::Number(number) => number.as_i64().or_else(|| {
            let value = number.as_f64()?;
            (value.is_finite()
                && value.fract() == 0.0
                && value >= i64::MIN as f64
                && value < i64::MAX as f64)
                .then_some(value as i64)
        }),
        serde_json::Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_flexible_token_counts() {
        let bucket: DailyUsageBucket =
            serde_json::from_str(r#"{"startDate":"2026-07-09","tokens":"123456789"}"#).unwrap();
        assert_eq!(bucket.tokens, 123_456_789);

        let usage: AccountTokenUsageResponse = serde_json::from_str(
            r#"{
                "summary":{"lifetimeTokens":"123456789","peakDailyTokens":456,"longestStreakDays":"5"},
                "dailyUsageBuckets":[
                    {"startDate":"2026-07-07","tokens":"1000"},
                    {"startDate":"2026-07-08","tokens":2000}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(usage.summary.lifetime_tokens, Some(123_456_789));
        assert_eq!(usage.summary.peak_daily_tokens, Some(456));
        assert_eq!(usage.summary.longest_streak_days, Some(5));
        assert_eq!(
            usage
                .daily_usage_buckets
                .unwrap()
                .iter()
                .map(|bucket| bucket.tokens)
                .collect::<Vec<_>>(),
            vec![1_000, 2_000]
        );
    }

    #[test]
    fn rejects_non_integral_and_out_of_range_token_counts() {
        for tokens in ["1.5", "1e40"] {
            let json = format!(r#"{{"startDate":"2026-07-09","tokens":{tokens}}}"#);
            assert!(serde_json::from_str::<DailyUsageBucket>(&json).is_err());
        }
    }

    #[test]
    fn prefers_named_codex_limit() {
        let limits: AccountRateLimitsResponse = serde_json::from_str(
            r#"{
                "rateLimits":{"limitId":"fallback","usedPercent":null},
                "rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"pro"}}
            }"#,
        )
        .unwrap();
        assert_eq!(
            limits.preferred_codex_limit().unwrap().plan_type.as_deref(),
            Some("pro")
        );
    }
}
