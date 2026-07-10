use std::cell::{Cell, RefCell};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use chrono::Local;
use gtk::cairo;
use gtk::gdk;
use gtk::glib::{self, ControlFlow, Propagation};
use gtk::prelude::*;
use gtk::{Align, Orientation};
use ksni::blocking::{Handle as TrayHandle, TrayMethods};

use crate::app_server;
use crate::autostart;
use crate::chart::usage_chart;
use crate::config::Preferences;
use crate::model::{DailyUsageBucket, RateLimitWindow, UsageSnapshot};
use crate::range::{Timeframe, UsageRange, format_full_tokens, format_tokens};
use crate::tray::{TrayCommand, UsageTray};

const REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
const POPOVER_WIDTH: i32 = 300;
const POPOVER_HEIGHT: i32 = 560;

enum WorkerEvent {
    Refreshed(Result<UsageSnapshot, String>),
}

pub struct UiController {
    application: gtk::Application,
    window: gtk::ApplicationWindow,
    scroller: gtk::ScrolledWindow,
    content: gtk::Box,
    snapshot: RefCell<Option<UsageSnapshot>>,
    last_error: RefCell<Option<String>>,
    status_note: RefCell<Option<String>>,
    timeframe: Cell<Timeframe>,
    history_page: Cell<usize>,
    refreshing: Cell<bool>,
    worker_sender: Sender<WorkerEvent>,
    worker_receiver: RefCell<Receiver<WorkerEvent>>,
    tray_receiver: RefCell<Receiver<TrayCommand>>,
    tray_handle: RefCell<Option<TrayHandle<UsageTray>>>,
    viewport_width: i32,
    viewport_height: i32,
}

impl UiController {
    pub fn new(application: &gtk::Application, tray_enabled: bool) -> Rc<Self> {
        Self::build(
            application,
            tray_enabled,
            Preferences::load().timeframe,
            None,
            true,
            (POPOVER_WIDTH, POPOVER_HEIGHT),
        )
    }

    pub fn with_snapshot(
        application: &gtk::Application,
        snapshot: UsageSnapshot,
        timeframe: Timeframe,
        width: i32,
        height: i32,
    ) -> Rc<Self> {
        Self::build(
            application,
            false,
            timeframe,
            Some(snapshot),
            false,
            (width, height),
        )
    }

    fn build(
        application: &gtk::Application,
        tray_enabled: bool,
        timeframe: Timeframe,
        snapshot: Option<UsageSnapshot>,
        live: bool,
        (viewport_width, viewport_height): (i32, i32),
    ) -> Rc<Self> {
        install_css();

        let (worker_sender, worker_receiver) = mpsc::channel();
        let (tray_sender, tray_receiver) = mpsc::channel();

        let tray_handle = if tray_enabled {
            let tray = UsageTray::new(tray_sender, timeframe, autostart::is_enabled());
            match tray.assume_sni_available(true).spawn() {
                Ok(handle) => Some(handle),
                Err(error) => {
                    eprintln!("codex-usage-bar: could not start system tray: {error}");
                    None
                }
            }
        } else {
            None
        };

        let window = gtk::ApplicationWindow::builder()
            .application(application)
            .title("Codex Usage Bar")
            .default_width(viewport_width)
            .default_height(viewport_height)
            .build();
        window.set_icon_name(Some("codex-usage-bar"));
        window.set_decorated(false);
        window.set_resizable(false);
        window.add_css_class("codex-window");
        update_window_palette(&window);
        if let Some(settings) = gtk::Settings::default() {
            let weak_window = window.downgrade();
            settings.connect_gtk_application_prefer_dark_theme_notify(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    update_window_palette(&window);
                }
            });
        }

        let content = gtk::Box::new(Orientation::Vertical, 0);
        content.add_css_class("content");
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            // External keeps the indicator hidden like macOS while still constraining the
            // viewport, so wheel, touchpad, touch, and keyboard scrolling remain functional.
            .vscrollbar_policy(gtk::PolicyType::External)
            .min_content_width(1)
            .min_content_height(1)
            .propagate_natural_width(false)
            .propagate_natural_height(false)
            .child(&content)
            .build();
        window.set_child(Some(&scroller));

        let controller = Rc::new(Self {
            application: application.clone(),
            window,
            scroller,
            content,
            snapshot: RefCell::new(snapshot),
            last_error: RefCell::new(None),
            status_note: RefCell::new(None),
            timeframe: Cell::new(timeframe),
            history_page: Cell::new(0),
            refreshing: Cell::new(false),
            worker_sender,
            worker_receiver: RefCell::new(worker_receiver),
            tray_receiver: RefCell::new(tray_receiver),
            tray_handle: RefCell::new(tray_handle),
            viewport_width,
            viewport_height,
        });

        if live {
            controller.connect_window();
            controller.install_poll();
            controller.install_auto_refresh();
        }
        controller.render();
        if live {
            controller.start_refresh();
        }
        controller
    }

    pub fn present_for_render(&self) {
        self.window.present();
    }

    pub fn render_to_png(&self, path: &std::path::Path) -> Result<(), String> {
        while glib::MainContext::default().iteration(false) {}
        let paintable = gtk::WidgetPaintable::new(Some(&self.window));
        let snapshot = gtk::Snapshot::new();
        paintable.snapshot(
            &snapshot,
            f64::from(self.viewport_width),
            f64::from(self.viewport_height),
        );
        let node = snapshot
            .to_node()
            .ok_or_else(|| "Popover produced no render node".to_string())?;
        let renderer = self
            .window
            .renderer()
            .ok_or_else(|| "Popover has no GSK renderer".to_string())?;
        let viewport = gtk::graphene::Rect::new(
            0.0,
            0.0,
            self.viewport_width as f32,
            self.viewport_height as f32,
        );
        let texture = renderer.render_texture(&node, Some(&viewport));
        if texture.width() != self.viewport_width || texture.height() != self.viewport_height {
            return Err(format!(
                "Popover texture was {}x{}, expected {}x{}",
                texture.width(),
                texture.height(),
                self.viewport_width,
                self.viewport_height
            ));
        }
        let mut downloader = gdk::TextureDownloader::new(&texture);
        downloader.set_format(gdk::MemoryFormat::R8g8b8a8);
        let (pixels, stride) = downloader.download_bytes();
        let pixels = pixels.as_ref();
        for y in 0..self.viewport_height as usize {
            for x in 0..self.viewport_width as usize {
                if pixels[y * stride + x * 4 + 3] != u8::MAX {
                    return Err(format!("Popover contains a transparent pixel at {x},{y}"));
                }
            }
        }
        texture
            .save_to_png(path)
            .map_err(|error| error.to_string())?;
        let bytes = std::fs::metadata(path)
            .map_err(|error| error.to_string())?
            .len();
        if bytes <= 10_000 {
            return Err(format!(
                "Popover PNG was unexpectedly small ({bytes} bytes)"
            ));
        }
        if self.viewport_height <= POPOVER_HEIGHT {
            let adjustment = self.scroller.vadjustment();
            let top = adjustment.lower();
            let bottom = (adjustment.upper() - adjustment.page_size()).max(top);
            if bottom <= top + 1.0 {
                return Err("Popover fixture has no usable vertical scroll range".into());
            }
            adjustment.set_value(bottom);
            if adjustment.value() <= top + 1.0 {
                return Err("Popover vertical adjustment did not scroll".into());
            }
        }
        self.window.set_visible(false);
        Ok(())
    }

    pub fn present(self: &Rc<Self>, anchor: Option<(i32, i32)>) {
        let adjustment = self.scroller.vadjustment();
        adjustment.set_value(adjustment.lower());
        self.window.present();
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(controller) = weak.upgrade() {
                let adjustment = controller.scroller.vadjustment();
                adjustment.set_value(adjustment.lower());
            }
        });
        position_sway_popover(anchor);

        let stale = self
            .snapshot
            .borrow()
            .as_ref()
            .map(|snapshot| {
                (Local::now() - snapshot.fetched_at).num_seconds()
                    >= REFRESH_INTERVAL.as_secs() as i64
            })
            .unwrap_or(true);
        if stale {
            self.start_refresh();
        }
    }

    fn connect_window(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            if let Some(controller) = weak.upgrade()
                && controller.tray_handle.borrow().is_none()
            {
                controller.application.quit();
            } else {
                window.set_visible(false);
            }
            Propagation::Stop
        });

        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, _| {
            if key != gdk::Key::Escape {
                return Propagation::Proceed;
            }
            if let Some(controller) = weak.upgrade() {
                controller.dismiss();
            }
            Propagation::Stop
        });
        self.window.add_controller(keys);
    }

    fn install_poll(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(80), move || {
            let Some(controller) = weak.upgrade() else {
                return ControlFlow::Break;
            };
            controller.process_worker_events();
            controller.process_tray_commands();
            ControlFlow::Continue
        });
    }

    fn install_auto_refresh(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(REFRESH_INTERVAL, move || {
            let Some(controller) = weak.upgrade() else {
                return ControlFlow::Break;
            };
            controller.start_refresh();
            ControlFlow::Continue
        });
    }

    fn process_worker_events(self: &Rc<Self>) {
        let events: Vec<_> = {
            let receiver = self.worker_receiver.borrow();
            std::iter::from_fn(|| receiver.try_recv().ok()).collect()
        };
        for event in events {
            match event {
                WorkerEvent::Refreshed(result) => {
                    self.refreshing.set(false);
                    match result {
                        Ok(snapshot) => {
                            self.snapshot.replace(Some(snapshot));
                            self.last_error.replace(None);
                        }
                        Err(error) => {
                            self.snapshot.replace(None);
                            self.last_error.replace(Some(clean_message(&error)));
                        }
                    }
                    self.render();
                }
            }
        }
    }

    fn process_tray_commands(self: &Rc<Self>) {
        let commands: Vec<_> = {
            let receiver = self.tray_receiver.borrow();
            std::iter::from_fn(|| receiver.try_recv().ok()).collect()
        };
        for command in commands {
            match command {
                TrayCommand::Toggle { x, y } => {
                    if self.window.is_visible() {
                        self.dismiss();
                    } else {
                        self.present((x > 0 && y > 0).then_some((x, y)));
                    }
                }
                TrayCommand::Show { x, y } => self.present((x > 0 && y > 0).then_some((x, y))),
                TrayCommand::Refresh => self.start_refresh(),
                TrayCommand::SetTimeframe(timeframe) => self.set_timeframe(timeframe),
                TrayCommand::SetAutostart(enabled) => self.set_autostart(enabled),
                TrayCommand::Quit => self.application.quit(),
            }
        }
    }

    fn start_refresh(self: &Rc<Self>) {
        if self.refreshing.replace(true) {
            return;
        }
        self.last_error.replace(None);
        self.render();
        let sender = self.worker_sender.clone();
        thread::spawn(move || {
            let result =
                app_server::fetch_usage_snapshot(FETCH_TIMEOUT).map_err(|error| error.to_string());
            let _ = sender.send(WorkerEvent::Refreshed(result));
        });
    }

    fn dismiss(&self) {
        if self.tray_handle.borrow().is_some() {
            self.window.set_visible(false);
        } else {
            self.application.quit();
        }
    }

    fn set_timeframe(self: &Rc<Self>, timeframe: Timeframe) {
        if self.timeframe.replace(timeframe) == timeframe {
            return;
        }
        self.history_page.set(0);
        if let Err(error) = (Preferences { timeframe }).save() {
            self.status_note
                .replace(Some(format!("Could not save preference: {error}")));
        }
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            handle.update(|tray| tray.timeframe = timeframe);
        }
        self.render();
    }

    fn set_autostart(self: &Rc<Self>, enabled: bool) {
        match autostart::set_enabled(enabled) {
            Ok(()) => self.status_note.replace(None),
            Err(error) => self.status_note.replace(Some(clean_status_message(&format!(
                "Could not change autostart: {error}"
            )))),
        };
        let actual = autostart::is_enabled();
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            handle.update(|tray| tray.autostart = actual);
        }
        self.render();
    }

    fn render(self: &Rc<Self>) {
        clear_box(&self.content);
        let snapshot = self.snapshot.borrow().clone();
        match snapshot {
            Some(snapshot) => self.render_snapshot(&snapshot),
            None if self.refreshing.get() => self.render_loading(),
            None => self.render_error(),
        }
    }

    fn render_loading(&self) {
        self.render_header_value("...");
        let grid = gtk::Grid::builder()
            .column_spacing(16)
            .row_spacing(8)
            .margin_top(12)
            .build();
        append_stat(&grid, 0, "Status", "Fetching account usage");
        self.content.append(&grid);
        self.update_tray_loading();
    }

    fn render_error(self: &Rc<Self>) {
        self.render_header_value("?");
        let message = self
            .last_error
            .borrow()
            .clone()
            .unwrap_or_else(|| "Codex usage could not be loaded.".into());
        let detail = label(&message, 0.0);
        detail.set_wrap(true);
        detail.set_selectable(true);
        detail.add_css_class("error-message");
        detail.set_margin_top(12);
        self.content.append(&detail);
        append_divider(&self.content);

        let retry = action_button("Retry", "view-refresh-symbolic");
        let weak = Rc::downgrade(self);
        retry.connect_clicked(move |_| {
            if let Some(controller) = weak.upgrade() {
                controller.start_refresh();
            }
        });
        self.content.append(&retry);
        let quit = action_button("Quit", "application-exit-symbolic");
        let application = self.application.clone();
        quit.connect_clicked(move |_| application.quit());
        self.content.append(&quit);
        self.update_tray_error(&message);
    }

    fn render_snapshot(self: &Rc<Self>, snapshot: &UsageSnapshot) {
        let timeframe = self.timeframe.get();
        let range = UsageRange::new(timeframe, snapshot.buckets());
        self.render_hero(&range);
        self.render_timeframes(timeframe);
        append_divider(&self.content);
        self.render_stats(timeframe, &range);
        append_divider(&self.content);
        self.render_chart(timeframe, &range);
        append_divider(&self.content);
        self.render_history(timeframe, &range);
        append_divider(&self.content);
        self.render_rate_limits(snapshot);

        let footer = label(
            &format!("Last refresh {}", relative_age(snapshot.fetched_at)),
            0.5,
        );
        footer.add_css_class("footer");
        footer.set_margin_top(14);
        self.content.append(&footer);

        append_divider(&self.content);
        self.render_actions();
        self.update_tray_snapshot(timeframe, &range, snapshot);
    }

    fn render_hero(&self, range: &UsageRange) {
        self.render_header_value(&format_tokens(range.total_tokens()));
    }

    fn render_header_value(&self, value: &str) {
        let card = gtk::Box::new(Orientation::Horizontal, 10);
        card.set_valign(Align::Center);
        let icon = usage_logo();
        let title = label("Usage", 0.0);
        title.add_css_class("hero-title");
        title.set_hexpand(true);
        let total = label(value, 1.0);
        total.add_css_class("hero-total");
        card.append(&icon);
        card.append(&title);
        card.append(&total);
        self.content.append(&card);
    }

    fn render_timeframes(self: &Rc<Self>, selected: Timeframe) {
        let row = gtk::Box::new(Orientation::Horizontal, 4);
        row.add_css_class("timeframe");
        row.set_accessible_role(gtk::AccessibleRole::TabList);
        row.set_homogeneous(true);
        let mut previous: Option<gtk::ToggleButton> = None;

        for timeframe in Timeframe::ALL {
            let button = gtk::ToggleButton::with_label(timeframe.short_title());
            button.set_accessible_role(gtk::AccessibleRole::Tab);
            button.add_css_class("flat");
            button.add_css_class("timeframe-tab");
            if let Some(previous) = previous.as_ref() {
                button.set_group(Some(previous));
            }
            button.set_active(timeframe == selected);
            button.update_state(&[gtk::accessible::State::Selected(Some(
                timeframe == selected,
            ))]);
            if timeframe == selected {
                button.add_css_class("selected");
            }
            let weak = Rc::downgrade(self);
            button.connect_toggled(move |button| {
                if button.is_active()
                    && let Some(controller) = weak.upgrade()
                {
                    controller.set_timeframe(timeframe);
                }
            });
            row.append(&button);
            previous = Some(button);
        }
        row.set_margin_top(14);
        self.content.append(&row);
    }

    fn render_stats(&self, timeframe: Timeframe, range: &UsageRange) {
        let section = section_box("section", 8);
        let grid = gtk::Grid::builder()
            .column_spacing(16)
            .row_spacing(8)
            .build();
        append_stat(
            &grid,
            0,
            timeframe.hero_title(),
            &format_full_tokens(range.total_tokens()),
        );
        append_stat(&grid, 1, "Scope", "All platforms");
        append_stat(
            &grid,
            2,
            "Average/day",
            &format_tokens(range.average_daily_tokens()),
        );
        append_stat(
            &grid,
            3,
            "Peak day",
            &format_tokens(range.peak_daily_tokens()),
        );
        append_stat(&grid, 4, "Active days", &range.active_days().to_string());
        section.append(&grid);
        self.content.append(&section);
    }

    fn render_chart(&self, timeframe: Timeframe, range: &UsageRange) {
        let chart_buckets = range.chart_buckets();
        let section = section_box("section", 9);
        let header = gtk::Box::new(Orientation::Horizontal, 8);
        let title = label("Recent activity", 0.0);
        title.add_css_class("section-title");
        title.set_hexpand(true);
        let peak = label(
            &if range.peak_daily_tokens() > 0 {
                format!("{} peak", format_tokens(range.peak_daily_tokens()))
            } else {
                "No usage".into()
            },
            1.0,
        );
        peak.add_css_class("muted");
        peak.add_css_class("chart-peak");
        header.append(&title);
        header.append(&peak);
        section.append(&header);
        section.append(&usage_chart(&chart_buckets, timeframe));
        self.content.append(&section);
    }

    fn render_history(self: &Rc<Self>, timeframe: Timeframe, range: &UsageRange) {
        let section = section_box("section", 6);
        let title = label(timeframe.history_title(), 0.0);
        title.add_css_class("section-title");
        section.append(&title);

        let mut history = range.history();
        history.reverse();
        let paginated = matches!(timeframe, Timeframe::Ninety | Timeframe::All);
        let page_size = 6;
        let page_count = if paginated {
            history.len().div_ceil(page_size).max(1)
        } else {
            1
        };
        let page = self.history_page.get().min(page_count - 1);
        self.history_page.set(page);
        let start = if paginated { page * page_size } else { 0 };

        if history.is_empty() {
            let grid = gtk::Grid::builder().column_spacing(16).build();
            append_stat(&grid, 0, "History", "No daily buckets");
            section.append(&grid);
        } else {
            for bucket in history.iter().skip(start).take(page_size) {
                section.append(&history_row(bucket));
            }
        }

        if paginated && page_count > 1 {
            let pager = gtk::Box::new(Orientation::Horizontal, 8);
            let newer = gtk::Button::from_icon_name("go-previous-symbolic");
            newer.add_css_class("flat");
            newer.add_css_class("pager-button");
            newer.set_tooltip_text(Some("Newer"));
            newer.set_sensitive(page > 0);
            let weak = Rc::downgrade(self);
            newer.connect_clicked(move |_| {
                if let Some(controller) = weak.upgrade() {
                    controller
                        .history_page
                        .set(controller.history_page.get().saturating_sub(1));
                    controller.render();
                }
            });
            let page_label = label(&format!("Page {} of {}", page + 1, page_count), 0.5);
            page_label.set_hexpand(true);
            page_label.add_css_class("muted");
            let older = gtk::Button::from_icon_name("go-next-symbolic");
            older.add_css_class("flat");
            older.add_css_class("pager-button");
            older.set_tooltip_text(Some("Older"));
            older.set_sensitive(page + 1 < page_count);
            let weak = Rc::downgrade(self);
            older.connect_clicked(move |_| {
                if let Some(controller) = weak.upgrade() {
                    controller
                        .history_page
                        .set((controller.history_page.get() + 1).min(page_count - 1));
                    controller.render();
                }
            });
            pager.append(&newer);
            pager.append(&page_label);
            pager.append(&older);
            section.append(&pager);
        }
        self.content.append(&section);
    }

    fn render_rate_limits(&self, snapshot: &UsageSnapshot) {
        let section = section_box("section", 5);
        let title = label("Rate limits", 0.0);
        title.add_css_class("section-title");
        section.append(&title);

        let limit = snapshot
            .rate_limits
            .as_ref()
            .and_then(|limits| limits.preferred_codex_limit());
        if let Some(limit) = limit {
            if let Some(primary) = limit.primary.as_ref() {
                section.append(&limit_window("Primary", primary));
            }
            if let Some(secondary) = limit.secondary.as_ref() {
                section.append(&limit_window("Secondary", secondary));
            }
            if limit.primary.is_none() && limit.secondary.is_none() {
                let grid = gtk::Grid::builder().column_spacing(16).build();
                append_stat(&grid, 0, "Window", "No active limit");
                section.append(&grid);
            }
            let grid = gtk::Grid::builder()
                .column_spacing(16)
                .row_spacing(6)
                .build();
            append_stat(
                &grid,
                0,
                "Plan",
                limit.plan_type.as_deref().unwrap_or("n/a"),
            );
            let credits = snapshot
                .rate_limits
                .as_ref()
                .and_then(|limits| limits.rate_limit_reset_credits.as_ref())
                .map(|credits| credits.available_count.to_string())
                .unwrap_or_else(|| "n/a".into());
            append_stat(&grid, 1, "Reset credits", &credits);
            section.append(&grid);
        } else {
            let grid = gtk::Grid::builder().column_spacing(16).build();
            append_stat(&grid, 0, "Window", "No data");
            section.append(&grid);
        }
        self.content.append(&section);
    }

    fn render_actions(self: &Rc<Self>) {
        let actions = gtk::Box::new(Orientation::Vertical, 0);
        let refresh = action_button("Refresh", "view-refresh-symbolic");
        let weak = Rc::downgrade(self);
        refresh.connect_clicked(move |_| {
            if let Some(controller) = weak.upgrade() {
                controller.start_refresh();
            }
        });

        let autostart = gtk::CheckButton::with_label("Open at Login");
        autostart.set_active(autostart::is_enabled());
        autostart.add_css_class("action-check");
        let weak = Rc::downgrade(self);
        autostart.connect_toggled(move |button| {
            if let Some(controller) = weak.upgrade() {
                controller.set_autostart(button.is_active());
            }
        });

        let quit = action_button("Quit", "application-exit-symbolic");
        let application = self.application.clone();
        quit.connect_clicked(move |_| application.quit());
        actions.append(&refresh);
        actions.append(&autostart);
        if let Some(note) = self.status_note.borrow().as_deref() {
            let note = label(note, 0.0);
            note.set_wrap(true);
            note.add_css_class("status-note");
            actions.append(&note);
        }
        actions.append(&quit);
        self.content.append(&actions);
    }

    fn update_tray_loading(&self) {
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            handle.update(|tray| {
                tray.status_line = "Loading usage…".into();
                tray.status_value = "Codex ...".into();
                tray.description = "Fetching account-wide Codex usage".into();
                tray.has_error = false;
            });
        }
    }

    fn update_tray_error(&self, message: &str) {
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            handle.update(|tray| {
                tray.status_line = "Usage unavailable".into();
                tray.status_value = "Codex ?".into();
                tray.description = clean_message(message);
                tray.has_error = true;
            });
        }
    }

    fn update_tray_snapshot(
        &self,
        timeframe: Timeframe,
        range: &UsageRange,
        snapshot: &UsageSnapshot,
    ) {
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            let status = format!(
                "{}: {}",
                timeframe.short_title(),
                format_tokens(range.total_tokens())
            );
            let description = format!(
                "{} tokens · refreshed {}",
                format_full_tokens(range.total_tokens()),
                relative_age(snapshot.fetched_at)
            );
            handle.update(|tray| {
                tray.timeframe = timeframe;
                tray.status_line = status;
                tray.status_value = format_tokens(range.total_tokens());
                tray.description = description;
                tray.has_error = false;
                tray.autostart = autostart::is_enabled();
            });
        }
    }
}

fn update_window_palette(window: &gtk::ApplicationWindow) {
    let dark = gtk::Settings::default()
        .is_some_and(|settings| settings.is_gtk_application_prefer_dark_theme());
    if dark {
        window.remove_css_class("codex-light");
        window.add_css_class("codex-dark");
    } else {
        window.remove_css_class("codex-dark");
        window.add_css_class("codex-light");
    }
}

fn install_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(include_str!("style.css"));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

fn position_sway_popover(anchor: Option<(i32, i32)>) {
    if std::env::var_os("SWAYSOCK").is_none() {
        return;
    }
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(80));
        run_sway_command("[app_id=\"io.github.conjfrnk.CodexUsageBar\"] floating enable");
        run_sway_command(&format!(
            "[app_id=\"io.github.conjfrnk.CodexUsageBar\"] resize set width {POPOVER_WIDTH} px height {POPOVER_HEIGHT} px"
        ));
        let command = if let Some((anchor_x, anchor_y)) = anchor {
            let (x, y) = sway_popover_position((anchor_x, anchor_y)).unwrap_or_else(|| {
                let x = anchor_x - POPOVER_WIDTH + 18;
                let y = if anchor_y > POPOVER_HEIGHT + 20 {
                    anchor_y - POPOVER_HEIGHT - 10
                } else {
                    anchor_y + 30
                };
                (x, y)
            });
            format!("[app_id=\"io.github.conjfrnk.CodexUsageBar\"] move position {x} {y}")
        } else {
            "[app_id=\"io.github.conjfrnk.CodexUsageBar\"] move position center".into()
        };
        run_sway_command(&command);
    });
}

fn sway_popover_position(anchor: (i32, i32)) -> Option<(i32, i32)> {
    let output = Command::new("swaymsg")
        .args(["-t", "get_outputs", "-r"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let outputs: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    popover_position_in_outputs(anchor, &outputs)
}

fn popover_position_in_outputs(
    (anchor_x, anchor_y): (i32, i32),
    outputs: &serde_json::Value,
) -> Option<(i32, i32)> {
    let output = outputs.as_array()?.iter().find(|output| {
        let Some(rect) = output.get("rect") else {
            return false;
        };
        let x = rect
            .get("x")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0) as i32;
        let y = rect
            .get("y")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0) as i32;
        let width = rect
            .get("width")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0) as i32;
        let height = rect
            .get("height")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0) as i32;
        anchor_x >= x && anchor_x < x + width && anchor_y >= y && anchor_y < y + height
    })?;
    let rect = output.get("rect")?;
    let output_x = rect.get("x")?.as_i64()? as i32;
    let output_y = rect.get("y")?.as_i64()? as i32;
    let output_width = rect.get("width")?.as_i64()? as i32;
    let output_height = rect.get("height")?.as_i64()? as i32;
    let maximum_x = (output_x + output_width - POPOVER_WIDTH).max(output_x);
    let maximum_y = (output_y + output_height - POPOVER_HEIGHT).max(output_y);
    let x = (anchor_x - POPOVER_WIDTH + 18).clamp(output_x, maximum_x);
    let proposed_y = if anchor_y >= output_y + output_height / 2 {
        anchor_y - POPOVER_HEIGHT - 10
    } else {
        anchor_y + 30
    };
    Some((x, proposed_y.clamp(output_y, maximum_y)))
}

fn run_sway_command(command: &str) {
    let _ = Command::new("swaymsg")
        .args(["-q", command])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn clear_box(container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}

fn section_box(class: &str, spacing: i32) -> gtk::Box {
    let section = gtk::Box::new(Orientation::Vertical, spacing);
    section.add_css_class(class);
    section
}

fn append_divider(container: &gtk::Box) {
    let divider = gtk::Separator::new(Orientation::Horizontal);
    divider.add_css_class("divider");
    container.append(&divider);
}

fn action_button(title: &str, icon_name: &str) -> gtk::Button {
    let button = gtk::Button::new();
    button.add_css_class("flat");
    button.add_css_class("action-row");
    let row = gtk::Box::new(Orientation::Horizontal, 10);
    let icon = gtk::Image::from_icon_name(icon_name);
    icon.set_pixel_size(14);
    icon.set_size_request(18, -1);
    let title = label(title, 0.0);
    title.set_hexpand(true);
    row.append(&icon);
    row.append(&title);
    button.set_child(Some(&row));
    button
}

fn usage_logo() -> gtk::DrawingArea {
    let logo = gtk::DrawingArea::new();
    logo.set_content_width(34);
    logo.set_content_height(34);
    logo.set_tooltip_text(Some("Codex Usage"));
    logo.set_accessible_role(gtk::AccessibleRole::Img);
    logo.update_property(&[gtk::accessible::Property::Label("Codex Usage")]);
    logo.set_draw_func(|_, context, width, height| {
        let side = f64::from(width.min(height));
        let radius = side * 0.22;
        rounded_rectangle(context, 0.5, 0.5, side - 1.0, side - 1.0, radius);
        let background = cairo::LinearGradient::new(0.0, 0.0, 0.0, side);
        background.add_color_stop_rgb(0.0, 0.22, 0.24, 0.29);
        background.add_color_stop_rgb(0.55, 0.10, 0.11, 0.14);
        background.add_color_stop_rgb(1.0, 0.035, 0.04, 0.05);
        let _ = context.set_source(&background);
        let _ = context.fill_preserve();
        context.set_source_rgba(1.0, 1.0, 1.0, 0.16);
        context.set_line_width(1.0);
        let _ = context.stroke();

        let center = side / 2.0;
        let mark_side = side * 0.62;
        let ring_width = mark_side * 0.185;
        let ring_radius = mark_side / 2.0 - ring_width / 2.0;
        context.set_line_width(ring_width);
        context.set_line_cap(cairo::LineCap::Round);
        context.set_source_rgba(1.0, 1.0, 1.0, 0.14);
        context.arc(center, center, ring_radius, 0.0, std::f64::consts::TAU);
        let _ = context.stroke();
        let start = -std::f64::consts::FRAC_PI_2;
        let sweep = std::f64::consts::TAU * 0.73;
        context.set_line_cap(cairo::LineCap::Butt);
        for segment in 0..48 {
            let from = segment as f64 / 48.0;
            let to = (segment + 1) as f64 / 48.0;
            let (red, green, blue) = if from < 0.5 {
                let amount = from * 2.0;
                (
                    0.42 + (0.20 - 0.42) * amount,
                    0.97 + (0.72 - 0.97) * amount,
                    0.86 + (0.99 - 0.86) * amount,
                )
            } else {
                let amount = (from - 0.5) * 2.0;
                (
                    0.20 + (0.32 - 0.20) * amount,
                    0.72 + (0.40 - 0.72) * amount,
                    0.99 + (0.98 - 0.99) * amount,
                )
            };
            context.set_source_rgb(red, green, blue);
            context.arc(
                center,
                center,
                ring_radius,
                start + sweep * from,
                start + sweep * to + 0.002,
            );
            let _ = context.stroke();
        }
        context.set_source_rgb(0.42, 0.97, 0.86);
        context.arc(
            center + ring_radius * start.cos(),
            center + ring_radius * start.sin(),
            ring_width / 2.0,
            0.0,
            std::f64::consts::TAU,
        );
        let _ = context.fill();
        let end = start + sweep;
        context.set_source_rgb(0.32, 0.40, 0.98);
        context.arc(
            center + ring_radius * end.cos(),
            center + ring_radius * end.sin(),
            ring_width / 2.0,
            0.0,
            std::f64::consts::TAU,
        );
        let _ = context.fill();

        context.set_source_rgb(1.0, 1.0, 1.0);
        context.set_line_width(mark_side * 0.099);
        context.set_line_cap(cairo::LineCap::Round);
        context.set_line_join(cairo::LineJoin::Round);
        let chevron_height = mark_side * 0.329;
        let chevron_reach = mark_side * 0.178;
        let chevron_center = center - mark_side * 0.03;
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
    });
    logo
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

fn label(text: &str, xalign: f32) -> gtk::Label {
    gtk::Label::builder().label(text).xalign(xalign).build()
}

fn muted_label(text: &str) -> gtk::Label {
    let label = label(text, 0.0);
    label.add_css_class("muted");
    label
}

fn append_stat(grid: &gtk::Grid, row: i32, name: &str, value: &str) {
    let name = label(name, 0.0);
    name.add_css_class("stat-label");
    name.set_hexpand(true);
    let value = label(value, 1.0);
    value.add_css_class("stat-value");
    grid.attach(&name, 0, row, 1, 1);
    grid.attach(&value, 1, row, 1, 1);
}

fn history_row(bucket: &DailyUsageBucket) -> gtk::Box {
    let row = gtk::Box::new(Orientation::Horizontal, 10);
    let date = label(&bucket.start_date, 0.0);
    date.add_css_class("history-date");
    date.add_css_class("muted");
    date.set_hexpand(true);
    let icon = history_icon();
    let value = label(&format_full_tokens(bucket.tokens), 1.0);
    value.add_css_class("history-value");
    row.set_tooltip_text(Some(&format!(
        "{}: {} tokens",
        bucket.start_date,
        format_full_tokens(bucket.tokens)
    )));
    row.append(&date);
    row.append(&icon);
    row.append(&value);
    row
}

fn history_icon() -> gtk::DrawingArea {
    let icon = gtk::DrawingArea::new();
    icon.set_content_width(22);
    icon.set_content_height(14);
    icon.set_accessible_role(gtk::AccessibleRole::Presentation);
    icon.set_draw_func(|area, context, width, height| {
        let foreground = area.color();
        context.set_source_rgba(
            f64::from(foreground.red()),
            f64::from(foreground.green()),
            f64::from(foreground.blue()),
            0.68,
        );
        context.set_line_width(1.25);
        context.set_line_cap(cairo::LineCap::Round);
        context.set_line_join(cairo::LineJoin::Round);
        let left = 3.0;
        let bottom = f64::from(height) - 2.5;
        let right = f64::from(width) - 3.0;
        let top = 2.5;
        context.move_to(left, top);
        context.line_to(left, bottom);
        context.line_to(right, bottom);
        let _ = context.stroke();
        context.move_to(left + 2.0, bottom - 2.0);
        context.line_to(left + 6.0, bottom - 5.0);
        context.line_to(left + 9.0, bottom - 3.5);
        context.line_to(right - 1.0, top + 1.0);
        let _ = context.stroke();
    });
    icon
}

fn limit_window(title: &str, window: &RateLimitWindow) -> gtk::Box {
    let box_ = gtk::Box::new(Orientation::Vertical, 0);
    let heading = gtk::Box::new(Orientation::Horizontal, 8);
    heading.add_css_class("limit-heading");
    let title = label(title, 0.0);
    title.add_css_class("stat-label");
    title.set_hexpand(true);
    let percent = label(&format_percent(window.used_percent), 1.0);
    percent.add_css_class("stat-value");
    heading.append(&title);
    heading.append(&percent);
    let progress = gtk::ProgressBar::new();
    progress.set_hexpand(true);
    progress.set_fraction((window.used_percent / 100.0).clamp(0.0, 1.0));
    if window.used_percent >= 90.0 {
        progress.add_css_class("error");
    } else if window.used_percent >= 70.0 {
        progress.add_css_class("warning");
    } else {
        progress.add_css_class("success");
    }
    let reset = muted_label(&format!("resets {}", relative_reset(window)));
    reset.add_css_class("limit-reset");
    let details = gtk::Box::new(Orientation::Horizontal, 8);
    details.set_margin_bottom(5);
    details.append(&progress);
    details.append(&reset);
    box_.append(&heading);
    box_.append(&details);
    box_
}

fn format_percent(value: f64) -> String {
    if value.round() == value {
        format!("{value:.0}%")
    } else {
        format!("{value:.1}%")
    }
}

fn relative_reset(window: &RateLimitWindow) -> String {
    let Some(reset) = window.reset_date() else {
        return "n/a".into();
    };
    let seconds = (reset - Local::now()).num_seconds();
    let absolute = seconds.unsigned_abs();
    if absolute < 5 {
        "now".into()
    } else if absolute < 60 {
        relative_value(seconds, absolute, "s")
    } else if absolute < 3_600 {
        relative_value(seconds, absolute / 60, "m")
    } else if absolute < 86_400 {
        relative_value(seconds, absolute / 3_600, "h")
    } else {
        relative_value(seconds, absolute / 86_400, "d")
    }
}

fn relative_value(seconds: i64, value: u64, suffix: &str) -> String {
    if seconds < 0 {
        format!("{value}{suffix} ago")
    } else {
        format!("in {value}{suffix}")
    }
}

fn relative_age(date: chrono::DateTime<Local>) -> String {
    let seconds = (Local::now() - date).num_seconds().max(0);
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

fn clean_message(message: &str) -> String {
    truncate_message(message, 240)
}

fn clean_status_message(message: &str) -> String {
    truncate_message(message, 140)
}

fn truncate_message(message: &str, maximum: usize) -> String {
    if message.chars().count() <= maximum {
        message.into()
    } else {
        format!(
            "{}...",
            message.chars().take(maximum - 3).collect::<String>()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchors_inside_the_clicked_sway_output_including_negative_coordinates() {
        let outputs = serde_json::json!([
            {"rect":{"x":-1920,"y":0,"width":1920,"height":1080}},
            {"rect":{"x":0,"y":0,"width":1920,"height":1200}}
        ]);
        assert_eq!(
            popover_position_in_outputs((-10, 1050), &outputs),
            Some((-300, 480))
        );
        assert_eq!(
            popover_position_in_outputs((1910, 20), &outputs),
            Some((1620, 50))
        );
    }

    #[test]
    fn rate_percent_and_message_formatting_match_macos_rules() {
        assert_eq!(format_percent(42.0), "42%");
        assert_eq!(format_percent(42.01), "42.0%");
        assert_eq!(format_percent(31.5), "31.5%");

        let message = "é".repeat(141);
        let clean = clean_status_message(&message);
        assert_eq!(clean.chars().count(), 140);
        assert!(clean.ends_with("..."));
    }

    #[test]
    fn missing_rate_limit_reset_uses_the_same_na_value_as_macos() {
        let window = RateLimitWindow {
            used_percent: 10.0,
            window_duration_mins: None,
            resets_at: None,
        };
        assert_eq!(relative_reset(&window), "n/a");
    }
}
