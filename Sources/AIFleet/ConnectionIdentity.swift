import Foundation

struct ConnectionIdentity: Codable, Equatable {
    let email: String
    let organizationID: String?

    init(email: String, organizationID: String?) {
        self.email = Self.normalize(email)
        self.organizationID = organizationID
    }
    init?(status: ProviderStatus) {
        guard status.authentication == .signedIn, let email = status.account?.email,
              !Self.normalize(email).isEmpty else { return nil }
        self.email = Self.normalize(email)
        organizationID = status.account?.organizationID
    }
    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func matches(_ other: ConnectionIdentity) -> Bool {
        email == other.email && (organizationID == nil || organizationID == other.organizationID)
    }
}
