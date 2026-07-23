use chrono::{Datelike, NaiveDate};

use crate::model::DailyUsageBucket;
use crate::range::Timeframe;

pub(super) const MAXIMUM_DRAW_POINTS: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum DateLabelStyle {
    SingleLetterWeekday,
    NumericMonthDay,
    AbbreviatedMonthDay,
    AbbreviatedMonthYear,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct AxisPolicy {
    pub(super) maximum_tick_count: usize,
    pub(super) date_label_style: DateLabelStyle,
}

impl AxisPolicy {
    pub(super) fn for_timeframe(timeframe: Timeframe, span_days: Option<i64>) -> Self {
        match timeframe {
            Timeframe::Seven => Self {
                maximum_tick_count: 7,
                date_label_style: DateLabelStyle::SingleLetterWeekday,
            },
            Timeframe::Thirty => Self {
                maximum_tick_count: 4,
                date_label_style: DateLabelStyle::NumericMonthDay,
            },
            Timeframe::Ninety => Self {
                maximum_tick_count: 3,
                date_label_style: DateLabelStyle::AbbreviatedMonthDay,
            },
            Timeframe::All => Self {
                maximum_tick_count: 3,
                date_label_style: if span_days.unwrap_or_default() >= 365 {
                    DateLabelStyle::AbbreviatedMonthYear
                } else {
                    DateLabelStyle::AbbreviatedMonthDay
                },
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ChartSample {
    pub(super) position: f64,
    pub(super) value: f64,
}

pub(super) struct PreparedChart {
    pub(super) positions: Vec<f64>,
    pub(super) peak: i64,
    pub(super) plot_values: Vec<i64>,
    pub(super) plot_positions: Vec<f64>,
    pub(super) trend: Option<[ChartSample; 2]>,
}

impl PreparedChart {
    pub(super) fn new(buckets: &[DailyUsageBucket]) -> Self {
        let positions = bucket_positions(buckets);
        let values: Vec<_> = buckets.iter().map(chart_token_value).collect();
        let peak = values.iter().copied().max().unwrap_or(0);
        let trend = least_squares_trend(&values, &positions);
        let (plot_values, plot_positions) =
            bounded_plot_series(&values, &positions, MAXIMUM_DRAW_POINTS);
        Self {
            positions,
            peak,
            plot_values,
            plot_positions,
            trend,
        }
    }
}

pub(super) fn least_squares_trend(
    values: &[i64],
    positions: &[f64],
) -> Option<[ChartSample; 2]> {
    if values.len() < 2
        || !values.iter().any(|value| *value > 0)
        || !valid_positions(positions, values.len())
    {
        return None;
    }

    let count = values.len() as f64;
    let mean_position = positions.iter().sum::<f64>() / count;
    let mean_value = values.iter().map(|value| *value as f64).sum::<f64>() / count;
    let (covariance, position_variance) = positions.iter().zip(values).fold(
        (0.0, 0.0),
        |(covariance, position_variance), (position, value)| {
            let centered_position = *position - mean_position;
            (
                covariance + centered_position * (*value as f64 - mean_value),
                position_variance + centered_position * centered_position,
            )
        },
    );
    if !position_variance.is_finite() || position_variance <= f64::EPSILON {
        return None;
    }

    let slope = covariance / position_variance;
    let intercept = mean_value - slope * mean_position;
    let end_value = intercept + slope;
    if !intercept.is_finite() || !end_value.is_finite() {
        return None;
    }
    Some([
        ChartSample {
            position: 0.0,
            value: intercept,
        },
        ChartSample {
            position: 1.0,
            value: end_value,
        },
    ])
}

pub(super) fn chart_token_value(bucket: &DailyUsageBucket) -> i64 {
    bucket.tokens.max(0)
}

pub(super) fn bucket_positions(buckets: &[DailyUsageBucket]) -> Vec<f64> {
    if buckets.len() <= 1 {
        return if buckets.is_empty() {
            Vec::new()
        } else {
            vec![0.5]
        };
    }
    // Calendar dates represent calendar buckets. Unix-midnight distances make
    // days around DST transitions 23 or 25 hours wide and visibly skew ticks.
    let dates: Option<Vec<NaiveDate>> = buckets
        .iter()
        .map(|bucket| NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d").ok())
        .collect();
    if let Some(dates) = dates {
        let span = (dates[dates.len() - 1] - dates[0]).num_days();
        if span > 0 && dates.windows(2).all(|window| window[1] > window[0]) {
            return dates
                .iter()
                .map(|date| (*date - dates[0]).num_days() as f64 / span as f64)
                .collect();
        }
    }
    evenly_spaced_positions(buckets.len())
}

pub(super) fn bucket_span_days(buckets: &[DailyUsageBucket]) -> Option<i64> {
    let first = NaiveDate::parse_from_str(&buckets.first()?.start_date, "%Y-%m-%d").ok()?;
    let last = NaiveDate::parse_from_str(&buckets.last()?.start_date, "%Y-%m-%d").ok()?;
    Some((last - first).num_days().abs())
}

pub(super) fn evenly_spaced_positions(count: usize) -> Vec<f64> {
    match count {
        0 => Vec::new(),
        1 => vec![0.5],
        _ => (0..count)
            .map(|index| index as f64 / (count - 1) as f64)
            .collect(),
    }
}

pub(super) fn valid_positions(positions: &[f64], count: usize) -> bool {
    if positions.len() != count || positions.is_empty() {
        return count == 0 && positions.is_empty();
    }
    if count == 1 {
        return positions[0].is_finite() && (0.0..=1.0).contains(&positions[0]);
    }
    positions.iter().all(|position| position.is_finite())
        && positions
            .first()
            .is_some_and(|position| position.abs() <= f64::EPSILON)
        && positions
            .last()
            .is_some_and(|position| (*position - 1.0).abs() <= f64::EPSILON)
        && positions.windows(2).all(|window| {
            let interval = window[1] - window[0];
            interval.is_finite() && interval >= 1e-12
        })
}

pub(super) fn bounded_plot_series(
    values: &[i64],
    positions: &[f64],
    maximum_points: usize,
) -> (Vec<i64>, Vec<f64>) {
    if values.len() != positions.len() {
        return (values.to_vec(), evenly_spaced_positions(values.len()));
    }
    if values.len() <= maximum_points || values.len() <= 2 {
        return (values.to_vec(), positions.to_vec());
    }
    let maximum_points = maximum_points.max(2);
    if maximum_points == 2 {
        return (
            vec![values[0], values[values.len() - 1]],
            vec![positions[0], positions[positions.len() - 1]],
        );
    }
    if maximum_points == 3 {
        let last = values.len() - 1;
        let peak = (1..last).max_by_key(|index| values[*index]).unwrap_or(0);
        let mut indices = vec![0, peak, last];
        indices.sort_unstable();
        indices.dedup();
        return (
            indices.iter().map(|index| values[*index]).collect(),
            indices.iter().map(|index| positions[*index]).collect(),
        );
    }
    let last = values.len() - 1;
    let interior_count = last - 1;
    let bin_count = ((maximum_points - 2) / 2).max(1);
    let mut indices = Vec::with_capacity(maximum_points);
    indices.push(0);
    for bin in 0..bin_count {
        let start = 1 + interior_count * bin / bin_count;
        let end = 1 + interior_count * (bin + 1) / bin_count;
        if start >= end {
            continue;
        }
        let mut minimum = start;
        let mut maximum = start;
        for index in start + 1..end {
            if values[index] < values[minimum] {
                minimum = index;
            }
            if values[index] > values[maximum] {
                maximum = index;
            }
        }
        if minimum <= maximum {
            indices.push(minimum);
            if maximum != minimum {
                indices.push(maximum);
            }
        } else {
            indices.push(maximum);
            indices.push(minimum);
        }
    }
    indices.push(last);
    indices.sort_unstable();
    indices.dedup();
    (
        indices.iter().map(|index| values[*index]).collect(),
        indices.iter().map(|index| positions[*index]).collect(),
    )
}

#[cfg(test)]
pub(super) fn nearest_index(position: f64, positions: &[f64]) -> Option<usize> {
    if !position.is_finite() || positions.is_empty() {
        return None;
    }
    let fallback;
    let positions = if valid_positions(positions, positions.len()) {
        positions
    } else {
        fallback = evenly_spaced_positions(positions.len());
        &fallback
    };
    nearest_index_in_valid_positions(position, positions)
}

pub(super) fn nearest_index_in_valid_positions(position: f64, positions: &[f64]) -> Option<usize> {
    if !position.is_finite() || positions.is_empty() {
        return None;
    }
    if positions.len() == 1 || position <= positions[0] {
        return Some(0);
    }
    if position >= positions[positions.len() - 1] {
        return Some(positions.len() - 1);
    }
    let mut lower = 0;
    let mut upper = positions.len() - 1;
    while upper - lower > 1 {
        let middle = (lower + upper) / 2;
        if positions[middle] < position {
            lower = middle;
        } else {
            upper = middle;
        }
    }
    Some(
        if position - positions[lower] < positions[upper] - position {
            lower
        } else {
            upper
        },
    )
}

#[cfg(test)]
pub(super) fn tick_indices(positions: &[f64], maximum: usize) -> Vec<usize> {
    let count = positions.len();
    if count == 0 || maximum == 0 {
        return Vec::new();
    }
    if count == 1 || maximum == 1 {
        return vec![0];
    }
    if count <= maximum {
        return (0..count).collect();
    }
    let fallback;
    let positions = if valid_positions(positions, count) {
        positions
    } else {
        fallback = evenly_spaced_positions(count);
        &fallback
    };
    tick_indices_in_valid_positions(positions, maximum)
}

pub(super) fn tick_indices_in_valid_positions(positions: &[f64], maximum: usize) -> Vec<usize> {
    let count = positions.len();
    if count == 0 || maximum == 0 {
        return Vec::new();
    }
    if count == 1 || maximum == 1 {
        return vec![0];
    }
    if count <= maximum {
        return (0..count).collect();
    }
    let mut result = Vec::new();
    for tick in 0..maximum {
        let fraction = tick as f64 / (maximum - 1) as f64;
        let position = positions[0] + fraction * (positions[count - 1] - positions[0]);
        if let Some(index) = nearest_index_in_valid_positions(position, positions)
            && result.last().copied() != Some(index)
        {
            result.push(index);
        }
    }
    result
}

pub(super) fn smoothed_samples(
    values: &[i64],
    positions: &[f64],
    samples_per_segment: usize,
) -> Vec<ChartSample> {
    if values.is_empty() {
        return Vec::new();
    }
    let fallback;
    let positions = if valid_positions(positions, values.len()) {
        positions
    } else {
        fallback = evenly_spaced_positions(values.len());
        &fallback
    };
    if values.len() == 1 {
        return vec![ChartSample {
            position: positions[0],
            value: values[0] as f64,
        }];
    }
    if values.len() < 3 || samples_per_segment <= 1 {
        return values
            .iter()
            .enumerate()
            .map(|(index, value)| ChartSample {
                position: positions[index],
                value: *value as f64,
            })
            .collect();
    }

    let source: Vec<_> = values.iter().map(|value| *value as f64).collect();
    let intervals: Vec<_> = positions
        .windows(2)
        .map(|window| window[1] - window[0])
        .collect();
    let deltas: Vec<_> = source
        .windows(2)
        .enumerate()
        .map(|(index, window)| (window[1] - window[0]) / intervals[index])
        .collect();
    let mut tangents = vec![0.0; source.len()];
    tangents[0] = deltas[0];
    tangents[source.len() - 1] = deltas[deltas.len() - 1];
    for index in 1..source.len() - 1 {
        let before = deltas[index - 1];
        let after = deltas[index];
        if (before > 0.0 && after > 0.0) || (before < 0.0 && after < 0.0) {
            let before_interval = intervals[index - 1];
            let after_interval = intervals[index];
            let before_weight = 2.0 * after_interval + before_interval;
            let after_weight = after_interval + 2.0 * before_interval;
            tangents[index] =
                (before_weight + after_weight) / (before_weight / before + after_weight / after);
        }
    }

    let mut result = Vec::with_capacity((source.len() - 1) * samples_per_segment + 1);
    for segment in 0..source.len() - 1 {
        let start = source[segment];
        let end = source[segment + 1];
        let start_position = positions[segment];
        let interval = intervals[segment];
        let lower = start.min(end);
        let upper = start.max(end);
        for sample_index in 0..samples_per_segment {
            let t = sample_index as f64 / samples_per_segment as f64;
            let t2 = t * t;
            let t3 = t2 * t;
            let h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
            let h10 = t3 - 2.0 * t2 + t;
            let h01 = -2.0 * t3 + 3.0 * t2;
            let h11 = t3 - t2;
            let value = (h00 * start
                + h10 * interval * tangents[segment]
                + h01 * end
                + h11 * interval * tangents[segment + 1])
                .clamp(lower, upper);
            result.push(ChartSample {
                position: start_position + t * interval,
                value,
            });
        }
    }
    result.push(ChartSample {
        position: positions[positions.len() - 1],
        value: source[source.len() - 1],
    });
    result
}

pub(super) fn clamped_center(proposed: f64, item_length: f64, lower: f64, upper: f64) -> f64 {
    if !lower.is_finite() || !upper.is_finite() || upper < lower {
        return if proposed.is_finite() { proposed } else { 0.0 };
    }
    let available = upper - lower;
    let midpoint = lower + available / 2.0;
    if !proposed.is_finite()
        || !item_length.is_finite()
        || item_length <= 0.0
        || item_length >= available
    {
        return midpoint;
    }
    let half = item_length / 2.0;
    proposed.clamp(lower + half, upper - half)
}

pub(super) fn chart_date_label(value: &str, _timeframe: Timeframe, policy: AxisPolicy) -> String {
    let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") else {
        return "Invalid date".into();
    };
    match policy.date_label_style {
        DateLabelStyle::SingleLetterWeekday => date
            .format("%a")
            .to_string()
            .chars()
            .next()
            .unwrap_or('?')
            .to_string(),
        DateLabelStyle::NumericMonthDay => format!("{}/{}", date.month(), date.day()),
        DateLabelStyle::AbbreviatedMonthDay => date.format("%b %-d").to_string(),
        DateLabelStyle::AbbreviatedMonthYear => date.format("%b %Y").to_string(),
    }
}

pub(super) fn tooltip_date(value: &str) -> String {
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map(|date| date.format("%b %-d, %Y").to_string())
        .unwrap_or_else(|_| "Invalid date".into())
}
