import Foundation
import SwiftData

/// The byline belongs to the reply, even if the reusable profile is edited later.
struct PersonaByline: Codable, Equatable, Sendable {
    var label: String
    var emoji: String
    var accentHex: String

    init(_ member: GroupMember) {
        label = member.displayLabel
        emoji = member.avatarEmoji
        accentHex = member.accentHex
    }

    init(label: String, emoji: String?, accentHex: String) {
        self.label = label
        self.emoji = emoji ?? "🤖"
        self.accentHex = accentHex
    }
}

@Model
final class PersonaProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    @Attribute(.externalStorage) var memberData: Data

    init(_ member: GroupMember) throws {
        let saved = member.portableProfile
        id = saved.id
        name = saved.name
        memberData = try JSONEncoder().encode(saved)
    }

    func member() throws -> GroupMember { try JSONDecoder().decode(GroupMember.self, from: memberData) }
}

extension GroupMember {
    /// A profile defines sources. Permission to poll and the last delivered item belong to a room.
    var portableProfile: Self {
        var copy = self
        copy.id = profileID ?? id
        copy.profileID = copy.id
        copy.isMuted = false
        copy.persona?.feeds = (persona?.feeds ?? []).map {
            PersonaFeed(id: $0.id, kind: $0.kind, address: $0.address, enabled: false)
        }
        return copy
    }

    var copyForNewRoom: Self {
        if profileID != nil { return inRoom() }
        var copy = self
        copy.id = UUID()
        copy.persona?.feeds = portableProfile.persona?.feeds ?? []
        return copy
    }

    func inRoom(replacing old: Self? = nil) -> Self {
        var copy = portableProfile
        copy.id = old?.id ?? UUID()
        copy.isMuted = old?.isMuted ?? false
        return copy.preservingFeedProgress(from: old, keepEnabled: true)
    }
}

@MainActor
enum PersonaLibrary {
    static func save(_ draft: GroupMember, in context: ModelContext) throws -> PersonaProfile {
        guard PersistenceController.canCommitUserData(in: context) else { throw BookImportError.cannotSave }
        var member = draft.portableProfile
        member.name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !member.name.isEmpty else { throw PersonaError.empty }
        let id = member.id
        let existing = try context.fetch(FetchDescriptor<PersonaProfile>(predicate: #Predicate { $0.id == id })).first
        let profile = try existing ?? PersonaProfile(member)
        let data = try JSONEncoder().encode(member)
        let chats = try context.fetch(FetchDescriptor<Conversation>())
        try context.save()
        do {
            if existing == nil { context.insert(profile) }
            profile.name = member.name
            profile.memberData = data
            for chat in chats {
                var settings = chat.assistanceSettings
                var changed = false
                for i in settings.groupMembers.indices where settings.groupMembers[i].profileID == id {
                    settings.groupMembers[i] = member.inRoom(replacing: settings.groupMembers[i])
                    changed = true
                }
                if let old = settings.privatePersona, old.profileID == id {
                    settings.privatePersona = member
                    if chat.primaryTarget?.id == old.target.id { chat.primaryTarget = member.target }
                    if chat.title == old.name { chat.title = member.name }
                    chat.assistantEmoji = member.avatarEmoji
                    changed = true
                }
                if changed { chat.assistanceSettings = settings }
            }
            try context.save()
        } catch { context.rollback(); throw error }
        return profile
    }

    static func invite(_ member: GroupMember, to chat: Conversation, in context: ModelContext) throws {
        guard PersistenceController.canCommitUserData(in: context), chat.isGroupMode, !chat.isDeleted,
              chat.groupMembers.count < 6, let id = member.profileID,
              !chat.groupMembers.contains(where: { $0.profileID == id }) else { throw BookImportError.cannotSave }
        guard let profile = try context.fetch(FetchDescriptor<PersonaProfile>(predicate: #Predicate { $0.id == id })).first else {
            throw BookImportError.unavailable
        }
        let current = try profile.member()
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>())
        guard ProviderConfig.readyTargets(in: providers).contains(where: { $0.id == current.target.id }) else {
            throw SystemEntryError.noModel
        }
        let previous = chat.assistanceSettingsData
        chat.groupMembers.append(current.inRoom())
        do { try context.save() } catch { chat.assistanceSettingsData = previous; throw error }
    }

    static func privateChat(with profile: PersonaProfile, in context: ModelContext) throws -> Conversation {
        guard PersistenceController.canCommitUserData(in: context) else { throw BookImportError.cannotSave }
        let member = try profile.member().portableProfile
        let chats = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        if let existing = chats.first(where: { !$0.isArenaMode && !$0.isGroupMode && $0.assistanceSettings.privatePersona?.profileID == profile.id }) {
            return existing
        }
        let chat = Conversation(title: member.name, assistantEmoji: member.avatarEmoji, primaryTarget: member.target)
        chat.assistanceSettings.privatePersona = member
        context.insert(chat)
        do { try context.save() } catch { context.delete(chat); throw error }
        return chat
    }
}
