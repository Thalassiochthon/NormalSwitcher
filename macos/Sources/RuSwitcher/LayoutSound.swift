import AppKit

enum LayoutSound: String, CaseIterable {
    case automatic, tap, double, wood, drop, rise, glass, soft, pulse

    init(savedValue: String?) {
        switch savedValue {
        case "Tink": self = .tap
        case "Pop": self = .wood
        case "Glass": self = .glass
        case "Ping": self = .rise
        case "Bottle": self = .drop
        default: self = savedValue.flatMap(Self.init(rawValue:)) ?? .automatic
        }
    }

    var title: String { L10n.settingsLayoutSoundName(rawValue) }

    @MainActor private static var clips: [String: NSSound] = [:]
    @MainActor private static var playing: NSSound?

    func play(firstLayout: Bool = true) {
        let name = self == .automatic ? (firstLayout ? "tap" : "soft") : rawValue
        DispatchQueue.main.async {
            guard let clip = Self.loadClip(name) else { return }
            Self.playing?.stop()
            Self.playing = clip
            clip.play()
        }
    }

    @MainActor private static func loadClip(_ name: String) -> NSSound? {
        if let clip = clips[name] { return clip }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "LayoutSounds"),
              let clip = NSSound(contentsOf: url, byReference: false) else { return nil }
        clips[name] = clip
        return clip
    }
}
