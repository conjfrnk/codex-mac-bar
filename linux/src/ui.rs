use std::cell::{Cell, RefCell};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Local, NaiveDate};
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
use crate::model::{
    AccountRateLimitsResponse, DailyUsageBucket, RateLimitWindow, SpendControlLimitSnapshot,
    UsageSnapshot,
};
use crate::range::{Timeframe, UsageRange, format_full_tokens, format_tokens};
use crate::tray::{TrayCommand, TrayMailboxReceiver, UsageTray, tray_mailbox};

mod presentation;

use presentation::*;

const REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);
const PRESENTATION_INTERVAL: Duration = Duration::from_secs(30);
const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
const POPOVER_WIDTH: i32 = 300;
const POPOVER_HEIGHT: i32 = 560;
const HISTORY_PAGE_SIZE: usize = 6;
const MAX_TRAY_COMMANDS_PER_POLL: usize = 32;
const LOADING_HERO_ACCESSIBLE_LABEL: &str = "Usage summary, loading account usage";
const UNAVAILABLE_HERO_ACCESSIBLE_LABEL: &str = "Usage summary, account usage unavailable";

enum WorkerEvent {
    Refreshed(Result<UsageSnapshot, String>),
}

enum RelativeLabel {
    Refresh {
        label: gtk::Label,
        fetched_at: DateTime<Local>,
    },
    StaleWarning {
        label: gtk::Label,
        fetched_at: DateTime<Local>,
        error: String,
    },
    Reset {
        label: gtk::Label,
        resets_at: Option<f64>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderLandmarkKind {
    Header,
    StaleWarning,
    TimeframeTabs,
    Summary,
    Chart,
    History,
    RateLimits,
    LoadingStatus,
    ErrorMessage,
    Actions,
}

impl RenderLandmarkKind {
    const fn name(self) -> &'static str {
        match self {
            Self::Header => "header",
            Self::StaleWarning => "stale warning",
            Self::TimeframeTabs => "timeframe tabs",
            Self::Summary => "summary",
            Self::Chart => "chart",
            Self::History => "history",
            Self::RateLimits => "rate limits",
            Self::LoadingStatus => "loading status",
            Self::ErrorMessage => "error message",
            Self::Actions => "actions",
        }
    }
}

struct RenderLandmark {
    kind: RenderLandmarkKind,
    widget: gtk::Widget,
    ink_probes: Vec<(&'static str, gtk::Widget)>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FocusTarget {
    Timeframe(Timeframe),
    Chart,
    HistoryNewer,
    HistoryOlder,
    Refresh,
    Autostart,
    Quit,
}

struct FocusEntry {
    target: FocusTarget,
    widget: gtk::Widget,
}

fn focus_restore_order(target: FocusTarget) -> [Option<FocusTarget>; 4] {
    use FocusTarget::{Autostart, HistoryNewer, HistoryOlder, Quit, Refresh};

    match target {
        HistoryNewer => [
            Some(HistoryNewer),
            Some(HistoryOlder),
            Some(Refresh),
            Some(Autostart),
        ],
        HistoryOlder => [
            Some(HistoryOlder),
            Some(HistoryNewer),
            Some(Refresh),
            Some(Autostart),
        ],
        Refresh => [Some(Refresh), Some(Autostart), Some(Quit), None],
        Autostart => [Some(Autostart), Some(Refresh), Some(Quit), None],
        Quit => [Some(Quit), Some(Autostart), Some(Refresh), None],
        target @ (FocusTarget::Timeframe(_) | FocusTarget::Chart) => {
            [Some(target), Some(Refresh), Some(Autostart), Some(Quit)]
        }
    }
}

fn widget_is_within(widget: &gtk::Widget, ancestor: &gtk::Widget) -> bool {
    let mut current = Some(widget.clone());
    while let Some(widget) = current {
        if widget == *ancestor {
            return true;
        }
        current = widget.parent();
    }
    false
}

pub struct UiController {
    application: gtk::Application,
    window: gtk::ApplicationWindow,
    window_paintable: gtk::WidgetPaintable,
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
    tray_receiver: TrayMailboxReceiver,
    tray_handle: RefCell<Option<TrayHandle<UsageTray>>>,
    viewport_width: i32,
    viewport_height: i32,
    live: bool,
    fixture_now: Option<DateTime<Local>>,
    relative_labels: RefCell<Vec<RelativeLabel>>,
    render_landmarks: RefCell<Vec<RenderLandmark>>,
    focus_registry: RefCell<Vec<FocusEntry>>,
    selectable_error_label: RefCell<Option<gtk::Label>>,
    focus_restore_generation: Cell<u64>,
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
        let fixture_now = if live {
            None
        } else {
            snapshot.as_ref().map(|value| value.fetched_at)
        };
        install_css();

        let (worker_sender, worker_receiver) = mpsc::channel();
        let (tray_sender, tray_receiver) = tray_mailbox();

        let tray_handle = if tray_enabled {
            let tray = UsageTray::new(tray_sender, timeframe, autostart::is_enabled());
            match tray.assume_sni_available(true).spawn() {
                Ok(handle) => Some(handle),
                Err(error) => {
                    eprintln!(
                        "codex-usage-bar: could not start system tray: {}",
                        clean_message(&error.to_string())
                    );
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
        if live {
            update_window_palette(&window);
            if let Some(settings) = gtk::Settings::default() {
                let weak_window = window.downgrade();
                settings.connect_gtk_application_prefer_dark_theme_notify(move |_| {
                    if let Some(window) = weak_window.upgrade() {
                        update_window_palette(&window);
                    }
                });
                let weak_window = window.downgrade();
                settings.connect_notify_local(Some("gtk-theme-name"), move |_, _| {
                    if let Some(window) = weak_window.upgrade() {
                        update_window_palette(&window);
                    }
                });
            }
        } else {
            // Visual fixtures explicitly request light or dark. Ignore the
            // host theme name here so `--appearance light` remains light even
            // when the developer's desktop currently uses a dark GTK theme.
            let dark = gtk::Settings::default()
                .is_some_and(|settings| settings.is_gtk_application_prefer_dark_theme());
            set_window_palette(&window, dark, false);
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
        let window_paintable = gtk::WidgetPaintable::new(Some(&window));

        let controller = Rc::new(Self {
            application: application.clone(),
            window,
            window_paintable,
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
            tray_receiver,
            tray_handle: RefCell::new(tray_handle),
            viewport_width,
            viewport_height,
            live,
            fixture_now,
            relative_labels: RefCell::new(Vec::new()),
            render_landmarks: RefCell::new(Vec::new()),
            focus_registry: RefCell::new(Vec::new()),
            selectable_error_label: RefCell::new(None),
            focus_restore_generation: Cell::new(0),
        });

        if live {
            controller.connect_window();
            controller.install_poll();
            controller.install_auto_refresh();
            controller.install_presentation_timer();
            controller.start_refresh();
        } else {
            controller.render();
        }
        controller
    }

    pub fn present_for_render(&self) {
        self.window.present();
        self.clear_initial_error_selection();
    }

    pub fn mark_stale_for_render(self: &Rc<Self>) {
        self.last_error
            .replace(Some("Fixture refresh failed".into()));
        self.render();
    }

    pub fn mark_long_stale_for_render(self: &Rc<Self>) {
        self.last_error.replace(Some("x".repeat(240)));
        self.render();
    }

    pub fn mark_loading_for_render(self: &Rc<Self>) {
        self.snapshot.replace(None);
        self.last_error.replace(None);
        self.refreshing.set(true);
        self.render();
    }

    pub fn mark_error_for_render(self: &Rc<Self>) {
        self.snapshot.replace(None);
        self.last_error
            .replace(Some("Fixture account usage could not be loaded".into()));
        self.refreshing.set(false);
        self.render();
    }

    pub fn mark_long_error_for_render(self: &Rc<Self>) {
        self.snapshot.replace(None);
        self.last_error.replace(Some("x".repeat(240)));
        self.refreshing.set(false);
        self.render();
    }

    pub fn render_to_png(&self, path: &std::path::Path) -> Result<(), String> {
        while glib::MainContext::default().iteration(false) {}
        self.clear_initial_error_selection();
        while glib::MainContext::default().iteration(false) {}
        if let Some(label) = self.selectable_error_label.borrow().as_ref() {
            if !label.is_selectable() || !label.is_focusable() {
                return Err(
                    "Popover error text was not available for selection and copying".into(),
                );
            }
            if gtk::prelude::GtkWindowExt::focus(&self.window)
                .is_some_and(|focused| widget_is_within(&focused, label.upcast_ref()))
            {
                return Err("Popover error text retained initial focus after presentation".into());
            }
        }
        let allocated_width = self.window.width();
        let allocated_height = self.window.height();
        if allocated_width != self.viewport_width || allocated_height != self.viewport_height {
            return Err(format!(
                "Popover window was allocated {allocated_width}x{allocated_height}, expected {}x{}; the display may be too small for this fixture",
                self.viewport_width, self.viewport_height
            ));
        }
        let texture = self.snapshot_window_texture()?;
        let mut downloader = gdk::TextureDownloader::new(&texture);
        downloader.set_format(gdk::MemoryFormat::R8g8b8a8);
        let (pixels, stride) = downloader.download_bytes();
        let background = validate_popover_pixels(
            pixels.as_ref(),
            stride,
            self.viewport_width as usize,
            self.viewport_height as usize,
        )?;
        self.validate_render_landmarks(background)?;
        texture
            .save_to_png(path)
            .map_err(|error| error.to_string())?;
        let bytes = std::fs::metadata(path)
            .map_err(|error| error.to_string())?
            .len();
        if bytes == 0 {
            return Err("Popover PNG was empty".into());
        }
        self.window.set_visible(false);
        Ok(())
    }

    fn snapshot_window_texture(&self) -> Result<gdk::Texture, String> {
        let snapshot = gtk::Snapshot::new();
        self.window_paintable.snapshot(
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
        Ok(texture)
    }

    fn expected_render_landmarks(&self) -> Vec<RenderLandmarkKind> {
        if self.snapshot.borrow().is_some() {
            let mut expected = vec![RenderLandmarkKind::Header];
            if self.last_error.borrow().is_some() {
                expected.push(RenderLandmarkKind::StaleWarning);
            }
            expected.extend([
                RenderLandmarkKind::TimeframeTabs,
                RenderLandmarkKind::Summary,
                RenderLandmarkKind::Chart,
                RenderLandmarkKind::History,
                RenderLandmarkKind::RateLimits,
                RenderLandmarkKind::Actions,
            ]);
            expected
        } else if self.refreshing.get() {
            vec![
                RenderLandmarkKind::Header,
                RenderLandmarkKind::LoadingStatus,
                RenderLandmarkKind::Actions,
            ]
        } else {
            vec![
                RenderLandmarkKind::Header,
                RenderLandmarkKind::ErrorMessage,
                RenderLandmarkKind::Actions,
            ]
        }
    }

    fn validate_render_landmarks(&self, background: [u8; 4]) -> Result<(), String> {
        let landmarks: Vec<_> = self
            .render_landmarks
            .borrow()
            .iter()
            .map(|landmark| {
                (
                    landmark.kind,
                    landmark.widget.clone(),
                    landmark.ink_probes.clone(),
                )
            })
            .collect();
        let actual: Vec<_> = landmarks.iter().map(|(kind, _, _)| *kind).collect();
        let expected = self.expected_render_landmarks();
        if actual != expected {
            let names = |kinds: &[RenderLandmarkKind]| {
                kinds
                    .iter()
                    .map(|kind| kind.name())
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            return Err(format!(
                "Popover render landmarks were [{}], expected [{}]",
                names(&actual),
                names(&expected)
            ));
        }

        let mut content_landmarks = Vec::with_capacity(landmarks.len());
        let mut previous_bottom = 0.0_f32;
        for (index, (kind, widget, ink_probes)) in landmarks.iter().enumerate() {
            let bounds = widget
                .compute_bounds(&self.content)
                .ok_or_else(|| format!("Popover {} landmark had no content bounds", kind.name()))?;
            if !bounds.x().is_finite()
                || !bounds.y().is_finite()
                || !bounds.width().is_finite()
                || !bounds.height().is_finite()
                || bounds.width() < 1.0
                || bounds.height() < 1.0
            {
                return Err(format!(
                    "Popover {} landmark had invalid bounds {bounds:?}",
                    kind.name()
                ));
            }
            if index > 0 && bounds.y() + 1.0 < previous_bottom {
                return Err(format!(
                    "Popover {} landmark overlapped or preceded the prior landmark",
                    kind.name()
                ));
            }
            previous_bottom = bounds.y() + bounds.height();
            content_landmarks.push((*kind, widget.clone(), ink_probes.clone(), bounds));
        }

        let adjustment = self.scroller.vadjustment();
        let top = adjustment.lower();
        let bottom = (adjustment.upper() - adjustment.page_size()).max(top);
        let mut maximum_scroll = top;
        for (kind, widget, ink_probes, content_bounds) in content_landmarks {
            let desired = (f64::from(content_bounds.y())
                + f64::from(content_bounds.height()) / 2.0
                - adjustment.page_size() / 2.0)
                .clamp(top, bottom);
            adjustment.set_value(desired);
            maximum_scroll = maximum_scroll.max(adjustment.value());

            let deadline = Instant::now() + Duration::from_millis(500);
            let window_bounds = loop {
                while glib::MainContext::default().iteration(false) {}
                if let Some(bounds) = widget.compute_bounds(&self.window)
                    && bounds.y() < self.viewport_height as f32
                    && bounds.y() + bounds.height() > 0.0
                {
                    break bounds;
                }
                if Instant::now() >= deadline {
                    return Err(format!(
                        "Popover {} landmark did not enter the viewport after scrolling",
                        kind.name()
                    ));
                }
                std::thread::sleep(Duration::from_millis(1));
            };
            let texture = self.snapshot_window_texture()?;
            let mut downloader = gdk::TextureDownloader::new(&texture);
            downloader.set_format(gdk::MemoryFormat::R8g8b8a8);
            let (pixels, stride) = downloader.download_bytes();
            let frame_background = validate_popover_pixels(
                pixels.as_ref(),
                stride,
                self.viewport_width as usize,
                self.viewport_height as usize,
            )?;
            if frame_background != background {
                return Err(format!(
                    "Popover {} landmark frame changed its background color",
                    kind.name()
                ));
            }
            if ink_probes.is_empty() {
                validate_landmark_ink(
                    pixels.as_ref(),
                    stride,
                    self.viewport_width as usize,
                    self.viewport_height as usize,
                    background,
                    window_bounds,
                    kind.name(),
                )?;
            } else {
                let mut regions = Vec::with_capacity(ink_probes.len());
                for (name, probe) in ink_probes {
                    let bounds = probe
                        .compute_bounds(&self.window)
                        .ok_or_else(|| format!("Popover {name} ink probe had no window bounds"))?;
                    regions.push((name, bounds));
                }
                validate_disjoint_ink_regions(
                    pixels.as_ref(),
                    stride,
                    self.viewport_width as usize,
                    self.viewport_height as usize,
                    background,
                    &regions,
                )?;
            }
        }
        if bottom > top + 1.0 && maximum_scroll <= top + 1.0 {
            return Err("Popover had a scroll range but landmark validation did not scroll".into());
        }
        adjustment.set_value(top);
        while glib::MainContext::default().iteration(false) {}
        Ok(())
    }

    pub fn present(self: &Rc<Self>, anchor: Option<(i32, i32)>) {
        if !self.window.is_visible() {
            // A hidden GtkWindow can retain a child focus widget. Since every
            // presentation starts at the top, discard that stale offscreen
            // focus before rebuilding or showing the window again.
            self.clear_window_focus();
        }
        if self.history_page.replace(0) != 0 {
            self.render();
        }
        let adjustment = self.scroller.vadjustment();
        adjustment.set_value(adjustment.lower());
        self.window.present();
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(controller) = weak.upgrade() {
                controller.clear_initial_error_selection();
                let adjustment = controller.scroller.vadjustment();
                adjustment.set_value(adjustment.lower());
            }
        });
        if let Some(application_id) = self.application.application_id() {
            position_sway_popover(anchor, &application_id);
        }

        let stale = self
            .snapshot
            .borrow()
            .as_ref()
            .map(|snapshot| {
                snapshot_needs_refresh(
                    snapshot.fetched_at,
                    self.now(),
                    REFRESH_INTERVAL.as_secs() as i64,
                )
            })
            .unwrap_or(true);
        if stale {
            self.start_refresh();
        }
    }

    fn connect_window(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            if let Some(controller) = weak.upgrade() {
                controller.dismiss();
            } else {
                window.set_visible(false);
            }
            Propagation::Stop
        });

        let keys = gtk::EventControllerKey::new();
        // Let a focused child consume Escape first (the chart uses it to clear
        // a pinned point); an unhandled Escape then dismisses the popover.
        keys.set_propagation_phase(gtk::PropagationPhase::Bubble);
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

    fn install_presentation_timer(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(PRESENTATION_INTERVAL, move || {
            let Some(controller) = weak.upgrade() else {
                return ControlFlow::Break;
            };
            if controller.window.is_visible() {
                let should_refresh =
                    controller
                        .snapshot
                        .borrow()
                        .as_ref()
                        .is_some_and(|snapshot| {
                            snapshot_needs_refresh(
                                snapshot.fetched_at,
                                controller.now(),
                                REFRESH_INTERVAL.as_secs() as i64,
                            )
                        });
                if should_refresh {
                    controller.start_refresh();
                } else if controller.snapshot.borrow().is_some() {
                    controller.update_relative_labels();
                }
            }
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
                            // Keep the last valid account data visible while
                            // surfacing a transient refresh failure.
                            self.last_error.replace(Some(clean_message(&error)));
                        }
                    }
                    self.render();
                }
            }
        }
    }

    fn process_tray_commands(self: &Rc<Self>) {
        for command in self.tray_receiver.take_pending(MAX_TRAY_COMMANDS_PER_POLL) {
            match command {
                TrayCommand::Toggle { x, y } => {
                    if self.window.is_visible() {
                        self.dismiss();
                    } else {
                        self.present(tray_anchor(x, y));
                    }
                }
                TrayCommand::Show { x, y } => self.present(tray_anchor(x, y)),
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
        self.render();
        let sender = self.worker_sender.clone();
        thread::spawn(move || {
            let result =
                app_server::fetch_usage_snapshot(FETCH_TIMEOUT).map_err(|error| error.to_string());
            let _ = sender.send(WorkerEvent::Refreshed(result));
        });
    }

    fn dismiss(&self) {
        self.clear_window_focus();
        if self.tray_handle.borrow().is_some() {
            self.window.set_visible(false);
        } else {
            self.application.quit();
        }
    }

    fn now(&self) -> DateTime<Local> {
        self.fixture_now.unwrap_or_else(Local::now)
    }

    fn range_anchor_date(&self, snapshot: &UsageSnapshot) -> NaiveDate {
        if self.fixture_now.is_some() {
            // A UTC instant can fall on different local dates around the
            // world. Anchor visual fixtures to their final calendar bucket so
            // a timezone change cannot shift the rendered range by a day.
            snapshot
                .buckets()
                .iter()
                .filter_map(|bucket| NaiveDate::parse_from_str(&bucket.start_date, "%Y-%m-%d").ok())
                .max()
                .unwrap_or_else(|| self.now().date_naive())
        } else {
            self.now().date_naive()
        }
    }

    fn update_relative_labels(&self) {
        let now = self.now();
        for item in self.relative_labels.borrow().iter() {
            match item {
                RelativeLabel::Refresh { label, fetched_at } => {
                    let age = relative_age(*fetched_at, now);
                    label.set_text(&if self.refreshing.get() {
                        format!("Refreshing… · Last refresh {age}")
                    } else {
                        format!("Last refresh {age}")
                    });
                }
                RelativeLabel::StaleWarning {
                    label,
                    fetched_at,
                    error,
                } => label.set_text(&format!(
                    "Refresh failed: {error} · Showing data from {}.",
                    relative_age(*fetched_at, now)
                )),
                RelativeLabel::Reset { label, resets_at } => {
                    label.set_text(&reset_description(*resets_at, now))
                }
            }
        }
        let snapshot = self.snapshot.borrow();
        if let Some(snapshot) = snapshot.as_ref() {
            let timeframe = self.timeframe.get();
            let range = UsageRange::at_date(
                timeframe,
                snapshot.buckets(),
                self.range_anchor_date(snapshot),
            );
            self.update_tray_snapshot(
                timeframe,
                UsagePresentation::new(timeframe, &range, snapshot),
                snapshot,
            );
        }
    }

    fn set_timeframe(self: &Rc<Self>, timeframe: Timeframe) {
        if self.timeframe.replace(timeframe) == timeframe {
            return;
        }
        self.history_page.set(0);
        match (Preferences { timeframe }).save() {
            Ok(()) => self.status_note.replace(None),
            Err(error) => self.status_note.replace(Some(clean_status_message(&format!(
                "Could not save preference: {error}"
            )))),
        };
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
        let focus_target = self.focused_target();
        self.relative_labels.borrow_mut().clear();
        self.render_landmarks.borrow_mut().clear();
        self.focus_registry.borrow_mut().clear();
        self.selectable_error_label.replace(None);
        clear_box(&self.content);
        let snapshot = self.snapshot.borrow().clone();
        match snapshot {
            Some(snapshot) => self.render_snapshot(&snapshot),
            None if self.refreshing.get() => self.render_loading(),
            None => self.render_error(),
        }
        self.restore_focus_after_render(focus_target);
    }

    fn register_focus_target<W>(&self, target: FocusTarget, widget: &W)
    where
        W: IsA<gtk::Widget> + Clone,
    {
        self.focus_registry.borrow_mut().push(FocusEntry {
            target,
            widget: widget.clone().upcast(),
        });
    }

    fn focused_target(&self) -> Option<FocusTarget> {
        let focused = gtk::prelude::GtkWindowExt::focus(&self.window)?;
        self.focus_registry
            .borrow()
            .iter()
            .find(|entry| widget_is_within(&focused, &entry.widget))
            .map(|entry| entry.target)
    }

    fn invalidate_focus_restore(&self) -> u64 {
        let generation = self.focus_restore_generation.get().wrapping_add(1);
        self.focus_restore_generation.set(generation);
        generation
    }

    fn clear_window_focus(&self) {
        self.invalidate_focus_restore();
        gtk::prelude::GtkWindowExt::set_focus(&self.window, None::<&gtk::Widget>);
    }

    fn clear_initial_error_selection(&self) {
        let Some(label) = self.selectable_error_label.borrow().as_ref().cloned() else {
            return;
        };
        // Keep the label selectable for deliberate mouse/keyboard copying, but
        // do not present the popover with the whole diagnostic preselected.
        label.select_region(0, 0);
        if gtk::prelude::GtkWindowExt::focus(&self.window)
            .is_some_and(|focused| widget_is_within(&focused, label.upcast_ref()))
        {
            gtk::prelude::GtkWindowExt::set_focus(&self.window, None::<&gtk::Widget>);
        }
    }

    fn restore_focus_after_render(self: &Rc<Self>, target: Option<FocusTarget>) {
        let generation = self.invalidate_focus_restore();
        let Some(target) = target else {
            return;
        };
        if !self.window.is_visible() {
            return;
        }

        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            let Some(controller) = weak.upgrade() else {
                return;
            };
            if controller.focus_restore_generation.get() != generation
                || !controller.window.is_visible()
            {
                return;
            }

            let window_widget = controller.window.clone().upcast::<gtk::Widget>();
            if gtk::prelude::GtkWindowExt::focus(&controller.window)
                .is_some_and(|focused| widget_is_within(&focused, &window_widget))
            {
                // Focus moved after the render. Never override a user or GTK
                // focus decision made while this restoration was pending.
                return;
            }

            for candidate in focus_restore_order(target).into_iter().flatten() {
                let widget = controller
                    .focus_registry
                    .borrow()
                    .iter()
                    .find(|entry| entry.target == candidate)
                    .map(|entry| entry.widget.clone());
                if let Some(widget) = widget
                    && widget.root().is_some()
                    && widget.is_visible()
                    && widget.is_sensitive()
                    && widget.is_focusable()
                    && widget.grab_focus()
                {
                    return;
                }
            }
        });
    }

    fn render_loading(self: &Rc<Self>) {
        self.render_header_value("...", LOADING_HERO_ACCESSIBLE_LABEL);
        let grid = gtk::Grid::builder()
            .column_spacing(16)
            .row_spacing(8)
            .margin_top(12)
            .build();
        append_stat(&grid, 0, "Status", "Fetching account usage");
        self.content.append(&grid);
        self.record_render_landmark(RenderLandmarkKind::LoadingStatus, &grid);
        append_divider(&self.content);
        self.render_actions();
        self.update_tray_loading();
    }

    fn render_error(self: &Rc<Self>) {
        self.render_header_value("?", UNAVAILABLE_HERO_ACCESSIBLE_LABEL);
        let message = self
            .last_error
            .borrow()
            .clone()
            .unwrap_or_else(|| "Codex usage could not be loaded.".into());
        let detail = label(&message, 0.0);
        detail.set_wrap(true);
        detail.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        detail.set_selectable(true);
        detail.add_css_class("error-message");
        detail.set_margin_top(12);
        self.content.append(&detail);
        self.selectable_error_label.replace(Some(detail.clone()));
        self.record_render_landmark(RenderLandmarkKind::ErrorMessage, &detail);
        append_divider(&self.content);

        self.render_actions();
        self.update_tray_error(&message);
    }

    fn render_snapshot(self: &Rc<Self>, snapshot: &UsageSnapshot) {
        let timeframe = self.timeframe.get();
        let range = UsageRange::at_date(
            timeframe,
            snapshot.buckets(),
            self.range_anchor_date(snapshot),
        );
        let presentation = UsagePresentation::new(timeframe, &range, snapshot);
        self.render_hero(presentation.total_tokens);
        if let Some(error) = self.last_error.borrow().clone() {
            let cleaned_error = clean_message(&error);
            let warning = label(
                &format!(
                    "Refresh failed: {cleaned_error} · Showing data from {}.",
                    relative_age(snapshot.fetched_at, self.now())
                ),
                0.0,
            );
            warning.set_wrap(true);
            warning.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            warning.add_css_class("warning-message");
            warning.set_margin_top(12);
            self.content.append(&warning);
            self.record_render_landmark(RenderLandmarkKind::StaleWarning, &warning);
            self.relative_labels
                .borrow_mut()
                .push(RelativeLabel::StaleWarning {
                    label: warning,
                    fetched_at: snapshot.fetched_at,
                    error: cleaned_error,
                });
        }
        self.render_timeframes(timeframe);
        append_divider(&self.content);
        self.render_stats(timeframe, &range, presentation);
        append_divider(&self.content);
        self.render_chart(timeframe, &range, presentation);
        append_divider(&self.content);
        self.render_history(
            timeframe,
            &range,
            presentation.daily_history_available && !range.merge_did_overflow(),
        );
        append_divider(&self.content);
        self.render_rate_limits(snapshot);

        let footer = label(
            &if self.refreshing.get() {
                format!(
                    "Refreshing… · Last refresh {}",
                    relative_age(snapshot.fetched_at, self.now())
                )
            } else {
                format!(
                    "Last refresh {}",
                    relative_age(snapshot.fetched_at, self.now())
                )
            },
            0.5,
        );
        footer.add_css_class("footer");
        footer.set_margin_top(14);
        self.content.append(&footer);
        self.relative_labels
            .borrow_mut()
            .push(RelativeLabel::Refresh {
                label: footer,
                fetched_at: snapshot.fetched_at,
            });

        append_divider(&self.content);
        self.render_actions();
        self.update_tray_snapshot(timeframe, presentation, snapshot);
    }

    fn render_hero(&self, total_tokens: Option<i64>) {
        let visible_value = total_tokens
            .map(format_tokens)
            .unwrap_or_else(|| "—".into());
        self.render_header_value(&visible_value, &hero_accessible_label(total_tokens));
    }

    fn render_header_value(&self, value: &str, accessible_label: &str) {
        let card = gtk::Box::new(Orientation::Horizontal, 10);
        card.set_valign(Align::Center);
        card.set_accessible_role(gtk::AccessibleRole::Group);
        card.update_property(&[gtk::accessible::Property::Label(accessible_label)]);
        let icon = usage_logo();
        icon.set_accessible_role(gtk::AccessibleRole::Presentation);
        let title = label("Usage", 0.0);
        title.add_css_class("hero-title");
        title.set_hexpand(true);
        title.set_ellipsize(gtk::pango::EllipsizeMode::End);
        title.set_accessible_role(gtk::AccessibleRole::Presentation);
        let total = label(value, 1.0);
        total.add_css_class("hero-total");
        total.set_ellipsize(gtk::pango::EllipsizeMode::End);
        total.set_accessible_role(gtk::AccessibleRole::Presentation);
        card.append(&icon);
        card.append(&title);
        card.append(&total);
        self.content.append(&card);
        self.record_render_landmark_with_probes(
            RenderLandmarkKind::Header,
            &card,
            vec![
                ("header logo", icon.upcast()),
                ("header title", title.upcast()),
                ("header value", total.upcast()),
            ],
        );
    }

    fn render_timeframes(self: &Rc<Self>, selected: Timeframe) {
        let row = gtk::Box::new(Orientation::Horizontal, 4);
        row.add_css_class("timeframe");
        row.set_accessible_role(gtk::AccessibleRole::TabList);
        row.set_homogeneous(true);
        let mut previous: Option<gtk::ToggleButton> = None;

        for timeframe in Timeframe::ALL {
            let title = label(timeframe.short_title(), 0.5);
            title.set_ellipsize(gtk::pango::EllipsizeMode::End);
            title.set_accessible_role(gtk::AccessibleRole::Presentation);
            let button = gtk::ToggleButton::builder().child(&title).build();
            button.set_accessible_role(gtk::AccessibleRole::Tab);
            button.update_property(&[gtk::accessible::Property::Label(timeframe.short_title())]);
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
            self.register_focus_target(FocusTarget::Timeframe(timeframe), &button);
            row.append(&button);
            previous = Some(button);
        }
        row.set_margin_top(14);
        self.content.append(&row);
        self.record_render_landmark(RenderLandmarkKind::TimeframeTabs, &row);
    }

    fn render_stats(
        &self,
        timeframe: Timeframe,
        range: &UsageRange,
        presentation: UsagePresentation,
    ) {
        let section = section_box("section", 8);
        let grid = gtk::Grid::builder()
            .column_spacing(16)
            .row_spacing(8)
            .build();
        append_stat(
            &grid,
            0,
            timeframe.hero_title(),
            &presentation
                .total_tokens
                .map(format_full_tokens)
                .unwrap_or_else(|| "n/a".into()),
        );
        append_stat(&grid, 1, "Scope", "All platforms");
        append_stat(
            &grid,
            2,
            "Average/day",
            &presentation
                .average_daily_tokens
                .map(format_tokens)
                .unwrap_or_else(|| "n/a".into()),
        );
        append_stat(
            &grid,
            3,
            "Peak day",
            &presentation
                .peak_daily_tokens
                .map(format_tokens)
                .unwrap_or_else(|| "n/a".into()),
        );
        append_stat(
            &grid,
            4,
            "Active days",
            &presentation
                .active_days
                .map(|value| value.to_string())
                .unwrap_or_else(|| "n/a".into()),
        );
        let history_status = if !presentation.daily_history_available {
            "Unavailable"
        } else if presentation.daily_history_partial {
            "Partial"
        } else {
            "Available"
        };
        append_stat(&grid, 5, "Daily history", history_status);
        if presentation.has_unreconciled_all_time_total {
            append_stat(&grid, 6, "Data quality", "All-time total unavailable");
        }
        section.append(&grid);
        if range.did_overflow() || range.rejected_bucket_count() > 0 {
            let warning = label(
                "Some daily values were invalid or too large; affected totals are unavailable.",
                0.0,
            );
            warning.set_wrap(true);
            warning.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            warning.add_css_class("warning-message");
            section.append(&warning);
        } else if presentation.has_unreconciled_all_time_total {
            let warning = label(
                "The all-time total is unavailable because summary data could not be reconciled with the reported peak and daily history.",
                0.0,
            );
            warning.set_wrap(true);
            warning.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            warning.add_css_class("warning-message");
            section.append(&warning);
        } else if presentation.daily_history_partial {
            let warning = label(
                "Daily history covers less usage than the all-time summary; the chart and history show only available days.",
                0.0,
            );
            warning.set_wrap(true);
            warning.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            warning.add_css_class("warning-message");
            section.append(&warning);
        }
        self.content.append(&section);
        self.record_render_landmark(RenderLandmarkKind::Summary, &section);
    }

    fn render_chart(
        &self,
        timeframe: Timeframe,
        range: &UsageRange,
        presentation: UsagePresentation,
    ) {
        let chart_buckets = range.chart_buckets();
        let section = section_box("section", 9);
        let header = gtk::Box::new(Orientation::Horizontal, 8);
        let title = section_title(if timeframe == Timeframe::All {
            "All-time activity"
        } else {
            "Recent activity"
        });
        title.set_hexpand(true);
        let chart_data_available =
            presentation.daily_history_available && !range.merge_did_overflow();
        let visible_peak = if chart_data_available {
            Some(range.peak_daily_tokens())
        } else {
            None
        };
        let peak = label(
            &visible_peak
                .filter(|value| *value > 0)
                .map(|value| {
                    if presentation.daily_history_partial {
                        format!("{} visible peak", format_tokens(value))
                    } else {
                        format!("{} peak", format_tokens(value))
                    }
                })
                .unwrap_or_else(|| {
                    if range.merge_did_overflow() {
                        "Peak unavailable".into()
                    } else if presentation.daily_history_available {
                        if presentation.daily_history_partial {
                            "No visible usage".into()
                        } else {
                            "No usage".into()
                        }
                    } else {
                        "Unavailable".into()
                    }
                }),
            1.0,
        );
        peak.add_css_class("muted");
        peak.add_css_class("chart-peak");
        header.append(&title);
        header.append(&peak);
        section.append(&header);
        let chart = usage_chart(&chart_buckets, timeframe, chart_data_available);
        self.register_focus_target(FocusTarget::Chart, &chart);
        section.append(&chart);
        self.content.append(&section);
        self.record_render_landmark(RenderLandmarkKind::Chart, &section);
    }

    fn render_history(
        self: &Rc<Self>,
        timeframe: Timeframe,
        range: &UsageRange,
        daily_history_available: bool,
    ) {
        let section = section_box("section", 6);
        let title = section_title(timeframe.history_title());
        section.append(&title);

        let mut history = if daily_history_available {
            range.history()
        } else {
            Vec::new()
        };
        history.reverse();
        let (page, page_count, page_range) =
            history_page_bounds(history.len(), self.history_page.get());
        self.history_page.set(page);

        if !daily_history_available {
            let grid = gtk::Grid::builder().column_spacing(16).build();
            append_stat(&grid, 0, "History", "Unavailable");
            section.append(&grid);
        } else if history.is_empty() {
            let grid = gtk::Grid::builder().column_spacing(16).build();
            append_stat(&grid, 0, "History", "No active days");
            section.append(&grid);
        } else {
            for bucket in &history[page_range] {
                section.append(&history_row(bucket));
            }
        }

        if page_count > 1 {
            let pager = gtk::Box::new(Orientation::Horizontal, 8);
            let newer = gtk::Button::from_icon_name("go-previous-symbolic");
            newer.add_css_class("flat");
            newer.add_css_class("pager-button");
            newer.set_tooltip_text(Some("Newer"));
            newer.update_property(&[gtk::accessible::Property::Label("Newer history page")]);
            newer.set_sensitive(page > 0);
            self.register_focus_target(FocusTarget::HistoryNewer, &newer);
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
            older.update_property(&[gtk::accessible::Property::Label("Older history page")]);
            older.set_sensitive(page + 1 < page_count);
            self.register_focus_target(FocusTarget::HistoryOlder, &older);
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
        self.record_render_landmark(RenderLandmarkKind::History, &section);
    }

    fn render_rate_limits(&self, snapshot: &UsageSnapshot) {
        let section = section_box("section", 5);
        let title = section_title("Rate limits");
        section.append(&title);

        let response = snapshot.rate_limits.as_ref();
        let has_data_quality_issues = response.is_some_and(has_rate_limit_decoding_issues);
        let limit = response.and_then(AccountRateLimitsResponse::preferred_codex_limit);
        if let Some(limit) = limit {
            if let Some(primary) = limit.primary.as_ref() {
                let (view, reset) = limit_window("Primary", primary, self.now());
                section.append(&view);
                self.relative_labels
                    .borrow_mut()
                    .push(RelativeLabel::Reset {
                        label: reset,
                        resets_at: primary.resets_at,
                    });
            }
            if let Some(secondary) = limit.secondary.as_ref() {
                let (view, reset) = limit_window("Secondary", secondary, self.now());
                section.append(&view);
                self.relative_labels
                    .borrow_mut()
                    .push(RelativeLabel::Reset {
                        label: reset,
                        resets_at: secondary.resets_at,
                    });
            }
            if let Some(individual) = limit.individual_limit.as_ref() {
                let (view, reset) = individual_limit_window(individual, self.now());
                section.append(&view);
                self.relative_labels
                    .borrow_mut()
                    .push(RelativeLabel::Reset {
                        label: reset,
                        resets_at: individual.resets_at,
                    });
            }
            let grid = gtk::Grid::builder()
                .column_spacing(16)
                .row_spacing(6)
                .build();
            let mut row = 0;
            if limit.primary.is_none()
                && limit.secondary.is_none()
                && limit.individual_limit.is_none()
            {
                append_stat(
                    &grid,
                    row,
                    "Window",
                    if has_data_quality_issues {
                        "Some data unavailable"
                    } else {
                        "No active limit"
                    },
                );
                row += 1;
            }
            let plan = limit
                .plan_type
                .as_deref()
                .map(|value| clean_remote_value(value, RATE_TEXT_LIMIT))
                .unwrap_or_else(|| "n/a".into());
            append_stat(&grid, row, "Plan", &plan);
            row += 1;

            if let Some(credits) = limit.credits.as_ref() {
                append_stat(&grid, row, "Credits", &format_credits(credits));
                row += 1;
            }

            if let Some(reached_type) =
                limit_reached_status(limit.rate_limit_reached_type.as_deref())
            {
                append_stat(&grid, row, "Limit reached", &reached_type);
                row += 1;
            }

            let reset_credits = response
                .and_then(|limits| limits.rate_limit_reset_credits.as_ref())
                .map(|credits| credits.available_count.to_string())
                .unwrap_or_else(|| "n/a".into());
            append_stat(&grid, row, "Reset credits", &reset_credits);
            row += 1;
            if has_data_quality_issues {
                append_stat(
                    &grid,
                    row,
                    "Data quality",
                    "Some rate-limit fields were omitted",
                );
            }
            section.append(&grid);
        } else {
            let grid = gtk::Grid::builder()
                .column_spacing(16)
                .row_spacing(6)
                .build();
            append_stat(
                &grid,
                0,
                "Window",
                if has_data_quality_issues {
                    "Some data unavailable"
                } else {
                    "No data"
                },
            );
            let reset_credits = response
                .and_then(|limits| limits.rate_limit_reset_credits.as_ref())
                .map(|credits| credits.available_count.to_string())
                .unwrap_or_else(|| "n/a".into());
            append_stat(&grid, 1, "Reset credits", &reset_credits);
            if has_data_quality_issues {
                append_stat(
                    &grid,
                    2,
                    "Data quality",
                    "Some rate-limit fields were omitted",
                );
            }
            section.append(&grid);
        }
        self.content.append(&section);
        self.record_render_landmark(RenderLandmarkKind::RateLimits, &section);
    }

    fn render_actions(self: &Rc<Self>) {
        let actions = gtk::Box::new(Orientation::Vertical, 0);
        let refresh = action_button(
            if self.refreshing.get() {
                "Refreshing…"
            } else if self.snapshot.borrow().is_none() {
                "Retry"
            } else {
                "Refresh"
            },
            "view-refresh-symbolic",
        );
        refresh.set_sensitive(!self.refreshing.get());
        self.register_focus_target(FocusTarget::Refresh, &refresh);
        let weak = Rc::downgrade(self);
        refresh.connect_clicked(move |_| {
            if let Some(controller) = weak.upgrade() {
                controller.start_refresh();
            }
        });

        let autostart = gtk::CheckButton::with_label("Open at Login");
        autostart.set_active(rendered_autostart_enabled(self.live, autostart::is_enabled));
        autostart.add_css_class("action-check");
        self.register_focus_target(FocusTarget::Autostart, &autostart);
        let weak = Rc::downgrade(self);
        autostart.connect_toggled(move |button| {
            if let Some(controller) = weak.upgrade() {
                controller.set_autostart(button.is_active());
            }
        });

        let quit = action_button("Quit", "application-exit-symbolic");
        self.register_focus_target(FocusTarget::Quit, &quit);
        let application = self.application.clone();
        quit.connect_clicked(move |_| application.quit());
        actions.append(&refresh);
        actions.append(&autostart);
        if let Some(note) = self.status_note.borrow().as_deref() {
            let note = label(note, 0.0);
            note.set_wrap(true);
            note.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            note.add_css_class("status-note");
            actions.append(&note);
        }
        actions.append(&quit);
        self.content.append(&actions);
        self.record_render_landmark(RenderLandmarkKind::Actions, &actions);
    }

    fn record_render_landmark<W>(&self, kind: RenderLandmarkKind, widget: &W)
    where
        W: IsA<gtk::Widget> + Clone,
    {
        self.render_landmarks.borrow_mut().push(RenderLandmark {
            kind,
            widget: widget.clone().upcast(),
            ink_probes: Vec::new(),
        });
    }

    fn record_render_landmark_with_probes<W>(
        &self,
        kind: RenderLandmarkKind,
        widget: &W,
        ink_probes: Vec<(&'static str, gtk::Widget)>,
    ) where
        W: IsA<gtk::Widget> + Clone,
    {
        self.render_landmarks.borrow_mut().push(RenderLandmark {
            kind,
            widget: widget.clone().upcast(),
            ink_probes,
        });
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
        presentation: UsagePresentation,
        snapshot: &UsageSnapshot,
    ) {
        if let Some(handle) = self.tray_handle.borrow().as_ref() {
            let compact_total = presentation.total_tokens.map(format_tokens);
            let status = compact_total
                .as_ref()
                .map(|total| format!("{}: {total}", timeframe.short_title()))
                .unwrap_or_else(|| format!("{}: unavailable", timeframe.short_title()));
            let mut description = presentation
                .total_tokens
                .map(|total| format!("{} tokens", format_full_tokens(total)))
                .unwrap_or_else(|| "Token total unavailable".into());
            description.push_str(&format!(
                " · refreshed {}",
                relative_age(snapshot.fetched_at, self.now())
            ));
            let refresh_error = self.last_error.borrow().clone();
            if let Some(error) = refresh_error.as_deref() {
                description = format!("Refresh failed: {} · {description}", clean_message(error));
            }
            handle.update(|tray| {
                tray.timeframe = timeframe;
                tray.status_line = status;
                tray.status_value = compact_total.unwrap_or_else(|| "?".into());
                tray.description = description;
                tray.has_error = refresh_error.is_some() || presentation.total_tokens.is_none();
                tray.autostart = autostart::is_enabled();
            });
        }
    }
}

fn validate_popover_pixels(
    pixels: &[u8],
    stride: usize,
    width: usize,
    height: usize,
) -> Result<[u8; 4], String> {
    let required = stride
        .checked_mul(height)
        .ok_or_else(|| "Popover pixel dimensions overflowed".to_string())?;
    if width == 0 || height == 0 || stride < width.saturating_mul(4) || pixels.len() < required {
        return Err("Popover returned an invalid pixel buffer".into());
    }
    // The opaque window background covers a strict majority of these compact
    // fixtures. Boyer-Moore finds that color without a potentially huge map of
    // antialiased pixel colors for user-requested 2000x2000 renders.
    let mut background = [0_u8; 4];
    let mut background_votes = 0_usize;
    for y in 0..height {
        for x in 0..width {
            let index = y * stride + x * 4;
            let pixel: [u8; 4] = pixels[index..index + 4]
                .try_into()
                .map_err(|_| "Popover pixel buffer was truncated".to_string())?;
            if pixel[3] != u8::MAX {
                return Err(format!("Popover contains a transparent pixel at {x},{y}"));
            }
            if background_votes == 0 {
                background = pixel;
                background_votes = 1;
            } else if pixel == background {
                background_votes += 1;
            } else {
                background_votes -= 1;
            }
        }
    }
    let background_count = (0..height)
        .flat_map(|y| (0..width).map(move |x| (y, x)))
        .filter(|(y, x)| {
            let index = *y * stride + *x * 4;
            pixels[index..index + 4] == background
        })
        .count();
    if background_count <= width.saturating_mul(height) / 2 {
        return Err("Popover had no stable majority background color".into());
    }
    if background_count == width.saturating_mul(height) {
        return Err("Popover was entirely blank".into());
    }
    Ok(background)
}

#[allow(clippy::too_many_arguments)]
fn validate_landmark_ink(
    pixels: &[u8],
    stride: usize,
    width: usize,
    height: usize,
    background: [u8; 4],
    bounds: gtk::graphene::Rect,
    name: &str,
) -> Result<(), String> {
    let left = bounds.x().floor().max(0.0) as usize;
    let top = bounds.y().floor().max(0.0) as usize;
    let right = (bounds.x() + bounds.width()).ceil().max(0.0) as usize;
    let bottom = (bounds.y() + bounds.height()).ceil().max(0.0) as usize;
    let right = right.min(width);
    let bottom = bottom.min(height);
    if left >= right || top >= bottom {
        return Err(format!(
            "Popover {name} landmark was outside the rendered viewport"
        ));
    }
    let ink = (top..bottom)
        .flat_map(|y| (left..right).map(move |x| (y, x)))
        .filter(|(y, x)| {
            let index = *y * stride + *x * 4;
            pixels[index..index + 4] != background
        })
        .count();
    let area = (right - left).saturating_mul(bottom - top);
    let minimum_ink = (area / 500).max(24);
    if ink < minimum_ink {
        return Err(format!(
            "Popover {name} landmark had only {ink} non-background pixels; expected at least {minimum_ink}"
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_disjoint_ink_regions(
    pixels: &[u8],
    stride: usize,
    width: usize,
    height: usize,
    background: [u8; 4],
    regions: &[(&str, gtk::graphene::Rect)],
) -> Result<(), String> {
    let mut previous_right = None;
    for (name, bounds) in regions {
        if !bounds.x().is_finite()
            || !bounds.y().is_finite()
            || !bounds.width().is_finite()
            || !bounds.height().is_finite()
            || bounds.width() < 1.0
            || bounds.height() < 1.0
        {
            return Err(format!(
                "Popover {name} ink probe had invalid bounds {bounds:?}"
            ));
        }
        if previous_right.is_some_and(|right| bounds.x() < right - 0.5) {
            return Err(format!(
                "Popover {name} ink probe overlapped the prior region"
            ));
        }
        previous_right = Some(bounds.x() + bounds.width());
        validate_landmark_ink(pixels, stride, width, height, background, *bounds, name)?;
    }
    Ok(())
}

fn update_window_palette(window: &gtk::ApplicationWindow) {
    let (dark, high_contrast) = gtk::Settings::default()
        .map(|settings| {
            let theme_name = settings.property::<String>("gtk-theme-name");
            (
                dark_theme_requested(settings.is_gtk_application_prefer_dark_theme(), &theme_name),
                high_contrast_theme(&theme_name),
            )
        })
        .unwrap_or((false, false));
    set_window_palette(window, dark, high_contrast);
}

fn set_window_palette(window: &gtk::ApplicationWindow, dark: bool, high_contrast: bool) {
    window.remove_css_class("codex-light");
    window.remove_css_class("codex-dark");
    window.remove_css_class("codex-system");
    if high_contrast {
        window.add_css_class("codex-system");
    } else if dark {
        window.add_css_class("codex-dark");
    } else {
        window.add_css_class("codex-light");
    }
    window.queue_draw();
}

fn high_contrast_theme(theme_name: &str) -> bool {
    let normalized = theme_name.to_ascii_lowercase();
    normalized.contains("highcontrast") || normalized.contains("high-contrast")
}

fn dark_theme_requested(prefer_dark: bool, theme_name: &str) -> bool {
    let normalized = theme_name.to_ascii_lowercase();
    prefer_dark
        || normalized.ends_with("dark")
        || normalized.contains("-dark-")
        || normalized.contains("_dark_")
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

fn position_sway_popover(anchor: Option<(i32, i32)>, application_id: &str) {
    if std::env::var_os("SWAYSOCK").is_none() {
        return;
    }
    let selector = sway_window_selector(application_id, std::process::id());
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(80));
        run_sway_command(&format!("{selector} floating enable"));
        run_sway_command(&format!(
            "{selector} resize set width {POPOVER_WIDTH} px height {POPOVER_HEIGHT} px"
        ));
        let command = if let Some((anchor_x, anchor_y)) = anchor {
            let (x, y) = sway_popover_position((anchor_x, anchor_y)).unwrap_or_else(|| {
                let x = anchor_x.saturating_sub(POPOVER_WIDTH).saturating_add(18);
                let y = if anchor_y > POPOVER_HEIGHT + 20 {
                    anchor_y.saturating_sub(POPOVER_HEIGHT).saturating_sub(10)
                } else {
                    anchor_y.saturating_add(30)
                };
                (x, y)
            });
            format!("{selector} move position {x} {y}")
        } else {
            format!("{selector} move position center")
        };
        run_sway_command(&command);
    });
}

fn sway_window_selector(application_id: &str, process_id: u32) -> String {
    let mut pattern = String::with_capacity(application_id.len() + 2);
    pattern.push('^');
    for character in application_id.chars() {
        if matches!(
            character,
            '\\' | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
        ) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern.push('$');
    format!("[app_id=\"{pattern}\" pid={process_id}]")
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
    let rect = outputs
        .as_array()?
        .iter()
        .filter(|output| output.get("active").and_then(|value| value.as_bool()) == Some(true))
        .filter_map(|output| sway_output_rect(output.get("rect")?))
        .find(|rect| {
            anchor_x >= rect.x
                && anchor_x < rect.right
                && anchor_y >= rect.y
                && anchor_y < rect.bottom
        })?;
    let maximum_x = rect.right.saturating_sub(POPOVER_WIDTH).max(rect.x);
    let maximum_y = rect.bottom.saturating_sub(POPOVER_HEIGHT).max(rect.y);
    let x = anchor_x
        .saturating_sub(POPOVER_WIDTH)
        .saturating_add(18)
        .clamp(rect.x, maximum_x);
    let proposed_y = if anchor_y >= rect.y.saturating_add(rect.height / 2) {
        anchor_y.saturating_sub(POPOVER_HEIGHT).saturating_sub(10)
    } else {
        anchor_y.saturating_add(30)
    };
    Some((x, proposed_y.clamp(rect.y, maximum_y)))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SwayOutputRect {
    x: i32,
    y: i32,
    height: i32,
    right: i32,
    bottom: i32,
}

fn sway_output_rect(value: &serde_json::Value) -> Option<SwayOutputRect> {
    let x = i32::try_from(value.get("x")?.as_i64()?).ok()?;
    let y = i32::try_from(value.get("y")?.as_i64()?).ok()?;
    let width = i32::try_from(value.get("width")?.as_i64()?).ok()?;
    let height = i32::try_from(value.get("height")?.as_i64()?).ok()?;
    if width <= 0 || height <= 0 {
        return None;
    }
    Some(SwayOutputRect {
        x,
        y,
        height,
        right: x.checked_add(width)?,
        bottom: y.checked_add(height)?,
    })
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

fn history_page_count(item_count: usize) -> usize {
    item_count.div_ceil(HISTORY_PAGE_SIZE).max(1)
}

fn rendered_autostart_enabled(live: bool, read_live_value: impl FnOnce() -> bool) -> bool {
    live && read_live_value()
}

fn history_page_bounds(
    item_count: usize,
    requested_page: usize,
) -> (usize, usize, std::ops::Range<usize>) {
    let page_count = history_page_count(item_count);
    let page = requested_page.min(page_count - 1);
    let start = page.saturating_mul(HISTORY_PAGE_SIZE).min(item_count);
    let end = start.saturating_add(HISTORY_PAGE_SIZE).min(item_count);
    (page, page_count, start..end)
}

fn section_box(class: &str, spacing: i32) -> gtk::Box {
    let section = gtk::Box::new(Orientation::Vertical, spacing);
    section.add_css_class(class);
    section
}

fn section_title(text: &str) -> gtk::Label {
    let title = label(text, 0.0);
    title.add_css_class("section-title");
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    title.set_tooltip_text(Some(text));
    title.set_accessible_role(gtk::AccessibleRole::Heading);
    title
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
    let name_text = name.to_string();
    let value_text = value.to_string();
    let name = label(&name_text, 0.0);
    name.add_css_class("stat-label");
    name.set_hexpand(true);
    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
    name.set_tooltip_text(Some(&name_text));
    name.set_accessible_role(gtk::AccessibleRole::Presentation);
    let value = label(&value_text, 1.0);
    value.add_css_class("stat-value");
    value.set_max_width_chars(24);
    value.set_ellipsize(gtk::pango::EllipsizeMode::End);
    value.set_tooltip_text(Some(&value_text));
    value.update_property(&[gtk::accessible::Property::Label(&format!(
        "{name_text}: {value_text}"
    ))]);
    grid.attach(&name, 0, row, 1, 1);
    grid.attach(&value, 1, row, 1, 1);
}

fn history_row(bucket: &DailyUsageBucket) -> gtk::Box {
    let row = gtk::Box::new(Orientation::Horizontal, 10);
    let date = label(&bucket.start_date, 0.0);
    date.add_css_class("history-date");
    date.add_css_class("muted");
    date.set_hexpand(true);
    date.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let icon = history_icon();
    let value = label(&format_full_tokens(bucket.tokens), 1.0);
    value.add_css_class("history-value");
    value.set_ellipsize(gtk::pango::EllipsizeMode::End);
    row.set_tooltip_text(Some(&format!(
        "{}: {} tokens",
        bucket.start_date,
        format_full_tokens(bucket.tokens)
    )));
    row.update_property(&[gtk::accessible::Property::Label(&format!(
        "{}: {} tokens",
        bucket.start_date,
        format_full_tokens(bucket.tokens)
    ))]);
    date.set_accessible_role(gtk::AccessibleRole::Presentation);
    value.set_accessible_role(gtk::AccessibleRole::Presentation);
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

fn limit_window(
    title: &str,
    window: &RateLimitWindow,
    now: DateTime<Local>,
) -> (gtk::Box, gtk::Label) {
    let box_ = gtk::Box::new(Orientation::Vertical, 0);
    box_.append(&limit_heading(title, &format_percent(window.used_percent)));
    box_.append(&limit_window_duration_row(
        title,
        window.window_duration_mins,
    ));
    let progress = limit_progress(title, window.used_percent);
    let reset = muted_label(&reset_description(window.resets_at, now));
    reset.add_css_class("limit-reset");
    let details = gtk::Box::new(Orientation::Horizontal, 8);
    details.set_margin_bottom(5);
    details.append(&progress);
    details.append(&reset);
    box_.append(&details);
    (box_, reset)
}

fn individual_limit_window(
    limit: &SpendControlLimitSnapshot,
    now: DateTime<Local>,
) -> (gtk::Box, gtk::Label) {
    let box_ = gtk::Box::new(Orientation::Vertical, 0);
    box_.append(&limit_heading(
        "Individual",
        &limit
            .used_percent
            .map(format_percent)
            .unwrap_or_else(|| "n/a".into()),
    ));
    if limit.used.is_some() || limit.limit.is_some() {
        box_.append(&limit_value_row(
            "Individual used",
            &limit
                .used
                .as_deref()
                .map(|value| clean_remote_value(value, RATE_TEXT_LIMIT))
                .unwrap_or_else(|| "n/a".into()),
        ));
        box_.append(&limit_value_row(
            "Individual limit",
            &limit
                .limit
                .as_deref()
                .map(|value| clean_remote_value(value, RATE_TEXT_LIMIT))
                .unwrap_or_else(|| "n/a".into()),
        ));
    }
    let details = gtk::Box::new(Orientation::Horizontal, 8);
    details.set_margin_bottom(5);
    if let Some(used_percent) = limit
        .used_percent
        .filter(|value| value.is_finite() && *value >= 0.0)
    {
        details.append(&limit_progress("Individual", used_percent));
    } else {
        let unavailable = muted_label("Usage unavailable");
        unavailable.set_hexpand(true);
        unavailable.update_property(&[gtk::accessible::Property::Label(
            "Individual usage unavailable",
        )]);
        details.append(&unavailable);
    }
    let reset = muted_label(&reset_description(limit.resets_at, now));
    reset.add_css_class("limit-reset");
    details.append(&reset);
    box_.append(&details);
    (box_, reset)
}

fn limit_heading(title: &str, value: &str) -> gtk::Box {
    let heading = gtk::Box::new(Orientation::Horizontal, 8);
    heading.add_css_class("limit-heading");
    let title_label = label(title, 0.0);
    title_label.add_css_class("stat-label");
    title_label.set_hexpand(true);
    let value_label = label(value, 1.0);
    value_label.add_css_class("stat-value");
    value_label.set_max_width_chars(18);
    value_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    value_label.set_tooltip_text(Some(value));
    heading.append(&title_label);
    heading.append(&value_label);
    heading
}

fn limit_window_duration_row(title: &str, minutes: Option<i64>) -> gtk::Box {
    limit_value_row(&format!("{title} window"), &format_window_duration(minutes))
}

fn limit_value_row(name: &str, value: &str) -> gtk::Box {
    let row = gtk::Box::new(Orientation::Horizontal, 8);
    let name_label = label(name, 0.0);
    name_label.add_css_class("stat-label");
    name_label.set_hexpand(true);
    name_label.set_accessible_role(gtk::AccessibleRole::Presentation);
    let value_label = label(value, 1.0);
    value_label.add_css_class("stat-value");
    value_label.set_accessible_role(gtk::AccessibleRole::Presentation);
    value_label.set_max_width_chars(24);
    value_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    value_label.set_tooltip_text(Some(value));
    row.update_property(&[gtk::accessible::Property::Label(&format!(
        "{name}: {value}"
    ))]);
    row.append(&name_label);
    row.append(&value_label);
    row
}

fn limit_progress(title: &str, used_percent: f64) -> gtk::ProgressBar {
    let progress = gtk::ProgressBar::new();
    progress.set_hexpand(true);
    let clamped_percent = clamped_progress_percent(used_percent);
    progress.set_fraction(clamped_percent / 100.0);
    progress.update_property(&[gtk::accessible::Property::Label(&format!(
        "{title} rate limit used: {}",
        format_percent(used_percent)
    ))]);
    if clamped_percent >= 90.0 {
        progress.add_css_class("error");
    } else if clamped_percent >= 70.0 {
        progress.add_css_class("warning");
    } else {
        progress.add_css_class("success");
    }
    progress
}

fn tray_anchor(x: i32, y: i32) -> Option<(i32, i32)> {
    ((x, y) != (0, 0)).then_some((x, y))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    use crate::model::CreditsSnapshot;

    #[test]
    fn anchors_inside_the_clicked_sway_output_including_negative_coordinates() {
        let outputs = serde_json::json!([
            {"active":true,"rect":{"x":-1920,"y":0,"width":1920,"height":1080}},
            {"active":true,"rect":{"x":0,"y":0,"width":1920,"height":1200}}
        ]);
        assert_eq!(
            popover_position_in_outputs((-10, 1050), &outputs),
            Some((-300, 480))
        );
        assert_eq!(
            popover_position_in_outputs((1910, 20), &outputs),
            Some((1620, 50))
        );
        assert_eq!(tray_anchor(-10, 0), Some((-10, 0)));
        assert_eq!(tray_anchor(0, -10), Some((0, -10)));
        assert_eq!(tray_anchor(0, 0), None);

        let invalid_outputs = serde_json::json!([
            {"active":false,"rect":{"x":0,"y":0,"width":1920,"height":1080}},
            {"rect":{"x":2147483600_i64,"y":0,"width":1000,"height":1080}}
        ]);
        assert_eq!(
            popover_position_in_outputs((20, 20), &invalid_outputs),
            None
        );
    }

    #[test]
    fn sway_selector_is_exact_and_scoped_to_one_numeric_process_id() {
        assert_eq!(
            sway_window_selector("io.github.conjfrnk.CodexUsageBar.Popover", 4_242),
            "[app_id=\"^io\\.github\\.conjfrnk\\.CodexUsageBar\\.Popover$\" pid=4242]"
        );
    }

    #[test]
    fn focus_restore_order_uses_safe_boundary_and_refresh_fallbacks() {
        assert_eq!(
            focus_restore_order(FocusTarget::HistoryOlder),
            [
                Some(FocusTarget::HistoryOlder),
                Some(FocusTarget::HistoryNewer),
                Some(FocusTarget::Refresh),
                Some(FocusTarget::Autostart),
            ]
        );
        assert_eq!(
            focus_restore_order(FocusTarget::HistoryNewer),
            [
                Some(FocusTarget::HistoryNewer),
                Some(FocusTarget::HistoryOlder),
                Some(FocusTarget::Refresh),
                Some(FocusTarget::Autostart),
            ]
        );
        assert_eq!(
            focus_restore_order(FocusTarget::Refresh),
            [
                Some(FocusTarget::Refresh),
                Some(FocusTarget::Autostart),
                Some(FocusTarget::Quit),
                None,
            ]
        );
    }

    #[test]
    fn rate_percent_and_message_formatting_match_macos_rules() {
        assert_eq!(format_percent(42.0), "42%");
        assert_eq!(format_percent(42.01), "42.0%");
        assert_eq!(format_percent(31.5), "31.5%");
        assert_eq!(format_percent(f64::INFINITY), "n/a");
        assert_eq!(format_percent(-1.0), "n/a");
        assert_eq!(format_percent(-0.0), "0%");
        assert_eq!(format_percent(120.0), "120%");
        assert_eq!(format_percent(1e9), "1.0E+09%");
        assert_eq!(format_percent(1e300), "1.0E+300%");
        assert!(format_percent(1e300).len() < 16);
        assert_eq!(clamped_progress_percent(120.0), 100.0);
        assert_eq!(clamped_progress_percent(-1.0), 0.0);
        assert_eq!(clamped_progress_percent(-0.0).to_bits(), 0.0_f64.to_bits());
        assert_eq!(format_window_duration(None), "n/a");
        assert_eq!(format_window_duration(Some(0)), "0m");
        assert_eq!(format_window_duration(Some(90)), "1h 30m");
        assert_eq!(format_window_duration(Some(300)), "5h");
        assert_eq!(format_window_duration(Some(10_080)), "7d");
        assert_eq!(
            format_window_duration(Some(i64::MAX)),
            "6405119470038038d 18h"
        );

        let message = "é".repeat(141);
        let clean = clean_status_message(&message);
        assert_eq!(clean.chars().count(), 140);
        assert!(clean.ends_with("..."));
        assert_eq!(
            clean_message("failed\n\u{001b}[31m  now\u{202e}"),
            "failed [31m now"
        );
        assert_eq!(clean_message("\n\t\u{202e}"), "Unknown error");
        assert_eq!(
            clean_remote_value("\u{2066} pro\npl\u{00ad}an ", 40),
            "pro pl an"
        );
        assert_eq!(clean_remote_value("pro\u{0001}plan", 40), "pro plan");
        assert_eq!(clean_remote_value("pro\u{fdd0}plan", 40), "pro plan");
        assert_eq!(clean_remote_value("pro\u{1fffe}plan", 40), "pro plan");
        assert_eq!(format_credit(12.50), "12.5");
        assert_eq!(format_credit(-0.0), "0");
        assert_eq!(format_credit(0.001), "0.001");
        assert_eq!(format_credit(0.00001), "1E-05");
        assert_eq!(format_credit(1.234567), "1.234567");
        assert_eq!(format_credit(1_234_567_890_123.0), "1234567890123");
        assert_eq!(
            format_credit(9.223_372_036_854_78e18),
            "9.22337203685478E+18"
        );
        assert_eq!(format_credit(f64::NAN), "n/a");
        assert_eq!(
            hero_accessible_label(Some(12_345_678)),
            "Usage summary, total token usage: 12,345,678 tokens"
        );
        assert_eq!(
            hero_accessible_label(None),
            "Usage summary, total token usage unavailable"
        );
        assert_eq!(
            LOADING_HERO_ACCESSIBLE_LABEL,
            "Usage summary, loading account usage"
        );
        assert_eq!(
            UNAVAILABLE_HERO_ACCESSIBLE_LABEL,
            "Usage summary, account usage unavailable"
        );
        let css = include_str!("style.css");
        assert!(css.contains(".chart:focus-visible"));
        assert!(css.contains("codex-system .chart:focus-visible"));
        assert!(high_contrast_theme("HighContrast"));
        assert!(high_contrast_theme("my-high-contrast-theme"));
        assert!(!high_contrast_theme("Adwaita-dark"));
        assert!(!rendered_autostart_enabled(false, || {
            panic!("fixtures must not read host autostart state")
        }));
        assert!(rendered_autostart_enabled(true, || true));
        assert!(!rendered_autostart_enabled(true, || false));

        let unsafe_prefix = format!("{}safe", "\u{202e}".repeat(100_000));
        assert_eq!(clean_remote_value(&unsafe_prefix, 40), "n/a");
        let unsafe_suffix = format!("ok{}", "\u{202e}".repeat(100_000));
        let bounded_suffix = clean_remote_value(&unsafe_suffix, 40);
        assert_eq!(bounded_suffix, "ok...");
        assert!(bounded_suffix.chars().count() <= 40);
        let legitimate_rate_value = "x".repeat(RATE_TEXT_LIMIT);
        assert_eq!(
            clean_remote_value(&legitimate_rate_value, RATE_TEXT_LIMIT),
            legitimate_rate_value
        );
        assert_eq!(
            clean_remote_value(
                &format!("{}   \n\t", "x".repeat(RATE_TEXT_LIMIT)),
                RATE_TEXT_LIMIT
            ),
            legitimate_rate_value
        );
        assert_eq!(
            clean_remote_value(
                &format!("{} y", "x".repeat(RATE_TEXT_LIMIT)),
                RATE_TEXT_LIMIT
            ),
            format!("{}...", "x".repeat(RATE_TEXT_LIMIT - 3))
        );
    }

    #[test]
    fn rate_credit_and_quality_presentations_keep_protocol_meaning() {
        let contradictory = CreditsSnapshot {
            has_credits: Some(false),
            unlimited: Some(true),
            balance: Some("999".into()),
            remaining: Some(999.0),
            total: Some(999.0),
            used: Some(0.0),
            decoding_issues: Vec::new(),
        };
        assert_eq!(format_credits(&contradictory), "Unlimited");
        assert_eq!(
            format_credits(&CreditsSnapshot {
                unlimited: Some(false),
                ..contradictory.clone()
            }),
            "None"
        );

        let balanced = CreditsSnapshot {
            remaining: Some(14.0),
            total: Some(20.0),
            used: Some(6.0),
            ..CreditsSnapshot::default()
        };
        assert_eq!(format_credits(&balanced), "14 / 20 remaining");
        assert_eq!(
            format_credits(&CreditsSnapshot {
                remaining: Some(0.001),
                ..CreditsSnapshot::default()
            }),
            "0.001 remaining"
        );
        assert_eq!(
            format_credits(&CreditsSnapshot {
                remaining: Some(30.0),
                total: Some(20.0),
                used: Some(8.0),
                ..CreditsSnapshot::default()
            }),
            "8 / 20 used"
        );
        assert_eq!(
            format_credits(&CreditsSnapshot {
                remaining: Some(30.0),
                total: Some(20.0),
                used: Some(25.0),
                ..CreditsSnapshot::default()
            }),
            "25 used"
        );
        assert_eq!(
            format_credits(&CreditsSnapshot {
                has_credits: Some(true),
                balance: Some("12.50".into()),
                ..CreditsSnapshot::default()
            }),
            "12.50"
        );
        assert_eq!(limit_reached_status(None), None);
        assert_eq!(limit_reached_status(Some("weekly")), Some("weekly".into()));
        assert_eq!(
            limit_reached_status(Some("\u{202e}")),
            Some("Reported".into())
        );

        let response = AccountRateLimitsResponse {
            decoding_issues: vec!["rateLimits.primary: malformed".into()],
            ..AccountRateLimitsResponse::default()
        };
        assert!(has_rate_limit_decoding_issues(&response));
        assert!(!has_rate_limit_decoding_issues(
            &AccountRateLimitsResponse::default()
        ));
    }

    #[test]
    fn every_timeframe_history_uses_six_row_pages() {
        assert_eq!(history_page_count(0), 1);
        assert_eq!(history_page_count(6), 1);
        assert_eq!(history_page_count(7), 2);
        assert_eq!(history_page_count(30), 5);
        for item_count in [7, 30, 90, 120] {
            let page_count = history_page_count(item_count);
            let mut visited = Vec::new();
            for requested in 0..page_count {
                let (page, count, range) = history_page_bounds(item_count, requested);
                assert_eq!(page, requested);
                assert_eq!(count, page_count);
                assert!(range.len() <= HISTORY_PAGE_SIZE);
                visited.extend(range);
            }
            assert_eq!(visited, (0..item_count).collect::<Vec<_>>());
            assert_eq!(
                history_page_bounds(item_count, usize::MAX).0,
                page_count - 1
            );
        }
    }

    #[test]
    fn reset_descriptions_match_macos_tense_and_now_boundaries() {
        let now = chrono::Utc
            .with_ymd_and_hms(2026, 1, 1, 0, 0, 0)
            .single()
            .unwrap()
            .with_timezone(&Local);
        let timestamp = now.timestamp() as f64;

        assert_eq!(reset_description(None, now), "reset unavailable");
        assert_eq!(
            reset_description(Some(timestamp - 3_600.0), now),
            "reset 1h ago"
        );
        assert_eq!(
            reset_description(Some(timestamp + 3_600.0), now),
            "resets in 1h"
        );
        for offset in [0.0, -0.5, 0.5] {
            assert_eq!(
                reset_description(Some(timestamp + offset), now),
                "resets now",
                "offset={offset}"
            );
        }
        assert_eq!(
            reset_description(Some(timestamp - 1.0), now),
            "reset 1s ago"
        );
        assert_eq!(
            reset_description(Some(timestamp + 1.0), now),
            "resets in 1s"
        );
    }

    #[test]
    fn relative_rate_resets_round_and_respect_dst_calendar_days() {
        let utc_now = chrono::Utc
            .with_ymd_and_hms(2026, 1, 1, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(
            relative_reset_dates(&(utc_now + chrono::Duration::milliseconds(500)), &utc_now),
            "in 0s"
        );
        assert_eq!(
            relative_reset_dates(
                &(utc_now + chrono::Duration::milliseconds(59_600)),
                &utc_now
            ),
            "in 59s"
        );
        assert_eq!(
            relative_reset_dates(&(utc_now - chrono::Duration::milliseconds(900)), &utc_now),
            "in 0s"
        );
        assert_eq!(
            relative_reset_dates(&(utc_now - chrono::Duration::seconds(1)), &utc_now),
            "1s ago"
        );
        assert_eq!(
            relative_reset_dates(&(utc_now + chrono::Duration::seconds(60)), &utc_now),
            "in 1m"
        );
        assert_eq!(
            relative_reset_dates(
                &(utc_now + chrono::Duration::milliseconds(3_599_900)),
                &utc_now
            ),
            "in 59m"
        );
        assert_eq!(
            relative_reset_dates(
                &(utc_now + chrono::Duration::minutes(23 * 60 + 36)),
                &utc_now
            ),
            "in 23h"
        );
        for (days, expected) in [
            (7, "in 1w"),
            (14, "in 2w"),
            (29, "in 4w"),
            (30, "in 4w"),
            (31, "in 1mo"),
            (59, "in 2mo"),
            (365, "in 1y"),
            (366, "in 1y"),
            (730, "in 2y"),
        ] {
            assert_eq!(
                relative_reset_dates(&(utc_now + chrono::Duration::days(days)), &utc_now),
                expected,
                "unexpected unit for {days} days"
            );
        }
        let january_31 = chrono::Utc
            .with_ymd_and_hms(2026, 1, 31, 0, 0, 0)
            .single()
            .unwrap();
        let february_28 = chrono::Utc
            .with_ymd_and_hms(2026, 2, 28, 0, 0, 0)
            .single()
            .unwrap();
        let march_1 = chrono::Utc
            .with_ymd_and_hms(2026, 3, 1, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&february_28, &january_31), "in 1mo");
        assert_eq!(relative_reset_dates(&march_1, &january_31), "in 1mo");
        let leap_day = chrono::Utc
            .with_ymd_and_hms(2024, 2, 29, 0, 0, 0)
            .single()
            .unwrap();
        let next_february_28 = chrono::Utc
            .with_ymd_and_hms(2025, 2, 28, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&next_february_28, &leap_day), "in 1y");
        assert_eq!(relative_reset_dates(&january_31, &february_28), "4w ago");
        let march_31 = chrono::Utc
            .with_ymd_and_hms(2026, 3, 31, 0, 0, 0)
            .single()
            .unwrap();
        let april_30 = chrono::Utc
            .with_ymd_and_hms(2026, 4, 30, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&february_28, &march_31), "1mo ago");
        assert_eq!(relative_reset_dates(&march_31, &april_30), "4w ago");
        assert_eq!(
            relative_reset_dates(&leap_day, &next_february_28),
            "11mo ago"
        );
        let march_1_2025 = chrono::Utc
            .with_ymd_and_hms(2025, 3, 1, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&leap_day, &march_1_2025), "1y ago");

        let standard = chrono::FixedOffset::west_opt(8 * 3_600).unwrap();
        let daylight = chrono::FixedOffset::west_opt(7 * 3_600).unwrap();
        let before = standard
            .with_ymd_and_hms(2026, 3, 8, 0, 0, 0)
            .single()
            .unwrap();
        let after = daylight
            .with_ymd_and_hms(2026, 3, 9, 0, 0, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&after, &before), "in 1d");
        assert_eq!(
            relative_reset_dates(
                &after.with_timezone(&chrono::Utc),
                &before.with_timezone(&chrono::Utc)
            ),
            "in 23h"
        );
        let spring_short_before = standard
            .with_ymd_and_hms(2026, 3, 7, 23, 59, 0)
            .single()
            .unwrap();
        let spring_short_after = daylight
            .with_ymd_and_hms(2026, 3, 8, 3, 1, 0)
            .single()
            .unwrap();
        assert_eq!(
            relative_reset_dates(&spring_short_after, &spring_short_before),
            "in 2h"
        );

        let fall_before = daylight
            .with_ymd_and_hms(2026, 11, 1, 0, 0, 0)
            .single()
            .unwrap();
        let fall_after_24 = standard
            .with_ymd_and_hms(2026, 11, 1, 23, 0, 0)
            .single()
            .unwrap();
        let fall_after_25 = standard
            .with_ymd_and_hms(2026, 11, 2, 0, 0, 0)
            .single()
            .unwrap();
        let fall_after_26 = standard
            .with_ymd_and_hms(2026, 11, 2, 1, 0, 0)
            .single()
            .unwrap();
        let fall_after_47 = standard
            .with_ymd_and_hms(2026, 11, 2, 22, 0, 0)
            .single()
            .unwrap();
        let fall_after_48 = standard
            .with_ymd_and_hms(2026, 11, 2, 23, 0, 0)
            .single()
            .unwrap();
        let fall_short_before = daylight
            .with_ymd_and_hms(2026, 10, 31, 23, 59, 0)
            .single()
            .unwrap();
        let fall_short_after = standard
            .with_ymd_and_hms(2026, 11, 1, 2, 1, 0)
            .single()
            .unwrap();
        assert_eq!(relative_reset_dates(&fall_after_24, &fall_before), "in 24h");
        assert_eq!(relative_reset_dates(&fall_after_25, &fall_before), "in 1d");
        assert_eq!(relative_reset_dates(&fall_after_26, &fall_before), "in 1d");
        assert_eq!(relative_reset_dates(&fall_after_47, &fall_before), "in 1d");
        assert_eq!(relative_reset_dates(&fall_after_48, &fall_before), "in 1d");
        assert_eq!(
            relative_reset_dates(&fall_short_after, &fall_short_before),
            "in 3h"
        );
    }

    #[test]
    fn wall_clock_changes_force_refresh_and_are_not_reported_as_fresh() {
        let now = Local::now();
        let future = now + chrono::Duration::minutes(1);
        assert!(snapshot_needs_refresh(future, now, 300));
        assert!(relative_age(future, now).contains("clock changed"));
        assert!(!snapshot_needs_refresh(now, now, 300));
        assert!(snapshot_needs_refresh(
            now - chrono::Duration::seconds(300),
            now,
            300
        ));
    }

    #[test]
    fn missing_and_partial_daily_history_do_not_present_false_zero_metrics() {
        let mut snapshot = crate::fixture::usage_snapshot();
        let lifetime = snapshot.usage.summary.lifetime_tokens.unwrap();
        snapshot.usage.daily_usage_buckets = None;
        let month_range = UsageRange::new(Timeframe::Thirty, snapshot.buckets());
        let month = UsagePresentation::new(Timeframe::Thirty, &month_range, &snapshot);
        assert_eq!(month.total_tokens, None);
        assert_eq!(month.average_daily_tokens, None);
        let all_range = UsageRange::new(Timeframe::All, snapshot.buckets());
        let all = UsagePresentation::new(Timeframe::All, &all_range, &snapshot);
        assert_eq!(all.total_tokens, Some(lifetime));
        assert_eq!(all.active_days, None);
        assert!(!all.has_unreconciled_all_time_total);

        let mut partial_snapshot = crate::fixture::usage_snapshot();
        partial_snapshot.usage.summary.lifetime_tokens = Some(i64::MAX);
        let partial_range = UsageRange::new(Timeframe::All, partial_snapshot.buckets());
        let partial = UsagePresentation::new(Timeframe::All, &partial_range, &partial_snapshot);
        assert!(partial.daily_history_partial);
        assert_eq!(partial.total_tokens, Some(i64::MAX));
        assert_eq!(partial.average_daily_tokens, None);
        assert_eq!(partial.active_days, None);
        assert!(!partial.has_unreconciled_all_time_total);

        let mut contradictory = crate::fixture::usage_snapshot();
        let contradictory_range = UsageRange::new(Timeframe::All, contradictory.buckets());
        let daily_total = contradictory_range.total_tokens();
        contradictory.usage.summary.lifetime_tokens = Some(daily_total);
        contradictory.usage.summary.peak_daily_tokens = Some(daily_total + 1);
        let contradictory =
            UsagePresentation::new(Timeframe::All, &contradictory_range, &contradictory);
        assert!(contradictory.daily_history_partial);
        assert_eq!(contradictory.total_tokens, None);
        assert_eq!(contradictory.peak_daily_tokens, Some(daily_total + 1));
        assert!(contradictory.has_unreconciled_all_time_total);

        let mut missing = crate::fixture::usage_snapshot();
        missing.usage.daily_usage_buckets = None;
        missing.usage.summary.lifetime_tokens = Some(100);
        missing.usage.summary.peak_daily_tokens = Some(800);
        let missing_range = UsageRange::new(Timeframe::All, missing.buckets());
        let missing = UsagePresentation::new(Timeframe::All, &missing_range, &missing);
        assert_eq!(missing.total_tokens, None);
        assert_eq!(missing.peak_daily_tokens, Some(800));
        assert!(missing.has_unreconciled_all_time_total);
    }

    #[test]
    fn saturated_daily_values_are_never_presented_as_exact_totals() {
        let mut snapshot = crate::fixture::usage_snapshot();
        snapshot.usage.daily_usage_buckets = Some(vec![
            DailyUsageBucket {
                start_date: "2026-07-12".into(),
                tokens: i64::MAX,
            },
            DailyUsageBucket {
                start_date: "2026-07-12".into(),
                tokens: 1,
            },
        ]);
        let merge_range = UsageRange::at_date(
            Timeframe::All,
            snapshot.buckets(),
            NaiveDate::from_ymd_opt(2026, 7, 13).unwrap(),
        );
        assert!(merge_range.merge_did_overflow());
        let merge = UsagePresentation::new(Timeframe::All, &merge_range, &snapshot);
        assert_eq!(merge.total_tokens, None);
        assert_eq!(merge.peak_daily_tokens, None);

        snapshot.usage.daily_usage_buckets = Some(vec![
            DailyUsageBucket {
                start_date: "2026-07-11".into(),
                tokens: i64::MAX,
            },
            DailyUsageBucket {
                start_date: "2026-07-12".into(),
                tokens: i64::MAX,
            },
        ]);
        let total_range = UsageRange::at_date(
            Timeframe::All,
            snapshot.buckets(),
            NaiveDate::from_ymd_opt(2026, 7, 13).unwrap(),
        );
        assert!(!total_range.merge_did_overflow());
        assert!(total_range.total_did_overflow());
        let total = UsagePresentation::new(Timeframe::All, &total_range, &snapshot);
        assert_eq!(total.total_tokens, None);
        assert_eq!(total.peak_daily_tokens, Some(i64::MAX));
    }

    #[test]
    fn visual_oracle_rejects_blank_and_translucent_popovers() {
        let width = 300;
        let height = 560;
        let stride = width * 4;
        let mut pixels = vec![u8::MAX; stride * height];
        assert!(validate_popover_pixels(&pixels[..10], stride, width, height).is_err());
        assert!(validate_popover_pixels(&pixels, width * 4 - 1, width, height).is_err());
        assert!(validate_popover_pixels(&[], usize::MAX, 1, 2).is_err());
        assert!(validate_popover_pixels(&pixels, stride, width, height).is_err());

        for start in [10, 70, 130, 310] {
            for y in start..start + 3 {
                for x in 0..width {
                    let index = y * stride + x * 4;
                    pixels[index..index + 4].copy_from_slice(&[0, 0, 0, u8::MAX]);
                }
            }
        }
        let background = validate_popover_pixels(&pixels, stride, width, height).unwrap();
        assert_eq!(background, [u8::MAX; 4]);
        assert!(
            validate_landmark_ink(
                &pixels,
                stride,
                width,
                height,
                background,
                gtk::graphene::Rect::new(0.0, 300.0, 300.0, 20.0),
                "test",
            )
            .is_ok()
        );
        assert!(
            validate_landmark_ink(
                &pixels,
                stride,
                width,
                height,
                background,
                gtk::graphene::Rect::new(0.0, 400.0, 300.0, 20.0),
                "blank test",
            )
            .is_err()
        );

        let header_height = 20;
        let mut header_pixels = vec![u8::MAX; stride * header_height];
        let regions = [
            (
                "header logo",
                gtk::graphene::Rect::new(0.0, 0.0, 100.0, 20.0),
            ),
            (
                "header title",
                gtk::graphene::Rect::new(100.0, 0.0, 100.0, 20.0),
            ),
            (
                "header value",
                gtk::graphene::Rect::new(200.0, 0.0, 100.0, 20.0),
            ),
        ];
        for y in 5..8 {
            for x in 10..30 {
                let index = y * stride + x * 4;
                header_pixels[index..index + 4].copy_from_slice(&[0, 0, 0, u8::MAX]);
            }
        }
        let logo_only_error = validate_disjoint_ink_regions(
            &header_pixels,
            stride,
            width,
            header_height,
            [u8::MAX; 4],
            &regions,
        )
        .unwrap_err();
        assert!(logo_only_error.contains("header title"));
        for offset in [100, 200] {
            for y in 5..8 {
                for x in offset + 10..offset + 30 {
                    let index = y * stride + x * 4;
                    header_pixels[index..index + 4].copy_from_slice(&[0, 0, 0, u8::MAX]);
                }
            }
        }
        assert!(
            validate_disjoint_ink_regions(
                &header_pixels,
                stride,
                width,
                header_height,
                [u8::MAX; 4],
                &regions,
            )
            .is_ok()
        );
        pixels[3] = 0;
        assert!(
            validate_popover_pixels(&pixels, stride, width, height)
                .unwrap_err()
                .contains("transparent")
        );
    }
}
