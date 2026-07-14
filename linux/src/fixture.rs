use std::collections::HashMap;

use chrono::{Days, Local, NaiveDate, TimeZone, Utc};

use crate::model::{
    AccountRateLimitsResponse, AccountTokenUsageResponse, CreditsSnapshot, DailyUsageBucket,
    RateLimitResetCreditsSummary, RateLimitSnapshot, RateLimitWindow, SpendControlLimitSnapshot,
    UsageSnapshot, UsageSummary,
};

pub fn usage_snapshot() -> UsageSnapshot {
    // Keep visual fixtures byte-stable across runs. The presentation layer uses
    // `fetched_at` as its clock while rendering fixtures, so relative labels and
    // reset countdowns are deterministic too.
    let now = Utc
        .with_ymd_and_hms(2026, 7, 13, 19, 0, 0)
        .single()
        .expect("fixture instant must be valid")
        .with_timezone(&Local);
    let today = NaiveDate::from_ymd_opt(2026, 7, 13).expect("fixture date must be valid");
    let buckets: Vec<_> = (0..120)
        .filter_map(|offset| {
            let date = today.checked_sub_days(Days::new(119 - offset))?;
            let tokens = if offset.is_multiple_of(11) {
                0
            } else {
                (((offset + 3) * (offset + 17) * 71_123) % 9_000_000) as i64
            };
            Some(DailyUsageBucket {
                start_date: date.format("%Y-%m-%d").to_string(),
                tokens,
            })
        })
        .collect();
    let total = buckets.iter().map(|bucket| bucket.tokens).sum();
    let usage = AccountTokenUsageResponse {
        summary: UsageSummary {
            lifetime_tokens: Some(total),
            peak_daily_tokens: buckets.iter().map(|bucket| bucket.tokens).max(),
            longest_running_turn_sec: Some(5_400),
            current_streak_days: Some(8),
            longest_streak_days: Some(21),
        },
        daily_usage_buckets: Some(buckets),
    };
    let limit = RateLimitSnapshot {
        limit_id: Some("codex".into()),
        limit_name: Some("Codex".into()),
        primary: Some(RateLimitWindow {
            used_percent: 64.0,
            window_duration_mins: Some(300),
            resets_at: Some((now + chrono::Duration::hours(1)).timestamp() as f64),
        }),
        secondary: Some(RateLimitWindow {
            used_percent: 31.5,
            window_duration_mins: Some(10_080),
            resets_at: Some((now + chrono::Duration::days(1)).timestamp() as f64),
        }),
        credits: Some(CreditsSnapshot {
            has_credits: None,
            unlimited: None,
            balance: None,
            remaining: Some(14.0),
            total: Some(20.0),
            used: Some(6.0),
            decoding_issues: Vec::new(),
        }),
        individual_limit: Some(SpendControlLimitSnapshot {
            limit: Some("100.00".into()),
            used: Some("37.00".into()),
            remaining_percent: Some(63),
            used_percent: Some(37.0),
            resets_at: Some((now + chrono::Duration::hours(2)).timestamp() as f64),
            decoding_issues: Vec::new(),
        }),
        plan_type: Some("pro".into()),
        rate_limit_reached_type: Some("weekly".into()),
        decoding_issues: Vec::new(),
    };
    let rate_limits = AccountRateLimitsResponse {
        rate_limits: Some(limit.clone()),
        rate_limits_by_limit_id: Some(HashMap::from([("codex".into(), limit)])),
        rate_limit_reset_credits: Some(RateLimitResetCreditsSummary { available_count: 2 }),
        decoding_issues: Vec::new(),
    };
    UsageSnapshot {
        fetched_at: now,
        usage,
        rate_limits: Some(rate_limits),
    }
}

pub fn maximum_usage_snapshot() -> UsageSnapshot {
    let mut snapshot = usage_snapshot();
    let date = snapshot
        .usage
        .daily_usage_buckets
        .as_ref()
        .and_then(|buckets| buckets.last())
        .map(|bucket| bucket.start_date.clone())
        .unwrap_or_else(|| "2026-07-13".into());
    snapshot.usage.daily_usage_buckets = Some(vec![DailyUsageBucket {
        start_date: date,
        tokens: i64::MAX,
    }]);
    snapshot.usage.summary.lifetime_tokens = Some(i64::MAX);
    snapshot.usage.summary.peak_daily_tokens = Some(i64::MAX);
    snapshot
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maximum_fixture_contains_one_exact_supported_value() {
        let snapshot = maximum_usage_snapshot();
        assert_eq!(snapshot.buckets().len(), 1);
        assert_eq!(snapshot.buckets()[0].tokens, i64::MAX);
        assert_eq!(snapshot.usage.summary.lifetime_tokens, Some(i64::MAX));
        assert_eq!(snapshot.usage.summary.peak_daily_tokens, Some(i64::MAX));
    }
}
