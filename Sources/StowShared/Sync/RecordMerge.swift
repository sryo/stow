import CloudKit
import Foundation

/// Three-way merge for an upload that collided with a newer server copy: each field
/// this device changed since `base` (the last server copy it knew) keeps its value,
/// every other field takes the server's. `dataJSON` merges key by key inside the JSON,
/// so a link's title and URL count as separate fields.
public enum RecordMerge {

    /// `theirs`, with this device's changes applied. Without a base, the server wins.
    public static func merge(base: CKRecord?, ours: CKRecord, theirs: CKRecord) -> CKRecord {
        guard let base else { return theirs }
        for key in ours.allKeys() {
            let mine = ours[key] as? NSObject
            let original = base[key] as? NSObject
            guard mine != original else { continue }
            if key == CKNodeFields.dataJSON,
               let merged = mergeJSON(base: original as? String, ours: mine as? String, theirs: theirs[key] as? String) {
                theirs[key] = merged as CKRecordValue
            } else {
                theirs[key] = ours[key]
            }
        }
        return theirs
    }

    private static func mergeJSON(base: String?, ours: String?, theirs: String?) -> String? {
        guard let base = object(base), let ours = object(ours), var merged = object(theirs) else { return nil }
        for key in Set(base.keys).union(ours.keys) {
            let mine = ours[key] as? NSObject
            guard mine != base[key] as? NSObject else { continue }
            merged[key] = ours[key]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
