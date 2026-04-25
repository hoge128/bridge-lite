mod app;
mod btime;
mod config;
mod db;
mod i18n;
mod menu;
#[cfg(target_os = "macos")]
mod macos_thumb;
mod metadata;
mod pairing;
mod raw_thumb;
mod scanner;
mod thumbnail;
mod xmp;

fn main() -> iced::Result {
    let settings = config::Settings::load();
    menu::init(settings.language);
    app::run_with(settings)
}
