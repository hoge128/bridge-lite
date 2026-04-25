use std::sync::OnceLock;

use muda::{Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
#[cfg(target_os = "macos")]
use muda::accelerator::{Accelerator, Code, Modifiers};

use crate::i18n::{Language, t};

// ── Menu item IDs ──────────────────────────────────────────────────────────

#[derive(Debug)]
pub struct MenuIds {
    pub open_dir:        muda::MenuId,
    pub settings:        muda::MenuId,
    pub toggle_filter:   muda::MenuId,
    pub toggle_grid:     muda::MenuId,
    pub toggle_sidebar:  muda::MenuId,
    pub about:           muda::MenuId,
    pub app_about:       muda::MenuId,
}

// ── Static handles for language-switch set_text ────────────────────────────

struct MenuHandles {
    ids:                 MenuIds,
    file_sub:            Submenu,
    view_sub:            Submenu,
    help_sub:            Submenu,
    open_dir_item:       MenuItem,
    settings_item:       MenuItem,
    toggle_filter_item:  MenuItem,
    toggle_grid_item:    MenuItem,
    toggle_sidebar_item: MenuItem,
    about_item:          MenuItem,
    app_about_item:      MenuItem,
}

// muda's Submenu/MenuItem use Rc internally, so they're not Send/Sync.
// All menu operations happen on the main thread, so this is safe in practice.
struct MainThreadOnly(MenuHandles);
unsafe impl Send for MainThreadOnly {}
unsafe impl Sync for MainThreadOnly {}

static HANDLES: OnceLock<MainThreadOnly> = OnceLock::new();

pub fn ids() -> &'static MenuIds {
    &HANDLES.get().expect("menu::init() not called").0.ids
}

// ── Build and register the native menu bar ─────────────────────────────────

pub fn init(lang: Language) {
    let s = t(lang);

    // ── Custom items ──────────────────────────────────────────────────────

    let open_dir = MenuItem::new(
        s.menu_open_folder,
        true,
        #[cfg(target_os = "macos")]
        Some(Accelerator::new(Some(Modifiers::META), Code::KeyO)),
        #[cfg(not(target_os = "macos"))]
        Some(Accelerator::new(Some(Modifiers::CONTROL), Code::KeyO)),
    );
    let settings = MenuItem::new(
        s.menu_preferences,
        true,
        #[cfg(target_os = "macos")]
        Some(Accelerator::new(Some(Modifiers::META), Code::Comma)),
        #[cfg(not(target_os = "macos"))]
        None,
    );
    let toggle_filter  = MenuItem::new(s.menu_toggle_filter,  true, None);
    let toggle_grid    = MenuItem::new(s.menu_toggle_grid,    true, None);
    let toggle_sidebar = MenuItem::new(s.menu_toggle_sidebar, true, None);
    let about_item     = MenuItem::new(s.menu_about,          true, None);
    let app_about_item = MenuItem::new(s.menu_about,          true, None);

    // ── bridge-lite (App) menu ────────────────────────────────────────────
    let app_sub = Submenu::new("bridge-lite", true);
    let _ = app_sub.append_items(&[
        &app_about_item,
        &settings,
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::services(None),
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::hide(None),
        &PredefinedMenuItem::hide_others(None),
        &PredefinedMenuItem::show_all(None),
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::quit(None),
    ]);

    // ── File menu ─────────────────────────────────────────────────────────
    let file_sub = Submenu::new(s.menu_file, true);
    let _ = file_sub.append_items(&[
        &open_dir,
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::close_window(None),
    ]);

    // ── Edit menu (all PredefinedMenuItem — macOS auto-translates) ────────
    let edit_sub = Submenu::new("Edit", true);
    let _ = edit_sub.append_items(&[
        &PredefinedMenuItem::undo(None),
        &PredefinedMenuItem::redo(None),
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::cut(None),
        &PredefinedMenuItem::copy(None),
        &PredefinedMenuItem::paste(None),
        &PredefinedMenuItem::select_all(None),
    ]);

    // ── View menu ─────────────────────────────────────────────────────────
    let view_sub = Submenu::new(s.menu_view, true);
    let _ = view_sub.append_items(&[
        &toggle_filter,
        &toggle_grid,
        &toggle_sidebar,
        &PredefinedMenuItem::separator(),
        &PredefinedMenuItem::fullscreen(None),
    ]);

    // ── Window menu ───────────────────────────────────────────────────────
    let window_sub = Submenu::new("Window", true);
    let _ = window_sub.append_items(&[
        &PredefinedMenuItem::minimize(None),
        &PredefinedMenuItem::maximize(None),
    ]);

    // ── Help menu ─────────────────────────────────────────────────────────
    let help_sub = Submenu::new(s.menu_help, true);
    let _ = help_sub.append_items(&[&about_item]);

    // ── Assemble & register ───────────────────────────────────────────────
    let menu = Menu::new();
    let _ = menu.append_items(&[
        &app_sub,
        &file_sub,
        &edit_sub,
        &view_sub,
        &window_sub,
        &help_sub,
    ]);

    #[cfg(target_os = "macos")]
    menu.init_for_nsapp();

    let handles = MenuHandles {
        ids: MenuIds {
            open_dir:       open_dir.id().clone(),
            settings:       settings.id().clone(),
            toggle_filter:  toggle_filter.id().clone(),
            toggle_grid:    toggle_grid.id().clone(),
            toggle_sidebar: toggle_sidebar.id().clone(),
            about:          about_item.id().clone(),
            app_about:      app_about_item.id().clone(),
        },
        file_sub,
        view_sub,
        help_sub,
        open_dir_item:       open_dir,
        settings_item:       settings,
        toggle_filter_item:  toggle_filter,
        toggle_grid_item:    toggle_grid,
        toggle_sidebar_item: toggle_sidebar,
        about_item,
        app_about_item,
    };
    HANDLES.set(MainThreadOnly(handles)).ok();

    // Keep Menu (and its NSMenu backing) alive for the process lifetime.
    Box::leak(Box::new(menu));
}

// ── Language switch ────────────────────────────────────────────────────────

pub fn update_language(lang: Language) {
    let h = &HANDLES.get().expect("menu::init() not called").0;
    let s = t(lang);
    h.file_sub.set_text(s.menu_file);
    h.view_sub.set_text(s.menu_view);
    h.help_sub.set_text(s.menu_help);
    h.open_dir_item.set_text(s.menu_open_folder);
    h.settings_item.set_text(s.menu_preferences);
    h.toggle_filter_item.set_text(s.menu_toggle_filter);
    h.toggle_grid_item.set_text(s.menu_toggle_grid);
    h.toggle_sidebar_item.set_text(s.menu_toggle_sidebar);
    h.about_item.set_text(s.menu_about);
    h.app_about_item.set_text(s.menu_about);
}

// ── Subscription stream ────────────────────────────────────────────────────

/// Returns a stream that yields each `MenuId` as a menu item is activated.
pub fn event_stream() -> impl iced::futures::Stream<Item = muda::MenuId> {
    let (tx, rx) = tokio::sync::mpsc::channel::<muda::MenuId>(32);

    std::thread::spawn(move || {
        let receiver = MenuEvent::receiver();
        loop {
            match receiver.recv() {
                Ok(event) => {
                    if tx.blocking_send(event.id).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    iced::futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|id| (id, rx))
    })
}
