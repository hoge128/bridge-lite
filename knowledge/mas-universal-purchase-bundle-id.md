# Mac App Store 版を iOS と Universal Purchase で統合する判断

## 背景

Mac 版は当初、DMG 直配布（Developer ID + Sparkle）のみだった。そこへ Mac App Store(MAS) 配信を
追加するにあたり、MAS ターゲットの Bundle ID をどうするかが論点になった。

初期方針では **`io.github.bridge-lite.mas`（Direct 版とも iOS とも別 ID）** で進めていた。
しかし「**iOS 版と同じ名前「BridgeLite」で App Store に出したい**」という要件が出たため、方針を変更した。

## 決定

MAS ターゲットの Bundle ID を **`io.github.bridge-lite.ios`（iOS ターゲットと完全一致）** に統一する。

| ターゲット | Bundle ID | 配布 |
|---|---|---|
| iOS | `io.github.bridge-lite.ios` | App Store（既存レコード） |
| **Mac App Store** | **`io.github.bridge-lite.ios`**（iOS と一致） | 同一レコードに macOS として相乗り |
| Direct (DMG) | `io.github.bridge-lite` | GitHub Releases + Sparkle（無関係） |

## なぜこの判断になったか

1. **App Store のアプリ名は（同一ストアフロント内で）一意でなければならない。**
   → 「BridgeLite」という名前の *別レコード* を Mac 用にもう1つ作ることはできない。

2. **iOS と同名で出す唯一の方法は Universal Purchase（1レコードに複数プラットフォーム統合）。**
   → 既存の iOS アプリレコードに「macOS プラットフォーム」を追加する形になる。
   → Apple の仕様上、これには **macOS と iOS の Bundle ID が完全一致**している必要がある。
   （参考: Apple "Add platforms" / Universal Purchase for Mac Apps）

3. **Bundle ID はアプリレコード作成後に変更できない（immutable）。**
   → iOS は既に `io.github.bridge-lite.ios` で `ios/v0.1.0`〜`v0.1.4` を配信済み＝ID 確定。
   → よって *Mac 側が iOS に合わせる* しかない。iOS の ID を綺麗な共有名に変えることは不可能。

4. `.ios` サフィックスが Mac アプリの Bundle ID に付くのは内部識別子のみで、**ユーザーには一切見えない**。
   見た目の違和感はあるが機能・審査上の問題はない。

## 却下した代替案

- **`io.github.bridge-lite.mas`（別 ID）のまま別レコードで出す**:
  名前を「BridgeLite」にできない（名前一意制約）。別名（例 "BridgeLite for Mac"）が必要になり要件未達。
- **iOS の Bundle ID を綺麗な共有名に変更して統一**:
  配信済みのため変更不可。レコードを作り直すと iOS のレビュー・履歴を失う。

## 実装への影響（このコミットで反映済み）

- `project.yml` の BridgeLiteMAS: `PRODUCT_BUNDLE_IDENTIFIER` / `CFBundleIdentifier` を `io.github.bridge-lite.ios` に。
  - `PRODUCT_NAME` は `BridgeLiteMAS` のまま（Direct とビルド生成物が衝突して Sparkle が ad-hoc 署名され
    Library Validation で SIGABRT した事故への対策。ユーザー表示名は `CFBundleDisplayName: BridgeLite`）。
- `fastlane/Appfile`・`Deliverfile` の `app_identifier` を `io.github.bridge-lite.ios` に。
  `deliver` は `platform("osx")` 限定で実行するため、同一レコードの **iOS 側メタデータは上書きしない**。

## リリース時に必要な前提作業（コード外）

1. Developer ポータル → Identifiers: App ID `io.github.bridge-lite.ios` で
   **macOS / Mac App Store + App Sandbox** capability を有効化。
2. App Store Connect → 既存 BridgeLite(iOS) レコードに **macOS プラットフォームを追加**。
3. `tools/do-release-mas.sh` → Xcode で BridgeLiteMAS を Archive → App Store Connect へ Upload
   （同一 Bundle ID なので同レコードに紐付く）→ `fastlane deliver` で macOS タブに投入。
