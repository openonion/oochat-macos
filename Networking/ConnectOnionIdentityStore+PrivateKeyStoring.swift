import ConnectOnionKit
import Foundation

extension ConnectOnionIdentityStore: PrivateKeyStoring {
    nonisolated func loadOrCreatePrivateKey() throws -> Data {
        /// Turn identity object into 32 bits for ConnectOnionKit identity storage
        try loadOrCreateIdentity().rawPrivateKey
    }
}
