# Xcode 26 / Swift 6 ビルドエラー知見集

> ビルド環境: Xcode 26.4.1 / Swift 6.0 / macOS 26.0 ターゲット / swift-bridge 0.1.59

---

## 1. `@AppStorage` + `@Observable` 非互換

**エラー**:
```
property wrapper cannot be applied to a computed property
```

**原因**: Swift の `@Observable` マクロは stored property を computed property に変換する。`@AppStorage` などの property wrapper はすでに computed property な対象には適用できない。

**修正**: `@AppStorage` を除去し、初期値を UserDefaults から読んで `didSet` で書き戻す。

```swift
// NG
@Observable class SettingsStore {
    @AppStorage("key") var value: String = ""
}

// OK
@Observable class SettingsStore {
    var value: String = UserDefaults.standard.string(forKey: "key") ?? "" {
        didSet { UserDefaults.standard.set(value, forKey: "key") }
    }
}
```

---

## 2. swift-bridge: `RustStr` が Swift スコープに見えない

**エラー**:
```
cannot find type 'RustStr' in scope  (SwiftBridgeCore.swift:29)
```

**原因**: swift-bridge が生成する `SwiftBridgeCore.swift` は `RustStr`（C struct）を参照するが、`SWIFT_INCLUDE_PATHS` で module.modulemap をポイントしただけでは自動で `import RustCore` されない。

**修正**: Objective-C bridging header を使って C 型をグローバルに公開する。`SWIFT_INCLUDE_PATHS` は削除。

```h
// BridgeLite/BridgeLite-Bridging-Header.h
#include "SwiftBridgeCore.h"
#include "bridge-ffi.h"
```

```yaml
# project.yml
HEADER_SEARCH_PATHS: $(inherited) $(PROJECT_DIR)/Generated/include
SWIFT_OBJC_BRIDGING_HEADER: BridgeLite/BridgeLite-Bridging-Header.h
# SWIFT_INCLUDE_PATHS は削除 (module.modulemap との併用で衝突する)
```

---

## 3. swift-bridge: `ToRustStr.toRustStr` が throwing closure を受け付けない

**エラー**:
```
invalid conversion from throwing function of type '(RustStr) throws -> BridgeDatabase'
to non-throwing function type '(RustStr) -> BridgeDatabase'
```

**原因**: `ToRustStr` プロトコルのメソッドシグネチャが `(RustStr) -> T` (non-throwing) のため、`throws` を持つ `bridge_open_database` の内部クロージャを渡せない（swift-bridge 0.1.59 が Swift 6 の型チェックに追いついていない）。

**修正**: `SwiftBridgeCore.swift` の `ToRustStr` プロトコルと全実装を `rethrows` に変更。`bridge-ffi.swift` の呼び出し側にも `try` を追加。

```swift
// SwiftBridgeCore.swift — プロトコル定義
public protocol ToRustStr {
    func toRustStr<T>(_ withUnsafeRustStr: (RustStr) throws -> T) rethrows -> T
}

// String 実装
public func toRustStr<T>(_ withUnsafeRustStr: (RustStr) throws -> T) rethrows -> T {
    return try self.utf8CString.withUnsafeBufferPointer({ bufferPtr in
        ...
        return try withUnsafeRustStr(rustStr)
    })
}

// optionalRustStrToRustStr
func optionalRustStrToRustStr<S: ToRustStr, T>(_ str: Optional<S>, _ withUnsafeRustStr: (RustStr) throws -> T) rethrows -> T {
    if let val = str { return try val.toRustStr(withUnsafeRustStr) }
    else { return try withUnsafeRustStr(RustStr(start: nil, len: 0)) }
}

// bridge-ffi.swift — 呼び出し側
public func bridge_open_database<GenericToRustStr: ToRustStr>(_ db_path: GenericToRustStr) throws -> BridgeDatabase {
    return try db_path.toRustStr({ ... })  // try を追加
}
```

---

## 4. swift-bridge: `BridgeFfiError` の Sendable / Error 準拠問題

**エラー**:
```
conformance to 'Sendable' must occur in the same source file as class 'BridgeFfiError'
non-final class 'BridgeFfiError' cannot conform to the 'Sendable' protocol
'Sendable' class 'BridgeFfiError' cannot inherit from another class other than 'NSObject'
```

**原因**: `extension BridgeFfiError: Swift.Error {}` を別ファイルから追加すると、Swift 6 が `Error` 型に `Sendable` を要求するが、クラス継承チェーン全体が非 final・非 NSObject のため自動合成できない。

**修正**: 生成ファイル `bridge-ffi.swift` のクラス宣言に直接 `Swift.Error, @unchecked Sendable` を追加。別ファイルの extension は削除。継承ヒエラルキー全体に `@unchecked Sendable` が必要。

```swift
// bridge-ffi.swift (生成ファイルを直接編集)
public class BridgeFfiErrorRef: @unchecked Sendable { ... }
public class BridgeFfiErrorRefMut: BridgeFfiErrorRef, @unchecked Sendable { ... }
public class BridgeFfiError: BridgeFfiErrorRefMut, Swift.Error, @unchecked Sendable { ... }
```

---

## 5. `NSDirectoryEnumerator.makeIterator()` が async コンテキストで使用不可

**エラー**:
```
instance method 'makeIterator' is unavailable from asynchronous contexts
```

**原因**: Swift 6 では `NSDirectoryEnumerator` の `for-in` ループ（= `makeIterator()` 呼び出し）が async タスク内で禁止。`NSEnumerator` は non-Sendable な ObjC クラスのため。

**修正**: `allObjects` で全オブジェクトを一括取得してから反復する。

```swift
// NG
for case let fileURL as URL in enumerator { ... }

// OK
let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
for fileURL in allURLs { ... }
```

---

## 6. `KeyPress.Result.ignore` → `.ignored` (API 変更)

**エラー**:
```
type 'KeyPress.Result' has no member 'ignore'
```

**原因**: macOS 26 で `KeyPress.Result` の未処理を表すメンバーが `.ignore` から `.ignored` に改名された。

**修正**: `.ignore` → `.ignored` に一括置換。

---

## 7. `RustVec` のサブスクリプトは `Int` (UInt 不可)

**エラー**:
```
cannot convert value of type 'UInt' to expected argument type 'Int'
```

**原因**: `SwiftBridgeCore.swift` の `RustVec.subscript(position: Int)` は `Int` を要求するが、`rustVec[UInt(i)]` と書いていた。

**修正**: `rustVec[UInt(i)]` → `rustVec[i]`（`i` が既に `Int` なら変換不要）。

---

## 8. `ShapeStyle.accent` 廃止 → `.tint` (macOS 26)

**エラー**:
```
type 'ShapeStyle' has no member 'accent'
```

**原因**: macOS 26 / SwiftUI 6 で `.accent` ShapeStyle が削除された。

**修正**: `.accent` → `.tint`

---

## 9. `@ViewBuilder` ストアドプロパティを持つジェネリック View struct の初期化子ラベル

**エラー**:
```
missing argument label 'title:' in call
    SectionBox("File Type") {
              ^
               title:
```

**原因**: `struct SectionBox<Content: View>` のように `@ViewBuilder let content: () -> Content` をストアドプロパティとして持つと、Swift は自動的にメンバーワイズ初期化子 `init(title: String, content: () -> Content)` を生成する。このとき `title:` ラベルが必須になるため、`SectionBox("File Type") { ... }` という通常の View 感覚の呼び出しがコンパイルエラーになる。

過去エラーとの関連性: なし（swift-bridge・Observable 系とは別種の、純粋な Swift 初期化子ラベルの問題）。

**修正**: 明示的な `init(_ title:, content:)` を定義して `_` でラベルを省略する。

```swift
// NG: メンバーワイズ init が title: ラベルを強制する
struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    // 自動生成される init(title: String, content: () -> Content) のみ存在
}

// OK: ラベルなし init を明示定義
struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
}

// 呼び出し側はラベルなしで書ける
SectionBox("File Type") { ... }
```

**適用ファイル**: `BridgeLite/Views/SidebarView.swift`（`SectionBox` 定義）

**注意**: `@ViewBuilder` クロージャプロパティはストアドプロパティとして保持するとき `@escaping` が必要。`var body: some View` 内の `content()` 呼び出しに `@escaping` 属性を付けないと別のエラーになる。

---

## ビルドを通すための生成ファイル編集ルール

swift-bridge 0.1.59 は Swift 6 に完全対応していないため、`Generated/` 内の生成ファイルを以下のルールで手動パッチしている。`tools/build-rust-xcframework.sh` を再実行するたびにパッチが必要になることに注意。

| ファイル | 変更内容 |
|---|---|
| `Generated/SwiftBridgeCore.swift` | `ToRustStr` プロトコルと全実装を `rethrows` 対応に変更 |
| `Generated/bridge-ffi.swift` | `bridge_open_database` の `toRustStr` 呼び出しに `try` を追加、`BridgeFfiError` 継承チェーンに `Swift.Error + @unchecked Sendable` を追加 |

将来 swift-bridge が Swift 6 に正式対応したら、これらのパッチは不要になる。

---

## 10. コード署名エラー: "The executable is not codesigned"

**エラー**:
```
The executable is not codesigned.
Domain: LaunchExecutableValidationErrorDomain
Code: 1
Recovery Suggestion: Sign the executable with a valid certificate and provisioning profile.
```

**原因**: `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = "-"` (ad-hoc) の組み合わせで、Xcode 26 が署名を無音でスキップすることがある。`codesign -d -v BridgeLite.app` が `code object is not signed at all` を返す状態。

**修正**: `project.pbxproj` の Debug・Release 両構成で `CODE_SIGN_STYLE` を `Automatic` に変更し、`CODE_SIGN_IDENTITY = "-"` 行を削除する。Xcode が Preferences に登録した Apple ID（Personal Team）で自動署名する。

```
// project.pbxproj (Debug・Release 両方)
CODE_SIGN_STYLE = Automatic;   // Manual → Automatic
// CODE_SIGN_IDENTITY = "-";  // この行を削除
```

**Apple ID について**: 普段使いの Apple ID で問題ない。Personal Team は無料で作られ、秘密鍵はローカル Keychain にのみ保存される。無料アカウントの場合、開発用証明書の有効期限は 7 日だが Xcode がビルド時に自動更新する。
