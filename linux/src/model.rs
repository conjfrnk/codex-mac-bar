// Keep the complete app-server payload shape even when the current UI only presents a subset.
#![allow(dead_code)]

use std::collections::HashMap;

use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DailyUsageBucket {
    pub start_date: String,
    pub tokens: i64,
}

impl<'de> Deserialize<'de> for DailyUsageBucket {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RawBucket {
            start_date: String,
            #[serde(deserialize_with = "deserialize_nonnegative_i64")]
            tokens: i64,
        }

        let raw = RawBucket::deserialize(deserializer)?;
        if !is_canonical_usage_date(&raw.start_date) {
            return Err(serde::de::Error::custom(
                "expected a canonical valid ASCII YYYY-MM-DD Gregorian date",
            ));
        }
        Ok(Self {
            start_date: raw.start_date,
            tokens: raw.tokens,
        })
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub lifetime_tokens: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub peak_daily_tokens: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub longest_running_turn_sec: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub current_streak_days: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub longest_streak_days: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountTokenUsageResponse {
    pub summary: UsageSummary,
    pub daily_usage_buckets: Option<Vec<DailyUsageBucket>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitWindow {
    #[serde(deserialize_with = "deserialize_finite_nonnegative_f64")]
    pub used_percent: f64,
    #[serde(default, deserialize_with = "deserialize_optional_nonnegative_i64")]
    pub window_duration_mins: Option<i64>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_finite_nonnegative_f64"
    )]
    pub resets_at: Option<f64>,
}

impl RateLimitWindow {
    pub fn reset_date(&self) -> Option<DateTime<Local>> {
        let raw = self.resets_at?;
        // Match the civil-date range used by the macOS presentation. Chrono can
        // represent much farther futures, but labels thousands of millennia long
        // are not useful and diverge from the app's other frontend.
        if !raw.is_finite() || !(0.0..=253_402_300_799.0).contains(&raw) {
            return None;
        }
        // The app-server protocol defines `resetsAt` as Unix seconds. Do not
        // guess milliseconds from magnitude: doing so can turn an invalid or
        // far-future value into a plausible but incorrect reset date.
        let seconds = raw.floor();
        if seconds >= i64::MAX as f64 {
            return None;
        }
        let mut whole_seconds = seconds as i64;
        let mut nanoseconds = ((raw - seconds) * 1_000_000_000.0).round() as u32;
        if nanoseconds == 1_000_000_000 {
            whole_seconds = whole_seconds.checked_add(1)?;
            nanoseconds = 0;
        }
        DateTime::<Utc>::from_timestamp(whole_seconds, nanoseconds)
            .map(|date| date.with_timezone(&Local))
    }
}

#[derive(Clone, Debug, Default)]
pub struct CreditsSnapshot {
    /// Current app-server fields.
    pub has_credits: Option<bool>,
    pub unlimited: Option<bool>,
    pub balance: Option<String>,
    /// Legacy fields retained for older Codex CLI payloads.
    pub remaining: Option<f64>,
    pub total: Option<f64>,
    pub used: Option<f64>,
    /// Malformed optional fields are omitted independently and recorded here.
    pub decoding_issues: Vec<String>,
}

impl<'de> Deserialize<'de> for CreditsSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let fields = deserialize_json_object(deserializer)?;
        let mut issues = Vec::new();
        Ok(Self {
            has_credits: decode_lossy_field(&fields, "hasCredits", &mut issues),
            unlimited: decode_lossy_field(&fields, "unlimited", &mut issues),
            balance: decode_lossy_field(&fields, "balance", &mut issues),
            remaining: decode_lossy_finite_nonnegative_f64_field(&fields, "remaining", &mut issues),
            total: decode_lossy_finite_nonnegative_f64_field(&fields, "total", &mut issues),
            used: decode_lossy_finite_nonnegative_f64_field(&fields, "used", &mut issues),
            decoding_issues: issues,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct SpendControlLimitSnapshot {
    /// Current app-server fields.
    pub limit: Option<String>,
    pub used: Option<String>,
    pub remaining_percent: Option<i32>,
    /// Current values are derived from `remainingPercent`; this field also
    /// accepts the historical `usedPercent` shape.
    pub used_percent: Option<f64>,
    pub resets_at: Option<f64>,
    /// Malformed optional fields are omitted independently and recorded here.
    pub decoding_issues: Vec<String>,
}

impl<'de> Deserialize<'de> for SpendControlLimitSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let fields = deserialize_json_object(deserializer)?;
        let mut issues = Vec::new();
        let limit = decode_lossy_field(&fields, "limit", &mut issues);
        let used = decode_lossy_field(&fields, "used", &mut issues);
        let remaining_percent =
            decode_lossy_remaining_percent_field(&fields, "remainingPercent", &mut issues);
        let legacy_used_percent =
            decode_lossy_finite_nonnegative_f64_field(&fields, "usedPercent", &mut issues);
        let used_percent = remaining_percent
            .map(|value| 100.0 - f64::from(value))
            .or(legacy_used_percent);
        let resets_at = decode_lossy_finite_nonnegative_f64_field(&fields, "resetsAt", &mut issues);
        Ok(Self {
            limit,
            used,
            remaining_percent,
            used_percent,
            resets_at,
            decoding_issues: issues,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct RateLimitSnapshot {
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    pub primary: Option<RateLimitWindow>,
    pub secondary: Option<RateLimitWindow>,
    pub credits: Option<CreditsSnapshot>,
    pub individual_limit: Option<SpendControlLimitSnapshot>,
    pub plan_type: Option<String>,
    pub rate_limit_reached_type: Option<String>,
    /// Malformed optional fields are omitted independently and recorded here.
    pub decoding_issues: Vec<String>,
}

impl<'de> Deserialize<'de> for RateLimitSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let fields = deserialize_json_object(deserializer)?;
        let mut issues = Vec::new();
        let limit_id = decode_lossy_field(&fields, "limitId", &mut issues);
        let limit_name = decode_lossy_field(&fields, "limitName", &mut issues);
        let primary = decode_lossy_field(&fields, "primary", &mut issues);
        let secondary = decode_lossy_field(&fields, "secondary", &mut issues);
        let credits: Option<CreditsSnapshot> = decode_lossy_field(&fields, "credits", &mut issues);
        let individual_limit: Option<SpendControlLimitSnapshot> =
            decode_lossy_field(&fields, "individualLimit", &mut issues);
        let plan_type = decode_lossy_field(&fields, "planType", &mut issues);
        let rate_limit_reached_type =
            decode_lossy_field(&fields, "rateLimitReachedType", &mut issues);
        if let Some(credits) = credits.as_ref() {
            issues.extend(
                credits
                    .decoding_issues
                    .iter()
                    .map(|issue| format!("credits.{issue}")),
            );
        }
        if let Some(individual_limit) = individual_limit.as_ref() {
            issues.extend(
                individual_limit
                    .decoding_issues
                    .iter()
                    .map(|issue| format!("individualLimit.{issue}")),
            );
        }
        Ok(Self {
            limit_id,
            limit_name,
            primary,
            secondary,
            credits,
            individual_limit,
            plan_type,
            rate_limit_reached_type,
            decoding_issues: issues,
        })
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitResetCreditsSummary {
    #[serde(deserialize_with = "deserialize_nonnegative_i64")]
    pub available_count: i64,
}

#[derive(Clone, Debug, Default)]
pub struct AccountRateLimitsResponse {
    pub rate_limits: Option<RateLimitSnapshot>,
    pub rate_limits_by_limit_id: Option<HashMap<String, RateLimitSnapshot>>,
    pub rate_limit_reset_credits: Option<RateLimitResetCreditsSummary>,
    /// Fully qualified paths of malformed optional fields that were omitted.
    pub decoding_issues: Vec<String>,
}

impl<'de> Deserialize<'de> for AccountRateLimitsResponse {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let fields = deserialize_json_object(deserializer)?;
        let mut issues = Vec::new();
        let rate_limits: Option<RateLimitSnapshot> =
            decode_lossy_field(&fields, "rateLimits", &mut issues);
        let rate_limits_by_limit_id =
            decode_lossy_rate_limit_map_field(&fields, "rateLimitsByLimitId", &mut issues);
        let rate_limit_reset_credits =
            decode_lossy_field(&fields, "rateLimitResetCredits", &mut issues);

        if let Some(rate_limits) = rate_limits.as_ref() {
            issues.extend(
                rate_limits
                    .decoding_issues
                    .iter()
                    .map(|issue| format!("rateLimits.{issue}")),
            );
        }
        if let Some(limits) = rate_limits_by_limit_id.as_ref() {
            for key in sorted_keys(limits) {
                let issue_key = bounded_issue_component(key);
                issues.extend(
                    limits[key]
                        .decoding_issues
                        .iter()
                        .map(|issue| format!("rateLimitsByLimitId.{issue_key}.{issue}")),
                );
            }
        }
        Ok(Self {
            rate_limits,
            rate_limits_by_limit_id,
            rate_limit_reset_credits,
            decoding_issues: issues,
        })
    }
}

impl AccountRateLimitsResponse {
    pub fn malformed_outer_response() -> Self {
        Self {
            decoding_issues: vec!["response: malformed value".into()],
            ..Self::default()
        }
    }

    pub fn preferred_codex_limit(&self) -> Option<&RateLimitSnapshot> {
        if let Some(limit) = self
            .rate_limits_by_limit_id
            .as_ref()
            .and_then(|limits| limits.get("codex"))
        {
            return Some(limit);
        }
        if let Some(limits) = self.rate_limits_by_limit_id.as_ref() {
            for key in sorted_keys(limits) {
                if limits[key].limit_id.as_deref() == Some("codex") {
                    return Some(&limits[key]);
                }
            }
        }
        self.rate_limits.as_ref()
    }

    pub fn has_meaningful_data(&self) -> bool {
        self.rate_limit_reset_credits.is_some()
            || self
                .preferred_codex_limit()
                .is_some_and(rate_limit_snapshot_has_meaningful_data)
    }
}

fn rate_limit_snapshot_has_meaningful_data(limit: &RateLimitSnapshot) -> bool {
    let credits = limit.credits.as_ref().is_some_and(|credits| {
        credits.has_credits.is_some()
            || credits.unlimited.is_some()
            || credits
                .balance
                .as_ref()
                .is_some_and(|value| !value.trim().is_empty())
            || credits.remaining.is_some()
            || credits.total.is_some()
            || credits.used.is_some()
    });
    let individual = limit.individual_limit.as_ref().is_some_and(|individual| {
        individual
            .limit
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
            || individual
                .used
                .as_ref()
                .is_some_and(|value| !value.trim().is_empty())
            || individual.remaining_percent.is_some()
            || individual.used_percent.is_some()
            || individual.resets_at.is_some()
    });
    limit.primary.is_some()
        || limit.secondary.is_some()
        || credits
        || individual
        || limit
            .plan_type
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
        || limit
            .rate_limit_reached_type
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
}

#[derive(Clone, Debug)]
pub struct UsageSnapshot {
    pub fetched_at: DateTime<Local>,
    pub usage: AccountTokenUsageResponse,
    pub rate_limits: Option<AccountRateLimitsResponse>,
}

impl UsageSnapshot {
    /// `None` means the server did not make daily history available. This is
    /// intentionally distinct from an available-but-empty array.
    pub fn daily_buckets(&self) -> Option<&[DailyUsageBucket]> {
        self.usage.daily_usage_buckets.as_deref()
    }

    /// Compatibility accessor for call sites that intentionally treat missing
    /// daily history as an empty collection.
    pub fn buckets(&self) -> &[DailyUsageBucket] {
        self.daily_buckets().unwrap_or_default()
    }
}

pub fn is_canonical_usage_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || &bytes[..4] == b"0000"
        || bytes
            .iter()
            .enumerate()
            .any(|(index, byte)| index != 4 && index != 7 && !byte.is_ascii_digit())
    {
        return false;
    }
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .is_ok_and(|date| date.format("%Y-%m-%d").to_string() == value)
}

fn deserialize_nonnegative_i64<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    value_to_i64(&value)
        .ok_or_else(|| serde::de::Error::custom("expected a nonnegative integer-compatible value"))
}

fn deserialize_optional_nonnegative_i64<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    value
        .map(|value| {
            value_to_i64(&value).ok_or_else(|| {
                serde::de::Error::custom("expected a nonnegative integer-compatible value")
            })
        })
        .transpose()
}

fn value_to_i64(value: &serde_json::Value) -> Option<i64> {
    match value {
        // `arbitrary_precision` keeps the original JSON lexeme. Parse it as a
        // decimal value instead of going through f64, which could silently turn
        // `9007199254740992.1` into the integer `9007199254740992`.
        serde_json::Value::Number(number) => exact_nonnegative_i64(&number.to_string()),
        serde_json::Value::String(value) => value.parse().ok(),
        _ => None,
    }
    .filter(|value| *value >= 0)
}

fn exact_nonnegative_i64(raw: &str) -> Option<i64> {
    let (negative, unsigned) = raw
        .strip_prefix('-')
        .map_or((false, raw), |value| (true, value));
    let (mantissa, exponent_text) = unsigned.find(['e', 'E']).map_or((unsigned, None), |index| {
        (&unsigned[..index], Some(&unsigned[index + 1..]))
    });

    let mut digit_count = 0_usize;
    let mut fraction_digits = 0_usize;
    let mut saw_decimal = false;
    let mut saw_nonzero = false;
    let mut trailing_zeros = 0_usize;
    for byte in mantissa.bytes() {
        match byte {
            b'.' if !saw_decimal => saw_decimal = true,
            b'0'..=b'9' => {
                digit_count = digit_count.checked_add(1)?;
                if saw_decimal {
                    fraction_digits = fraction_digits.checked_add(1)?;
                }
                if byte == b'0' {
                    trailing_zeros = trailing_zeros.checked_add(1)?;
                } else {
                    saw_nonzero = true;
                    trailing_zeros = 0;
                }
            }
            _ => return None,
        }
    }
    if digit_count == 0 {
        return None;
    }
    // Negative zero and zero with an arbitrarily large exponent are both zero.
    if !saw_nonzero {
        return Some(0);
    }
    if negative {
        return None;
    }

    let exponent = exponent_text.map_or(Some(0), parse_json_exponent)?;
    let fraction_digits = i64::try_from(fraction_digits).ok()?;
    let decimal_shift = exponent.checked_sub(fraction_digits)?;
    let (kept_digits, appended_zeros) = if decimal_shift < 0 {
        let removed_digits = usize::try_from(decimal_shift.unsigned_abs()).ok()?;
        if removed_digits > trailing_zeros {
            return None;
        }
        (digit_count.checked_sub(removed_digits)?, 0_usize)
    } else {
        let appended_zeros = usize::try_from(decimal_shift).ok()?;
        // Any nonzero signed 64-bit value has at most 19 decimal digits.
        if appended_zeros > 19 {
            return None;
        }
        (digit_count, appended_zeros)
    };

    let mut parsed = 0_i64;
    let mut logical_index = 0_usize;
    for byte in mantissa.bytes().filter(u8::is_ascii_digit) {
        if logical_index >= kept_digits {
            break;
        }
        parsed = parsed
            .checked_mul(10)?
            .checked_add(i64::from(byte - b'0'))?;
        logical_index += 1;
    }
    if logical_index != kept_digits {
        return None;
    }
    for _ in 0..appended_zeros {
        parsed = parsed.checked_mul(10)?;
    }
    Some(parsed)
}

fn parse_json_exponent(raw: &str) -> Option<i64> {
    let (negative, digits) = if let Some(digits) = raw.strip_prefix('-') {
        (true, digits)
    } else {
        (false, raw.strip_prefix('+').unwrap_or(raw))
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        return Some(0);
    }
    let magnitude = significant.parse::<u64>().ok()?;
    if negative {
        if magnitude == (i64::MAX as u64) + 1 {
            Some(i64::MIN)
        } else {
            i64::try_from(magnitude).ok()?.checked_neg()
        }
    } else {
        i64::try_from(magnitude).ok()
    }
}

fn deserialize_finite_nonnegative_f64<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    value_to_f64(&value)
        .ok_or_else(|| serde::de::Error::custom("expected a finite nonnegative number"))
}

fn deserialize_optional_finite_nonnegative_f64<'de, D>(
    deserializer: D,
) -> Result<Option<f64>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    value
        .map(|value| {
            value_to_f64(&value)
                .ok_or_else(|| serde::de::Error::custom("expected a finite nonnegative number"))
        })
        .transpose()
}

fn value_to_f64(value: &serde_json::Value) -> Option<f64> {
    let value = match value {
        serde_json::Value::Number(number) => number.as_f64(),
        _ => None,
    }?;
    (value.is_finite() && value >= 0.0).then_some(value)
}

fn deserialize_json_object<'de, D>(
    deserializer: D,
) -> Result<serde_json::Map<String, serde_json::Value>, D::Error>
where
    D: Deserializer<'de>,
{
    serde_json::Map::<String, serde_json::Value>::deserialize(deserializer)
}

fn decode_lossy_field<T>(
    fields: &serde_json::Map<String, serde_json::Value>,
    key: &str,
    issues: &mut Vec<String>,
) -> Option<T>
where
    T: DeserializeOwned,
{
    let value = fields.get(key)?;
    if value.is_null() {
        return None;
    }
    match serde_json::from_value(value.clone()) {
        Ok(value) => Some(value),
        Err(_) => {
            // Keep issue metadata bounded and avoid retaining attacker-controlled
            // values that serde may quote in its detailed diagnostic.
            issues.push(format!("{key}: malformed value"));
            None
        }
    }
}

fn decode_lossy_finite_nonnegative_f64_field(
    fields: &serde_json::Map<String, serde_json::Value>,
    key: &str,
    issues: &mut Vec<String>,
) -> Option<f64> {
    let value = fields.get(key)?;
    if value.is_null() {
        return None;
    }
    if let Some(value) = value_to_f64(value) {
        return Some(value);
    }
    issues.push(format!("{key}: expected a finite nonnegative number"));
    None
}

fn decode_lossy_remaining_percent_field(
    fields: &serde_json::Map<String, serde_json::Value>,
    key: &str,
    issues: &mut Vec<String>,
) -> Option<i32> {
    let value = fields.get(key)?;
    if value.is_null() {
        return None;
    }
    if let Some(value) = value_to_i64(value).and_then(|value| i32::try_from(value).ok())
        && (0..=100).contains(&value)
    {
        return Some(value);
    }
    issues.push(format!("{key}: expected an integer from 0 through 100"));
    None
}

fn decode_lossy_rate_limit_map_field(
    fields: &serde_json::Map<String, serde_json::Value>,
    key: &str,
    issues: &mut Vec<String>,
) -> Option<HashMap<String, RateLimitSnapshot>> {
    let value = fields.get(key)?;
    if value.is_null() {
        return None;
    }
    let Some(entries) = value.as_object() else {
        issues.push(format!("{key}: expected an object"));
        return None;
    };
    let mut entry_keys: Vec<_> = entries.keys().collect();
    entry_keys.sort();
    let mut limits = HashMap::with_capacity(entries.len());
    for entry_key in entry_keys {
        match serde_json::from_value::<RateLimitSnapshot>(entries[entry_key].clone()) {
            Ok(limit) => {
                limits.insert(entry_key.clone(), limit);
            }
            Err(_) => issues.push(format!(
                "{key}.{}: malformed value",
                bounded_issue_component(entry_key)
            )),
        }
    }
    Some(limits)
}

fn bounded_issue_component(value: &str) -> String {
    let mut characters = value.chars();
    let mut result = String::with_capacity(65);
    for _ in 0..64 {
        let Some(character) = characters.next() else {
            break;
        };
        if !character.is_control()
            && !matches!(
                character,
                '\u{061c}'
                    | '\u{200b}'..='\u{200f}'
                    | '\u{202a}'..='\u{202e}'
                    | '\u{2060}'..='\u{206f}'
                    | '\u{feff}'
            )
        {
            result.push(character);
        }
    }
    if characters.next().is_some() {
        result.push('…');
    }
    if result.is_empty() {
        "<unnamed>".into()
    } else {
        result
    }
}

fn sorted_keys<T>(map: &HashMap<String, T>) -> Vec<&String> {
    let mut keys: Vec<_> = map.keys().collect();
    keys.sort();
    keys
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
        for tokens in [
            "-1",
            "1.5",
            "1e40",
            "9007199254740992.1",
            "1.000000000000000000000000000000000000001",
        ] {
            let json = format!(r#"{{"startDate":"2026-07-09","tokens":{tokens}}}"#);
            assert!(serde_json::from_str::<DailyUsageBucket>(&json).is_err());
        }
    }

    #[test]
    fn accepts_only_mathematically_integral_numeric_token_lexemes() {
        for (tokens, expected) in [
            ("1.0", 1),
            ("1e3", 1_000),
            ("1e+0000000000000000000000003", 1_000),
            ("100e-2", 1),
            ("100e-0000000000000000000000002", 1),
            ("0.0001e4", 1),
            ("9223372036854775807.0", i64::MAX),
        ] {
            let json = format!(r#"{{"startDate":"2026-07-09","tokens":{tokens}}}"#);
            let bucket: DailyUsageBucket = serde_json::from_str(&json).unwrap();
            assert_eq!(bucket.tokens, expected, "unexpected result for {tokens}");
        }
    }

    #[test]
    fn issue_components_bound_raw_inspection_and_strip_directional_controls() {
        let hostile = format!("{}safe", "\u{202e}".repeat(100_000));
        let component = bounded_issue_component(&hostile);
        assert!(component.chars().count() <= 65);
        assert!(!component.contains('\u{202e}'));
        assert!(component.ends_with('…'));
        assert_eq!(bounded_issue_component("\n\r"), "<unnamed>");
    }

    #[test]
    fn rejects_noncanonical_or_invalid_bucket_dates() {
        for date in [
            "2026-7-09",
            "2026-07-9",
            "2026-02-29",
            "0000-01-01",
            "２０２６-07-09",
        ] {
            let json = format!(r#"{{"startDate":"{date}","tokens":1}}"#);
            assert!(serde_json::from_str::<DailyUsageBucket>(&json).is_err());
        }
        assert!(
            serde_json::from_str::<DailyUsageBucket>(r#"{"startDate":"2024-02-29","tokens":1}"#)
                .is_ok()
        );
    }

    #[test]
    fn requires_summary_and_rejects_negative_summary_values() {
        assert!(
            serde_json::from_str::<AccountTokenUsageResponse>(r#"{"dailyUsageBuckets":null}"#)
                .is_err()
        );
        assert!(
            serde_json::from_str::<AccountTokenUsageResponse>(
                r#"{"summary":{"lifetimeTokens":-1},"dailyUsageBuckets":null}"#
            )
            .is_err()
        );
    }

    #[test]
    fn reset_timestamps_are_always_interpreted_as_unix_seconds() {
        let ordinary: RateLimitWindow =
            serde_json::from_str(r#"{"usedPercent":42,"resetsAt":1700000000}"#).unwrap();
        assert_eq!(ordinary.reset_date().unwrap().timestamp(), 1_700_000_000);

        let far_future_seconds: RateLimitWindow =
            serde_json::from_str(r#"{"usedPercent":42,"resetsAt":13000000000}"#).unwrap();
        assert_eq!(
            far_future_seconds.reset_date().unwrap().timestamp(),
            13_000_000_000
        );

        let beyond_civil_range: RateLimitWindow =
            serde_json::from_str(r#"{"usedPercent":42,"resetsAt":1700000000000}"#).unwrap();
        assert!(beyond_civil_range.reset_date().is_none());
    }

    #[test]
    fn rate_limit_doubles_reject_numeric_strings_like_the_macos_decoder() {
        assert!(
            serde_json::from_str::<RateLimitWindow>(
                r#"{"usedPercent":"42","resetsAt":1700000000}"#
            )
            .is_err()
        );
        let credits: CreditsSnapshot =
            serde_json::from_str(r#"{"remaining":"2","total":3}"#).unwrap();
        assert_eq!(credits.remaining, None);
        assert_eq!(credits.total, Some(3.0));
        assert!(
            credits
                .decoding_issues
                .iter()
                .any(|issue| issue.starts_with("remaining:"))
        );
        let individual: SpendControlLimitSnapshot =
            serde_json::from_str(r#"{"usedPercent":"37.5","resetsAt":"1700000000","limit":"100"}"#)
                .unwrap();
        assert_eq!(individual.used_percent, None);
        assert_eq!(individual.resets_at, None);
        assert_eq!(individual.limit.as_deref(), Some("100"));
        assert_eq!(individual.decoding_issues.len(), 2);
    }

    #[test]
    fn decodes_current_and_legacy_optional_rate_limit_shapes_lossily() {
        let limits: AccountRateLimitsResponse = serde_json::from_str(
            r#"{
                "rateLimits": {
                    "limitId":"fallback",
                    "primary":{"usedPercent":55,"windowDurationMins":300,"resetsAt":1700000000},
                    "secondary":{"usedPercent":"malformed"},
                    "credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},
                    "individualLimit":{
                        "limit":"100","used":"40","remainingPercent":60,"resetsAt":1700000000
                    }
                },
                "rateLimitsByLimitId": {
                    "bad": "malformed",
                    "codex": {
                        "limitId":"codex",
                        "credits":{"remaining":14,"total":20,"used":6}
                    }
                },
                "rateLimitResetCredits":{"availableCount":2}
            }"#,
        )
        .unwrap();

        let fallback = limits.rate_limits.as_ref().unwrap();
        assert_eq!(fallback.primary.as_ref().unwrap().used_percent, 55.0);
        assert!(fallback.secondary.is_none());
        assert_eq!(fallback.credits.as_ref().unwrap().has_credits, Some(true));
        assert_eq!(
            fallback.individual_limit.as_ref().unwrap().used_percent,
            Some(40.0)
        );
        assert!(
            !limits
                .rate_limits_by_limit_id
                .as_ref()
                .unwrap()
                .contains_key("bad")
        );
        assert_eq!(
            limits
                .preferred_codex_limit()
                .unwrap()
                .credits
                .as_ref()
                .unwrap()
                .remaining,
            Some(14.0)
        );
        assert!(
            limits
                .decoding_issues
                .iter()
                .any(|issue| issue.starts_with("rateLimits.secondary:"))
        );
        assert!(
            limits
                .decoding_issues
                .iter()
                .any(|issue| issue.starts_with("rateLimitsByLimitId.bad:"))
        );
    }

    #[test]
    fn malformed_rate_fields_preserve_valid_siblings_and_report_full_paths() {
        let limits: AccountRateLimitsResponse = serde_json::from_str(
            r#"{
                "rateLimits": {
                    "limitId":"fallback",
                    "primary":{"usedPercent":55,"windowDurationMins":-1},
                    "secondary":{"usedPercent":34,"windowDurationMins":300},
                    "credits":{
                        "hasCredits":"yes",
                        "unlimited":false,
                        "balance":"12.50",
                        "remaining":-2,
                        "total":10,
                        "used":3
                    },
                    "individualLimit":{
                        "limit":"100",
                        "used":"37",
                        "remainingPercent":63.000000000000000001,
                        "usedPercent":37.5,
                        "resetsAt":"bad"
                    },
                    "planType":9,
                    "rateLimitReachedType":"weekly"
                },
                "rateLimitsByLimitId": {
                    "bad": [],
                    "codex": {
                        "limitId":"codex",
                        "primary":{"usedPercent":42,"windowDurationMins":300},
                        "credits":{"hasCredits":true,"balance":false}
                    }
                },
                "rateLimitResetCredits":{"availableCount":9007199254740992.1}
            }"#,
        )
        .unwrap();

        let fallback = limits.rate_limits.as_ref().unwrap();
        assert!(fallback.primary.is_none());
        assert_eq!(fallback.secondary.as_ref().unwrap().used_percent, 34.0);
        let credits = fallback.credits.as_ref().unwrap();
        assert_eq!(credits.has_credits, None);
        assert_eq!(credits.unlimited, Some(false));
        assert_eq!(credits.balance.as_deref(), Some("12.50"));
        assert_eq!(credits.remaining, None);
        assert_eq!(credits.total, Some(10.0));
        assert_eq!(credits.used, Some(3.0));
        let individual = fallback.individual_limit.as_ref().unwrap();
        assert_eq!(individual.limit.as_deref(), Some("100"));
        assert_eq!(individual.used.as_deref(), Some("37"));
        assert_eq!(individual.remaining_percent, None);
        assert_eq!(individual.used_percent, Some(37.5));
        assert_eq!(individual.resets_at, None);
        assert_eq!(fallback.plan_type, None);
        assert_eq!(fallback.rate_limit_reached_type.as_deref(), Some("weekly"));
        assert!(limits.rate_limit_reset_credits.is_none());

        let mapped = limits
            .rate_limits_by_limit_id
            .as_ref()
            .unwrap()
            .get("codex")
            .unwrap();
        assert_eq!(mapped.primary.as_ref().unwrap().used_percent, 42.0);
        assert_eq!(mapped.credits.as_ref().unwrap().has_credits, Some(true));
        assert_eq!(mapped.credits.as_ref().unwrap().balance, None);
        assert!(
            !limits
                .rate_limits_by_limit_id
                .as_ref()
                .unwrap()
                .contains_key("bad")
        );

        for path in [
            "rateLimits.primary:",
            "rateLimits.credits.hasCredits:",
            "rateLimits.credits.remaining:",
            "rateLimits.individualLimit.remainingPercent:",
            "rateLimits.individualLimit.resetsAt:",
            "rateLimits.planType:",
            "rateLimitsByLimitId.bad:",
            "rateLimitsByLimitId.codex.credits.balance:",
            "rateLimitResetCredits:",
        ] {
            assert!(
                limits
                    .decoding_issues
                    .iter()
                    .any(|issue| issue.starts_with(path)),
                "missing issue path {path}: {:?}",
                limits.decoding_issues
            );
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

    #[test]
    fn malformed_outer_rate_limit_response_has_bounded_quality_metadata() {
        let limits = AccountRateLimitsResponse::malformed_outer_response();
        assert!(limits.preferred_codex_limit().is_none());
        assert!(!limits.has_meaningful_data());
        assert_eq!(limits.decoding_issues, ["response: malformed value"]);
    }

    #[test]
    fn empty_rate_limit_shapes_are_not_meaningful_availability() {
        assert!(!AccountRateLimitsResponse::default().has_meaningful_data());
        assert!(
            !AccountRateLimitsResponse {
                rate_limits: Some(RateLimitSnapshot {
                    limit_id: Some("codex".into()),
                    limit_name: Some("Codex".into()),
                    plan_type: Some("  ".into()),
                    ..RateLimitSnapshot::default()
                }),
                ..AccountRateLimitsResponse::default()
            }
            .has_meaningful_data()
        );
        assert!(
            AccountRateLimitsResponse {
                rate_limits: Some(RateLimitSnapshot {
                    primary: Some(RateLimitWindow {
                        used_percent: 0.0,
                        window_duration_mins: None,
                        resets_at: None,
                    }),
                    ..RateLimitSnapshot::default()
                }),
                ..AccountRateLimitsResponse::default()
            }
            .has_meaningful_data()
        );
        assert!(
            AccountRateLimitsResponse {
                rate_limit_reset_credits: Some(RateLimitResetCreditsSummary { available_count: 0 }),
                ..AccountRateLimitsResponse::default()
            }
            .has_meaningful_data()
        );
    }
}
