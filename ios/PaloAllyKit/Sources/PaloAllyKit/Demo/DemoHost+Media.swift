import Foundation

/// An image or file the app sent the demo.
struct DemoMedia: Sendable {
    var mediaType: String
    var name: String?
    var data: Data
    var isImage: Bool { name == nil }
}

extension DemoHost {
    /// media.upload / uploadChunk / get / read, as the host's MediaStore:
    /// images in one call, other files in chunks, read back by id.
    func dispatchMedia(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case RPCMethod.mediaUpload:
            let type = p["mediaType"]?.stringValue ?? ""
            guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(type) else {
                throw DemoError(message: "只支持 JPEG、PNG、GIF、WebP 图片")
            }
            guard let data = Data(base64Encoded: p["data"]?.stringValue ?? ""), !data.isEmpty else { throw DemoError(message: "图片是空的") }
            let id = nextID("img")
            media[id] = DemoMedia(mediaType: type, data: data)
            return try .from(Attachment(id: id, mediaType: type))
        case RPCMethod.mediaUploadChunk:
            let name = p["name"]?.stringValue ?? "file"
            let chunk = Data(base64Encoded: p["data"]?.stringValue ?? "") ?? Data()
            var uid = p["uploadId"]?.stringValue ?? ""
            if uid.isEmpty {
                uid = nextID("up")
                uploads[uid] = DemoMedia(mediaType: p["mediaType"]?.stringValue ?? DemoHost.mime(for: name), name: name, data: Data())
            }
            guard var up = uploads[uid] else { throw DemoError(message: "上传已失效，重新发送") }
            up.data.append(chunk)
            guard p["done"]?.boolValue == true else {
                uploads[uid] = up
                return ["uploadId": .string(uid)]
            }
            uploads[uid] = nil
            let id = nextID("file")
            media[id] = up
            return try .from(Attachment(id: id, kind: "file", mediaType: up.mediaType, name: up.name, size: Int64(up.data.count)))
        case RPCMethod.mediaGet:
            guard let m = media[p["id"]?.stringValue ?? ""], m.isImage else { return nil }
            return ["mediaType": .string(m.mediaType), "data": .string(m.data.base64EncodedString())]
        case RPCMethod.mediaRead:
            guard let m = media[p["id"]?.stringValue ?? ""] else { return nil }
            let offset = min(Int(p["offset"]?.doubleValue ?? 0), m.data.count)
            let end = min(m.data.count, offset + 256 * 1024)
            return ["data": .string(m.data.subdata(in: offset..<end).base64EncodedString()), "size": .number(Double(m.data.count)),
                    "mime": .string(m.mediaType), "eof": .bool(end >= m.data.count)]
        default:
            return nil
        }
    }

    /// The attachments a chat.send or pals.send names (nil: none); an id
    /// that wasn't uploaded is refused, as the host does.
    func attachments(_ ids: JSONValue?) throws -> [Attachment]? {
        guard case .array(let list)? = ids, !list.isEmpty else { return nil }
        return try list.map { v in
            let id = v.stringValue ?? ""
            guard let m = media[id] else { throw DemoError(message: "附件没传上来，重发一次") }
            return m.isImage ? Attachment(id: id, mediaType: m.mediaType)
                : Attachment(id: id, kind: "file", mediaType: m.mediaType, name: m.name, size: Int64(m.data.count))
        }
    }
}
