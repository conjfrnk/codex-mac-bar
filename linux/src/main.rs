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
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gtk::gio;
use gtk::prelude::*;

use ui::UiController;

const APPLICATION_ID: &str = "io.github.conjfrnk.CodexUsageBar";

fn main() -> gtk::glib::ExitCode {
    let arguments: Vec<_> = std::env::args_os().collect();
    if arguments
        .iter()
        .any(|argument| argument == "--help" || argument == "-h")
    {
        println!(
            "Codex Usage Bar for Linux\n\nUsage: codex-usage-bar [--show | --background | --no-tray | --check | --waybar]\n       codex-usage-bar --render-popover PATH [--appearance light|dark] [--timeframe seven|thirty|ninety|all] [--width PX] [--height PX]\n\n  --show           Open the usage popover after starting the status item\n  --background     Start without opening the usage popover (the default)\n  --no-tray        Show only the popover window and quit when it closes\n  --check          Verify the Codex app-server connection without starting GTK\n  --waybar         Print one Waybar JSON status object and exit\n  --render-popover Render a deterministic parity fixture for visual checks"
        );
        return 0.into();
    }
    if arguments
        .iter()
        .any(|argument| argument == "--version" || argument == "-V")
    {
        println!("codex-usage-bar {}", env!("CARGO_PKG_VERSION"));
        return 0.into();
    }
    if arguments.iter().any(|argument| argument == "--check") {
        return match app_server::fetch_usage_snapshot(Duration::from_secs(20)) {
            Ok(snapshot) => {
                println!(
                    "Codex app-server connection OK: {} daily buckets, rate limits {}",
                    snapshot.buckets().len(),
                    if snapshot.rate_limits.is_some() {
                        "available"
                    } else {
                        "unavailable"
                    }
                );
                0.into()
            }
            Err(error) => {
                eprintln!("Codex app-server check failed: {error}");
                1.into()
            }
        };
    }
    if arguments.iter().any(|argument| argument == "--waybar") {
        return print_waybar_status();
    }
    if let Some(path) = option_value(&arguments, "--render-popover") {
        return render_popover_fixture(&arguments, PathBuf::from(path));
    }

    let application = gtk::Application::builder()
        .application_id(APPLICATION_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    let controller = Rc::new(RefCell::new(None::<Rc<UiController>>));

    application.connect_command_line({
        let controller = controller.clone();
        move |application, command_line| {
            let arguments = command_line.arguments();
            let no_tray = arguments.iter().any(|argument| argument == "--no-tray");
            let instance = controller
                .borrow_mut()
                .get_or_insert_with(|| UiController::new(application, !no_tray))
                .clone();
            if should_present(&arguments) {
                instance.present(None);
            }
            0.into()
        }
    });

    application.run()
}

fn should_present(arguments: &[std::ffi::OsString]) -> bool {
    let show = arguments
        .iter()
        .any(|argument| argument == "--show" || argument == "--no-tray");
    show && !arguments.iter().any(|argument| argument == "--background")
}

fn option_value(arguments: &[std::ffi::OsString], name: &str) -> Option<String> {
    let index = arguments.iter().position(|argument| argument == name)?;
    arguments
        .get(index + 1)
        .map(|value| value.to_string_lossy().into_owned())
}

fn render_popover_fixture(arguments: &[std::ffi::OsString], path: PathBuf) -> gtk::glib::ExitCode {
    let appearance = option_value(arguments, "--appearance").unwrap_or_else(|| "light".into());
    let dark = match appearance.as_str() {
        "light" => false,
        "dark" => true,
        _ => {
            eprintln!("--appearance must be light or dark");
            return 1.into();
        }
    };
    let timeframe = match option_value(arguments, "--timeframe").as_deref() {
        None | Some("thirty") => range::Timeframe::Thirty,
        Some("seven") => range::Timeframe::Seven,
        Some("ninety") => range::Timeframe::Ninety,
        Some("all") => range::Timeframe::All,
        Some(_) => {
            eprintln!("--timeframe must be one of: seven, thirty, ninety, all");
            return 1.into();
        }
    };
    let width = match render_dimension(arguments, "--width", 300) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("{error}");
            return 1.into();
        }
    };
    let height = match render_dimension(arguments, "--height", 560) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("{error}");
            return 1.into();
        }
    };
    if let Some(parent) = path.parent()
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
            let controller = UiController::with_snapshot(
                application,
                fixture::usage_snapshot(),
                timeframe,
                width,
                height,
            );
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
            println!(
                "PASS render popover appearance={appearance} size={width}x{height} bytes={bytes} path={}",
                path.display()
            );
            0.into()
        }
        Err(error) => {
            eprintln!("Could not render popover: {error}");
            1.into()
        }
    }
}

fn render_dimension(
    arguments: &[std::ffi::OsString],
    name: &str,
    default_value: i32,
) -> Result<i32, String> {
    let Some(raw) = option_value(arguments, name) else {
        return Ok(default_value);
    };
    let value = raw
        .parse::<i32>()
        .map_err(|_| format!("{name} must be between 220 and 2000"))?;
    if !(220..=2_000).contains(&value) {
        return Err(format!("{name} must be between 220 and 2000"));
    }
    Ok(value)
}

fn print_waybar_status() -> gtk::glib::ExitCode {
    let preferences = config::Preferences::load();
    match app_server::fetch_usage_snapshot(Duration::from_secs(20)) {
        Ok(snapshot) => {
            let range = range::UsageRange::new(preferences.timeframe, snapshot.buckets());
            let compact = range::format_tokens(range.total_tokens());
            let full = range::format_full_tokens(range.total_tokens());
            println!(
                "{}",
                serde_json::json!({
                    "text": format!("◕ {compact}"),
                    "tooltip": format!(
                        "Codex {}: {} tokens\nClick to open usage",
                        preferences.timeframe.short_title(),
                        full
                    ),
                    "class": "ready",
                    "percentage": 100
                })
            );
            0.into()
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
            1.into()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<std::ffi::OsString> {
        values.iter().map(std::ffi::OsString::from).collect()
    }

    #[test]
    fn launch_is_hidden_by_default_but_explicit_show_and_no_tray_present() {
        assert!(!should_present(&arguments(&["codex-usage-bar"])));
        assert!(should_present(&arguments(&["codex-usage-bar", "--show"])));
        assert!(should_present(&arguments(&[
            "codex-usage-bar",
            "--no-tray"
        ])));
        assert!(!should_present(&arguments(&[
            "codex-usage-bar",
            "--show",
            "--background"
        ])));
    }

    #[test]
    fn visual_fixture_dimensions_match_macos_validation() {
        assert_eq!(render_dimension(&arguments(&[]), "--width", 300), Ok(300));
        assert_eq!(
            render_dimension(&arguments(&["--width", "260"]), "--width", 300),
            Ok(260)
        );
        assert!(render_dimension(&arguments(&["--width", "219"]), "--width", 300).is_err());
        assert!(render_dimension(&arguments(&["--width", "2001"]), "--width", 300).is_err());
    }
}
