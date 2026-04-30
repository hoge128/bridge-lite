import Foundation
import Darwin
import IOKit
import IOKit.storage

// MARK: - StorageKind

enum StorageKind: Equatable {
    case ssdInternal
    case ssdExternal
    case rotational
    case network
    case removable
    case unknown
}

// MARK: - StorageProbe

enum StorageProbe {
    /// ボリュームのストレージ種別を同期的に返す（~数 ms、メインスレッド可）。
    static func probe(url: URL) -> StorageKind {
        let keys: Set<URLResourceKey> = [
            .volumeIsLocalKey, .volumeIsInternalKey,
            .volumeIsRemovableKey
        ]
        let v = try? url.resourceValues(forKeys: keys)

        if v?.volumeIsLocal == false { return .network }
        if v?.volumeIsRemovable == true { return .removable }

        return queryMediumType(path: url.path, isInternal: v?.volumeIsInternal ?? false)
    }

    // MARK: - Private

    private static func queryMediumType(path: String, isInternal: Bool) -> StorageKind {
        // statfs でマウント元デバイス名を取得 (e.g. "/dev/disk1s2")
        var st = statfs()
        guard statfs(path, &st) == 0 else { return .unknown }
        let devPath = withUnsafeBytes(of: st.f_mntfromname) { buf in
            buf.withMemoryRebound(to: CChar.self) { String(cString: $0.baseAddress!) }
        }
        // "/dev/disk1s2" → "disk1s2" → 親ディスク "disk1"
        let leafName = URL(fileURLWithPath: devPath).lastPathComponent
        let bsdName = wholeDiskName(from: leafName)

        // IOKit で BSD 名からサービスを検索
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(service) }

        // IORegistry を親方向に辿って kIOPropertyDeviceCharacteristicsKey を探す
        var entry = service
        IOObjectRetain(entry)
        var mediumType: String?

        while true {
            if let dict = IORegistryEntryCreateCFProperty(
                entry,
                kIOPropertyDeviceCharacteristicsKey as CFString,
                kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] {
                mediumType = dict[kIOPropertyMediumTypeKey] as? String
                IOObjectRelease(entry)
                break
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { break }
            entry = parent
        }

        switch mediumType {
        case kIOPropertyMediumTypeRotationalKey:
            return .rotational
        case kIOPropertyMediumTypeSolidStateKey:
            return isInternal ? .ssdInternal : .ssdExternal
        default:
            return .unknown
        }
    }

    /// "disk1s2" → "disk1"、"disk3s1s1" → "disk3"（パーティション部分を除去して親ディスク名を返す）
    private static func wholeDiskName(from bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        // "disk" の直後にある連続する数字が親ディスク番号
        let afterPrefix = bsdName.dropFirst(4)
        let diskNumber = afterPrefix.prefix(while: \.isNumber)
        return diskNumber.isEmpty ? bsdName : "disk" + diskNumber
    }
}
