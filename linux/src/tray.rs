use std::collections::VecDeque;
use std::f64::consts::{FRAC_PI_2, TAU};
use std::sync::{Arc, Mutex, MutexGuard};

use gtk::cairo;
use ksni::menu::{CheckmarkItem, RadioGroup, RadioItem, StandardItem};
use ksni::{Icon, MenuItem, Status, ToolTip, Tray};

use crate::range::Timeframe;

const MAX_PENDING_WINDOW_COMMANDS: usize = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrayCommand {
    Toggle { x: i32, y: i32 },
    Show { x: i32, y: i32 },
    Refresh,
    SetTimeframe(Timeframe),
    SetAutostart(bool),
    Quit,
}

#[derive(Default)]
struct TrayMailboxState {
    transient_commands: VecDeque<TrayCommand>,
    refresh_pending: bool,
    latest_timeframe: Option<Timeframe>,
    latest_autostart: Option<bool>,
    quit_pending: bool,
}

#[derive(Clone)]
pub struct TrayMailboxSender {
    state: Arc<Mutex<TrayMailboxState>>,
}

pub struct TrayMailboxReceiver {
    state: Arc<Mutex<TrayMailboxState>>,
}

pub fn tray_mailbox() -> (TrayMailboxSender, TrayMailboxReceiver) {
    let state = Arc::new(Mutex::new(TrayMailboxState::default()));
    (
        TrayMailboxSender {
            state: Arc::clone(&state),
        },
        TrayMailboxReceiver { state },
    )
}

fn mailbox_state(state: &Mutex<TrayMailboxState>) -> MutexGuard<'_, TrayMailboxState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl TrayMailboxSender {
    pub fn send(&self, command: TrayCommand) {
        let mut state = mailbox_state(&self.state);
        match command {
            TrayCommand::Quit => state.quit_pending = true,
            TrayCommand::Refresh => state.refresh_pending = true,
            TrayCommand::SetTimeframe(timeframe) => state.latest_timeframe = Some(timeframe),
            TrayCommand::SetAutostart(enabled) => state.latest_autostart = Some(enabled),
            command @ (TrayCommand::Toggle { .. } | TrayCommand::Show { .. }) => {
                coalesce_window_command(&mut state.transient_commands, command);
            }
        }
    }
}

fn coalesce_window_command(commands: &mut VecDeque<TrayCommand>, command: TrayCommand) {
    debug_assert!(matches!(
        command,
        TrayCommand::Toggle { .. } | TrayCommand::Show { .. }
    ));
    let mut sequence: Vec<_> = commands.drain(..).collect();
    sequence.push(command);

    if let Some(show_index) = sequence
        .iter()
        .rposition(|command| matches!(command, TrayCommand::Show { .. }))
    {
        let TrayCommand::Show { x, y } = sequence[show_index] else {
            unreachable!();
        };
        let mut visible = true;
        let mut last_present = (x, y);
        let mut last_toggle = None;
        for command in &sequence[show_index + 1..] {
            let TrayCommand::Toggle { x, y } = *command else {
                unreachable!("the final Show supersedes every earlier Show")
            };
            visible = !visible;
            last_toggle = Some((x, y));
            if visible {
                last_present = (x, y);
            }
        }
        commands.push_back(TrayCommand::Show {
            x: last_present.0,
            y: last_present.1,
        });
        if !visible {
            let (x, y) = last_toggle.expect("a forced-hidden state has a closing Toggle");
            commands.push_back(TrayCommand::Toggle { x, y });
        }
    } else if sequence.len() % 2 == 1 {
        commands.push_back(
            *sequence
                .last()
                .expect("the new command makes this nonempty"),
        );
    } else {
        // Two toggles preserve identity for either initial visibility while
        // retaining the last reopening anchor when the window started visible.
        commands.extend(sequence[sequence.len() - 2..].iter().copied());
    }
    debug_assert!(commands.len() <= MAX_PENDING_WINDOW_COMMANDS);
}

impl TrayMailboxReceiver {
    pub fn take_pending(&self, maximum: usize) -> Vec<TrayCommand> {
        if maximum == 0 {
            return Vec::new();
        }
        let mut state = mailbox_state(&self.state);
        if state.quit_pending {
            state.quit_pending = false;
            state.refresh_pending = false;
            state.latest_timeframe = None;
            state.latest_autostart = None;
            state.transient_commands.clear();
            return vec![TrayCommand::Quit];
        }

        let mut commands = Vec::with_capacity(maximum.min(4));
        if let Some(timeframe) = state.latest_timeframe.take() {
            commands.push(TrayCommand::SetTimeframe(timeframe));
        }
        if commands.len() < maximum
            && let Some(enabled) = state.latest_autostart.take()
        {
            commands.push(TrayCommand::SetAutostart(enabled));
        }
        if commands.len() < maximum && std::mem::take(&mut state.refresh_pending) {
            commands.push(TrayCommand::Refresh);
        }
        while commands.len() < maximum {
            let Some(command) = state.transient_commands.pop_front() else {
                break;
            };
            commands.push(command);
        }
        commands
    }

    #[cfg(test)]
    fn pending_transient_count(&self) -> usize {
        mailbox_state(&self.state).transient_commands.len()
    }
}

pub struct UsageTray {
    pub commands: TrayMailboxSender,
    pub timeframe: Timeframe,
    pub autostart: bool,
    pub status_line: String,
    pub status_value: String,
    pub description: String,
    pub has_error: bool,
}

impl UsageTray {
    pub fn new(commands: TrayMailboxSender, timeframe: Timeframe, autostart: bool) -> Self {
        Self {
            commands,
            timeframe,
            autostart,
            status_line: "Loading usage…".into(),
            status_value: "Codex ...".into(),
            description: "Fetching account-wide Codex usage".into(),
            has_error: false,
        }
    }

    fn send(&self, command: TrayCommand) {
        self.commands.send(command);
    }
}

impl Tray for UsageTray {
    fn id(&self) -> String {
        "codex-usage-bar".into()
    }

    fn title(&self) -> String {
        format!("Codex — {}", sanitize_tray_text(&self.status_line, 140))
    }

    fn status(&self) -> Status {
        if self.has_error {
            Status::NeedsAttention
        } else {
            Status::Active
        }
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        [22, 32, 48]
            .into_iter()
            .map(|size| render_status_icon(size, &self.status_value, false))
            .collect()
    }

    fn attention_icon_pixmap(&self) -> Vec<Icon> {
        [22, 32, 48]
            .into_iter()
            .map(|size| render_status_icon(size, &self.status_value, true))
            .collect()
    }

    fn tool_tip(&self) -> ToolTip {
        let status_line = sanitize_tray_text(&self.status_line, 140);
        let description = sanitize_tray_text(&self.description, 240);
        ToolTip {
            icon_pixmap: self.icon_pixmap(),
            title: "Codex Usage Bar".into(),
            description: format!("{status_line}\n{description}"),
            ..Default::default()
        }
    }

    fn activate(&mut self, x: i32, y: i32) {
        self.send(TrayCommand::Toggle { x, y });
    }

    fn secondary_activate(&mut self, _x: i32, _y: i32) {
        self.send(TrayCommand::Refresh);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let status_line = sanitize_tray_text(&self.status_line, 140);
        vec![
            StandardItem {
                label: status_line,
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Open Usage".into(),
                icon_name: "view-statistics-symbolic".into(),
                activate: Box::new(|tray: &mut UsageTray| {
                    tray.send(TrayCommand::Show { x: 0, y: 0 })
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Refresh".into(),
                icon_name: "view-refresh-symbolic".into(),
                activate: Box::new(|tray: &mut UsageTray| tray.send(TrayCommand::Refresh)),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            RadioGroup {
                selected: timeframe_index(self.timeframe),
                select: Box::new(|tray: &mut UsageTray, index| {
                    if let Some(timeframe) = Timeframe::ALL.get(index).copied() {
                        tray.timeframe = timeframe;
                        tray.send(TrayCommand::SetTimeframe(timeframe));
                    }
                }),
                options: Timeframe::ALL
                    .into_iter()
                    .map(|timeframe| RadioItem {
                        label: timeframe.short_title().into(),
                        ..Default::default()
                    })
                    .collect(),
            }
            .into(),
            MenuItem::Separator,
            CheckmarkItem {
                label: "Open at Login".into(),
                checked: self.autostart,
                activate: Box::new(|tray: &mut UsageTray| {
                    tray.autostart = !tray.autostart;
                    tray.send(TrayCommand::SetAutostart(tray.autostart));
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Quit".into(),
                icon_name: "application-exit-symbolic".into(),
                activate: Box::new(|tray: &mut UsageTray| tray.send(TrayCommand::Quit)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

pub fn timeframe_index(timeframe: Timeframe) -> usize {
    Timeframe::ALL
        .iter()
        .position(|candidate| *candidate == timeframe)
        .unwrap_or(1)
}

#[cfg(test)]
fn render_icon(size: i32) -> Icon {
    render_status_icon(size, "", false)
}

fn render_status_icon(size: i32, value: &str, attention: bool) -> Icon {
    let size = size.clamp(1, 256);
    let value = sanitize_tray_text(value, 16);
    render_status_icon_cairo(size, &value, attention)
        .unwrap_or_else(|| render_status_icon_bitmap(size, &value, attention))
}

fn sanitize_tray_text(value: &str, maximum: usize) -> String {
    if maximum == 0 {
        return String::new();
    }
    let mut result = String::new();
    let mut character_count = 0;
    let mut pending_space = false;
    for character in value.chars() {
        if character.is_whitespace() {
            pending_space = !result.is_empty();
            continue;
        }
        if unsafe_tray_character(character) {
            continue;
        }
        if pending_space {
            if character_count == maximum {
                break;
            }
            result.push(' ');
            character_count += 1;
            pending_space = false;
        }
        if character_count == maximum {
            break;
        }
        result.push(character);
        character_count += 1;
    }
    result
}

fn unsafe_tray_character(character: char) -> bool {
    character.is_control()
        || matches!(
            character,
            '\u{00ad}'
                | '\u{034f}'
                | '\u{061c}'
                | '\u{115f}'
                | '\u{1160}'
                | '\u{17b4}'
                | '\u{17b5}'
                | '\u{180b}'..='\u{180f}'
                | '\u{200b}'..='\u{200f}'
                | '\u{202a}'..='\u{202e}'
                | '\u{2060}'..='\u{206f}'
                | '\u{3164}'
                | '\u{feff}'
                | '\u{ffa0}'
                | '\u{fff9}'..='\u{fffb}'
                | '\u{e0001}'
                | '\u{e0020}'..='\u{e007f}'
        )
}

fn render_status_icon_cairo(size: i32, value: &str, attention: bool) -> Option<Icon> {
    let measurement_surface = cairo::ImageSurface::create(cairo::Format::ARgb32, 1, 1).ok()?;
    let measurement = cairo::Context::new(&measurement_surface).ok()?;
    measurement.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    measurement.set_font_size(f64::from(size) * 0.64);
    let text_extents = measurement.text_extents(value).ok()?;
    let gap = if value.is_empty() {
        0.0
    } else {
        (f64::from(size) * 0.16).max(3.0)
    };
    let text_width = if value.is_empty() {
        0.0
    } else {
        text_extents.x_advance().max(text_extents.width()) + 3.0
    };
    let width = (f64::from(size) + gap + text_width).ceil() as i32;
    let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, width, size).ok()?;
    let context = cairo::Context::new(&surface).ok()?;
    let side = f64::from(size);
    let center = side / 2.0;
    let ring_width = side * (2.8 / 18.0);
    let ring_radius = side * (6.2 / 18.0);

    // StatusNotifier pixmaps cannot assume a dark panel. A compact dark halo
    // keeps the otherwise white gauge legible on both light and dark panels.
    context.set_line_width(ring_width + (side * 0.08).max(1.0));
    context.set_line_cap(cairo::LineCap::Round);
    context.set_source_rgba(0.0, 0.0, 0.0, 0.72);
    context.arc(center, center, ring_radius, 0.0, TAU);
    let _ = context.stroke();

    context.set_line_width(ring_width);
    context.set_source_rgba(1.0, 1.0, 1.0, 0.35);
    context.arc(center, center, ring_radius, 0.0, TAU);
    let _ = context.stroke();

    context.set_line_width(ring_width + (side * 0.08).max(1.0));
    context.set_source_rgba(0.0, 0.0, 0.0, 0.82);
    context.arc(
        center,
        center,
        ring_radius,
        -FRAC_PI_2,
        -FRAC_PI_2 + TAU * 0.73,
    );
    let _ = context.stroke();
    context.set_line_width(ring_width);
    if attention {
        context.set_source_rgb(0.92, 0.35, 0.27);
    } else {
        context.set_source_rgb(1.0, 1.0, 1.0);
    }
    context.arc(
        center,
        center,
        ring_radius,
        -FRAC_PI_2,
        -FRAC_PI_2 + TAU * 0.73,
    );
    let _ = context.stroke();

    let chevron_height = side * (3.6 / 18.0);
    let chevron_reach = side * (2.0 / 18.0);
    let chevron_center = center - side * (0.3 / 18.0);
    context.set_line_join(cairo::LineJoin::Round);
    context.set_source_rgba(0.0, 0.0, 0.0, 0.82);
    context.set_line_width(side * (1.5 / 18.0) + (side * 0.08).max(1.0));
    context.move_to(
        chevron_center - chevron_reach / 2.0,
        center - chevron_height / 2.0,
    );
    context.line_to(chevron_center + chevron_reach / 2.0, center);
    context.line_to(
        chevron_center - chevron_reach / 2.0,
        center + chevron_height / 2.0,
    );
    let _ = context.stroke();
    context.set_source_rgb(1.0, 1.0, 1.0);
    context.set_line_width(side * (1.5 / 18.0));
    context.move_to(
        chevron_center - chevron_reach / 2.0,
        center - chevron_height / 2.0,
    );
    context.line_to(chevron_center + chevron_reach / 2.0, center);
    context.line_to(
        chevron_center - chevron_reach / 2.0,
        center + chevron_height / 2.0,
    );
    let _ = context.stroke();

    if !value.is_empty() {
        context.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        context.set_font_size(side * 0.64);
        let extents = context.text_extents(value).ok()?;
        let x = side + gap;
        let baseline = (side - extents.height()) / 2.0 - extents.y_bearing();
        context.move_to(x, baseline);
        context.text_path(value);
        context.set_source_rgba(0.0, 0.0, 0.0, 0.82);
        context.set_line_width((side * 0.075).max(1.0));
        context.set_line_join(cairo::LineJoin::Round);
        let _ = context.stroke_preserve();
        context.set_source_rgb(1.0, 1.0, 1.0);
        let _ = context.fill();
    }

    drop(context);
    surface.flush();
    let stride = surface.stride() as usize;
    let pixels = surface.data().ok()?;
    let mut data = Vec::with_capacity((width * size * 4) as usize);
    for y in 0..size as usize {
        for x in 0..width as usize {
            let index = y * stride + x * 4;
            let pixel = u32::from_ne_bytes(pixels[index..index + 4].try_into().ok()?);
            data.extend_from_slice(&pixel.to_be_bytes());
        }
    }
    drop(pixels);
    Some(Icon {
        width,
        height: size,
        data,
    })
}

fn render_status_icon_bitmap(size: i32, value: &str, attention: bool) -> Icon {
    let scale = (size / 7).max(1);
    let glyph_width = bitmap_text_width(value, scale);
    let gap = if value.is_empty() {
        0
    } else {
        (size / 7).max(3)
    };
    let width = size + gap + glyph_width;
    let mut data = vec![0_u8; (width * size * 4) as usize];

    render_gauge_pixels(&mut data, width, size, attention);
    if !value.is_empty() {
        let text_y = (size - 5 * scale) / 2;
        draw_bitmap_text(&mut data, width, size, size + gap, text_y, value, scale);
    }

    Icon {
        width,
        height: size,
        data,
    }
}

fn render_gauge_pixels(data: &mut [u8], canvas_width: i32, size: i32, attention: bool) {
    let side = size as f64;
    let center = (side - 1.0) / 2.0;
    let radius = side * 0.34;
    let ring_half_width = (side * 0.075).max(1.0);
    for y in 0..size {
        for x in 0..size {
            let dx = x as f64 - center;
            let dy = y as f64 - center;
            let distance = dx.hypot(dy);
            let on_ring = (distance - radius).abs() <= ring_half_width;
            let near_ring = (distance - radius).abs() <= ring_half_width + 1.0;
            let angle = (dy.atan2(dx) + FRAC_PI_2).rem_euclid(TAU);
            let in_progress = angle <= TAU * 0.73;

            let chevron_width = side * 0.18;
            let chevron_height = side * 0.22;
            let shifted_x = dx + side * 0.035;
            let chevron_distance = if shifted_x.abs() <= chevron_width {
                (dy.abs() - (shifted_x + chevron_width) * chevron_height / (2.0 * chevron_width))
                    .abs()
            } else {
                f64::MAX
            };
            let on_chevron = shifted_x >= -chevron_width
                && shifted_x <= chevron_width * 0.35
                && chevron_distance <= (side * 0.045).max(1.0);
            let near_chevron = shifted_x >= -chevron_width - 1.0
                && shifted_x <= chevron_width * 0.35 + 1.0
                && chevron_distance <= (side * 0.045).max(1.0) + 1.0;

            let color = if on_chevron {
                Some((255, 255, 255, 255))
            } else if on_ring && in_progress {
                if attention {
                    Some((255, 235, 90, 70))
                } else {
                    Some((255, 255, 255, 255))
                }
            } else if on_ring {
                Some((90, 255, 255, 255))
            } else if near_chevron || near_ring {
                Some((190, 0, 0, 0))
            } else {
                None
            };

            if let Some((alpha, red, green, blue)) = color {
                let index = ((y * canvas_width + x) * 4) as usize;
                data[index..index + 4].copy_from_slice(&[alpha, red, green, blue]);
            }
        }
    }
}

fn bitmap_text_width(value: &str, scale: i32) -> i32 {
    let mut width = 0;
    for (index, character) in value.chars().enumerate() {
        if index > 0 {
            width += scale;
        }
        width += i32::from(bitmap_glyph(character).0) * scale;
    }
    width
}

fn draw_bitmap_text(
    data: &mut [u8],
    width: i32,
    height: i32,
    mut x: i32,
    y: i32,
    value: &str,
    scale: i32,
) {
    for character in value.chars() {
        let (glyph_width, rows) = bitmap_glyph(character);
        for (row, bits) in rows.into_iter().enumerate() {
            for column in 0..glyph_width {
                let mask = 1 << (glyph_width - column - 1);
                if bits & mask == 0 {
                    continue;
                }
                let pixel_x = x + i32::from(column) * scale;
                let pixel_y = y + row as i32 * scale;
                for offset_y in -1..=scale {
                    for offset_x in -1..=scale {
                        set_argb_pixel(
                            data,
                            width,
                            height,
                            pixel_x + offset_x,
                            pixel_y + offset_y,
                            [190, 0, 0, 0],
                        );
                    }
                }
                for fill_y in 0..scale {
                    for fill_x in 0..scale {
                        set_argb_pixel(
                            data,
                            width,
                            height,
                            pixel_x + fill_x,
                            pixel_y + fill_y,
                            [255, 255, 255, 255],
                        );
                    }
                }
            }
        }
        x += i32::from(glyph_width) * scale + scale;
    }
}

fn set_argb_pixel(data: &mut [u8], width: i32, height: i32, x: i32, y: i32, color: [u8; 4]) {
    if x < 0 || y < 0 || x >= width || y >= height {
        return;
    }
    let index = ((y * width + x) * 4) as usize;
    if color[0] >= data[index] {
        data[index..index + 4].copy_from_slice(&color);
    }
}

fn bitmap_glyph(character: char) -> (u8, [u8; 5]) {
    match character.to_ascii_uppercase() {
        '0' => (3, [0b111, 0b101, 0b101, 0b101, 0b111]),
        '1' => (3, [0b010, 0b110, 0b010, 0b010, 0b111]),
        '2' => (3, [0b111, 0b001, 0b111, 0b100, 0b111]),
        '3' => (3, [0b111, 0b001, 0b111, 0b001, 0b111]),
        '4' => (3, [0b101, 0b101, 0b111, 0b001, 0b001]),
        '5' => (3, [0b111, 0b100, 0b111, 0b001, 0b111]),
        '6' => (3, [0b111, 0b100, 0b111, 0b101, 0b111]),
        '7' => (3, [0b111, 0b001, 0b010, 0b010, 0b010]),
        '8' => (3, [0b111, 0b101, 0b111, 0b101, 0b111]),
        '9' => (3, [0b111, 0b101, 0b111, 0b001, 0b111]),
        'K' => (3, [0b101, 0b101, 0b110, 0b101, 0b101]),
        'M' => (5, [0b10001, 0b11011, 0b10101, 0b10001, 0b10001]),
        'B' => (3, [0b110, 0b101, 0b110, 0b101, 0b110]),
        'T' => (3, [0b111, 0b010, 0b010, 0b010, 0b010]),
        'C' => (3, [0b111, 0b100, 0b100, 0b100, 0b111]),
        'O' => (3, [0b111, 0b101, 0b101, 0b101, 0b111]),
        'D' => (3, [0b110, 0b101, 0b101, 0b101, 0b110]),
        'E' => (3, [0b111, 0b100, 0b110, 0b100, 0b111]),
        'X' => (3, [0b101, 0b101, 0b010, 0b101, 0b101]),
        '?' => (3, [0b111, 0b001, 0b011, 0b000, 0b010]),
        '-' => (3, [0b000, 0b000, 0b111, 0b000, 0b000]),
        '.' => (1, [0b0, 0b0, 0b0, 0b0, 0b1]),
        ' ' => (2, [0b0, 0b0, 0b0, 0b0, 0b0]),
        _ => (3, [0b111, 0b101, 0b101, 0b101, 0b111]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icon_has_argb_data_for_every_pixel() {
        let icon = render_icon(32);
        assert_eq!(icon.data.len(), 32 * 32 * 4);
        assert!(icon.data.chunks_exact(4).any(|pixel| pixel[0] > 0));
    }

    #[test]
    fn status_icon_contains_the_compact_total_beside_the_gauge() {
        let icon = render_status_icon(22, "12.2M", false);
        assert_eq!(icon.height, 22);
        assert!(icon.width > icon.height);
        assert_eq!(icon.data.len(), (icon.width * icon.height * 4) as usize);
        assert!(icon.data.chunks_exact(4).any(|pixel| pixel == [255; 4]));
    }

    #[test]
    fn native_status_icon_uses_antialiased_cairo_text_when_available() {
        let icon = render_status_icon_cairo(22, "12.2M", false).unwrap();
        assert!(icon.width > icon.height);
        assert!(
            icon.data
                .chunks_exact(4)
                .any(|pixel| pixel[0] > 0 && pixel[0] < u8::MAX)
        );
    }

    #[test]
    fn maps_timeframes_to_radio_indices() {
        assert_eq!(timeframe_index(Timeframe::Seven), 0);
        assert_eq!(timeframe_index(Timeframe::All), 3);
    }

    #[test]
    fn tray_text_and_icon_dimensions_are_bounded_and_single_line() {
        assert_eq!(
            sanitize_tray_text("failed\n\u{001b}[31m now\u{202e}", 140),
            "failed [31m now"
        );
        assert_eq!(sanitize_tray_text("abcdef", 3), "abc");
        let icon = render_status_icon(-40, &"9".repeat(10_000), false);
        assert_eq!(icon.height, 1);
        assert!(icon.width <= 256);

        let (sender, _receiver) = tray_mailbox();
        let mut tray = UsageTray::new(sender, Timeframe::Thirty, false);
        tray.status_line = "status\nspoofed".into();
        tray.description = "detail\u{202e}\nline".into();
        assert!(!tray.title().contains('\n'));
        let tooltip = tray.tool_tip();
        assert_eq!(tooltip.description.matches('\n').count(), 1);
    }

    #[test]
    fn tray_mailbox_is_bounded_and_coalesces_latest_state() {
        let (sender, receiver) = tray_mailbox();
        sender.send(TrayCommand::SetTimeframe(Timeframe::Seven));
        sender.send(TrayCommand::SetTimeframe(Timeframe::All));
        sender.send(TrayCommand::SetAutostart(false));
        sender.send(TrayCommand::SetAutostart(true));
        sender.send(TrayCommand::Refresh);
        sender.send(TrayCommand::Refresh);
        for coordinate in 0..10_000 {
            sender.send(TrayCommand::Toggle {
                x: coordinate,
                y: coordinate,
            });
        }

        assert_eq!(
            receiver.pending_transient_count(),
            MAX_PENDING_WINDOW_COMMANDS
        );
        let first = receiver.take_pending(4);
        assert_eq!(first[0], TrayCommand::SetTimeframe(Timeframe::All));
        assert_eq!(first[1], TrayCommand::SetAutostart(true));
        assert_eq!(first[2], TrayCommand::Refresh);
        assert!(matches!(first[3], TrayCommand::Toggle { .. }));
        assert!(receiver.take_pending(4).len() <= 4);
    }

    #[test]
    fn tray_mailbox_preserves_toggle_parity_beyond_its_bound() {
        let (sender, receiver) = tray_mailbox();
        for coordinate in 0..33 {
            sender.send(TrayCommand::Toggle {
                x: coordinate,
                y: -coordinate,
            });
        }
        assert_eq!(receiver.pending_transient_count(), 1);
        assert_eq!(
            receiver.take_pending(32),
            vec![TrayCommand::Toggle { x: 32, y: -32 }]
        );

        for coordinate in 0..34 {
            sender.send(TrayCommand::Toggle {
                x: coordinate,
                y: coordinate,
            });
        }
        assert_eq!(receiver.pending_transient_count(), 2);
        assert_eq!(
            receiver.take_pending(32),
            vec![
                TrayCommand::Toggle { x: 32, y: 32 },
                TrayCommand::Toggle { x: 33, y: 33 },
            ]
        );
    }

    #[test]
    fn tray_mailbox_coalesces_show_and_toggle_without_losing_final_state() {
        let (sender, receiver) = tray_mailbox();
        sender.send(TrayCommand::Toggle { x: 1, y: 1 });
        sender.send(TrayCommand::Show { x: 10, y: 20 });
        sender.send(TrayCommand::Toggle { x: 30, y: 40 });
        assert_eq!(
            receiver.take_pending(32),
            vec![
                TrayCommand::Show { x: 10, y: 20 },
                TrayCommand::Toggle { x: 30, y: 40 },
            ]
        );

        sender.send(TrayCommand::Show { x: 10, y: 20 });
        sender.send(TrayCommand::Toggle { x: 30, y: 40 });
        sender.send(TrayCommand::Toggle { x: 50, y: 60 });
        assert_eq!(
            receiver.take_pending(32),
            vec![TrayCommand::Show { x: 50, y: 60 }]
        );

        sender.send(TrayCommand::Show { x: 70, y: 80 });
        sender.send(TrayCommand::Toggle { x: 90, y: 100 });
        assert_eq!(
            receiver.take_pending(1),
            vec![TrayCommand::Show { x: 70, y: 80 }]
        );
        sender.send(TrayCommand::Toggle { x: 110, y: 120 });
        assert_eq!(
            receiver.take_pending(32),
            vec![
                TrayCommand::Toggle { x: 90, y: 100 },
                TrayCommand::Toggle { x: 110, y: 120 },
            ]
        );
    }

    #[test]
    fn every_short_show_toggle_sequence_reduces_to_the_same_outcome() {
        fn outcome(
            commands: &[TrayCommand],
            initially_visible: bool,
        ) -> (bool, Option<(i32, i32)>) {
            let mut visible = initially_visible;
            let mut last_present = None;
            for command in commands {
                match *command {
                    TrayCommand::Show { x, y } => {
                        visible = true;
                        last_present = Some((x, y));
                    }
                    TrayCommand::Toggle { x, y } => {
                        visible = !visible;
                        if visible {
                            last_present = Some((x, y));
                        }
                    }
                    _ => unreachable!(),
                }
            }
            (visible, visible.then_some(last_present).flatten())
        }

        for length in 1..=10 {
            for mask in 0_u16..(1_u16 << length) {
                let original: Vec<_> = (0..length)
                    .map(|index| {
                        if mask & (1 << index) == 0 {
                            TrayCommand::Toggle {
                                x: index,
                                y: -index,
                            }
                        } else {
                            TrayCommand::Show {
                                x: index,
                                y: -index,
                            }
                        }
                    })
                    .collect();
                let mut reduced = VecDeque::new();
                for command in &original {
                    coalesce_window_command(&mut reduced, *command);
                    assert!(reduced.len() <= MAX_PENDING_WINDOW_COMMANDS);
                }
                let reduced: Vec<_> = reduced.into_iter().collect();
                for initially_visible in [false, true] {
                    assert_eq!(
                        outcome(&reduced, initially_visible),
                        outcome(&original, initially_visible),
                        "length={length} mask={mask:#x} initial={initially_visible} reduced={reduced:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn tray_mailbox_never_loses_quit() {
        let (sender, receiver) = tray_mailbox();
        for coordinate in 0..10_000 {
            sender.send(TrayCommand::Show {
                x: coordinate,
                y: coordinate,
            });
        }
        sender.send(TrayCommand::SetTimeframe(Timeframe::Ninety));
        sender.send(TrayCommand::Quit);
        sender.send(TrayCommand::Refresh);

        assert_eq!(receiver.take_pending(1), vec![TrayCommand::Quit]);
        assert!(receiver.take_pending(64).is_empty());
    }
}
