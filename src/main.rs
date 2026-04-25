mod app;
mod btime;
mod config;
mod db;
mod i18n;
mod menu;
mod theme;
#[cfg(target_os = "macos")]
mod macos_thumb;
mod metadata;
mod pairing;
mod phash;
mod raw_thumb;
mod scanner;
mod thumbnail;
mod xmp;
// === MEMORY_GUARD: BEGIN ===
mod memory_guard;
// === MEMORY_GUARD: END ===

fn main() -> iced::Result {
    let settings = config::Settings::load();
    menu::init(settings.language);
    app::run_with(settings)
}
