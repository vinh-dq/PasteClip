import CloudKit
import Foundation
import PasteClipCore
import PasteClipSystem

/// Mirrors clips and pinboards to the user's private iCloud database with CKSyncEngine.
///
/// Only works in a build signed with the iCloud (CloudKit) entitlement; check `isAvailable`
/// first. Clip contents go in encrypted fields. The paste stack stays local.
public final class CloudSync: ObservableObject, CKSyncEngineDelegate, @unchecked Sendable {
    public static var isAvailable: Bool { Entitlements.hasCloudKit }

    @Published public private(set) var status = "Off"

    private let store: ClipStore
    private var engine: CKSyncEngine?
    private let zoneID = CKRecordZone.ID(zoneName: "PasteClip", ownerName: CKCurrentUserDefaultName)
    private let stateURL: URL
    private let fieldsURL: URL
    /// Last known server system fields (change tags) per record, so saves don't conflict.
    private var systemFields: [String: Data] = [:]

    public init(store: ClipStore) {
        self.store = store
        stateURL = store.directory.appendingPathComponent("sync-state.json")
        fieldsURL = store.directory.appendingPathComponent("sync-records.json")
    }

    // Everything below runs on the main thread; CKSyncEngine callbacks hop there first.

    public func start() {
        guard engine == nil, Self.isAvailable, let containerID = Entitlements.iCloudContainers.first else { return }
        let state = loadState()
        systemFields = state == nil ? [:] : loadFields()

        let config = CKSyncEngine.Configuration(
            database: CKContainer(identifier: containerID).privateCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        let engine = CKSyncEngine(config)
        self.engine = engine
        if state == nil {
            // First run on this Mac: create the zone and upload everything we have.
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            enqueue(saved: store.allSyncRecords, deleted: [])
        }
        store.onLocalChange = { [weak self] saved, deleted in self?.enqueue(saved: saved, deleted: deleted) }
        status = "Syncing…"
        syncNow()
    }

    public func stop() {
        store.onLocalChange = nil
        engine = nil
        status = "Off"
    }

    public func syncNow() {
        guard let engine else { return }
        Task {
            try? await engine.fetchChanges()
            try? await engine.sendChanges()
        }
    }

    private func enqueue(saved: [SyncRecord], deleted: [SyncRecord]) {
        engine?.state.add(pendingRecordZoneChanges:
            saved.map { .saveRecord(recordID($0)) } + deleted.map { .deleteRecord(recordID($0)) })
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.makeRecord(id) }
        }
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                enqueue(saved: store.allSyncRecords, deleted: [])
            case .signOut, .switchAccounts:
                // Keep the local history; forget what we knew about the old account.
                systemFields = [:]
                saveFields()
                status = "Not signed in to iCloud"
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                // The zone was deleted (e.g. from iCloud settings). Recreate it from local data.
                systemFields = [:]
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                enqueue(saved: store.allSyncRecords, deleted: [])
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications { apply(modification.record) }
            for deletion in changes.deletions {
                systemFields[deletion.recordID.recordName] = nil
                switch syncRecord(deletion.recordID) {
                case .clip(let id): store.removeRemoteClip(id)
                case .pinboard(let id): store.removeRemotePinboard(id)
                case nil: break
                }
            }
            saveFields()

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                systemFields[record.recordID.recordName] = Self.encodeSystemFields(record)
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Someone else changed it first; take theirs.
                    if let server = failure.error.serverRecord { apply(server) }
                case .zoneNotFound:
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    systemFields[id.recordName] = nil
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                default:
                    break // Network and throttling errors are retried by the engine.
                }
            }
            saveFields()

        case .didFetchChanges, .didSendChanges:
            status = "Up to date · " + Date().formatted(date: .omitted, time: .shortened)

        default:
            break
        }
    }

    // MARK: - Records

    private func recordID(_ record: SyncRecord) -> CKRecord.ID {
        switch record {
        case .clip(let id): return CKRecord.ID(recordName: "clip-\(id.uuidString)", zoneID: zoneID)
        case .pinboard(let id): return CKRecord.ID(recordName: "board-\(id.uuidString)", zoneID: zoneID)
        }
    }

    private func syncRecord(_ id: CKRecord.ID) -> SyncRecord? {
        let name = id.recordName
        if name.hasPrefix("clip-"), let uuid = UUID(uuidString: String(name.dropFirst(5))) { return .clip(uuid) }
        if name.hasPrefix("board-"), let uuid = UUID(uuidString: String(name.dropFirst(6))) { return .pinboard(uuid) }
        return nil
    }

    private func makeRecord(_ id: CKRecord.ID) -> CKRecord? {
        switch syncRecord(id) {
        case .clip(let uuid):
            guard let item = store.item(withID: uuid) else { return nil }
            let record = existingRecord(id) ?? CKRecord(recordType: "Clip", recordID: id)
            record["kind"] = item.kind.rawValue
            record["date"] = item.date
            record["pinned"] = item.pinned
            record["pinboard"] = item.pinboardID?.uuidString
            record["boardOrder"] = item.boardOrder
            record["sourceBundleID"] = item.sourceBundleID
            record["richType"] = item.richType
            record.encryptedValues["text"] = item.text
            record.encryptedValues["title"] = item.title
            record.encryptedValues["filePaths"] = item.filePaths
            record.encryptedValues["ocrText"] = item.ocrText
            record.encryptedValues["sourceName"] = item.sourceName
            record["image"] = store.imageURL(for: item).map(CKAsset.init(fileURL:))
            record["rich"] = store.richURL(for: item).map(CKAsset.init(fileURL:))
            return record

        case .pinboard(let uuid):
            guard let board = store.pinboard(withID: uuid) else { return nil }
            let record = existingRecord(id) ?? CKRecord(recordType: "Pinboard", recordID: id)
            record.encryptedValues["name"] = board.name
            record["colorIndex"] = board.colorIndex
            record["created"] = board.created
            record["order"] = board.order
            return record

        case nil:
            return nil
        }
    }

    private func apply(_ record: CKRecord) {
        systemFields[record.recordID.recordName] = Self.encodeSystemFields(record)
        switch syncRecord(record.recordID) {
        case .clip(let id):
            guard let kind = (record["kind"] as? String).flatMap(ClipKind.init(rawValue:)) else { return }
            var item = ClipItem(kind: kind,
                                text: record.encryptedValues["text"] as? String,
                                filePaths: record.encryptedValues["filePaths"] as? [String],
                                sourceBundleID: record["sourceBundleID"] as? String,
                                sourceName: record.encryptedValues["sourceName"] as? String)
            item.id = id
            item.title = record.encryptedValues["title"] as? String
            item.ocrText = record.encryptedValues["ocrText"] as? String
            item.richType = record["richType"] as? String
            item.date = record["date"] as? Date ?? Date()
            item.pinned = record["pinned"] as? Bool ?? false
            item.pinboardID = (record["pinboard"] as? String).flatMap(UUID.init(uuidString:))
            item.boardOrder = record["boardOrder"] as? Double
            store.applyRemote(item,
                              imageSource: (record["image"] as? CKAsset)?.fileURL,
                              richSource: (record["rich"] as? CKAsset)?.fileURL)

        case .pinboard(let id):
            var board = Pinboard(name: record.encryptedValues["name"] as? String ?? "Pinboard",
                                 colorIndex: record["colorIndex"] as? Int ?? 0)
            board.id = id
            board.created = record["created"] as? Date ?? Date()
            board.order = record["order"] as? Double
            store.applyRemote(board)

        case nil:
            break
        }
    }

    private func existingRecord(_ id: CKRecord.ID) -> CKRecord? {
        guard let data = systemFields[id.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    // MARK: - Persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func loadFields() -> [String: Data] {
        guard let data = try? Data(contentsOf: fieldsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private func saveFields() {
        guard let data = try? JSONEncoder().encode(systemFields) else { return }
        try? data.write(to: fieldsURL, options: .atomic)
    }
}
