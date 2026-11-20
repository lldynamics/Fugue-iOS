import Foundation

/// Capture the models at voting time. Regeneration and revision selection may change a reply later.
struct ArenaBallot: Codable, Equatable {
    struct Candidate: Codable, Equatable {
        let messageID: UUID
        let providerID: UUID?
        let providerName: String
        let modelID: String
        let modelName: String
    }

    let winnerID: UUID
    let candidates: [Candidate]

    struct Standing: Identifiable {
        struct ID: Hashable {
            let provider: String
            let model: String
        }
        let id: ID
        let providerName: String
        let modelName: String
        var wins = 0
        var rounds = 0
        var winRate: Double { Double(wins) / Double(rounds) }
    }

    static func standings(in conversations: [Conversation]) -> [Standing] {
        let messages = conversations.flatMap { chat in
            chat.messages.filter { $0.comparisonGroupID != nil && !$0.isSynthesis }
        }
        return standings(from: messages)
    }

    static func standings(from arenaMessages: [ChatMessage]) -> [Standing] {
        var rows: [Standing.ID: Standing] = [:]
        for message in arenaMessages where message.comparisonGroupID != nil && !message.isSynthesis {
            guard message.assistanceMetadataData != nil,
                  let ballot = message.assistanceMetadata.blindArenaBallot,
                  ballot.winnerID == message.id else { continue }
            for candidate in ballot.candidates where !candidate.modelID.isEmpty {
                let id = Standing.ID(provider: candidate.providerID?.uuidString ?? candidate.providerName, model: candidate.modelID)
                var row = rows[id] ?? Standing(id: id, providerName: candidate.providerName, modelName: candidate.modelName)
                row.rounds += 1
                if candidate.messageID == ballot.winnerID { row.wins += 1 }
                rows[id] = row
            }
        }
        return rows.values.sorted {
            if $0.winRate != $1.winRate { return $0.winRate > $1.winRate }
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            return ($0.id.provider, $0.id.model) < ($1.id.provider, $1.id.model)
        }
    }
}
