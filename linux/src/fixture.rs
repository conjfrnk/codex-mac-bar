use std::collections::HashMap;

use chrono::{Days, Local};

use crate::model::{
    AccountRateLimitsResponse, AccountTokenUsageResponse, CreditsSnapshot, DailyUsageBucket,
    RateLimitResetCreditsSummary, RateLimitSnapshot, RateLimitWindow, UsageSnapshot, UsageSummary,
};

pub fn usage_snapshot() -> UsageSnapshot {
    let now = Local::now();
    let today = now.date_naive();
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
            remaining: Some(14.0),
            total: Some(20.0),
            used: Some(6.0),
        }),
        individual_limit: None,
        plan_type: Some("pro".into()),
        rate_limit_reached_type: None,
    };
    let rate_limits = AccountRateLimitsResponse {
        rate_limits: Some(limit.clone()),
        rate_limits_by_limit_id: Some(HashMap::from([("codex".into(), limit)])),
        rate_limit_reset_credits: Some(RateLimitResetCreditsSummary { available_count: 2 }),
    };
    UsageSnapshot {
        fetched_at: now,
        usage,
        rate_limits: Some(rate_limits),
    }
}
