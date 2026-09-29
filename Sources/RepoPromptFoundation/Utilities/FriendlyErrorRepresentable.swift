import Foundation

protocol FriendlyErrorRepresentable: Error {
    var friendlyErrorString: String { get }
}
