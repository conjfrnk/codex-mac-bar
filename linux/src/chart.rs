use std::cell::RefCell;
use std::rc::Rc;

use chrono::{Datelike, Local, NaiveDate, TimeZone};
use gtk::cairo;
use gtk::gdk;
use gtk::glib::Propagation;
use gtk::prelude::*;

use crate::model::DailyUsageBucket;
use crate::range::{Timeframe, format_axis_tokens, format_full_tokens, nice_axis_maximum};

const MINT: (f64, f64, f64) = (0.29, 0.87, 0.75);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DateLabelStyle {
    SingleLetterWeekday,
    NumericMonthDay,
    AbbreviatedMonthDay,
    AbbreviatedMonthYear,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AxisPolicy {
    maximum_tick_count: usize,
    date_label_style: DateLabelStyle,
}

impl AxisPolicy {
    fn for_timeframe(timeframe: Timeframe, span_days: Option<i64>) -> Self {
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

#[derive(Clone, Copy, Debug)]
struct ChartLayout {
    left: f64,
    right: f64,
    top: f64,
    bottom: f64,
}

impl ChartLayout {
    fn new(width: f64, height: f64) -> Self {
        let left = 42.0_f64.min(28.0_f64.max(width * 0.18));
        Self {
            left,
            right: (width - 4.0).max(left + 1.0),
            top: 18.0,
            bottom: (height - 25.0).max(19.0),
        }
    }

    fn width(self) -> f64 {
        self.right - self.left
    }

    fn height(self) -> f64 {
        self.bottom - self.top
    }

    fn mid_x(self) -> f64 {
        (self.left + self.right) / 2.0
    }

    fn mid_y(self) -> f64 {
        (self.top + self.bottom) / 2.0
    }
}

#[derive(Default)]
struct Selection {
    hovered: Option<usize>,
    pinned: Option<usize>,
    suppress_hover_until_reentry: bool,
}

impl Selection {
    fn active(&self) -> Option<usize> {
        self.hovered.or(self.pinned)
    }

    fn reset(&mut self) {
        self.hovered = None;
        self.pinned = None;
        self.suppress_hover_until_reentry = false;
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct ChartSample {
    position: f64,
    value: f64,
}

pub fn usage_chart(buckets: &[DailyUsageBucket], timeframe: Timeframe) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::new();
    area.set_content_height(150);
    area.set_hexpand(true);
    area.add_css_class("chart");
    area.set_focusable(true);
    area.set_focus_on_click(true);
    area.set_accessible_role(gtk::AccessibleRole::Slider);
    area.set_tooltip_text(Some(
        "Daily token usage chart; move, click, or use arrow keys to inspect a day",
    ));

    let buckets = Rc::new(buckets.to_vec());
    let selection = Rc::new(RefCell::new(Selection::default()));
    update_chart_accessibility(&area, &buckets, None);
    let draw_buckets = buckets.clone();
    let draw_selection = selection.clone();
    area.set_draw_func(move |area, context, width, height| {
        draw_chart(
            area,
            context,
            width,
            height,
            &draw_buckets,
            timeframe,
            draw_selection.borrow().active(),
        );
    });

    let motion = gtk::EventControllerMotion::new();
    let enter_selection = selection.clone();
    motion.connect_enter(move |_, _, _| {
        enter_selection.borrow_mut().suppress_hover_until_reentry = false;
    });
    let motion_buckets = buckets.clone();
    let leave_buckets = buckets.clone();
    let motion_selection = selection.clone();
    let weak_area = area.downgrade();
    motion.connect_motion(move |_, x, y| {
        let Some(area) = weak_area.upgrade() else {
            return;
        };
        let layout = ChartLayout::new(f64::from(area.width()), f64::from(area.height()));
        let active = {
            let mut selection = motion_selection.borrow_mut();
            if !selection.suppress_hover_until_reentry
                && x >= layout.left
                && x <= layout.right
                && y >= layout.top
                && y <= layout.bottom
            {
                let position = (x - layout.left) / layout.width();
                selection.hovered = nearest_index(position, &bucket_positions(&motion_buckets));
            } else if !selection.suppress_hover_until_reentry {
                selection.hovered = None;
            }
            selection.active()
        };
        update_chart_accessibility(&area, &motion_buckets, active);
        area.queue_draw();
    });
    let leave_selection = selection.clone();
    let weak_area = area.downgrade();
    motion.connect_leave(move |_| {
        let active = {
            let mut selection = leave_selection.borrow_mut();
            selection.hovered = None;
            selection.active()
        };
        if let Some(area) = weak_area.upgrade() {
            update_chart_accessibility(&area, &leave_buckets, active);
            area.queue_draw();
        }
    });
    area.add_controller(motion);

    let click = gtk::GestureClick::new();
    click.set_button(gdk::BUTTON_PRIMARY);
    let click_buckets = buckets.clone();
    let click_selection = selection.clone();
    let weak_area = area.downgrade();
    click.connect_released(move |_, _, x, y| {
        let Some(area) = weak_area.upgrade() else {
            return;
        };
        let layout = ChartLayout::new(f64::from(area.width()), f64::from(area.height()));
        if x < layout.left || x > layout.right || y < layout.top || y > layout.bottom {
            return;
        }
        let index = nearest_index(
            (x - layout.left) / layout.width(),
            &bucket_positions(&click_buckets),
        );
        let mut selection = click_selection.borrow_mut();
        selection.pinned = index;
        selection.hovered = index;
        selection.suppress_hover_until_reentry = false;
        drop(selection);
        area.grab_focus();
        update_chart_accessibility(&area, &click_buckets, index);
        area.queue_draw();
    });
    area.add_controller(click);

    let keys = gtk::EventControllerKey::new();
    let key_buckets = buckets;
    let key_selection = selection;
    let weak_area = area.downgrade();
    keys.connect_key_pressed(move |_, key, _, _| {
        let Some(area) = weak_area.upgrade() else {
            return Propagation::Proceed;
        };
        if key == gdk::Key::Escape {
            key_selection.borrow_mut().reset();
            update_chart_accessibility(&area, &key_buckets, None);
            area.queue_draw();
            return Propagation::Stop;
        }
        let direction = if key == gdk::Key::Left || key == gdk::Key::Down {
            -1
        } else if key == gdk::Key::Right || key == gdk::Key::Up {
            1
        } else {
            return Propagation::Proceed;
        };
        if key_buckets.is_empty() {
            return Propagation::Stop;
        }
        let mut selection = key_selection.borrow_mut();
        let current = selection.active().unwrap_or(key_buckets.len() - 1);
        let next = if direction < 0 {
            current.saturating_sub(1)
        } else {
            (current + 1).min(key_buckets.len() - 1)
        };
        selection.hovered = None;
        selection.pinned = Some(next);
        selection.suppress_hover_until_reentry = true;
        drop(selection);
        update_chart_accessibility(&area, &key_buckets, Some(next));
        area.queue_draw();
        Propagation::Stop
    });
    area.add_controller(keys);
    area
}

fn update_chart_accessibility(
    area: &gtk::DrawingArea,
    buckets: &[DailyUsageBucket],
    selected: Option<usize>,
) {
    let value = if let Some(index) = selected.filter(|index| *index < buckets.len()) {
        let bucket = &buckets[index];
        format!(
            "{}, {} tokens",
            tooltip_date(&bucket.start_date),
            format_full_tokens(bucket.tokens)
        )
    } else if buckets.is_empty() {
        "No usage data".into()
    } else {
        "No point selected".into()
    };
    let maximum = buckets.len().saturating_sub(1) as f64;
    let current = selected
        .unwrap_or_else(|| buckets.len().saturating_sub(1))
        .min(buckets.len().saturating_sub(1)) as f64;
    area.update_property(&[
        gtk::accessible::Property::Label("Daily token usage chart"),
        gtk::accessible::Property::Description(
            "Move the pointer, click, or use the left and right arrow keys to inspect daily values.",
        ),
        gtk::accessible::Property::KeyShortcuts("Left Right Up Down Escape"),
        gtk::accessible::Property::ValueMin(0.0),
        gtk::accessible::Property::ValueMax(maximum),
        gtk::accessible::Property::ValueNow(current),
        gtk::accessible::Property::ValueText(&value),
    ]);
}

fn draw_chart(
    area: &gtk::DrawingArea,
    context: &cairo::Context,
    width: i32,
    height: i32,
    buckets: &[DailyUsageBucket],
    timeframe: Timeframe,
    selected: Option<usize>,
) {
    draw_chart_with_foreground(
        context,
        width,
        height,
        buckets,
        timeframe,
        selected,
        area.color(),
    );
}

fn draw_chart_with_foreground(
    context: &cairo::Context,
    width: i32,
    height: i32,
    buckets: &[DailyUsageBucket],
    timeframe: Timeframe,
    selected: Option<usize>,
    foreground: gdk::RGBA,
) {
    let layout = ChartLayout::new(f64::from(width), f64::from(height));
    let positions = bucket_positions(buckets);
    let peak = buckets
        .iter()
        .map(|bucket| bucket.tokens)
        .max()
        .unwrap_or(0);
    let axis_max = nice_axis_maximum(peak);
    let span_days = bucket_span_days(buckets);
    let policy = AxisPolicy::for_timeframe(timeframe, span_days);

    draw_axes(
        context, layout, buckets, &positions, timeframe, policy, axis_max, foreground,
    );

    let has_activity = peak > 0 && buckets.iter().any(|bucket| bucket.tokens > 0);
    if has_activity && buckets.len() > 1 {
        let values: Vec<_> = buckets.iter().map(|bucket| bucket.tokens).collect();
        let samples = smoothed_samples(&values, &positions, 12);
        context.set_source_rgb(MINT.0, MINT.1, MINT.2);
        context.set_line_width(2.5);
        context.set_line_cap(cairo::LineCap::Round);
        context.set_line_join(cairo::LineJoin::Round);
        for (index, sample) in samples.iter().enumerate() {
            let x = layout.left + sample.position * layout.width();
            let y = y_position(sample.value, layout, axis_max);
            if index == 0 {
                context.move_to(x, y);
            } else {
                context.line_to(x, y);
            }
        }
        let _ = context.stroke();
    } else if has_activity && buckets.len() == 1 {
        let (x, y) = point_for(0, buckets, &positions, layout, axis_max);
        context.set_source_rgb(MINT.0, MINT.1, MINT.2);
        context.arc(x, y, 3.5, 0.0, std::f64::consts::TAU);
        let _ = context.fill();
    } else {
        context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        context.set_font_size(12.0);
        set_rgba(context, foreground, 0.64);
        draw_centered_text(context, "No activity", layout.mid_x(), layout.mid_y());
    }

    if let Some(index) = selected.filter(|index| *index < buckets.len()) {
        draw_selection(
            context, layout, buckets, &positions, axis_max, index, foreground,
        );
        draw_tooltip(
            context,
            layout,
            &buckets[index],
            point_for(index, buckets, &positions, layout, axis_max),
            foreground,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_axes(
    context: &cairo::Context,
    layout: ChartLayout,
    buckets: &[DailyUsageBucket],
    positions: &[f64],
    timeframe: Timeframe,
    policy: AxisPolicy,
    axis_max: i64,
    foreground: gdk::RGBA,
) {
    context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    context.set_font_size(9.0);
    set_rgba(context, foreground, 0.64);
    draw_right_aligned_text(context, "Tokens", layout.left - 6.0, 10.0);

    let mut axis_values = vec![axis_max, axis_max / 2, 0];
    axis_values.dedup();
    for value in axis_values {
        let y = y_position(value as f64, layout, axis_max);
        set_rgba(context, foreground, 0.20);
        context.set_line_width(1.0);
        context.move_to(layout.left, y);
        context.line_to(layout.right, y);
        let _ = context.stroke();

        context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        set_rgba(context, foreground, 0.64);
        draw_fitted_text(
            context,
            &format_axis_tokens(value),
            layout.left - 7.0,
            y + 3.0,
            (layout.left - 7.0).max(1.0),
            9.0,
            0.7,
            TextAlignment::Right,
        );
    }

    set_rgba(context, foreground, 0.32);
    context.set_line_width(1.0);
    context.move_to(layout.left, layout.top);
    context.line_to(layout.left, layout.bottom);
    context.line_to(layout.right, layout.bottom);
    let _ = context.stroke();

    let label_width = if policy.date_label_style == DateLabelStyle::SingleLetterWeekday {
        18.0
    } else {
        56.0
    };
    for index in tick_indices(positions, policy.maximum_tick_count) {
        let x = layout.left + positions[index] * layout.width();
        set_rgba(context, foreground, 0.40);
        context.move_to(x, layout.bottom);
        context.line_to(x, layout.bottom + 3.0);
        let _ = context.stroke();

        let text = chart_date_label(&buckets[index].start_date, timeframe, policy);
        context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        set_rgba(context, foreground, 0.64);
        let center = if buckets.len() <= 1 {
            x
        } else if index == 0 {
            layout.left + label_width / 2.0
        } else if index == buckets.len() - 1 {
            layout.right - label_width / 2.0
        } else {
            x
        };
        draw_fitted_text(
            context,
            &text,
            center,
            layout.bottom + 16.0,
            label_width,
            9.0,
            0.7,
            TextAlignment::Center,
        );
    }
}

fn draw_selection(
    context: &cairo::Context,
    layout: ChartLayout,
    buckets: &[DailyUsageBucket],
    positions: &[f64],
    axis_max: i64,
    index: usize,
    foreground: gdk::RGBA,
) {
    let (x, y) = point_for(index, buckets, positions, layout, axis_max);
    set_rgba(context, foreground, 0.45);
    context.set_line_width(1.0);
    context.set_dash(&[3.0, 3.0], 0.0);
    context.move_to(x, layout.top);
    context.line_to(x, layout.bottom);
    let _ = context.stroke();
    context.set_dash(&[], 0.0);

    let light_background = foreground.red() < 0.5;
    if light_background {
        context.set_source_rgb(0.957, 0.957, 0.965);
    } else {
        context.set_source_rgb(0.12, 0.12, 0.13);
    }
    context.arc(x, y, 5.0, 0.0, std::f64::consts::TAU);
    let _ = context.fill_preserve();
    context.set_source_rgb(MINT.0, MINT.1, MINT.2);
    context.set_line_width(3.0);
    let _ = context.stroke();
}

fn draw_tooltip(
    context: &cairo::Context,
    layout: ChartLayout,
    bucket: &DailyUsageBucket,
    point: (f64, f64),
    foreground: gdk::RGBA,
) {
    let tooltip_width = layout.width().min(146.0);
    let tooltip_height = 47.0;
    let center_x = clamped_center(point.0, tooltip_width, layout.left, layout.right);
    let proposed_y = if point.1 > layout.mid_y() {
        point.1 - 31.0
    } else {
        point.1 + 31.0
    };
    let center_y = clamped_center(proposed_y, tooltip_height, layout.top, layout.bottom);
    let x = center_x - tooltip_width / 2.0;
    let y = center_y - tooltip_height / 2.0;

    rounded_rectangle(context, x, y + 2.0, tooltip_width, tooltip_height, 7.0);
    context.set_source_rgba(0.0, 0.0, 0.0, 0.14);
    let _ = context.fill();

    rounded_rectangle(context, x, y, tooltip_width, tooltip_height, 7.0);
    if foreground.red() < 0.5 {
        context.set_source_rgb(0.985, 0.985, 0.99);
    } else {
        context.set_source_rgb(0.18, 0.18, 0.20);
    }
    let _ = context.fill_preserve();
    set_rgba(context, foreground, 0.32);
    context.set_line_width(1.0);
    let _ = context.stroke();

    context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    set_rgba(context, foreground, 0.64);
    draw_fitted_text(
        context,
        &tooltip_date(&bucket.start_date),
        x + 8.0,
        y + 16.0,
        tooltip_width - 16.0,
        10.0,
        0.75,
        TextAlignment::Left,
    );

    set_rgba(context, foreground, 1.0);
    draw_fitted_text(
        context,
        &format!("{} tokens", format_full_tokens(bucket.tokens)),
        x + 8.0,
        y + 34.0,
        tooltip_width - 16.0,
        11.0,
        0.6,
        TextAlignment::Left,
    );
}

fn point_for(
    index: usize,
    buckets: &[DailyUsageBucket],
    positions: &[f64],
    layout: ChartLayout,
    axis_max: i64,
) -> (f64, f64) {
    (
        layout.left + positions[index] * layout.width(),
        y_position(buckets[index].tokens as f64, layout, axis_max),
    )
}

fn y_position(value: f64, layout: ChartLayout, axis_max: i64) -> f64 {
    let ratio = (value / axis_max.max(1) as f64).clamp(0.0, 1.0);
    layout.bottom - layout.height() * ratio
}

fn set_rgba(context: &cairo::Context, color: gdk::RGBA, alpha: f64) {
    context.set_source_rgba(
        f64::from(color.red()),
        f64::from(color.green()),
        f64::from(color.blue()),
        alpha,
    );
}

fn draw_right_aligned_text(context: &cairo::Context, text: &str, right: f64, baseline: f64) {
    if let Ok(extents) = context.text_extents(text) {
        context.move_to(right - extents.width(), baseline);
        let _ = context.show_text(text);
    }
}

fn draw_centered_text(context: &cairo::Context, text: &str, x: f64, y: f64) {
    if let Ok(extents) = context.text_extents(text) {
        context.move_to(x - extents.width() / 2.0, y + extents.height() / 2.0);
        let _ = context.show_text(text);
    }
}

#[derive(Clone, Copy)]
enum TextAlignment {
    Left,
    Center,
    Right,
}

#[allow(clippy::too_many_arguments)]
fn draw_fitted_text(
    context: &cairo::Context,
    text: &str,
    anchor_x: f64,
    baseline: f64,
    maximum_width: f64,
    font_size: f64,
    minimum_scale: f64,
    alignment: TextAlignment,
) {
    context.set_font_size(font_size);
    let Ok(mut extents) = context.text_extents(text) else {
        return;
    };
    if extents.width() > maximum_width {
        let scale = (maximum_width / extents.width()).max(minimum_scale);
        context.set_font_size(font_size * scale);
        let Ok(scaled) = context.text_extents(text) else {
            return;
        };
        extents = scaled;
    }
    let x = match alignment {
        TextAlignment::Left => anchor_x,
        TextAlignment::Center => anchor_x - extents.width() / 2.0,
        TextAlignment::Right => anchor_x - extents.width(),
    };
    context.move_to(x, baseline);
    let _ = context.show_text(text);
}

fn rounded_rectangle(
    context: &cairo::Context,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    radius: f64,
) {
    let right = x + width;
    let bottom = y + height;
    context.new_sub_path();
    context.arc(
        right - radius,
        y + radius,
        radius,
        -std::f64::consts::FRAC_PI_2,
        0.0,
    );
    context.arc(
        right - radius,
        bottom - radius,
        radius,
        0.0,
        std::f64::consts::FRAC_PI_2,
    );
    context.arc(
        x + radius,
        bottom - radius,
        radius,
        std::f64::consts::FRAC_PI_2,
        std::f64::consts::PI,
    );
    context.arc(
        x + radius,
        y + radius,
        radius,
        std::f64::consts::PI,
        std::f64::consts::PI * 1.5,
    );
    context.close_path();
}

fn bucket_positions(buckets: &[DailyUsageBucket]) -> Vec<f64> {
    if buckets.len() <= 1 {
        return if buckets.is_empty() {
            Vec::new()
        } else {
            vec![0.5]
        };
    }
    let timestamps: Option<Vec<i64>> = buckets
        .iter()
        .map(|bucket| {
            let date = NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d").ok()?;
            let midnight = date.and_hms_opt(0, 0, 0)?;
            Local
                .from_local_datetime(&midnight)
                .earliest()
                .map(|date| date.timestamp_millis())
        })
        .collect();
    if let Some(timestamps) = timestamps {
        let span = timestamps[timestamps.len() - 1] - timestamps[0];
        if span > 0 {
            return timestamps
                .iter()
                .map(|timestamp| (*timestamp - timestamps[0]) as f64 / span as f64)
                .collect();
        }
    }
    evenly_spaced_positions(buckets.len())
}

fn bucket_span_days(buckets: &[DailyUsageBucket]) -> Option<i64> {
    let first = NaiveDate::parse_from_str(&buckets.first()?.start_date, "%Y-%m-%d").ok()?;
    let last = NaiveDate::parse_from_str(&buckets.last()?.start_date, "%Y-%m-%d").ok()?;
    Some((last - first).num_days().abs())
}

fn evenly_spaced_positions(count: usize) -> Vec<f64> {
    match count {
        0 => Vec::new(),
        1 => vec![0.5],
        _ => (0..count)
            .map(|index| index as f64 / (count - 1) as f64)
            .collect(),
    }
}

fn valid_positions(positions: &[f64], count: usize) -> bool {
    positions.len() == count
        && positions.iter().all(|position| position.is_finite())
        && positions.first().is_some_and(|position| *position >= 0.0)
        && positions.last().is_some_and(|position| *position <= 1.0)
        && positions.windows(2).all(|window| {
            let interval = window[1] - window[0];
            interval.is_finite() && interval >= 1e-12
        })
}

fn nearest_index(position: f64, positions: &[f64]) -> Option<usize> {
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

fn tick_indices(positions: &[f64], maximum: usize) -> Vec<usize> {
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
    let mut result = Vec::new();
    for tick in 0..maximum {
        let fraction = tick as f64 / (maximum - 1) as f64;
        let position = positions[0] + fraction * (positions[count - 1] - positions[0]);
        if let Some(index) = nearest_index(position, positions)
            && result.last().copied() != Some(index)
        {
            result.push(index);
        }
    }
    result
}

fn smoothed_samples(
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

fn clamped_center(proposed: f64, item_length: f64, lower: f64, upper: f64) -> f64 {
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

fn chart_date_label(value: &str, _timeframe: Timeframe, policy: AxisPolicy) -> String {
    let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") else {
        return value.into();
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

fn tooltip_date(value: &str) -> String {
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map(|date| date.format("%b %-d, %Y").to_string())
        .unwrap_or_else(|_| value.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Days;

    fn bucket(date: &str, tokens: i64) -> DailyUsageBucket {
        DailyUsageBucket {
            start_date: date.into(),
            tokens,
        }
    }

    fn daily_buckets(count: usize, tokens: impl Fn(usize) -> i64) -> Vec<DailyUsageBucket> {
        let start = NaiveDate::from_ymd_opt(2026, 4, 11).unwrap();
        (0..count)
            .map(|offset| DailyUsageBucket {
                start_date: start
                    .checked_add_days(Days::new(offset as u64))
                    .unwrap()
                    .format("%Y-%m-%d")
                    .to_string(),
                tokens: tokens(offset),
            })
            .collect()
    }

    fn render_fixture(
        buckets: &[DailyUsageBucket],
        timeframe: Timeframe,
        selected: Option<usize>,
        dark: bool,
    ) -> Vec<u8> {
        let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, 264, 150).unwrap();
        let context = cairo::Context::new(&surface).unwrap();
        if dark {
            context.set_source_rgb(0.12, 0.12, 0.12);
        } else {
            context.set_source_rgb(1.0, 1.0, 1.0);
        }
        context.paint().unwrap();
        let foreground = if dark {
            gdk::RGBA::new(0.94, 0.94, 0.94, 1.0)
        } else {
            gdk::RGBA::new(0.12, 0.12, 0.13, 1.0)
        };
        draw_chart_with_foreground(&context, 264, 150, buckets, timeframe, selected, foreground);
        context.status().unwrap();
        drop(context);
        surface.flush();
        surface.data().unwrap().to_vec()
    }

    #[test]
    fn chart_positions_follow_date_gaps() {
        let buckets = vec![
            bucket("2026-01-01", 1),
            bucket("2026-01-02", 2),
            bucket("2026-01-11", 3),
        ];
        assert_eq!(bucket_positions(&buckets), vec![0.0, 0.1, 1.0]);
        assert_eq!(nearest_index(0.2, &bucket_positions(&buckets)), Some(1));
    }

    #[test]
    fn ticks_are_chosen_by_date_position() {
        let positions = vec![0.0, 0.01, 0.49, 0.51, 0.99, 1.0];
        assert_eq!(tick_indices(&positions, 3), vec![0, 3, 5]);
    }

    #[test]
    fn smoothing_preserves_every_endpoint_and_cannot_overshoot() {
        let values = [0, 80, 20, 120, 120, 10];
        let positions = evenly_spaced_positions(values.len());
        let samples_per_segment = 16;
        let samples = smoothed_samples(&values, &positions, samples_per_segment);
        assert_eq!(samples.first().unwrap().value, 0.0);
        assert_eq!(samples.last().unwrap().value, 10.0);
        assert_eq!(samples.len(), (values.len() - 1) * samples_per_segment + 1);
        for (index, value) in values.iter().enumerate() {
            assert_eq!(samples[index * samples_per_segment].value, *value as f64);
        }
        for segment in 0..values.len() - 1 {
            let start = segment * samples_per_segment;
            let lower = values[segment].min(values[segment + 1]) as f64;
            let upper = values[segment].max(values[segment + 1]) as f64;
            assert!(
                samples[start..=start + samples_per_segment]
                    .iter()
                    .all(|sample| sample.value >= lower && sample.value <= upper)
            );
            for pair in samples[start..=start + samples_per_segment].windows(2) {
                if values[segment] <= values[segment + 1] {
                    assert!(pair[1].value >= pair[0].value);
                } else {
                    assert!(pair[1].value <= pair[0].value);
                }
            }
        }
    }

    #[test]
    fn smoothing_stays_on_zero_between_empty_calendar_days() {
        let values = [50, 0, 0, 80];
        let samples_per_segment = 12;
        let samples = smoothed_samples(
            &values,
            &evenly_spaced_positions(values.len()),
            samples_per_segment,
        );

        assert_eq!(samples[samples_per_segment].value, 0.0);
        assert_eq!(samples[samples_per_segment * 2].value, 0.0);
        assert!(
            samples[samples_per_segment..=samples_per_segment * 2]
                .iter()
                .all(|sample| sample.value == 0.0)
        );
    }

    #[test]
    fn empty_one_and_two_point_series_remain_unsmoothed() {
        assert!(smoothed_samples(&[], &[], 12).is_empty());
        assert_eq!(
            smoothed_samples(&[42], &[0.5], 12),
            vec![ChartSample {
                position: 0.5,
                value: 42.0
            }]
        );
        assert_eq!(
            smoothed_samples(&[10, 30], &[0.0, 1.0], 12),
            vec![
                ChartSample {
                    position: 0.0,
                    value: 10.0
                },
                ChartSample {
                    position: 1.0,
                    value: 30.0
                }
            ]
        );
    }

    #[test]
    fn unstable_positions_fall_back_to_finite_even_spacing() {
        for positions in [
            vec![f64::NEG_INFINITY, 0.0, f64::INFINITY],
            vec![0.0, f64::MIN_POSITIVE, 1.0],
        ] {
            let samples = smoothed_samples(&[0, 1, 2], &positions, 4);
            assert!(
                samples
                    .iter()
                    .all(|sample| sample.position.is_finite() && sample.value.is_finite())
            );
            assert_eq!(samples.first().unwrap().position, 0.0);
            assert_eq!(samples.last().unwrap().position, 1.0);
        }
        assert_eq!(
            tick_indices(&[f64::NEG_INFINITY, 0.0, f64::INFINITY], 2),
            vec![0, 2]
        );
    }

    #[test]
    fn timeframe_tick_counts_match_macos_policy() {
        assert!(tick_indices(&[], 4).is_empty());
        assert_eq!(tick_indices(&[0.5], 4), vec![0]);
        assert_eq!(
            tick_indices(&evenly_spaced_positions(7), 4),
            vec![0, 2, 4, 6]
        );
        assert_eq!(
            tick_indices(&evenly_spaced_positions(30), 4),
            vec![0, 10, 19, 29]
        );
        assert_eq!(
            tick_indices(&evenly_spaced_positions(90), 3),
            vec![0, 45, 89]
        );

        let week_policy = AxisPolicy::for_timeframe(Timeframe::Seven, Some(6));
        assert_eq!(week_policy.maximum_tick_count, 7);
        assert_eq!(
            week_policy.date_label_style,
            DateLabelStyle::SingleLetterWeekday
        );
        assert_eq!(
            tick_indices(&evenly_spaced_positions(7), week_policy.maximum_tick_count),
            vec![0, 1, 2, 3, 4, 5, 6]
        );
    }

    #[test]
    fn all_time_axis_switches_to_year_labels_after_one_year() {
        assert_eq!(
            AxisPolicy::for_timeframe(Timeframe::All, Some(364)).date_label_style,
            DateLabelStyle::AbbreviatedMonthDay
        );
        assert_eq!(
            AxisPolicy::for_timeframe(Timeframe::All, Some(365)).date_label_style,
            DateLabelStyle::AbbreviatedMonthYear
        );
    }

    #[test]
    fn tooltip_centers_stay_inside_the_plot() {
        assert_eq!(clamped_center(1.0, 40.0, 0.0, 100.0), 20.0);
        assert_eq!(clamped_center(99.0, 40.0, 0.0, 100.0), 80.0);
        assert_eq!(clamped_center(50.0, 40.0, 0.0, 100.0), 50.0);
        assert_eq!(clamped_center(50.0, 400.0, 0.0, 100.0), 50.0);
        assert!(clamped_center(0.0, 1.0, f64::NAN, 10.0).is_finite());
    }

    #[test]
    fn macos_chart_visual_edge_cases_all_render_nonempty_surfaces() {
        let month = daily_buckets(30, |day| {
            let wave = ((day * day * 83_117) % 4_200_000) as i64;
            if day.is_multiple_of(8) {
                0
            } else {
                wave + 350_000
            }
        });
        let fixtures = vec![
            (Timeframe::Seven, month[23..].to_vec(), None, true),
            (Timeframe::Thirty, month.clone(), None, false),
            (Timeframe::Thirty, month.clone(), None, true),
            (Timeframe::Thirty, month.clone(), Some(0), false),
            (
                Timeframe::Thirty,
                month.clone(),
                Some(month.len() - 1),
                true,
            ),
            (
                Timeframe::Ninety,
                daily_buckets(90, |day| ((day * 791_993) % 8_000_000) as i64),
                None,
                false,
            ),
            (
                Timeframe::All,
                vec![
                    bucket("2024-01-01", 120_000),
                    bucket("2024-01-15", 4_200_000),
                    bucket("2025-06-01", 900_000),
                    bucket("2026-07-09", 7_800_000),
                ],
                None,
                true,
            ),
            (Timeframe::Seven, daily_buckets(7, |_| 0), None, false),
            (
                Timeframe::All,
                vec![bucket("2026-07-09", i64::MAX)],
                Some(0),
                true,
            ),
            (
                Timeframe::All,
                vec![bucket("2026-07-01", 1), bucket("2026-07-09", 9_999_999_999)],
                None,
                false,
            ),
        ];

        for (timeframe, buckets, selected, dark) in fixtures {
            let pixels = render_fixture(&buckets, timeframe, selected, dark);
            let background = if dark {
                [31, 31, 31, 255]
            } else {
                [255, 255, 255, 255]
            };
            assert_eq!(pixels.len(), 264 * 150 * 4);
            assert!(
                pixels
                    .chunks_exact(4)
                    .filter(|pixel| *pixel != background)
                    .count()
                    > 100
            );
        }

        let light = render_fixture(&month, Timeframe::Thirty, None, false);
        let dark = render_fixture(&month, Timeframe::Thirty, None, true);
        assert_ne!(light, dark);
    }
}
