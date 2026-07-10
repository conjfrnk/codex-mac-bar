use std::f64::consts::{FRAC_PI_2, TAU};
use std::sync::mpsc::Sender;

use gtk::cairo;
use ksni::menu::{CheckmarkItem, RadioGroup, RadioItem, StandardItem};
use ksni::{Icon, MenuItem, Status, ToolTip, Tray};

use crate::range::Timeframe;

#[derive(Clone, Copy, Debug)]
pub enum TrayCommand {
    Toggle { x: i32, y: i32 },
    Show { x: i32, y: i32 },
    Refresh,
    SetTimeframe(Timeframe),
    SetAutostart(bool),
    Quit,
}

pub struct UsageTray {
    pub commands: Sender<TrayCommand>,
    pub timeframe: Timeframe,
    pub autostart: bool,
    pub status_line: String,
    pub status_value: String,
    pub description: String,
    pub has_error: bool,
}

impl UsageTray {
    pub fn new(commands: Sender<TrayCommand>, timeframe: Timeframe, autostart: bool) -> Self {
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
        let _ = self.commands.send(command);
    }
}

impl Tray for UsageTray {
    fn id(&self) -> String {
        "codex-usage-bar".into()
    }

    fn title(&self) -> String {
        format!("Codex — {}", self.status_line)
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
        ToolTip {
            icon_pixmap: self.icon_pixmap(),
            title: "Codex Usage Bar".into(),
            description: format!("{}\n{}", self.status_line, self.description),
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
        let status_line = self.status_line.clone();
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
    render_status_icon_cairo(size, value, attention)
        .unwrap_or_else(|| render_status_icon_bitmap(size, value, attention))
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

    context.set_line_width(ring_width);
    context.set_line_cap(cairo::LineCap::Round);
    context.set_source_rgba(1.0, 1.0, 1.0, 0.35);
    context.arc(center, center, ring_radius, 0.0, TAU);
    let _ = context.stroke();

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
    context.set_source_rgb(1.0, 1.0, 1.0);
    context.set_line_width(side * (1.5 / 18.0));
    context.set_line_join(cairo::LineJoin::Round);
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
}
