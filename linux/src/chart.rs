use std::cell::RefCell;
use std::rc::Rc;

use gtk::cairo;
use gtk::gdk;
use gtk::glib::Propagation;
use gtk::prelude::*;

use crate::model::DailyUsageBucket;
use crate::range::{Timeframe, format_axis_tokens, format_full_tokens, nice_axis_maximum};

mod preparation;

use preparation::*;

const MINT: (f64, f64, f64) = (0.29, 0.87, 0.75);
const LIGHT_BACKGROUND_MINT: (f64, f64, f64) = (0.03, 0.45, 0.37);
const DRAW_POINTS_PER_PIXEL: usize = 3;

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

    fn clear_for_escape(&mut self) -> bool {
        let had_selection = self.active().is_some();
        if had_selection {
            self.hovered = None;
            self.pinned = None;
            // Pointer motion can arrive between two Escape presses. Keep hover
            // disabled until a real leave/re-enter cycle so that the second
            // Escape reliably bubbles to the window and dismisses it.
            self.suppress_hover_until_reentry = true;
        }
        had_selection
    }
}

pub fn usage_chart(
    buckets: &[DailyUsageBucket],
    timeframe: Timeframe,
    data_available: bool,
) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::new();
    area.set_content_height(150);
    area.set_hexpand(true);
    area.add_css_class("chart");
    let buckets = if data_available {
        buckets.to_vec()
    } else {
        Vec::new()
    };
    let adjustable = !buckets.is_empty();
    area.set_focusable(adjustable);
    area.set_focus_on_click(adjustable);
    area.set_accessible_role(if adjustable {
        gtk::AccessibleRole::Slider
    } else {
        gtk::AccessibleRole::Img
    });
    let buckets = Rc::new(buckets);
    // Parsing calendar dates for every pointer event made an all-time chart do
    // O(n) work per mouse movement. Positions are immutable for the widget.
    let prepared = Rc::new(PreparedChart::new(&buckets));
    let selection = Rc::new(RefCell::new(Selection::default()));
    update_chart_accessibility(&area, &buckets, None, data_available);
    let draw_buckets = buckets.clone();
    let draw_prepared = prepared.clone();
    let draw_selection = selection.clone();
    area.set_draw_func(move |area, context, width, height| {
        draw_prepared_chart(
            context,
            width,
            height,
            &draw_buckets,
            &draw_prepared,
            timeframe,
            draw_selection.borrow().active(),
            area.color(),
            data_available,
            widget_uses_high_contrast(area),
        );
    });

    if !adjustable {
        return area;
    }

    let motion = gtk::EventControllerMotion::new();
    let enter_selection = selection.clone();
    motion.connect_enter(move |_, _, _| {
        enter_selection.borrow_mut().suppress_hover_until_reentry = false;
    });
    let motion_buckets = buckets.clone();
    let motion_prepared = prepared.clone();
    let leave_buckets = buckets.clone();
    let motion_selection = selection.clone();
    let weak_area = area.downgrade();
    motion.connect_motion(move |_, x, y| {
        let Some(area) = weak_area.upgrade() else {
            return;
        };
        let layout = ChartLayout::new(f64::from(area.width()), f64::from(area.height()));
        let (active, changed) = {
            let mut selection = motion_selection.borrow_mut();
            let previous = selection.active();
            if !selection.suppress_hover_until_reentry
                && x >= layout.left
                && x <= layout.right
                && y >= layout.top
                && y <= layout.bottom
            {
                let position = (x - layout.left) / layout.width();
                selection.hovered =
                    nearest_index_in_valid_positions(position, &motion_prepared.positions);
            } else if !selection.suppress_hover_until_reentry {
                selection.hovered = None;
            }
            let active = selection.active();
            (active, active != previous)
        };
        if !changed {
            return;
        }
        update_chart_accessibility(&area, &motion_buckets, active, data_available);
        area.queue_draw();
    });
    let leave_selection = selection.clone();
    let weak_area = area.downgrade();
    motion.connect_leave(move |_| {
        let (active, changed) = {
            let mut selection = leave_selection.borrow_mut();
            let previous = selection.active();
            selection.hovered = None;
            let active = selection.active();
            (active, active != previous)
        };
        if changed && let Some(area) = weak_area.upgrade() {
            update_chart_accessibility(&area, &leave_buckets, active, data_available);
            area.queue_draw();
        }
    });
    area.add_controller(motion);

    let click = gtk::GestureClick::new();
    click.set_button(gdk::BUTTON_PRIMARY);
    let click_buckets = buckets.clone();
    let click_prepared = prepared;
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
        let index = nearest_index_in_valid_positions(
            (x - layout.left) / layout.width(),
            &click_prepared.positions,
        );
        let mut selection = click_selection.borrow_mut();
        selection.pinned = index;
        selection.hovered = index;
        selection.suppress_hover_until_reentry = false;
        drop(selection);
        area.grab_focus();
        update_chart_accessibility(&area, &click_buckets, index, data_available);
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
            // The first Escape clears an active chart inspection. Once there
            // is nothing left to clear, let the window's bubble controller
            // dismiss the popover instead of trapping Escape forever.
            if !key_selection.borrow_mut().clear_for_escape() {
                return Propagation::Proceed;
            }
            update_chart_accessibility(&area, &key_buckets, None, data_available);
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
        update_chart_accessibility(&area, &key_buckets, Some(next), data_available);
        area.queue_draw();
        Propagation::Stop
    });
    area.add_controller(keys);
    area
}

fn widget_uses_high_contrast(widget: &impl IsA<gtk::Widget>) -> bool {
    let mut current = Some(widget.as_ref().clone());
    while let Some(widget) = current {
        if widget.has_css_class("codex-system") {
            return true;
        }
        current = widget.parent();
    }
    false
}

fn update_chart_accessibility(
    area: &gtk::DrawingArea,
    buckets: &[DailyUsageBucket],
    selected: Option<usize>,
    data_available: bool,
) {
    let value = if let Some(index) = selected.filter(|index| *index < buckets.len()) {
        let bucket = &buckets[index];
        format!(
            "{}, {} tokens",
            tooltip_date(&bucket.start_date),
            format_full_tokens(chart_token_value(bucket))
        )
    } else if !data_available {
        "Usage history unavailable".into()
    } else if buckets.is_empty() {
        "No activity".into()
    } else {
        let bucket = &buckets[buckets.len() - 1];
        format!(
            "Most recent: {}, {} tokens",
            tooltip_date(&bucket.start_date),
            format_full_tokens(chart_token_value(bucket))
        )
    };
    if buckets.is_empty() {
        area.update_property(&[
            gtk::accessible::Property::Label("Daily token usage chart"),
            gtk::accessible::Property::Description(if data_available {
                "No daily activity is available for this timeframe."
            } else {
                "Daily usage history is unavailable or could not be represented safely."
            }),
        ]);
        return;
    }
    let maximum = buckets.len().saturating_sub(1) as f64;
    let current = selected
        .unwrap_or(buckets.len().saturating_sub(1))
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

#[cfg(test)]
fn draw_chart_with_foreground(
    context: &cairo::Context,
    width: i32,
    height: i32,
    buckets: &[DailyUsageBucket],
    timeframe: Timeframe,
    selected: Option<usize>,
    foreground: gdk::RGBA,
    include_trend: bool,
) {
    let mut prepared = PreparedChart::new(buckets);
    if !include_trend {
        prepared.trend = None;
    }
    draw_prepared_chart(
        context, width, height, buckets, &prepared, timeframe, selected, foreground, true, false,
    );
}

#[allow(clippy::too_many_arguments)]
fn draw_prepared_chart(
    context: &cairo::Context,
    width: i32,
    height: i32,
    buckets: &[DailyUsageBucket],
    prepared: &PreparedChart,
    timeframe: Timeframe,
    selected: Option<usize>,
    foreground: gdk::RGBA,
    data_available: bool,
    high_contrast: bool,
) {
    let layout = ChartLayout::new(f64::from(width), f64::from(height));
    let positions = &prepared.positions;
    let peak = prepared.peak;
    let axis_max = nice_axis_maximum(peak);
    let span_days = bucket_span_days(buckets);
    let policy = AxisPolicy::for_timeframe(timeframe, span_days);

    draw_axes(
        context, layout, buckets, positions, timeframe, policy, axis_max, foreground,
    );

    let has_activity = data_available && peak > 0;
    let accent = chart_accent(foreground, high_contrast);
    if has_activity && let Some(trend) = prepared.trend {
        draw_trend_line(context, layout, trend, axis_max, accent);
    }
    if has_activity && buckets.len() > 1 {
        let maximum_points = (width.max(1) as usize)
            .saturating_mul(DRAW_POINTS_PER_PIXEL)
            .clamp(2, MAXIMUM_DRAW_POINTS);
        let (plot_values, plot_positions) = bounded_plot_series(
            &prepared.plot_values,
            &prepared.plot_positions,
            maximum_points,
        );
        let segment_count = plot_values.len().saturating_sub(1).max(1);
        let samples_per_segment =
            ((width.max(1) as usize).saturating_mul(2) / segment_count).clamp(1, 12);
        let samples = smoothed_samples(&plot_values, &plot_positions, samples_per_segment);
        context.set_source_rgb(accent.0, accent.1, accent.2);
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
        let (x, y) = point_for(0, buckets, positions, layout, axis_max);
        context.set_source_rgb(accent.0, accent.1, accent.2);
        context.arc(x, y, 3.5, 0.0, std::f64::consts::TAU);
        let _ = context.fill();
    } else {
        context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        context.set_font_size(12.0);
        set_rgba(context, foreground, 0.64);
        draw_centered_text(
            context,
            if data_available {
                "No activity"
            } else {
                "Usage unavailable"
            },
            layout.mid_x(),
            layout.mid_y(),
        );
    }

    if let Some(index) = selected.filter(|index| *index < buckets.len()) {
        draw_selection(
            context,
            layout,
            point_for(index, buckets, positions, layout, axis_max),
            foreground,
            accent,
        );
        draw_tooltip(
            context,
            layout,
            &buckets[index],
            point_for(index, buckets, positions, layout, axis_max),
            foreground,
        );
    }
}

fn draw_trend_line(
    context: &cairo::Context,
    layout: ChartLayout,
    trend: [ChartSample; 2],
    axis_max: i64,
    accent: (f64, f64, f64),
) {
    if context.save().is_err() {
        return;
    }
    context.rectangle(layout.left, layout.top, layout.width(), layout.height());
    context.clip();
    context.set_source_rgba(accent.0, accent.1, accent.2, 0.28);
    context.set_line_width(1.5);
    context.set_line_cap(cairo::LineCap::Round);
    for (index, sample) in trend.iter().enumerate() {
        let x = layout.left + sample.position * layout.width();
        let y = unclamped_y_position(sample.value, layout, axis_max);
        if index == 0 {
            context.move_to(x, y);
        } else {
            context.line_to(x, y);
        }
    }
    let _ = context.stroke();
    let _ = context.restore();
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
    // Prepared positions are validated once when they are built; avoid an
    // O(n) validation scan on every hover-triggered redraw.
    for index in tick_indices_in_valid_positions(positions, policy.maximum_tick_count) {
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
    point: (f64, f64),
    foreground: gdk::RGBA,
    accent: (f64, f64, f64),
) {
    let (x, y) = point;
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
    context.set_source_rgb(accent.0, accent.1, accent.2);
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
        &format!("{} tokens", format_full_tokens(chart_token_value(bucket))),
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
        y_position(chart_token_value(&buckets[index]) as f64, layout, axis_max),
    )
}

fn y_position(value: f64, layout: ChartLayout, axis_max: i64) -> f64 {
    let ratio = (value / axis_max.max(1) as f64).clamp(0.0, 1.0);
    layout.bottom - layout.height() * ratio
}

fn unclamped_y_position(value: f64, layout: ChartLayout, axis_max: i64) -> f64 {
    layout.bottom - layout.height() * value / axis_max.max(1) as f64
}

fn set_rgba(context: &cairo::Context, color: gdk::RGBA, alpha: f64) {
    context.set_source_rgba(
        f64::from(color.red()),
        f64::from(color.green()),
        f64::from(color.blue()),
        alpha,
    );
}

fn chart_accent(foreground: gdk::RGBA, high_contrast: bool) -> (f64, f64, f64) {
    if high_contrast {
        return (
            f64::from(foreground.red()),
            f64::from(foreground.green()),
            f64::from(foreground.blue()),
        );
    }
    // A dark foreground means a light canvas. The brighter macOS mint is
    // excellent on dark backgrounds but too faint against white, so use its
    // darker companion there to keep the data line distinguishable.
    if foreground.red() < 0.5 {
        LIGHT_BACKGROUND_MINT
    } else {
        MINT
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Days, NaiveDate};

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
        render_fixture_with_trend(buckets, timeframe, selected, dark, true)
    }

    fn render_fixture_with_trend(
        buckets: &[DailyUsageBucket],
        timeframe: Timeframe,
        selected: Option<usize>,
        dark: bool,
        include_trend: bool,
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
        draw_chart_with_foreground(
            &context,
            264,
            150,
            buckets,
            timeframe,
            selected,
            foreground,
            include_trend,
        );
        context.status().unwrap();
        drop(context);
        surface.flush();
        surface.data().unwrap().to_vec()
    }

    fn assert_trend(values: &[i64], positions: &[f64], expected: [f64; 2]) {
        let trend = least_squares_trend(values, positions).expect("expected a visible trend");
        assert_eq!(trend[0].position, 0.0);
        assert_eq!(trend[1].position, 1.0);
        for (sample, expected_value) in trend.iter().zip(expected) {
            assert!(
                (sample.value - expected_value).abs() <= 1e-9,
                "expected {expected_value}, got {}",
                sample.value
            );
        }
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
    fn trend_direction_and_magnitude_use_every_visible_value() {
        let positions = [0.0, 0.25, 0.5, 0.75, 1.0];

        assert_trend(&[10, 0, 0, 10, 10], &positions, [4.0, 8.0]);
        assert_trend(&[10, 10, 0, 0, 10], &positions, [8.0, 4.0]);
        assert_trend(&[10, 0, 0, 20, 20], &positions, [2.0, 18.0]);
    }

    #[test]
    fn trend_uses_calendar_positions_and_preserves_a_positive_flat_average() {
        assert_trend(&[10, 20, 60], &[0.0, 0.2, 1.0], [10.0, 60.0]);
        assert_trend(&[42, 42, 42], &[0.0, 0.5, 1.0], [42.0, 42.0]);
    }

    #[test]
    fn trend_is_absent_for_insufficient_or_zero_activity_series() {
        assert_eq!(least_squares_trend(&[], &[]), None);
        assert_eq!(least_squares_trend(&[42], &[0.5]), None);
        assert_eq!(least_squares_trend(&[0, 0], &[0.0, 1.0]), None);
        assert_eq!(least_squares_trend(&[1, 2], &[0.0]), None);
    }

    #[test]
    fn eligible_trend_is_rendered_and_clipped_to_the_plot() {
        let buckets = daily_buckets(5, |day| if day == 4 { 100 } else { 0 });
        let with_trend = render_fixture_with_trend(
            &buckets,
            Timeframe::Seven,
            None,
            false,
            true,
        );
        let without_trend = render_fixture_with_trend(
            &buckets,
            Timeframe::Seven,
            None,
            false,
            false,
        );
        let layout = ChartLayout::new(264.0, 150.0);
        let differing_pixels: Vec<_> = with_trend
            .chunks_exact(4)
            .zip(without_trend.chunks_exact(4))
            .enumerate()
            .filter_map(|(index, (with, without))| (with != without).then_some(index))
            .collect();

        assert!(!differing_pixels.is_empty());
        assert!(differing_pixels.iter().all(|index| {
            let x = (*index % 264) as f64;
            let y = (*index / 264) as f64;
            x >= layout.left.floor()
                && x <= layout.right.ceil()
                && y >= layout.top.floor()
                && y <= layout.bottom.ceil()
        }));

        let zero_activity = daily_buckets(5, |_| 0);
        assert_eq!(
            render_fixture_with_trend(
                &zero_activity,
                Timeframe::Seven,
                None,
                false,
                true,
            ),
            render_fixture_with_trend(
                &zero_activity,
                Timeframe::Seven,
                None,
                false,
                false,
            )
        );
        let single = [bucket("2026-04-11", 42)];
        assert_eq!(
            render_fixture_with_trend(&single, Timeframe::All, None, false, true),
            render_fixture_with_trend(&single, Timeframe::All, None, false, false)
        );
    }

    #[test]
    fn chart_positions_use_calendar_days_and_require_real_endpoints() {
        let buckets = vec![
            bucket("2026-03-07", 1),
            bucket("2026-03-08", 2),
            bucket("2026-03-09", 3),
        ];
        assert_eq!(bucket_positions(&buckets), vec![0.0, 0.5, 1.0]);
        assert!(valid_positions(&[0.0, 0.5, 1.0], 3));
        assert!(!valid_positions(&[0.1, 0.5, 1.0], 3));
        assert!(!valid_positions(&[0.0, 0.5, 0.9], 3));
        assert_eq!(
            bucket_positions(&[
                bucket("2026-03-08", 1),
                bucket("2026-03-07", 2),
                bucket("2026-03-09", 3),
            ]),
            vec![0.0, 0.5, 1.0]
        );
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
    fn plot_bounding_preserves_endpoints_and_each_bins_extrema() {
        let values: Vec<_> = (0..20_000)
            .map(|index| {
                if index == 12_345 {
                    i64::MAX
                } else {
                    (index % 97) as i64
                }
            })
            .collect();
        let positions = evenly_spaced_positions(values.len());
        let (bounded_values, bounded_positions) = bounded_plot_series(&values, &positions, 792);
        assert!(bounded_values.len() <= 792);
        assert_eq!(bounded_values.first(), values.first());
        assert_eq!(bounded_values.last(), values.last());
        assert!(bounded_values.contains(&i64::MAX));
        assert_eq!(bounded_values.len(), bounded_positions.len());
        assert!(valid_positions(&bounded_positions, bounded_positions.len()));

        let (three_values, three_positions) = bounded_plot_series(&values, &positions, 3);
        assert_eq!(three_values.len(), 3);
        assert_eq!(three_values[1], i64::MAX);
        assert!(valid_positions(&three_positions, three_positions.len()));
    }

    #[test]
    fn escape_is_only_consumed_when_a_chart_selection_was_cleared() {
        let mut selection = Selection::default();
        assert!(!selection.clear_for_escape());
        selection.pinned = Some(2);
        selection.suppress_hover_until_reentry = true;
        assert!(selection.clear_for_escape());
        assert_eq!(selection.active(), None);
        assert!(selection.suppress_hover_until_reentry);
        assert!(!selection.clear_for_escape());
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
    fn high_contrast_chart_uses_the_dynamic_theme_foreground() {
        let foreground = gdk::RGBA::new(0.13, 0.57, 0.91, 1.0);
        assert_eq!(
            chart_accent(foreground, true),
            (0.13_f32.into(), 0.57_f32.into(), 0.91_f32.into())
        );
        assert_ne!(
            chart_accent(foreground, false),
            chart_accent(foreground, true)
        );
        assert!(
            !include_str!("chart.rs").contains(concat!("set_tooltip_", "text")),
            "the drawn chart tooltip must not be duplicated by a GTK tooltip"
        );
    }

    #[test]
    fn invalid_dates_and_negative_direct_fixture_values_are_not_exposed() {
        let policy = AxisPolicy::for_timeframe(Timeframe::Thirty, None);
        assert_eq!(
            chart_date_label("\nspoofed", Timeframe::Thirty, policy),
            "Invalid date"
        );
        assert_eq!(tooltip_date("\u{202e}spoofed"), "Invalid date");
        assert_eq!(chart_token_value(&bucket("2026-01-01", -42)), 0);
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
