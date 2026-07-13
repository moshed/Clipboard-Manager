import SwiftData
import Foundation

@Model
final class ClipboardImageBlob {
    @Attribute(.unique) var id: UUID
    var data: Data

    init(id: UUID, data: Data) {
        self.id = id
        self.data = data
    }
}

enum ClipboardImageStore {
    static func fullData(for entryID: UUID, context: ModelContext) -> Data? {
        var descriptor = FetchDescriptor<ClipboardImageBlob>(
            predicate: #Predicate { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.data
    }

    static func deleteBlob(for entryID: UUID, context: ModelContext) {
        var descriptor = FetchDescriptor<ClipboardImageBlob>(
            predicate: #Predicate { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        if let blob = (try? context.fetch(descriptor))?.first {
            context.delete(blob)
        }
    }
}
