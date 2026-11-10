import AppKit

enum LayoutSound: String, CaseIterable {
    case automatic, tink = "Tink", pop = "Pop", glass = "Glass", ping = "Ping", bottle = "Bottle"

    var title: String { self == .automatic ? L10n.settingsLayoutSoundDefault : rawValue }

    func play(firstLayout: Bool = true) {
        let defaultName = firstLayout ? "Tink" : "Pop"
        let name = self == .automatic ? defaultName : rawValue
        (NSSound(named: name) ?? NSSound(named: defaultName))?.play()
    }
}
