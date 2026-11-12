@preconcurrency import Contacts
import Foundation

struct ContactSource: Codable, Sendable {
    let id: String
    let label: String
    let name: String
    let type: Int
    let isDefault: Bool
    let cardCount: Int
}

struct LocalContactCard: Codable, Sendable {
    let id: String
    var fullName = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nickname = ""
    var organization = ""
    var isOrganization = false
    var sourceIDs: [String] = []
}

struct ContactsSnapshot: Sendable {
    let capturedAt: Date
    let sources: [ContactSource]
    let individual: [LocalContactCard]
    let unified: [LocalContactCard]
    let candidateLinks: [String: [String]]
}

enum ContactsReportError: LocalizedError {
    case permission(Int)
    case changedDuringRead
    case invalidArguments
    case invalidCases
    case installRequired

    var errorDescription: String? {
        switch self {
        case .permission(let status): "Contacts permission unavailable (status \(status)); existing reports retained."
        case .changedDuringRead: "Contacts changed during capture; existing reports retained. Run contacts-report again."
        case .invalidArguments: "contacts-report accepts only --check-cases PATH."
        case .invalidCases: "Cases must have unique nonempty IDs and nonempty expected names."
        case .installRequired: "Launch contacts-report through /Applications/ChatType.app."
        }
    }
}

protocol ContactsSnapshotProviding: Sendable {
    func capture() throws -> ContactsSnapshot
}

private final class ContactsReadChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.withLock { changed = true } }
    var hasChanged: Bool { lock.withLock { changed } }
}

struct NativeContactsSnapshotProvider: ContactsSnapshotProviding {
    func capture() throws -> ContactsSnapshot {
        guard AppInstallLocation.launchBlocker() == nil else { throw ContactsReportError.installRequired }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { throw ContactsReportError.permission(status.rawValue) }
        let store = CNContactStore()
        let changes = ContactsReadChanges()
        let observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange,
            object: nil, queue: nil) { _ in changes.mark() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor, CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactTypeKey as CNKeyDescriptor]
        func fetch(_ unified: Bool, keys: [CNKeyDescriptor], predicate: NSPredicate? = nil) throws -> [CNContact] {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = unified
            request.predicate = predicate
            var result: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, _ in result.append(contact) }
            return result
        }
        let idKey = [CNContactIdentifierKey as CNKeyDescriptor]
        let beforeRaw = Set(try fetch(false, keys: idKey).map(\.identifier))
        let beforeUnified = Set(try fetch(true, keys: idKey).map(\.identifier))
        let containers = try store.containers(matching: nil).sorted { $0.identifier < $1.identifier }
        let defaultID = store.defaultContainerIdentifier()
        var sources: [ContactSource] = []
        var memberships: [String: [String]] = [:]
        for (offset, container) in containers.enumerated() {
            let ids = try fetch(false, keys: idKey,
                predicate: CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)).map(\.identifier)
            sources.append(ContactSource(id: container.identifier, label: "C\(offset + 1)", name: container.name,
                type: container.type.rawValue, isDefault: container.identifier == defaultID, cardCount: ids.count))
            for id in ids { memberships[id, default: []].append(container.identifier) }
        }
        let raw = try fetch(false, keys: keys)
        let unified = try fetch(true, keys: keys)
        guard beforeRaw == Set(raw.map(\.identifier)), beforeRaw.count == raw.count,
              beforeUnified == Set(unified.map(\.identifier)), beforeUnified.count == unified.count else {
            throw ContactsReportError.changedDuringRead
        }
        func card(_ c: CNContact) -> LocalContactCard {
            LocalContactCard(id: c.identifier, fullName: CNContactFormatter.string(from: c, style: .fullName) ?? "",
                givenName: c.givenName, middleName: c.middleName, familyName: c.familyName,
                nickname: c.nickname, organization: c.organizationName,
                isOrganization: c.contactType == .organization, sourceIDs: memberships[c.identifier, default: []].sorted())
        }
        let unifiedCards = unified.map(card)
        let candidateIDs = Set(ContactsReportGroups.groups(unifiedCards, nickname: false).flatMap { $0.map(\.id) }
            + ContactsReportGroups.groups(unifiedCards, nickname: true).flatMap { $0.map(\.id) })
        var links: [String: [String]] = [:]
        for contact in unified where candidateIDs.contains(contact.identifier) {
            links[contact.identifier] = raw.filter {
                contact.isUnifiedWithContact(withIdentifier: $0.identifier)
            }.map(\.identifier).sorted()
        }
        guard !changes.hasChanged else { throw ContactsReportError.changedDuringRead }
        return ContactsSnapshot(capturedAt: Date(), sources: sources, individual: raw.map(card),
            unified: unifiedCards, candidateLinks: links)
    }
}

enum ContactsReportGroups {
    static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func groups(_ cards: [LocalContactCard], nickname: Bool) -> [[LocalContactCard]] {
        let eligible = cards.filter { nickname || !$0.isOrganization }
            .filter { !key(nickname ? $0.nickname : $0.fullName).isEmpty }
        return Dictionary(grouping: eligible) { key(nickname ? $0.nickname : $0.fullName) }
            .sorted { $0.key < $1.key }.map { $0.value.sorted { $0.id < $1.id } }.filter { $0.count > 1 }
    }
}
