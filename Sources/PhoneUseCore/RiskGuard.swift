import Foundation

/// Decides which taps wait for the user's approval. The model flags irreversible taps itself; this is the
/// floor under that, reading the label under the finger.
public struct RiskGuard: Sendable {
    public var words: [String]

    public init(words: [String] = RiskGuard.defaultWords) {
        self.words = words
    }

    public static let defaultWords = [
        "send", "post", "publish", "reply", "share",
        "pay", "buy", "purchase", "order", "checkout", "check out", "subscribe", "donate", "transfer",
        "book", "reserve", "confirm", "submit", "approve", "accept", "allow entry",
        "delete", "remove", "erase", "unsubscribe", "cancel booking", "cancel order", "cancel class",
        "cancel subscription", "cancel reservation", "log out", "sign out",
    ]

    /// Taps that can simply be undone, or only open checkout, even when the model calls them irreversible. Placing the order is not here.
    public static let undoable = ["add to cart", "add to bag", "add to basket", "add to wishlist", "add to wish list", "save for later",
                                         "proceed to buy", "proceed to checkout", "buy now"]

    /// Choosing how to pay. The person allows the purchase here, once; the order placed after it doesn't ask again.
    public static let paymentStep = ["use this payment method", "payment method", "cash on delivery", "pay on delivery",
                                     "continue to payment", "proceed to payment", "select payment", "choose payment"]

    public func isPaymentStep(_ target: String) -> Bool {
        let label = target.lowercased()
        return Self.paymentStep.contains { label.contains($0) }
    }

    /// The tap that places an order or pays, which the payment step's Allow covers.
    public func placesOrder(_ target: String) -> Bool {
        let label = target.lowercased()
        return ["place your order", "place order", "pay now", "confirm order", "complete order"].contains { label.contains($0) }
    }

    public func needsApproval(target: String, flaggedIrreversible: Bool) -> Bool {
        let label = target.lowercased()
        if Self.undoable.contains(where: { label.contains($0) }) { return false }
        if flaggedIrreversible { return true }
        let tokens = Set(label.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.contains { word in
            word.contains(" ") ? label.contains(word) : tokens.contains(word)
        }
    }
}
