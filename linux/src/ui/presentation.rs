use chrono::{DateTime, Datelike, Local, Months, TimeZone};

use crate::model::{AccountRateLimitsResponse, CreditsSnapshot, RateLimitWindow, UsageSnapshot};
use crate::range::{Timeframe, UsageRange, format_full_tokens, reconcile_all_time_summary};
use crate::text_safety::is_unsafe_format_character;

pub(super) const RATE_TEXT_LIMIT: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct UsagePresentation {
    pub(super) total_tokens: Option<i64>,
    pub(super) average_daily_tokens: Option<i64>,
    pub(super) peak_daily_tokens: Option<i64>,
    pub(super) active_days: Option<usize>,
    pub(super) daily_history_available: bool,
    pub(super) daily_history_partial: bool,
    pub(super) has_unreconciled_all_time_total: bool,
}

impl UsagePresentation {
    pub(super) fn new(timeframe: Timeframe, range: &UsageRange, snapshot: &UsageSnapshot) -> Self {
        let daily_history_available = snapshot.daily_buckets().is_some();
        let summary = &snapshot.usage.summary;
        let totals_invalid = range.merge_did_overflow()
            || range.total_did_overflow()
            || range.rejected_bucket_count() > 0;
        let peak_invalid = range.merge_did_overflow() || range.rejected_bucket_count() > 0;
        let exact_daily_total =
            (daily_history_available && !totals_invalid).then_some(range.total_tokens());
        let exact_daily_peak =
            (daily_history_available && !peak_invalid).then_some(range.peak_daily_tokens());
        let (total_tokens, peak_daily_tokens, daily_history_partial, has_unreconciled) =
            if timeframe == Timeframe::All {
                let reconciled = reconcile_all_time_summary(
                    daily_history_available,
                    exact_daily_total,
                    exact_daily_peak,
                    summary.lifetime_tokens,
                    summary.peak_daily_tokens,
                );
                (
                    reconciled.total_tokens,
                    if peak_invalid {
                        None
                    } else {
                        reconciled.peak_daily_tokens
                    },
                    daily_history_available && (totals_invalid || reconciled.daily_history_partial),
                    !totals_invalid && reconciled.has_unreconciled_total,
                )
            } else {
                (
                    exact_daily_total,
                    exact_daily_peak,
                    daily_history_available && totals_invalid,
                    false,
                )
            };
        let complete_daily_metrics = daily_history_available && !daily_history_partial;
        Self {
            total_tokens,
            average_daily_tokens: complete_daily_metrics.then_some(range.average_daily_tokens()),
            peak_daily_tokens,
            active_days: if complete_daily_metrics {
                Some(range.active_days())
            } else {
                None
            },
            daily_history_available,
            daily_history_partial,
            has_unreconciled_all_time_total: has_unreconciled,
        }
    }
}

pub(super) fn format_percent(value: f64) -> String {
    if !value.is_finite() || value < 0.0 {
        return "n/a".into();
    }
    let value = if value == 0.0 { 0.0 } else { value };
    if value.abs() >= 1_000_000_000.0 {
        return format!("{}%", format_scientific(value, 1, false));
    }
    if value.round() == value {
        format!("{value:.0}%")
    } else {
        format!("{value:.1}%")
    }
}

pub(super) fn clamped_progress_percent(value: f64) -> f64 {
    if value.is_finite() && value >= 0.0 {
        if value == 0.0 {
            0.0
        } else {
            value.clamp(0.0, 100.0)
        }
    } else {
        0.0
    }
}

pub(super) fn format_window_duration(minutes: Option<i64>) -> String {
    let Some(minutes) = minutes.filter(|minutes| *minutes >= 0) else {
        return "n/a".into();
    };
    if minutes >= 1_440 {
        let days = minutes / 1_440;
        let hours = (minutes % 1_440) / 60;
        if hours == 0 {
            format!("{days}d")
        } else {
            format!("{days}d {hours}h")
        }
    } else if minutes >= 60 {
        let hours = minutes / 60;
        let remaining_minutes = minutes % 60;
        if remaining_minutes == 0 {
            format!("{hours}h")
        } else {
            format!("{hours}h {remaining_minutes}m")
        }
    } else {
        format!("{minutes}m")
    }
}

pub(super) fn reset_description(resets_at: Option<f64>, now: DateTime<Local>) -> String {
    let Some(reset) = (RateLimitWindow {
        used_percent: 0.0,
        window_duration_mins: None,
        resets_at,
    })
    .reset_date() else {
        return "reset unavailable".into();
    };
    let Some(delta_milliseconds) = reset.timestamp_millis().checked_sub(now.timestamp_millis())
    else {
        return "reset unavailable".into();
    };
    if delta_milliseconds.unsigned_abs() < 1_000 {
        return "resets now".into();
    }
    let relative = relative_reset_dates(&reset, &now);
    if relative == "n/a" {
        return "reset unavailable".into();
    }
    if delta_milliseconds < 0 {
        format!("reset {relative}")
    } else {
        format!("resets {relative}")
    }
}

pub(super) fn relative_reset_dates<Tz: TimeZone>(
    reset: &DateTime<Tz>,
    now: &DateTime<Tz>,
) -> String {
    let Some(delta_milliseconds) = reset.timestamp_millis().checked_sub(now.timestamp_millis())
    else {
        return "n/a".into();
    };
    let delta_seconds = delta_milliseconds as f64 / 1_000.0;
    let absolute = delta_seconds.abs();
    let (earlier, later) = if delta_milliseconds < 0 {
        (reset, now)
    } else {
        (now, reset)
    };
    let complete_months = complete_local_months(now, reset, delta_milliseconds >= 0);
    let complete_days = complete_local_days(earlier, later);
    let (amount, suffix) = if complete_months >= 12 {
        (complete_months / 12, "y")
    } else if complete_months >= 1 {
        (complete_months, "mo")
    } else if complete_days >= 7 {
        (complete_days / 7, "w")
    } else if complete_days >= 1 {
        (complete_days, "d")
    } else if absolute >= 3_600.0 {
        ((absolute / 3_600.0).floor() as u64, "h")
    } else if absolute >= 60.0 {
        ((absolute / 60.0).floor() as u64, "m")
    } else {
        (absolute.floor() as u64, "s")
    };
    if amount == 0 || delta_seconds >= 0.0 {
        format!("in {amount}{suffix}")
    } else {
        format!("{amount}{suffix} ago")
    }
}

fn complete_local_days<Tz: TimeZone>(earlier: &DateTime<Tz>, later: &DateTime<Tz>) -> u64 {
    let mut days = (later.date_naive() - earlier.date_naive())
        .num_days()
        .max(0) as u64;
    if later.time() < earlier.time() {
        days = days.saturating_sub(1);
    }
    days
}

fn complete_local_months<Tz: TimeZone>(
    origin: &DateTime<Tz>,
    target: &DateTime<Tz>,
    forward: bool,
) -> u64 {
    let origin_local = origin.naive_local();
    let target_local = target.naive_local();
    let (earlier_local, later_local) = if forward {
        (origin_local, target_local)
    } else {
        (target_local, origin_local)
    };
    let month_delta = (later_local.year() - earlier_local.year())
        .saturating_mul(12)
        .saturating_add(later_local.month() as i32 - earlier_local.month() as i32);
    let mut months = u32::try_from(month_delta.max(0)).unwrap_or(u32::MAX);
    if months == 0 {
        return 0;
    }
    let candidate = if forward {
        origin_local.checked_add_months(Months::new(months))
    } else {
        origin_local.checked_sub_months(Months::new(months))
    };
    match candidate {
        Some(candidate)
            if (forward && candidate <= target_local)
                || (!forward && candidate >= target_local) => {}
        _ => months -= 1,
    }
    u64::from(months)
}

pub(super) fn relative_age(date: DateTime<Local>, now: DateTime<Local>) -> String {
    let seconds = (now - date).num_seconds();
    if seconds < -5 {
        return "after the system clock changed".into();
    }
    let seconds = seconds.max(0);
    if seconds < 5 {
        "now".into()
    } else if seconds < 60 {
        format!("{seconds}s ago")
    } else if seconds < 3_600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h ago", seconds / 3_600)
    } else {
        format!("{}d ago", seconds / 86_400)
    }
}

pub(super) fn snapshot_needs_refresh(
    fetched_at: DateTime<Local>,
    now: DateTime<Local>,
    maximum_age_seconds: i64,
) -> bool {
    let age = (now - fetched_at).num_seconds();
    age < -5 || age >= maximum_age_seconds.max(0)
}

pub(super) fn has_rate_limit_decoding_issues(response: &AccountRateLimitsResponse) -> bool {
    !response.decoding_issues.is_empty()
}

pub(super) fn format_credits(credits: &CreditsSnapshot) -> String {
    if credits.unlimited == Some(true) {
        return "Unlimited".into();
    }
    // Outside the explicit unlimited state, false is authoritative over a
    // contradictory balance or legacy counters.
    if credits.has_credits == Some(false) {
        return "None".into();
    }
    if let Some(balance) = credits
        .balance
        .as_deref()
        .map(|value| clean_remote_value(value, RATE_TEXT_LIMIT))
        .filter(|value| value != "n/a")
    {
        return balance;
    }
    if credits.has_credits == Some(true) {
        return "Available".into();
    }

    let remaining = credits
        .remaining
        .filter(|value| value.is_finite() && *value >= 0.0);
    let total = credits
        .total
        .filter(|value| value.is_finite() && *value >= 0.0);
    let used = credits
        .used
        .filter(|value| value.is_finite() && *value >= 0.0);
    if let (Some(remaining), Some(total)) = (remaining, total)
        && remaining <= total
    {
        return format!(
            "{} / {} remaining",
            format_credit(remaining),
            format_credit(total)
        );
    }
    if let Some(remaining) = remaining
        && total.is_none()
    {
        return format!("{} remaining", format_credit(remaining));
    }
    if let (Some(used), Some(total)) = (used, total)
        && used <= total
    {
        return format!("{} / {} used", format_credit(used), format_credit(total));
    }
    if let Some(used) = used {
        return format!("{} used", format_credit(used));
    }
    if let Some(remaining) = remaining {
        return format!("{} remaining", format_credit(remaining));
    }
    "n/a".into()
}

pub(super) fn limit_reached_status(value: Option<&str>) -> Option<String> {
    value.map(|value| {
        let cleaned = clean_remote_value(value, RATE_TEXT_LIMIT);
        if cleaned == "n/a" {
            "Reported".into()
        } else {
            cleaned
        }
    })
}

pub(super) fn format_credit(value: f64) -> String {
    if !value.is_finite() || value < 0.0 {
        return "n/a".into();
    }
    let value = if value == 0.0 { 0.0 } else { value };
    if value < i64::MAX as f64 && value.trunc() == value {
        return format!("{value:.0}");
    }
    format_significant_decimal(value, 15)
}

fn format_significant_decimal(value: f64, significant_digits: usize) -> String {
    let significant_digits = significant_digits.clamp(1, 17);
    let scientific = format!("{value:.*e}", significant_digits - 1);
    let Some((mantissa, exponent)) = scientific.split_once('e') else {
        return scientific;
    };
    let Ok(exponent_value) = exponent.parse::<i32>() else {
        return scientific;
    };
    if exponent_value < -4 || exponent_value >= i32::try_from(significant_digits).unwrap_or(17) {
        let mantissa = mantissa.trim_end_matches('0').trim_end_matches('.');
        return format_normalized_exponent(mantissa, exponent_value);
    }
    let decimal_places = i32::try_from(significant_digits - 1)
        .unwrap_or(16)
        .saturating_sub(exponent_value)
        .max(0) as usize;
    let mut formatted = format!("{value:.*}", decimal_places);
    while formatted.ends_with('0') {
        formatted.pop();
    }
    if formatted.ends_with('.') {
        formatted.pop();
    }
    formatted
}

fn format_scientific(value: f64, fractional_digits: usize, trim_mantissa: bool) -> String {
    let scientific = format!("{value:.*e}", fractional_digits.min(16));
    let Some((mantissa, exponent)) = scientific.split_once('e') else {
        return scientific;
    };
    let Ok(exponent) = exponent.parse::<i32>() else {
        return scientific;
    };
    let mantissa = if trim_mantissa {
        mantissa.trim_end_matches('0').trim_end_matches('.')
    } else {
        mantissa
    };
    format_normalized_exponent(mantissa, exponent)
}

fn format_normalized_exponent(mantissa: &str, exponent: i32) -> String {
    format!("{mantissa}E{exponent:+03}")
}

pub(super) fn hero_accessible_label(total_tokens: Option<i64>) -> String {
    total_tokens.map_or_else(
        || "Usage summary, total token usage unavailable".into(),
        |total| {
            format!(
                "Usage summary, total token usage: {} tokens",
                format_full_tokens(total)
            )
        },
    )
}

pub(super) fn clean_message(message: &str) -> String {
    let value = sanitize_single_line(message, 240);
    if value.is_empty() {
        "Unknown error".into()
    } else {
        value
    }
}

pub(super) fn clean_status_message(message: &str) -> String {
    let value = sanitize_single_line(message, 140);
    if value.is_empty() {
        "Operation failed".into()
    } else {
        value
    }
}

pub(super) fn clean_remote_value(value: &str, maximum: usize) -> String {
    let value = sanitize_single_line(value, maximum);
    if value.is_empty() {
        "n/a".into()
    } else {
        value
    }
}

fn sanitize_single_line(message: &str, maximum: usize) -> String {
    let maximum = maximum.min(4_096);
    if maximum == 0 {
        return String::new();
    }
    let inspection_limit = maximum.saturating_mul(8).max(256);
    let mut characters = Vec::with_capacity(maximum);
    let mut pending_space = false;
    let mut truncated = false;
    for (inspected, character) in message.chars().enumerate() {
        if inspected >= inspection_limit {
            truncated = true;
            break;
        }
        if character.is_whitespace() || is_unsafe_format_character(character) {
            pending_space = !characters.is_empty();
            continue;
        }
        if pending_space {
            if characters.len() >= maximum {
                truncated = true;
                break;
            }
            characters.push(' ');
            pending_space = false;
        }
        if characters.len() >= maximum {
            truncated = true;
            break;
        }
        characters.push(character);
    }
    if characters.is_empty() {
        return String::new();
    }
    if !truncated {
        return characters.into_iter().collect();
    }
    if maximum <= 3 {
        return ".".repeat(maximum);
    }
    characters.truncate(maximum - 3);
    while characters.last() == Some(&' ') {
        characters.pop();
    }
    characters.into_iter().chain(['.', '.', '.']).collect()
}
