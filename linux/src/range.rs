use std::collections::BTreeMap;

use chrono::{Days, Local, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::model::DailyUsageBucket;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Timeframe {
    Seven,
    #[default]
    Thirty,
    Ninety,
    All,
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
            Self::Seven => "7-day history",
            Self::Thirty => "30-day history",
            Self::Ninety => "90-day history",
            Self::All => "Daily history",
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
}

impl UsageRange {
    pub fn new(timeframe: Timeframe, source: &[DailyUsageBucket]) -> Self {
        Self::at_date(timeframe, source, Local::now().date_naive())
    }

    pub fn at_date(timeframe: Timeframe, source: &[DailyUsageBucket], today: NaiveDate) -> Self {
        let merged = merge_buckets(source);
        let buckets = match timeframe.days() {
            None => merged,
            Some(days) => {
                let first = today
                    .checked_sub_days(Days::new(days.saturating_sub(1)))
                    .unwrap_or(today);
                let values: BTreeMap<&str, i64> = merged
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
        Self { buckets }
    }

    pub fn total_tokens(&self) -> i64 {
        self.buckets.iter().map(|bucket| bucket.tokens).sum()
    }

    pub fn average_daily_tokens(&self) -> i64 {
        if self.buckets.is_empty() {
            0
        } else {
            self.total_tokens() / self.buckets.len() as i64
        }
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

    /// Returns a calendar-contiguous series for plotting without changing the summary math.
    /// The app-server can omit inactive dates in all-time data; a chart must represent those
    /// dates at zero instead of drawing a smooth bridge between the surrounding active days.
    pub fn chart_buckets(&self) -> Vec<DailyUsageBucket> {
        fill_calendar_gaps(&self.buckets)
    }
}

fn fill_calendar_gaps(source: &[DailyUsageBucket]) -> Vec<DailyUsageBucket> {
    let mut tokens_by_date = BTreeMap::<NaiveDate, i64>::new();
    for bucket in source {
        let Ok(date) = NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d") else {
            // Preserve unusual future app-server data rather than silently dropping it.
            return source.to_vec();
        };
        *tokens_by_date.entry(date).or_default() += bucket.tokens;
    }
    let Some(first) = tokens_by_date.keys().next().copied() else {
        return Vec::new();
    };
    let last = tokens_by_date.keys().next_back().copied().unwrap_or(first);
    let day_count = (last - first).num_days().max(0) as u64;
    (0..=day_count)
        .filter_map(|offset| first.checked_add_days(Days::new(offset)))
        .map(|date| DailyUsageBucket {
            start_date: date.format("%Y-%m-%d").to_string(),
            tokens: tokens_by_date.get(&date).copied().unwrap_or(0),
        })
        .collect()
}

pub fn merge_buckets(source: &[DailyUsageBucket]) -> Vec<DailyUsageBucket> {
    let mut totals = BTreeMap::<String, i64>::new();
    for bucket in source {
        *totals.entry(bucket.start_date.clone()).or_default() += bucket.tokens;
    }
    totals
        .into_iter()
        .map(|(start_date, tokens)| DailyUsageBucket { start_date, tokens })
        .collect()
}

pub fn format_tokens(value: i64) -> String {
    let absolute = value.unsigned_abs() as f64;
    let sign = if value < 0 { "-" } else { "" };
    let (scaled, suffix, maximum_fraction_digits) = if absolute < 1_000.0 {
        return value.to_string();
    } else if absolute < 1_000_000.0 {
        (absolute / 1_000.0, "K", 1)
    } else if absolute < 1_000_000_000.0 {
        (absolute / 1_000_000.0, "M", 1)
    } else if absolute < 1_000_000_000_000.0 {
        (absolute / 1_000_000_000.0, "B", 3)
    } else {
        (absolute / 1_000_000_000_000.0, "T", 2)
    };
    let precision = if scaled >= 100.0 {
        0
    } else {
        maximum_fraction_digits
    };
    format!("{sign}{scaled:.precision$}{suffix}")
}

pub fn format_axis_tokens(value: i64) -> String {
    let absolute = value.unsigned_abs() as f64;
    let sign = if value < 0 { "-" } else { "" };
    let (scaled, suffix) = if absolute < 1_000.0 {
        return value.to_string();
    } else if absolute < 1_000_000.0 {
        (absolute / 1_000.0, "K")
    } else if absolute < 1_000_000_000.0 {
        (absolute / 1_000_000.0, "M")
    } else if absolute < 1_000_000_000_000.0 {
        (absolute / 1_000_000_000.0, "B")
    } else {
        (absolute / 1_000_000_000_000.0, "T")
    };
    let mut number = format!("{scaled:.1}");
    while number.contains('.') && number.ends_with('0') {
        number.pop();
    }
    if number.ends_with('.') {
        number.pop();
    }
    let (whole, fraction) = number.split_once('.').unwrap_or((&number, ""));
    let grouped = group_digits(whole);
    if fraction.is_empty() {
        format!("{sign}{grouped}{suffix}")
    } else {
        format!("{sign}{grouped}.{fraction}{suffix}")
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
    let magnitude = 10_f64.powf((value as f64).log10().floor());
    let normalized = value as f64 / magnitude;
    let nice = if normalized <= 1.0 {
        1.0
    } else if normalized <= 2.0 {
        2.0
    } else if normalized <= 5.0 {
        5.0
    } else {
        10.0
    };
    (nice * magnitude).round().min(i64::MAX as f64) as i64
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
        assert_eq!(range.average_daily_tokens(), 10);
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
        assert_eq!(range.average_daily_tokens(), 65);
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
        assert_eq!(format_axis_tokens(500_000), "500K");
        assert_eq!(format_axis_tokens(5_000_000_000), "5B");
        assert_eq!(format_axis_tokens(2_500_000_000), "2.5B");
        assert_eq!(format_axis_tokens(i64::MAX), "9,223,372T");
        assert_eq!(format_full_tokens(12_345_678), "12,345,678");
        assert_eq!(nice_axis_maximum(4_181_000_000), 5_000_000_000);
    }
}
