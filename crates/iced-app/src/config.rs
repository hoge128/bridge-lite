use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::i18n::Language;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ThemeChoice {
    BridgeDark,
    BridgeLight,
    Dark,
    Light,
    Dracula,
    Nord,
    SolarizedDark,
    SolarizedLight,
    GruvboxDark,
    TokyoNight,
}

impl ThemeChoice {
    pub const ALL: &'static [ThemeChoice] = &[
        ThemeChoice::BridgeDark,
        ThemeChoice::BridgeLight,
        ThemeChoice::Dark,
        ThemeChoice::Light,
        ThemeChoice::Dracula,
        ThemeChoice::Nord,
        ThemeChoice::SolarizedDark,
        ThemeChoice::SolarizedLight,
        ThemeChoice::GruvboxDark,
        ThemeChoice::TokyoNight,
    ];

    pub fn label(self) -> &'static str {
        match self {
            ThemeChoice::BridgeDark => "Bridge Dark",
            ThemeChoice::BridgeLight => "Bridge Light",
            ThemeChoice::Dark => "Dark",
            ThemeChoice::Light => "Light",
            ThemeChoice::Dracula => "Dracula",
            ThemeChoice::Nord => "Nord",
            ThemeChoice::SolarizedDark => "Solarized Dark",
            ThemeChoice::SolarizedLight => "Solarized Light",
            ThemeChoice::GruvboxDark => "Gruvbox Dark",
            ThemeChoice::TokyoNight => "Tokyo Night",
        }
    }

    pub fn to_iced(self) -> iced::Theme {
        match self {
            ThemeChoice::BridgeDark => crate::theme::bridge_dark(),
            ThemeChoice::BridgeLight => crate::theme::bridge_light(),
            ThemeChoice::Dark => iced::Theme::Dark,
            ThemeChoice::Light => iced::Theme::Light,
            ThemeChoice::Dracula => iced::Theme::Dracula,
            ThemeChoice::Nord => iced::Theme::Nord,
            ThemeChoice::SolarizedDark => iced::Theme::SolarizedDark,
            ThemeChoice::SolarizedLight => iced::Theme::SolarizedLight,
            ThemeChoice::GruvboxDark => iced::Theme::GruvboxDark,
            ThemeChoice::TokyoNight => iced::Theme::TokyoNight,
        }
    }
}

impl Default for ThemeChoice {
    fn default() -> Self {
        ThemeChoice::BridgeDark
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub default_path: String,
    #[serde(default)]
    pub theme: ThemeChoice,
    #[serde(default)]
    pub language: Language,
}

fn config_path() -> PathBuf {
    let base = dirs_next::config_dir().unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("bridge-lite");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("config.json")
}

impl Settings {
    pub fn load() -> Self {
        let path = config_path();
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str::<Settings>(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        let path = config_path();
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        std::fs::write(path, json)
    }
}
