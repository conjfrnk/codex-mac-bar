use std::collections::{BTreeMap, BTreeSet};

use chrono::{Days, Local, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::model::{DailyUsageBucket, is_canonical_usage_date};

const MAXIMUM_SPARSE_CHART_POINT_COUNT: usize = 20_000;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Timeframe {
    Seven,
    #[default]
    Thirty,
    Ninety,
    All,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AllTimeSummarySelection {
    pub total_tokens: Option<i64>,
    pub peak_daily_tokens: Option<i64>,
    pub daily_history_partial: bool,
    pub has_unreconciled_total: bool,
}

/// Reconciles independently reported all-time summary fields with the daily
/// series. Summary values can prove that visible daily history is partial, but
/// they must not produce a total below either the visible or reported peak.
pub fn reconcile_all_time_summary(
    daily_history_available: bool,
    exact_daily_total: Option<i64>,
    exact_daily_peak: Option<i64>,
    lifetime_tokens: Option<i64>,
    summary_peak_daily_tokens: Option<i64>,
) -> AllTimeSummarySelection {
    let lifetime = lifetime_tokens.filter(|value| *value >= 0);
    let summary_peak = summary_peak_daily_tokens.filter(|value| *value >= 0);
    let peak_daily_tokens = [summary_peak, exact_daily_peak].into_iter().flatten().max();

    let (total_tokens, daily_history_partial) =
        if daily_history_available && exact_daily_total.is_none() {
            // A saturated or otherwise inexact daily sum cannot be compared with a
            // lifetime total. An exact peak can still prove the history is partial.
            (
                None,
                exact_daily_peak.is_some()
                    && summary_peak.is_some_and(|value| value > exact_daily_peak.unwrap_or(0)),
            )
        } else {
            let daily_history_partial = daily_history_available
                && (lifetime.is_some_and(|value| value > exact_daily_total.unwrap_or(0))
                    || summary_peak.is_some_and(|value| value > exact_daily_peak.unwrap_or(0)));
            let candidate_total = if daily_history_partial {
                // Once a summary proves the visible daily series is a subset, its
                // sum is not an exact all-time total. Only a strictly larger
                // lifetime value can supply the missing history.
                lifetime.filter(|value| exact_daily_total.is_some_and(|daily| *value > daily))
            } else {
                [lifetime, exact_daily_total].into_iter().flatten().max()
            };
            (
                candidate_total.filter(|value| {
                    peak_daily_tokens.is_none_or(|peak_daily_tokens| *value >= peak_daily_tokens)
                }),
                daily_history_partial,
            )
        };

    AllTimeSummarySelection {
        total_tokens,
        peak_daily_tokens,
        daily_history_partial,
        has_unreconciled_total: total_tokens.is_none()
            && (daily_history_available
                || lifetime_tokens.is_some()
                || summary_peak_daily_tokens.is_some()),
    }
}

impl Timeframe {
    pub const ALL: [Self; 4] = [Self::Seven, Self::Thirty, Self::Ninety, Self::All];

    pub fn short_title(self) -> &'static str {
        match self {
            Self::Seven => "Week",
            Self::Thirty => "Month",
            Self::Ninety => "Quarter",
            Self::All => "All",
        }
    }

    pub fn hero_title(self) -> &'static str {
        match self {
            Self::Seven => "Last 7 days (rolling)",
            Self::Thirty => "Last 30 days (rolling)",
            Self::Ninety => "Last 90 days (rolling)",
            Self::All => "All time",
        }
    }

    pub fn history_title(self) -> &'static str {
        match self {
            Self::Seven => "Week active-day history",
            Self::Thirty => "Month active-day history",
            Self::Ninety => "Quarter active-day history",
            Self::All => "Active-day history",
        }
    }

    pub fn days(self) -> Option<u64> {
        match self {
            Self::Seven => Some(7),
            Self::Thirty => Some(30),
            Self::Ninety => Some(90),
            Self::All => None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct UsageRange {
    pub buckets: Vec<DailyUsageBucket>,
    chart_buckets: Vec<DailyUsageBucket>,
    calendar_day_count: usize,
    total_tokens: i64,
    did_overflow: bool,
    merge_did_overflow: bool,
    total_did_overflow: bool,
    rejected_bucket_count: usize,
}

impl UsageRange {
    pub fn new(timeframe: Timeframe, source: &[DailyUsageBucket]) -> Self {
        Self::at_date(timeframe, source, Local::now().date_naive())
    }

    pub fn at_date(timeframe: Timeframe, source: &[DailyUsageBucket], today: NaiveDate) -> Self {
        let merged = merge_buckets_reporting_overflow(source);
        let buckets = match timeframe.days() {
            None => merged.buckets.clone(),
            Some(days) => {
                let Some(first) = today.checked_sub_days(Days::new(days.saturating_sub(1))) else {
                    return Self::empty(merged.rejected_bucket_count);
                };
                let values: BTreeMap<&str, i64> = merged
                    .buckets
                    .iter()
                    .map(|bucket| (bucket.start_date.as_str(), bucket.tokens))
                    .collect();
                (0..days)
                    .filter_map(|offset| first.checked_add_days(Days::new(offset)))
                    .map(|date| {
                        let start_date = date.format("%Y-%m-%d").to_string();
                        DailyUsageBucket {
                            tokens: values.get(start_date.as_str()).copied().unwrap_or(0),
                            start_date,
                        }
                    })
                    .collect()
            }
        };
        let chart_buckets = if timeframe == Timeframe::All {
            sparse_calendar_series(&buckets, today)
        } else {
            buckets.clone()
        };
        let calendar_day_count = match timeframe.days() {
            Some(_) => buckets.len(),
            None => all_time_calendar_day_count(&buckets, today),
        };
        let selected_merge_overflow = {
            let selected_start_dates: BTreeSet<_> = buckets
                .iter()
                .map(|bucket| bucket.start_date.as_str())
                .collect();
            merged
                .overflowed_start_dates
                .iter()
                .any(|date| selected_start_dates.contains(date.as_str()))
        };
        let (total_tokens, total_overflow) = saturating_total(&buckets);
        Self {
            buckets,
            chart_buckets,
            calendar_day_count,
            total_tokens,
            did_overflow: selected_merge_overflow || total_overflow,
            merge_did_overflow: selected_merge_overflow,
            total_did_overflow: total_overflow,
            rejected_bucket_count: merged.rejected_bucket_count,
        }
    }

    pub fn total_tokens(&self) -> i64 {
        self.total_tokens
    }

    pub fn average_daily_tokens(&self) -> i64 {
        i64::try_from(self.calendar_day_count)
            .ok()
            .filter(|divisor| *divisor > 0)
            .map_or(0, |divisor| self.total_tokens / divisor)
    }

    pub fn peak_daily_tokens(&self) -> i64 {
        self.buckets
            .iter()
            .map(|bucket| bucket.tokens)
            .max()
            .unwrap_or(0)
    }

    pub fn active_days(&self) -> usize {
        self.buckets
            .iter()
            .filter(|bucket| bucket.tokens > 0)
            .count()
    }

    pub fn history(&self) -> Vec<DailyUsageBucket> {
        self.buckets
            .iter()
            .filter(|bucket| bucket.tokens > 0)
            .cloned()
            .collect()
    }

    /// Returns a calendar-positioned series for plotting without changing the summary math.
    /// The app-server can omit inactive dates in all-time data; a chart must represent those
    /// dates at zero instead of drawing a smooth bridge between the surrounding active days.
    pub fn chart_buckets(&self) -> Vec<DailyUsageBucket> {
        self.chart_buckets.clone()
    }

    pub fn did_overflow(&self) -> bool {
        self.did_overflow
    }

    pub fn merge_did_overflow(&self) -> bool {
        self.merge_did_overflow
    }

    pub fn total_did_overflow(&self) -> bool {
        self.total_did_overflow
    }

    pub fn rejected_bucket_count(&self) -> usize {
        self.rejected_bucket_count
    }

    fn empty(rejected_bucket_count: usize) -> Self {
        Self {
            buckets: Vec::new(),
            chart_buckets: Vec::new(),
            calendar_day_count: 0,
            total_tokens: 0,
            did_overflow: false,
            merge_did_overflow: false,
            total_did_overflow: false,
            rejected_bucket_count,
        }
    }
}

fn all_time_calendar_day_count(source: &[DailyUsageBucket], today: NaiveDate) -> usize {
    let Some(first) = source
        .first()
        .and_then(|bucket| NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d").ok())
    else {
        return 0;
    };
    let last = source
        .last()
        .and_then(|bucket| NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d").ok())
        .unwrap_or(first);
    let endpoint = last.max(today);
    usize::try_from((endpoint - first).num_days())
        .ok()
        .and_then(|distance| distance.checked_add(1))
        .unwrap_or(usize::MAX)
}

/// Insert only the zero-valued boundaries required to prevent a chart from
/// smoothing across omitted idle spans. This remains bounded even when two
/// source dates are years apart.
fn sparse_calendar_series(source: &[DailyUsageBucket], today: NaiveDate) -> Vec<DailyUsageBucket> {
    let Some(first) = source.first().cloned() else {
        return Vec::new();
    };
    let Some(mut previous_date) = NaiveDate::parse_from_str(&first.start_date, "%Y-%m-%d").ok()
    else {
        return Vec::new();
    };
    let mut result = Vec::with_capacity(
        source
            .len()
            .saturating_mul(3)
            .min(MAXIMUM_SPARSE_CHART_POINT_COUNT),
    );
    append_bounded_chart_bucket(&mut result, first);

    for bucket in source.iter().skip(1) {
        let Ok(current_date) = NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d") else {
            continue;
        };
        let gap = (current_date - previous_date).num_days();
        if gap > 1
            && let Some(after_previous) = previous_date.checked_add_days(Days::new(1))
        {
            append_bounded_chart_bucket(
                &mut result,
                DailyUsageBucket {
                    start_date: after_previous.format("%Y-%m-%d").to_string(),
                    tokens: 0,
                },
            );
            if gap > 2
                && let Some(before_current) = current_date.checked_sub_days(Days::new(1))
            {
                append_bounded_chart_bucket(
                    &mut result,
                    DailyUsageBucket {
                        start_date: before_current.format("%Y-%m-%d").to_string(),
                        tokens: 0,
                    },
                );
            }
        }
        append_bounded_chart_bucket(&mut result, bucket.clone());
        previous_date = current_date;
    }

    let trailing_gap = (today - previous_date).num_days();
    if trailing_gap > 0
        && let Some(next) = previous_date.checked_add_days(Days::new(1))
    {
        append_bounded_chart_bucket(
            &mut result,
            DailyUsageBucket {
                start_date: next.format("%Y-%m-%d").to_string(),
                tokens: 0,
            },
        );
        if trailing_gap > 1 {
            append_bounded_chart_bucket(
                &mut result,
                DailyUsageBucket {
                    start_date: today.format("%Y-%m-%d").to_string(),
                    tokens: 0,
                },
            );
        }
    }
    bounded_chart_series(&result, MAXIMUM_SPARSE_CHART_POINT_COUNT)
}

struct MergeResult {
    buckets: Vec<DailyUsageBucket>,
    overflowed_start_dates: BTreeSet<String>,
    rejected_bucket_count: usize,
}

fn merge_buckets_reporting_overflow(source: &[DailyUsageBucket]) -> MergeResult {
    let mut totals = BTreeMap::<String, i64>::new();
    let mut overflowed_start_dates = BTreeSet::new();
    let mut rejected_bucket_count = 0;
    for bucket in source {
        if !is_canonical_usage_date(&bucket.start_date) || bucket.tokens < 0 {
            rejected_bucket_count += 1;
            continue;
        }
        let total = totals.entry(bucket.start_date.clone()).or_default();
        match total.checked_add(bucket.tokens) {
            Some(value) => *total = value,
            None => {
                *total = i64::MAX;
                overflowed_start_dates.insert(bucket.start_date.clone());
            }
        }
    }
    MergeResult {
        buckets: totals
            .into_iter()
            .map(|(start_date, tokens)| DailyUsageBucket { start_date, tokens })
            .collect(),
        overflowed_start_dates,
        rejected_bucket_count,
    }
}

fn saturating_total(source: &[DailyUsageBucket]) -> (i64, bool) {
    let mut total: i64 = 0;
    let mut did_overflow = false;
    for bucket in source {
        match total.checked_add(bucket.tokens.max(0)) {
            Some(value) => total = value,
            None => {
                total = i64::MAX;
                did_overflow = true;
            }
        }
    }
    (total, did_overflow)
}

fn append_bounded_chart_bucket(result: &mut Vec<DailyUsageBucket>, bucket: DailyUsageBucket) {
    if result
        .last()
        .is_some_and(|last| last.start_date == bucket.start_date)
    {
        if let Some(last) = result.last_mut() {
            *last = bucket;
        }
        return;
    }
    if result.len() >= MAXIMUM_SPARSE_CHART_POINT_COUNT {
        *result = bounded_chart_series(result, MAXIMUM_SPARSE_CHART_POINT_COUNT / 2);
    }
    result.push(bucket);
}

fn bounded_chart_series(source: &[DailyUsageBucket], limit: usize) -> Vec<DailyUsageBucket> {
    if limit < 2 || source.len() <= limit {
        return source.to_vec();
    }
    let last_index = source.len() - 1;
    let interior_count = last_index - 1;
    let bin_count = ((limit - 2) / 2).max(1);
    let mut result = Vec::with_capacity(limit);
    result.push(source[0].clone());
    for bin in 0..bin_count {
        let start = 1 + (bin * interior_count / bin_count);
        let end = 1 + ((bin + 1) * interior_count / bin_count);
        if start >= end {
            continue;
        }
        let mut minimum = start;
        let mut maximum = start;
        for index in (start + 1)..end {
            if source[index].tokens < source[minimum].tokens {
                minimum = index;
            }
            if source[index].tokens > source[maximum].tokens {
                maximum = index;
            }
        }
        let mut extrema = [minimum, maximum];
        extrema.sort_unstable();
        for index in extrema {
            if result
                .last()
                .is_none_or(|bucket| bucket.start_date != source[index].start_date)
            {
                result.push(source[index].clone());
            }
        }
    }
    if result
        .last()
        .is_none_or(|bucket| bucket.start_date != source[last_index].start_date)
    {
        result.push(source[last_index].clone());
    }
    result
}

pub fn format_tokens(value: i64) -> String {
    let absolute = value.unsigned_abs() as f64;
    let sign = if value < 0 { "-" } else { "" };
    if absolute < 1_000.0 {
        return value.to_string();
    }
    let divisors = [
        1.0,
        1_000.0,
        1_000_000.0,
        1_000_000_000.0,
        1_000_000_000_000.0,
    ];
    let suffixes = ["", "K", "M", "B", "T"];
    let fraction_digits: [usize; 5] = [0, 1, 1, 3, 2];
    let mut unit = ((absolute.log10() / 3.0).floor() as usize).min(suffixes.len() - 1);
    loop {
        let scaled = absolute / divisors[unit];
        let precision = if scaled >= 100.0 {
            0
        } else {
            fraction_digits[unit]
        };
        let scale = 10_f64.powi(precision as i32);
        let rounded = (scaled * scale).round() / scale;
        if rounded >= 1_000.0 && unit < suffixes.len() - 1 {
            unit += 1;
            continue;
        }
        return format!("{sign}{rounded:.precision$}{}", suffixes[unit]);
    }
}

pub fn format_axis_tokens(value: i64) -> String {
    let absolute = value.unsigned_abs() as f64;
    let sign = if value < 0 { "-" } else { "" };
    if absolute < 1_000.0 {
        return value.to_string();
    }
    if absolute >= 1_000_000_000_000_000.0 {
        return format!("{:.1e}", value as f64)
            .replace("e+", "e")
            .replace("e0", "e");
    }
    let divisors = [
        1.0,
        1_000.0,
        1_000_000.0,
        1_000_000_000.0,
        1_000_000_000_000.0,
    ];
    let suffixes = ["", "K", "M", "B", "T"];
    let mut unit = ((absolute.log10() / 3.0).floor() as usize).min(suffixes.len() - 1);
    loop {
        let rounded = (absolute / divisors[unit] * 10.0).round() / 10.0;
        if rounded >= 1_000.0 && unit < suffixes.len() - 1 {
            unit += 1;
            continue;
        }
        let mut number = format!("{rounded:.1}");
        while number.contains('.') && number.ends_with('0') {
            number.pop();
        }
        if number.ends_with('.') {
            number.pop();
        }
        return format!("{sign}{number}{}", suffixes[unit]);
    }
}

pub fn format_full_tokens(value: i64) -> String {
    let sign = if value < 0 { "-" } else { "" };
    let digits = value.unsigned_abs().to_string();
    format!("{sign}{}", group_digits(&digits))
}

fn group_digits(digits: &str) -> String {
    let mut output = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            output.push(',');
        }
        output.push(character);
    }
    output
}

pub fn nice_axis_maximum(value: i64) -> i64 {
    if value <= 0 {
        return 0;
    }
    let mut magnitude = 1_i64;
    while value / magnitude >= 10 && magnitude <= i64::MAX / 10 {
        magnitude *= 10;
    }
    for multiplier in [1_i64, 2, 5, 10] {
        if let Some(candidate) = magnitude.checked_mul(multiplier)
            && candidate >= value
        {
            return candidate;
        }
    }
    i64::MAX
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket(date: &str, tokens: i64) -> DailyUsageBucket {
        DailyUsageBucket {
            start_date: date.into(),
            tokens,
        }
    }

    #[test]
    fn rolling_range_fills_missing_days_and_merges_duplicates() {
        let range = UsageRange::at_date(
            Timeframe::Seven,
            &[
                bucket("2026-07-09", 20),
                bucket("2026-07-09", 22),
                bucket("2026-07-07", 8),
                bucket("2020-01-01", 99),
            ],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        assert_eq!(range.buckets.len(), 7);
        assert_eq!(range.total_tokens(), 50);
        assert_eq!(range.buckets.last().unwrap().tokens, 42);
        assert_eq!(range.active_days(), 2);
    }

    #[test]
    fn thirty_day_range_uses_the_calendar_window_ending_today() {
        let range = UsageRange::at_date(
            Timeframe::Thirty,
            &[
                bucket("2026-06-08", 999),
                bucket("2026-06-09", 20),
                bucket("2026-07-07", 100),
                bucket("2026-07-08", 1),
                bucket("2026-07-09", 500),
            ],
            NaiveDate::from_ymd_opt(2026, 7, 8).unwrap(),
        );
        assert_eq!(range.total_tokens(), 121);
        assert_eq!(range.buckets.len(), 30);
        assert_eq!(range.buckets.first().unwrap().start_date, "2026-06-09");
        assert_eq!(range.buckets.last().unwrap().start_date, "2026-07-08");
    }

    #[test]
    fn all_time_range_merges_sorts_and_filters_history_like_macos() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[
                bucket("2026-07-08", 10),
                bucket("2026-07-07", 0),
                bucket("2026-07-08", 15),
                bucket("2026-07-06", 5),
            ],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        assert_eq!(
            range.buckets,
            vec![
                bucket("2026-07-06", 5),
                bucket("2026-07-07", 0),
                bucket("2026-07-08", 25)
            ]
        );
        assert_eq!(
            range.history(),
            vec![bucket("2026-07-06", 5), bucket("2026-07-08", 25)]
        );
        assert_eq!(range.active_days(), 2);
        assert_eq!(range.peak_daily_tokens(), 25);
        assert_eq!(range.average_daily_tokens(), 7);
    }

    #[test]
    fn all_time_summary_reconciliation_never_claims_impossible_totals() {
        let complete = reconcile_all_time_summary(true, Some(500), Some(300), Some(500), Some(300));
        assert_eq!(complete.total_tokens, Some(500));
        assert_eq!(complete.peak_daily_tokens, Some(300));
        assert!(!complete.daily_history_partial);
        assert!(!complete.has_unreconciled_total);

        let partial = reconcile_all_time_summary(true, Some(500), Some(300), Some(900), Some(700));
        assert_eq!(partial.total_tokens, Some(900));
        assert_eq!(partial.peak_daily_tokens, Some(700));
        assert!(partial.daily_history_partial);
        assert!(!partial.has_unreconciled_total);

        let no_credible_lifetime =
            reconcile_all_time_summary(true, Some(500), Some(300), Some(500), Some(700));
        assert_eq!(no_credible_lifetime.total_tokens, None);
        assert_eq!(no_credible_lifetime.peak_daily_tokens, Some(700));
        assert!(no_credible_lifetime.daily_history_partial);
        assert!(no_credible_lifetime.has_unreconciled_total);

        let below_peak = reconcile_all_time_summary(false, None, None, Some(100), Some(800));
        assert_eq!(below_peak.total_tokens, None);
        assert_eq!(below_peak.peak_daily_tokens, Some(800));
        assert!(!below_peak.daily_history_partial);
        assert!(below_peak.has_unreconciled_total);
    }

    #[test]
    fn partial_daily_history_requires_a_strictly_larger_lifetime_total() {
        for lifetime in [None, Some(499), Some(500)] {
            let selection =
                reconcile_all_time_summary(true, Some(500), Some(300), lifetime, Some(700));
            assert_eq!(selection.total_tokens, None, "lifetime={lifetime:?}");
            assert!(selection.daily_history_partial);
            assert!(selection.has_unreconciled_total);
        }
        let credible = reconcile_all_time_summary(true, Some(500), Some(300), Some(701), Some(700));
        assert_eq!(credible.total_tokens, Some(701));
        assert!(!credible.has_unreconciled_total);
    }

    #[test]
    fn chart_series_drops_to_zero_on_dates_omitted_by_the_server() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[bucket("2026-07-06", 50), bucket("2026-07-09", 80)],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );

        assert_eq!(
            range.chart_buckets(),
            vec![
                bucket("2026-07-06", 50),
                bucket("2026-07-07", 0),
                bucket("2026-07-08", 0),
                bucket("2026-07-09", 80),
            ]
        );
        assert_eq!(range.buckets.len(), 2);
        assert_eq!(range.average_daily_tokens(), 32);
    }

    #[test]
    fn rolling_chart_series_retains_each_zero_usage_day() {
        let range = UsageRange::at_date(
            Timeframe::Seven,
            &[bucket("2026-07-06", 50), bucket("2026-07-08", 80)],
            NaiveDate::from_ymd_opt(2026, 7, 8).unwrap(),
        );

        let chart = range.chart_buckets();
        assert_eq!(chart.len(), 7);
        assert_eq!(chart[5], bucket("2026-07-07", 0));
    }

    #[test]
    fn formats_token_counts() {
        assert_eq!(format_tokens(999), "999");
        assert_eq!(format_tokens(1_000), "1.0K");
        assert_eq!(format_tokens(1_200), "1.2K");
        assert_eq!(format_tokens(149_009_942), "149M");
        assert_eq!(format_tokens(1_250_000_000), "1.250B");
        assert_eq!(format_tokens(150_400_000_000), "150B");
        assert_eq!(format_tokens(4_181_000_000), "4.181B");
        assert_eq!(format_tokens(999_999), "1.0M");
        assert_eq!(format_axis_tokens(500_000), "500K");
        assert_eq!(format_axis_tokens(5_000_000_000), "5B");
        assert_eq!(format_axis_tokens(2_500_000_000), "2.5B");
        assert_eq!(format_axis_tokens(999_999), "1M");
        assert_eq!(format_axis_tokens(i64::MAX), "9.2e18");
        assert_eq!(format_full_tokens(12_345_678), "12,345,678");
        assert_eq!(nice_axis_maximum(4_181_000_000), 5_000_000_000);
        assert_eq!(nice_axis_maximum(i64::MAX), i64::MAX);
    }

    #[test]
    fn invalid_negative_and_overflowing_buckets_are_safe_and_observable() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[
                bucket("2026-07-08", i64::MAX),
                bucket("2026-07-08", 1),
                bucket("2026-07-09", i64::MAX),
                bucket("not-a-date", 10),
                bucket("2026-07-10", -1),
            ],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        assert_eq!(range.total_tokens(), i64::MAX);
        assert!(range.did_overflow());
        assert!(range.merge_did_overflow());
        assert!(range.total_did_overflow());
        assert_eq!(range.rejected_bucket_count(), 2);
        assert_eq!(range.buckets.len(), 2);
    }

    #[test]
    fn overflow_outside_a_fixed_window_does_not_poison_the_selected_total() {
        let range = UsageRange::at_date(
            Timeframe::Seven,
            &[
                bucket("2020-01-01", i64::MAX),
                bucket("2020-01-01", 1),
                bucket("2026-07-09", 100),
            ],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        assert_eq!(range.total_tokens(), 100);
        assert!(!range.did_overflow());
        assert!(!range.merge_did_overflow());
        assert!(!range.total_did_overflow());
    }

    #[test]
    fn total_overflow_is_distinct_from_same_day_merge_overflow() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[bucket("2026-07-08", i64::MAX), bucket("2026-07-09", 1)],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        assert!(range.did_overflow());
        assert!(!range.merge_did_overflow());
        assert!(range.total_did_overflow());
    }

    #[test]
    fn all_time_average_counts_omitted_and_trailing_calendar_days() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[bucket("2026-07-01", 90), bucket("2026-07-03", 10)],
            NaiveDate::from_ymd_opt(2026, 7, 10).unwrap(),
        );
        assert_eq!(range.total_tokens(), 100);
        assert_eq!(range.average_daily_tokens(), 10);
        assert_eq!(
            range.chart_buckets().last().unwrap(),
            &bucket("2026-07-10", 0)
        );
    }

    #[test]
    fn all_time_chart_is_sparse_across_extreme_date_gaps() {
        let range = UsageRange::at_date(
            Timeframe::All,
            &[bucket("0001-01-01", 1), bucket("9999-12-31", 2)],
            NaiveDate::from_ymd_opt(2026, 7, 9).unwrap(),
        );
        let chart = range.chart_buckets();
        assert_eq!(chart.len(), 4);
        assert_eq!(chart.first().unwrap(), &bucket("0001-01-01", 1));
        assert_eq!(chart.last().unwrap(), &bucket("9999-12-31", 2));
    }
}
