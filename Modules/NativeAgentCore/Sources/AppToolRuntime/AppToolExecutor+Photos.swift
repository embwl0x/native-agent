import Foundation
import NativeAgentCore
import PersistenceCore
import Photos

extension AppToolExecutor {
    @MainActor
    func runPhotosRead(verb: String, input: [String: JSONValue]) async -> JSONValue {
        var bounds: [String: Date] = [:]
        for key in ["start", "end"] {
            if let value = input[key] {
                guard case .string(let text) = value,
                      let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) else {
                    return Self.failure("invalid_date", "start and end must be ISO 8601 timestamps with a timezone; start is inclusive and end exclusive.")
                }
                bounds[key] = date
            }
        }
        if let start = bounds["start"], let end = bounds["end"], start >= end {
            return Self.failure("invalid_range", "start must be earlier than end.")
        }
        let media: String
        switch input["media_type"] {
        case nil: media = "all"
        case .string(let value)? where ["all", "image", "video"].contains(value): media = value
        default: return Self.failure("invalid_media_type", "media_type must be all, image or video.")
        }
        let limit: Int
        switch input["limit"] {
        case nil: limit = 10
        case .int(let value)? where (1...100).contains(value): limit = Int(value)
        default: return Self.failure("invalid_limit", "limit must be an integer from 1 to 100; default 10.")
        }
        var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else {
            return Self.failure("photos_access_off", "Photos access is off. User can enable NativeAgent in System Settings › Privacy & Security › Photos. If access is restricted by device management, the administrator must allow it.")
        }
        let limited = authorization == .limited
        let dates = bounds
        return await Task.detached {
            let options = PHFetchOptions()
            var predicates: [NSPredicate] = []
            if let start = dates["start"] { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
            if let end = dates["end"] { predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate)) }
            if media != "all" {
                predicates.append(NSPredicate(format: "mediaType == %d", (media == "image" ? PHAssetMediaType.image : .video).rawValue))
            }
            if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
            if verb == "recent" {
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = limit
            }
            let assets = PHAsset.fetchAssets(with: options)
            var result: [String: JSONValue] = ["status": .string("ok"), "count": .int(Int64(assets.count)),
                "media_type": .string(media), "limited_access": .bool(limited),
                "coverage": .string(limited ? "Only assets shared with NativeAgent; counts are not whole-library totals." : "Accessible Photos library assets; dates are creation dates.")]
            if verb == "recent" {
                let iso = ISO8601DateFormatter()
                result["assets"] = .array((0..<assets.count).map { index in
                    let asset = assets.object(at: index)
                    let kind = switch asset.mediaType { case .image: "image"; case .video: "video"; case .audio: "audio"; default: "unknown" }
                    var row: [String: JSONValue] = ["id": .string(asset.localIdentifier),
                        "date": asset.creationDate.map { .string(iso.string(from: $0)) } ?? .null,
                        "media_type": .string(kind), "width": .int(Int64(asset.pixelWidth)),
                        "height": .int(Int64(asset.pixelHeight)), "favorite": .bool(asset.isFavorite)]
                    if let location = asset.location {
                        row["location"] = .object(["latitude": .double(location.coordinate.latitude), "longitude": .double(location.coordinate.longitude)])
                    }
                    return .object(row)
                })
            }
            return .object(result)
        }.value
    }
}
