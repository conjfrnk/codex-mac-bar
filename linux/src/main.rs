mod app_server;
mod autostart;
mod chart;
mod config;
mod fixture;
mod model;
mod range;
mod tray;
mod ui;

use std::cell::RefCell;
use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gtk::gio;
use gtk::prelude::*;

use ui::UiController;

const APPLICATION_ID: &str = "io.github.conjfrnk.CodexUsageBar";
const NO_TRAY_APPLICATION_ID: &str = "io.github.conjfrnk.CodexUsageBar.Popover";
const CLI_USAGE_ERROR: u8 = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LaunchMode {
    Background,
    Show,
    NoTray,
}

impl LaunchMode {
    fn should_present(self) -> bool {
        matches!(self, Self::Show | Self::NoTray)
    }

    fn has_tray(self) -> bool {
        self != Self::NoTray
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Appearance {
    Light,
    Dark,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderState {
    Normal,
    Stale,
    Loading,
    Error,
    Maximum,
    LongStale,
    LongError,
}

impl Appearance {
    fn title(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RenderOptions {
    path: PathBuf,
    appearance: Appearance,
    timeframe: range::Timeframe,
    width: i32,
    height: i32,
    state: RenderState,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum CliCommand {
    Help,
    Version,
    Check,
    Waybar,
    Render(RenderOptions),
    Launch(LaunchMode),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DailyHistoryQuality {
    Complete,
    Partial,
    Unavailable,
}

#[derive(Clone, Debug)]
enum PrimaryMode {
    Help,
    Version,
    Check,
    Waybar,
    Render(PathBuf),
    Launch(LaunchMode),
}

impl PrimaryMode {
    fn option_name(&self) -> &'static str {
        match self {
            Self::Help => "--help",
            Self::Version => "--version",
            Self::Check => "--check",
            Self::Waybar => "--waybar",
            Self::Render(_) => "--render-popover",
            Self::Launch(LaunchMode::Background) => "--background",
            Self::Launch(LaunchMode::Show) => "--show",
            Self::Launch(LaunchMode::NoTray) => "--no-tray",
        }
    }
}

fn main() -> gtk::glib::ExitCode {
    let arguments: Vec<_> = std::env::args_os().collect();
    let command = match parse_cli(&arguments) {
        Ok(command) => command,
        Err(error) => {
            eprintln!("{error}\nTry --help for usage.");
            return CLI_USAGE_ERROR.into();
        }
    };
    let initial_launch_mode = match command {
        CliCommand::Help => {
            print_help();
            return 0.into();
        }
        CliCommand::Version => {
            println!("codex-usage-bar {}", env!("CARGO_PKG_VERSION"));
            return 0.into();
        }
        CliCommand::Check => return check_connection(),
        CliCommand::Waybar => return print_waybar_status(),
        CliCommand::Render(options) => return render_popover_fixture(options),
        CliCommand::Launch(mode) => mode,
    };

    let application = gtk::Application::builder()
        .application_id(application_id_for(initial_launch_mode))
        .flags(application_flags_for(initial_launch_mode))
        .build();
    let controller = Rc::new(RefCell::new(None::<Rc<UiController>>));

    application.connect_command_line({
        let controller = controller.clone();
        move |application, command_line| {
            let arguments = command_line.arguments();
            let launch_mode = match parse_cli(&arguments) {
                Ok(CliCommand::Launch(mode)) => mode,
                Ok(_) => {
                    eprintln!("This command cannot be forwarded to a running application.");
                    return CLI_USAGE_ERROR.into();
                }
                Err(error) => {
                    eprintln!("{error}\nTry --help for usage.");
                    return CLI_USAGE_ERROR.into();
                }
            };
            let instance = controller
                .borrow_mut()
                .get_or_insert_with(|| UiController::new(application, launch_mode.has_tray()))
                .clone();
            if launch_mode.should_present() {
                instance.present(None);
            }
            0.into()
        }
    });

    application.run()
}

fn application_flags_for(_mode: LaunchMode) -> gio::ApplicationFlags {
    gio::ApplicationFlags::HANDLES_COMMAND_LINE
}

fn application_id_for(mode: LaunchMode) -> &'static str {
    if mode == LaunchMode::NoTray {
        // Use a separate registered application so a popover-only process can
        // coexist with the tray owner while repeated Waybar clicks are forwarded
        // to the already-running popover instead of creating duplicates.
        NO_TRAY_APPLICATION_ID
    } else {
        APPLICATION_ID
    }
}

fn parse_cli(arguments: &[OsString]) -> Result<CliCommand, String> {
    let mut primary = None;
    let mut appearance = None;
    let mut timeframe = None;
    let mut width = None;
    let mut height = None;
    let mut state = None;
    let mut index = 1;

    while index < arguments.len() {
        let argument = arguments[index].as_os_str();
        match argument.to_str() {
            Some("--help" | "-h") => {
                set_primary_mode(&mut primary, PrimaryMode::Help)?;
            }
            Some("--version" | "-V") => {
                set_primary_mode(&mut primary, PrimaryMode::Version)?;
            }
            Some("--check") => {
                set_primary_mode(&mut primary, PrimaryMode::Check)?;
            }
            Some("--waybar") => {
                set_primary_mode(&mut primary, PrimaryMode::Waybar)?;
            }
            Some("--show") => {
                set_primary_mode(&mut primary, PrimaryMode::Launch(LaunchMode::Show))?;
            }
            Some("--background") => {
                set_primary_mode(&mut primary, PrimaryMode::Launch(LaunchMode::Background))?;
            }
            Some("--no-tray") => {
                set_primary_mode(&mut primary, PrimaryMode::Launch(LaunchMode::NoTray))?;
            }
            Some("--render-popover") => {
                let value = take_option_value(arguments, &mut index, "--render-popover")?;
                if value.as_os_str().as_bytes().is_empty() {
                    return Err("--render-popover requires a non-empty path".into());
                }
                set_primary_mode(&mut primary, PrimaryMode::Render(PathBuf::from(value)))?;
            }
            Some("--appearance") => {
                reject_duplicate(&appearance, "--appearance")?;
                let value = take_text_option(arguments, &mut index, "--appearance")?;
                appearance = Some(match value {
                    "light" => Appearance::Light,
                    "dark" => Appearance::Dark,
                    _ => return Err("--appearance must be light or dark".into()),
                });
            }
            Some("--timeframe") => {
                reject_duplicate(&timeframe, "--timeframe")?;
                let value = take_text_option(arguments, &mut index, "--timeframe")?;
                timeframe = Some(match value {
                    "seven" => range::Timeframe::Seven,
                    "thirty" => range::Timeframe::Thirty,
                    "ninety" => range::Timeframe::Ninety,
                    "all" => range::Timeframe::All,
                    _ => {
                        return Err("--timeframe must be one of: seven, thirty, ninety, all".into());
                    }
                });
            }
            Some("--width") => {
                reject_duplicate(&width, "--width")?;
                width = Some(take_dimension(arguments, &mut index, "--width")?);
            }
            Some("--height") => {
                reject_duplicate(&height, "--height")?;
                height = Some(take_dimension(arguments, &mut index, "--height")?);
            }
            Some("--state") => {
                reject_duplicate(&state, "--state")?;
                let value = take_text_option(arguments, &mut index, "--state")?;
                state = Some(match value {
                    "normal" => RenderState::Normal,
                    "stale" => RenderState::Stale,
                    "loading" => RenderState::Loading,
                    "error" => RenderState::Error,
                    "maximum" => RenderState::Maximum,
                    "long-stale" => RenderState::LongStale,
                    "long-error" => RenderState::LongError,
                    _ => {
                        return Err(
                            "--state must be normal, stale, loading, error, maximum, long-stale, or long-error"
                                .into(),
                        );
                    }
                });
            }
            Some(value) => return Err(unknown_argument_error(value)),
            None => return Err("unknown argument contains non-UTF-8 bytes".into()),
        }
        index += 1;
    }

    let has_render_options = appearance.is_some()
        || timeframe.is_some()
        || width.is_some()
        || height.is_some()
        || state.is_some();
    match primary {
        Some(PrimaryMode::Help) if !has_render_options => Ok(CliCommand::Help),
        Some(PrimaryMode::Version) if !has_render_options => Ok(CliCommand::Version),
        Some(PrimaryMode::Check) if !has_render_options => Ok(CliCommand::Check),
        Some(PrimaryMode::Waybar) if !has_render_options => Ok(CliCommand::Waybar),
        Some(PrimaryMode::Launch(mode)) if !has_render_options => Ok(CliCommand::Launch(mode)),
        Some(PrimaryMode::Render(path)) => Ok(CliCommand::Render(RenderOptions {
            path,
            appearance: appearance.unwrap_or(Appearance::Light),
            timeframe: timeframe.unwrap_or(range::Timeframe::Thirty),
            width: width.unwrap_or(300),
            height: height.unwrap_or(560),
            state: state.unwrap_or(RenderState::Normal),
        })),
        Some(mode) => Err(format!(
            "render options can only be used with --render-popover, not {}",
            mode.option_name()
        )),
        None if has_render_options => Err("render options require --render-popover PATH".into()),
        None => Ok(CliCommand::Launch(LaunchMode::Background)),
    }
}

fn unknown_argument_error(value: &str) -> String {
    if value.len() <= 128 && value.bytes().all(|byte| byte.is_ascii_graphic()) {
        format!("unknown argument: {value}")
    } else {
        "unknown argument contains unsupported characters".into()
    }
}

fn set_primary_mode(primary: &mut Option<PrimaryMode>, mode: PrimaryMode) -> Result<(), String> {
    if let Some(existing) = primary {
        return Err(format!(
            "{} cannot be combined with {}; choose exactly one command mode",
            mode.option_name(),
            existing.option_name()
        ));
    }
    *primary = Some(mode);
    Ok(())
}

fn reject_duplicate<T>(value: &Option<T>, option: &str) -> Result<(), String> {
    if value.is_some() {
        Err(format!("{option} may only be specified once"))
    } else {
        Ok(())
    }
}

fn take_option_value(
    arguments: &[OsString],
    index: &mut usize,
    option: &str,
) -> Result<OsString, String> {
    let value_index = index
        .checked_add(1)
        .ok_or_else(|| format!("{option} requires a value"))?;
    let value = arguments
        .get(value_index)
        .ok_or_else(|| format!("{option} requires a value"))?;
    if value.as_os_str().as_bytes().starts_with(b"-") {
        return Err(format!("{option} requires a value"));
    }
    *index = value_index;
    Ok(value.clone())
}

fn take_text_option<'a>(
    arguments: &'a [OsString],
    index: &mut usize,
    option: &str,
) -> Result<&'a str, String> {
    let value_index = index
        .checked_add(1)
        .ok_or_else(|| format!("{option} requires a value"))?;
    let value = arguments
        .get(value_index)
        .ok_or_else(|| format!("{option} requires a value"))?;
    if value.as_os_str().as_bytes().starts_with(b"-") {
        return Err(format!("{option} requires a value"));
    }
    let text = value
        .to_str()
        .ok_or_else(|| format!("{option} requires a UTF-8 value"))?;
    *index = value_index;
    Ok(text)
}

fn take_dimension(arguments: &[OsString], index: &mut usize, option: &str) -> Result<i32, String> {
    let raw = take_text_option(arguments, index, option)?;
    let value = raw
        .parse::<i32>()
        .map_err(|_| format!("{option} must be between 220 and 2000"))?;
    if !(220..=2_000).contains(&value) {
        return Err(format!("{option} must be between 220 and 2000"));
    }
    Ok(value)
}

fn print_help() {
    println!(
        "Codex Usage Bar for Linux\n\nUsage: codex-usage-bar [--show | --background | --no-tray | --check | --waybar]\n       codex-usage-bar [--help | --version]\n       codex-usage-bar --render-popover PATH [--appearance light|dark] [--timeframe seven|thirty|ninety|all] [--width PX] [--height PX] [--state normal|stale|loading|error|maximum|long-stale|long-error]\n\n  --show           Open the usage popover after starting the status item\n  --background     Start without opening the usage popover (the default)\n  --no-tray        Show only the popover window and quit when it closes\n  --check          Verify the Codex app-server connection without starting GTK\n  --waybar         Print one Waybar JSON status object and exit\n  --render-popover Render a deterministic parity fixture for visual checks\n  --help, -h       Print this help and exit\n  --version, -V    Print the version and exit"
    );
}

fn check_connection() -> gtk::glib::ExitCode {
    match app_server::fetch_usage_snapshot(Duration::from_secs(20)) {
        Ok(snapshot) => {
            let daily_status = check_daily_status(snapshot.daily_buckets());
            println!(
                "Codex app-server connection OK: {daily_status}, rate limits {}",
                check_rate_limit_status(snapshot.rate_limits.as_ref())
            );
            0.into()
        }
        Err(error) => {
            eprintln!("Codex app-server check failed: {error}");
            1.into()
        }
    }
}

fn check_daily_status(buckets: Option<&[model::DailyUsageBucket]>) -> String {
    buckets.map_or_else(
        || "daily buckets unavailable".into(),
        |buckets| format!("{} daily buckets", buckets.len()),
    )
}

fn check_rate_limit_status(limits: Option<&model::AccountRateLimitsResponse>) -> &'static str {
    match limits {
        Some(limits) if limits.has_meaningful_data() && !limits.decoding_issues.is_empty() => {
            "partially available"
        }
        Some(limits) if limits.has_meaningful_data() => "available",
        Some(limits) if !limits.decoding_issues.is_empty() => "unavailable (data quality issues)",
        Some(_) | None => "unavailable",
    }
}

fn render_popover_fixture(options: RenderOptions) -> gtk::glib::ExitCode {
    let RenderOptions {
        path,
        appearance,
        timeframe,
        width,
        height,
        state,
    } = options;
    let dark = appearance == Appearance::Dark;
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        && let Err(error) = std::fs::create_dir_all(parent)
    {
        eprintln!("Could not create popover output directory: {error}");
        return 1.into();
    }

    let application = gtk::Application::builder()
        .application_id("io.github.conjfrnk.CodexUsageBar.VisualCheck")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let result = Rc::new(RefCell::new(None::<Result<(), String>>));
    application.connect_activate({
        let result = result.clone();
        let path = path.clone();
        move |application| {
            if let Some(settings) = gtk::Settings::default() {
                settings.set_gtk_application_prefer_dark_theme(dark);
            }
            let snapshot = if state == RenderState::Maximum {
                fixture::maximum_usage_snapshot()
            } else {
                fixture::usage_snapshot()
            };
            let controller =
                UiController::with_snapshot(application, snapshot, timeframe, width, height);
            match state {
                RenderState::Normal => {}
                RenderState::Stale => controller.mark_stale_for_render(),
                RenderState::Loading => controller.mark_loading_for_render(),
                RenderState::Error => controller.mark_error_for_render(),
                RenderState::Maximum => {}
                RenderState::LongStale => controller.mark_long_stale_for_render(),
                RenderState::LongError => controller.mark_long_error_for_render(),
            }
            controller.present_for_render();
            let application = application.clone();
            let result = result.clone();
            let path = path.clone();
            gtk::glib::timeout_add_local_once(Duration::from_millis(180), move || {
                result.replace(Some(controller.render_to_png(&path)));
                application.quit();
            });
        }
    });
    application.run_with_args::<&str>(&[]);

    match result
        .borrow_mut()
        .take()
        .unwrap_or_else(|| Err("Popover renderer exited without producing a result".into()))
    {
        Ok(()) => {
            let bytes = std::fs::metadata(&path)
                .map(|metadata| metadata.len())
                .unwrap_or_default();
            let appearance = appearance.title();
            println!(
                "PASS render popover appearance={appearance} size={width}x{height} bytes={bytes} path={path:?}"
            );
            0.into()
        }
        Err(error) => {
            eprintln!("Could not render popover: {error}");
            1.into()
        }
    }
}

fn print_waybar_status() -> gtk::glib::ExitCode {
    let preferences = config::Preferences::load();
    match app_server::fetch_usage_snapshot(Duration::from_secs(20)) {
        Ok(snapshot) => {
            match selected_waybar_total(
                preferences.timeframe,
                snapshot.daily_buckets(),
                snapshot.usage.summary.lifetime_tokens,
                snapshot.usage.summary.peak_daily_tokens,
            ) {
                Ok((total, daily_quality)) => {
                    let compact = range::format_tokens(total);
                    let full = range::format_full_tokens(total);
                    let availability_note = match daily_quality {
                        DailyHistoryQuality::Complete => "",
                        DailyHistoryQuality::Partial => {
                            "\nDaily history is partial; showing the lifetime summary"
                        }
                        DailyHistoryQuality::Unavailable => {
                            "\nDaily history unavailable; showing the lifetime summary"
                        }
                    };
                    println!(
                        "{}",
                        serde_json::json!({
                            "text": format!("◕ {compact}"),
                            "tooltip": format!(
                                "Codex {}: {} tokens{availability_note}\nClick to open usage",
                                preferences.timeframe.short_title(),
                                full
                            ),
                            "class": if daily_quality == DailyHistoryQuality::Complete {
                                "ready"
                            } else {
                                "partial"
                            },
                            "percentage": 100
                        })
                    );
                    0.into()
                }
                Err(reason) => {
                    println!(
                        "{}",
                        serde_json::json!({
                            "text": "◯ Codex ?",
                            "tooltip": format!("Codex usage unavailable: {reason}"),
                            "class": "unavailable",
                            "percentage": 0
                        })
                    );
                    // The app-server answered and this is a valid Waybar status
                    // object. Keep the module alive while clearly reporting that
                    // the selected total cannot be calculated.
                    0.into()
                }
            }
        }
        Err(error) => {
            println!(
                "{}",
                serde_json::json!({
                    "text": "◯ Codex ?",
                    "tooltip": format!("Codex usage unavailable: {error}"),
                    "class": "error",
                    "percentage": 0
                })
            );
            // Waybar hides custom modules whose command exits nonzero before it
            // consumes their JSON. This is a valid visible error status, so keep
            // the module alive and let its `error` class communicate the failure.
            0.into()
        }
    }
}

fn selected_waybar_total(
    timeframe: range::Timeframe,
    daily_buckets: Option<&[model::DailyUsageBucket]>,
    lifetime_tokens: Option<i64>,
    peak_daily_tokens: Option<i64>,
) -> Result<(i64, DailyHistoryQuality), &'static str> {
    if let Some(buckets) = daily_buckets {
        let selected = range::UsageRange::new(timeframe, buckets);
        if selected.did_overflow() {
            return Err("daily token totals exceed the supported range");
        }
        if selected.rejected_bucket_count() > 0 {
            return Err("daily history contains invalid buckets");
        }
        if timeframe != range::Timeframe::All {
            return Ok((selected.total_tokens(), DailyHistoryQuality::Complete));
        }
        let reconciled = range::reconcile_all_time_summary(
            true,
            Some(selected.total_tokens()),
            Some(selected.peak_daily_tokens()),
            lifetime_tokens,
            peak_daily_tokens,
        );
        return reconciled
            .total_tokens
            .map(|total| {
                (
                    total,
                    if reconciled.daily_history_partial {
                        DailyHistoryQuality::Partial
                    } else {
                        DailyHistoryQuality::Complete
                    },
                )
            })
            .ok_or("all-time summary could not be reconciled with daily history and peak usage");
    }

    if timeframe == range::Timeframe::All {
        return range::reconcile_all_time_summary(
            false,
            None,
            None,
            lifetime_tokens,
            peak_daily_tokens,
        )
        .total_tokens
        .map(|tokens| (tokens, DailyHistoryQuality::Unavailable))
        .ok_or("daily history and a credible lifetime total were not provided");
    }

    Err("daily history was not provided for the selected timeframe")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;

    fn arguments(values: &[&str]) -> Vec<std::ffi::OsString> {
        values.iter().map(std::ffi::OsString::from).collect()
    }

    #[test]
    fn parses_each_visible_launch_mode_and_the_hidden_default() {
        assert_eq!(
            parse_cli(&arguments(&["codex-usage-bar"])),
            Ok(CliCommand::Launch(LaunchMode::Background))
        );
        assert_eq!(
            parse_cli(&arguments(&["codex-usage-bar", "--show"])),
            Ok(CliCommand::Launch(LaunchMode::Show))
        );
        assert_eq!(
            parse_cli(&arguments(&["codex-usage-bar", "--background"])),
            Ok(CliCommand::Launch(LaunchMode::Background))
        );
        assert_eq!(
            parse_cli(&arguments(&["codex-usage-bar", "--no-tray"])),
            Ok(CliCommand::Launch(LaunchMode::NoTray))
        );
        assert!(LaunchMode::NoTray.should_present());
        assert!(!LaunchMode::NoTray.has_tray());
    }

    #[test]
    fn no_tray_mode_has_a_distinct_unique_application_identity() {
        assert_eq!(
            application_id_for(LaunchMode::NoTray),
            NO_TRAY_APPLICATION_ID
        );
        assert_eq!(application_id_for(LaunchMode::Show), APPLICATION_ID);
        assert_eq!(application_id_for(LaunchMode::Background), APPLICATION_ID);
        assert_ne!(NO_TRAY_APPLICATION_ID, APPLICATION_ID);

        for mode in [LaunchMode::NoTray, LaunchMode::Show, LaunchMode::Background] {
            let flags = application_flags_for(mode);
            assert!(flags.contains(gio::ApplicationFlags::HANDLES_COMMAND_LINE));
            assert!(!flags.contains(gio::ApplicationFlags::NON_UNIQUE));
        }
    }

    #[test]
    fn rejects_conflicting_duplicate_and_unknown_modes() {
        for values in [
            &["codex-usage-bar", "--no-tray", "--background"][..],
            &["codex-usage-bar", "--show", "--no-tray"][..],
            &["codex-usage-bar", "--check", "--waybar"][..],
            &["codex-usage-bar", "--check", "--check"][..],
            &["codex-usage-bar", "--help", "--version"][..],
            &["codex-usage-bar", "positional"][..],
            &["codex-usage-bar", "--unknown"][..],
            &["codex-usage-bar", "--unknown\nforged-output"][..],
        ] {
            assert!(
                parse_cli(&arguments(values)).is_err(),
                "accepted {values:?}"
            );
        }
        let error =
            parse_cli(&arguments(&["codex-usage-bar", "--unknown\nforged-output"])).unwrap_err();
        assert!(!error.chars().any(char::is_control));
    }

    #[test]
    fn render_options_are_strict_and_have_documented_defaults() {
        assert_eq!(
            parse_cli(&arguments(&[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png"
            ])),
            Ok(CliCommand::Render(RenderOptions {
                path: PathBuf::from("fixture.png"),
                appearance: Appearance::Light,
                timeframe: range::Timeframe::Thirty,
                width: 300,
                height: 560,
                state: RenderState::Normal,
            }))
        );
        for (value, expected) in [
            ("normal", RenderState::Normal),
            ("stale", RenderState::Stale),
            ("loading", RenderState::Loading),
            ("error", RenderState::Error),
            ("maximum", RenderState::Maximum),
            ("long-stale", RenderState::LongStale),
            ("long-error", RenderState::LongError),
        ] {
            let parsed = parse_cli(&arguments(&[
                "codex-usage-bar",
                "--render-popover",
                "state.png",
                "--state",
                value,
                "--width",
                "220",
                "--height",
                "2000",
            ]));
            assert!(matches!(
                parsed,
                Ok(CliCommand::Render(RenderOptions {
                    width: 220,
                    height: 2000,
                    state,
                    ..
                })) if state == expected
            ));
        }
        assert_eq!(
            parse_cli(&arguments(&[
                "codex-usage-bar",
                "--render-popover",
                "stale.png",
                "--state",
                "stale"
            ])),
            Ok(CliCommand::Render(RenderOptions {
                path: PathBuf::from("stale.png"),
                appearance: Appearance::Light,
                timeframe: range::Timeframe::Thirty,
                width: 300,
                height: 560,
                state: RenderState::Stale,
            }))
        );
        assert_eq!(
            parse_cli(&arguments(&[
                "codex-usage-bar",
                "--appearance",
                "dark",
                "--width",
                "260",
                "--render-popover",
                "fixture.png",
                "--timeframe",
                "all",
                "--height",
                "700"
            ])),
            Ok(CliCommand::Render(RenderOptions {
                path: PathBuf::from("fixture.png"),
                appearance: Appearance::Dark,
                timeframe: range::Timeframe::All,
                width: 260,
                height: 700,
                state: RenderState::Normal,
            }))
        );
    }

    #[test]
    fn rejects_missing_duplicate_misplaced_and_invalid_render_options() {
        for values in [
            &["codex-usage-bar", "--render-popover"][..],
            &["codex-usage-bar", "--render-popover", "--check"][..],
            &["codex-usage-bar", "--render-popover", ""][..],
            &["codex-usage-bar", "--appearance", "dark"][..],
            &["codex-usage-bar", "--width", "260"][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--appearance",
                "dark",
                "--appearance",
                "light",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--width",
                "219",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--height",
                "2001",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--timeframe",
                "month",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--appearance",
                "system",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--state",
                "unknown",
            ][..],
            &[
                "codex-usage-bar",
                "--render-popover",
                "fixture.png",
                "--state",
                "loading",
                "--state",
                "error",
            ][..],
        ] {
            assert!(
                parse_cli(&arguments(values)).is_err(),
                "accepted {values:?}"
            );
        }
    }

    #[test]
    fn render_path_is_preserved_losslessly() {
        let raw_path = OsString::from_vec(b"fixture-\xff.png".to_vec());
        let parsed = parse_cli(&[
            OsString::from("codex-usage-bar"),
            OsString::from("--render-popover"),
            raw_path.clone(),
        ]);
        assert_eq!(
            parsed,
            Ok(CliCommand::Render(RenderOptions {
                path: PathBuf::from(raw_path),
                appearance: Appearance::Light,
                timeframe: range::Timeframe::Thirty,
                width: 300,
                height: 560,
                state: RenderState::Normal,
            }))
        );
        assert!(
            parse_cli(&[
                OsString::from("codex-usage-bar"),
                OsString::from_vec(b"--unknown-\xff".to_vec()),
            ])
            .is_err()
        );
    }

    #[test]
    fn check_reports_missing_daily_history_as_unavailable() {
        assert_eq!(check_daily_status(None), "daily buckets unavailable");
        assert_eq!(check_daily_status(Some(&[])), "0 daily buckets");
        assert_eq!(check_rate_limit_status(None), "unavailable");
        assert_eq!(
            check_rate_limit_status(Some(
                &model::AccountRateLimitsResponse::malformed_outer_response()
            )),
            "unavailable (data quality issues)"
        );
        assert_eq!(
            check_rate_limit_status(Some(&model::AccountRateLimitsResponse::default())),
            "unavailable"
        );
        let partial: model::AccountRateLimitsResponse = serde_json::from_str(
            r#"{"rateLimits":{"primary":{"usedPercent":10},"secondary":"bad"}}"#,
        )
        .unwrap();
        assert_eq!(
            check_rate_limit_status(Some(&partial)),
            "partially available"
        );
    }

    #[test]
    fn waybar_does_not_turn_missing_daily_history_into_zero() {
        assert!(selected_waybar_total(range::Timeframe::Thirty, None, Some(9_999), None).is_err());
        assert_eq!(
            selected_waybar_total(range::Timeframe::All, None, Some(9_999), None),
            Ok((9_999, DailyHistoryQuality::Unavailable))
        );
        assert!(selected_waybar_total(range::Timeframe::All, None, None, None).is_err());
        assert!(selected_waybar_total(range::Timeframe::All, None, Some(100), Some(800)).is_err());
    }

    #[test]
    fn waybar_all_time_total_uses_the_larger_lifetime_summary() {
        let buckets = [model::DailyUsageBucket {
            start_date: chrono::Local::now()
                .date_naive()
                .format("%Y-%m-%d")
                .to_string(),
            tokens: 100,
        }];
        assert_eq!(
            selected_waybar_total(range::Timeframe::All, Some(&buckets), Some(250), None),
            Ok((250, DailyHistoryQuality::Partial))
        );
        assert_eq!(
            selected_waybar_total(range::Timeframe::Thirty, Some(&buckets), Some(250), None),
            Ok((100, DailyHistoryQuality::Complete))
        );
        assert!(
            selected_waybar_total(range::Timeframe::All, Some(&buckets), Some(100), Some(250))
                .is_err()
        );
        assert!(
            selected_waybar_total(range::Timeframe::All, Some(&buckets), None, Some(250)).is_err()
        );
    }

    #[test]
    fn waybar_rejects_saturating_totals() {
        let date = chrono::Local::now()
            .date_naive()
            .format("%Y-%m-%d")
            .to_string();
        let buckets = [
            model::DailyUsageBucket {
                start_date: date.clone(),
                tokens: i64::MAX,
            },
            model::DailyUsageBucket {
                start_date: date,
                tokens: 1,
            },
        ];
        assert!(selected_waybar_total(range::Timeframe::All, Some(&buckets), None, None).is_err());
    }
}
