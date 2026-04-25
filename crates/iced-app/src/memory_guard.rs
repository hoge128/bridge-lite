//! Memory-usage guardrail — intentionally self-contained.
//!
//! Monitors `phys_footprint` (the same value Activity Monitor shows) via the
//! macOS `task_vm_info` API and pauses thumbnail / pHash queues when memory
//! grows too large.
//!
//! **Removal procedure:**
//!   1. `rm src/memory_guard.rs`
//!   2. Remove every `// === MEMORY_GUARD: BEGIN ===` … `// === MEMORY_GUARD: END ===`
//!      block from `src/main.rs` and `src/app.rs`
//!   3. `cargo build`

use std::ffi::c_void;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use iced::widget::{container, text};
use iced::{Background, Color, Element, Length, Subscription};

// ── Thresholds ─────────────────────────────────────────────────────────────

/// Footprint (MB) above which new queue items are suspended and the banner appears.
const WARN_MB: u64 = 1500;
/// Footprint (MB) above which `full_res_handle` is also freed.
const CRITICAL_MB: u64 = 2500;
/// Sampling interval.
const SAMPLE_SECS: u64 = 2;

// ── Types ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum Event {
    Normal(u64),
    Warn(u64),
    Critical(u64),
    SampleFailed,
}

#[derive(Debug)]
pub struct State {
    pub paused: bool,
    pub critical: bool,
    pub footprint_mb: u64,
    log_path: PathBuf,
}

impl Default for State {
    fn default() -> Self {
        let base = std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"));
        Self {
            paused: false,
            critical: false,
            footprint_mb: 0,
            log_path: base.join(".bridge-lite").join("memory.log"),
        }
    }
}

/// Snapshot of app state appended to each log line for diagnostics.
pub struct Diagnostics {
    pub thumb_queue_len: usize,
    pub phash_active: usize,
    pub images_total: usize,
    pub current_path: Option<PathBuf>,
}

pub enum Action {
    None,
    Resume,
}

// ── Public API ──────────────────────────────────────────────────────────────

pub fn is_paused(state: &State) -> bool {
    state.paused
}

/// Periodic subscription that samples memory every [`SAMPLE_SECS`] seconds.
pub fn subscription() -> Subscription<Event> {
    iced::time::every(Duration::from_secs(SAMPLE_SECS)).map(|_| match current_footprint_mb() {
        None => Event::SampleFailed,
        Some(mb) if mb >= CRITICAL_MB => Event::Critical(mb),
        Some(mb) if mb >= WARN_MB => Event::Warn(mb),
        Some(mb) => Event::Normal(mb),
    })
}

/// Update internal state and write a log entry when needed.
/// Returns `Action::Resume` when transitioning from paused → normal so the
/// caller can restart the queues.
pub fn handle(state: &mut State, ev: Event, diag: Diagnostics) -> Action {
    match ev {
        Event::SampleFailed => Action::None,
        Event::Normal(mb) => {
            let was_paused = state.paused;
            state.footprint_mb = mb;
            state.paused = false;
            state.critical = false;
            if was_paused { Action::Resume } else { Action::None }
        }
        Event::Warn(mb) => {
            state.footprint_mb = mb;
            state.paused = true;
            state.critical = false;
            write_log(&state.log_path, "WARN", mb, &diag);
            Action::None
        }
        Event::Critical(mb) => {
            state.footprint_mb = mb;
            state.paused = true;
            state.critical = true;
            write_log(&state.log_path, "CRIT", mb, &diag);
            Action::None
        }
    }
}

/// Returns a warning banner element while memory is elevated, `None` otherwise.
/// Generic over `M` so this module has no dependency on `app::Message`.
pub fn view_banner<'a, M: Clone + 'a>(state: &State) -> Option<Element<'a, M>> {
    if !state.paused {
        return None;
    }
    let label = if state.critical {
        format!("⚠ Memory critical: {} MB — queue paused, full-res freed", state.footprint_mb)
    } else {
        format!("⚠ Memory high: {} MB — thumbnail queue paused", state.footprint_mb)
    };
    Some(
        container(
            text(label).size(11).style(|_: &iced::Theme| iced::widget::text::Style {
                color: Some(Color::from_rgb(1.0, 0.95, 0.6)),
            }),
        )
        .width(Length::Fill)
        .padding([3, 12])
        .style(|_: &iced::Theme| iced::widget::container::Style {
            background: Some(Background::Color(Color::from_rgb(0.55, 0.15, 0.0))),
            ..Default::default()
        })
        .into(),
    )
}

// ── Log ─────────────────────────────────────────────────────────────────────

fn write_log(path: &PathBuf, level: &str, mb: u64, diag: &Diagnostics) {
    let _ = write_log_inner(path, level, mb, diag);
}

fn write_log_inner(
    path: &PathBuf,
    level: &str,
    mb: u64,
    diag: &Diagnostics,
) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let path_str = diag
        .current_path
        .as_deref()
        .and_then(|p| p.to_str())
        .unwrap_or("-");
    let line = format!(
        "[{ts}] [{level}] footprint={mb}MB queue={q} phash_active={pa} images={im} path={path}\n",
        q = diag.thumb_queue_len,
        pa = diag.phash_active,
        im = diag.images_total,
        path = path_str,
    );
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(line.as_bytes())
}

// ── macOS task_info FFI ─────────────────────────────────────────────────────

const TASK_VM_INFO_FLAVOR: u32 = 22;
const KERN_SUCCESS: i32 = 0;

// Mirrors the first 19 fields of task_vm_info_data_t up through phys_footprint.
// TASK_VM_INFO_REV0_COUNT = sizeof(this struct) / sizeof(u32) = 36, which is
// exactly the minimum count the kernel accepts for TASK_VM_INFO.
#[repr(C)]
struct TaskVmInfo {
    virtual_size:               u64, // mach_vm_size_t
    region_count:               i32, // integer_t
    page_size:                  i32, // integer_t
    resident_size:              u64,
    resident_size_peak:         u64,
    device:                     u64,
    device_peak:                u64,
    internal:                   u64,
    internal_peak:              u64,
    external:                   u64,
    external_peak:              u64,
    reusable:                   u64,
    reusable_peak:              u64,
    purgeable_volatile_pmap:    u64,
    purgeable_volatile_virtual: u64,
    compressed:                 u64,
    compressed_peak:            u64,
    compressed_lifetime:        u64,
    phys_footprint:             u64, // offset 136 — what Activity Monitor shows
}

unsafe extern "C" {
    static mach_task_self_: u32;
    fn task_info(task: u32, flavor: u32, info: *mut c_void, count: *mut u32) -> i32;
}

fn current_footprint_mb() -> Option<u64> {
    let mut info = std::mem::MaybeUninit::<TaskVmInfo>::uninit();
    let mut count = (std::mem::size_of::<TaskVmInfo>() / 4) as u32; // 144 / 4 = 36
    let kr = unsafe {
        task_info(
            mach_task_self_,
            TASK_VM_INFO_FLAVOR,
            info.as_mut_ptr() as *mut c_void,
            &mut count,
        )
    };
    if kr != KERN_SUCCESS {
        return None;
    }
    Some(unsafe { info.assume_init() }.phys_footprint / (1024 * 1024))
}
