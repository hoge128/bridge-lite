// バックグラウンド処理用の rayon スレッドプール。
//
// 通常モードでは論理コア数の 1/2 に制限し、他アプリへの影響を抑える。
// Burst Mode 対応時はこの値を動的に切り替える（現時点では初期化時に一度だけ決定）。

use rayon::ThreadPool;
use std::sync::OnceLock;

static BACKGROUND_POOL: OnceLock<ThreadPool> = OnceLock::new();

/// スキャン・dedup 等のバックグラウンド並列処理で使う共有 ThreadPool を返す。
/// 論理コア数の 1/2（最低 1）で初期化される。
pub fn background_pool() -> &'static ThreadPool {
    BACKGROUND_POOL.get_or_init(|| {
        let threads = std::thread::available_parallelism()
            .map(|n| (n.get() / 2).max(1))
            .unwrap_or(2);
        rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|i| format!("bridge-bg-{i}"))
            .build()
            .expect("failed to build background rayon pool")
    })
}
