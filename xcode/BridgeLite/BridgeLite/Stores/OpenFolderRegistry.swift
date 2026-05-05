import AppKit
import Foundation

/// 開いているフォルダ URL → NSWindow の対応を管理するシングルトン。
/// 複数ウィンドウで同じフォルダを開かないようにするためのチェックに使う。
@MainActor
final class OpenFolderRegistry {
    static let shared = OpenFolderRegistry()

    private final class WeakRef {
        weak var window: NSWindow?
    }

    private var registrations: [URL: WeakRef] = [:]

    private init() {}

    func register(url: URL, window: NSWindow) {
        let key = canonicalize(url)
        let ref = WeakRef()
        ref.window = window
        registrations[key] = ref
    }

    func unregister(url: URL) {
        let key = canonicalize(url)
        registrations.removeValue(forKey: key)
    }

    /// 同じフォルダを既に開いているウィンドウを返す。なければ nil。
    /// 呼び出し時に dead な weak 参照を遅延掃除する。
    func windowForFolder(_ url: URL) -> NSWindow? {
        // 解放済みウィンドウのエントリを掃除
        registrations = registrations.filter { $0.value.window != nil }
        let key = canonicalize(url)
        return registrations[key]?.window
    }

    /// 末尾スラッシュ・シンボリックリンクの差を吸収して比較キーに正規化する。
    private func canonicalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
