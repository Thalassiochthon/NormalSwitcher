import AppKit

enum LayoutSound: String, CaseIterable {
    case automatic, silent, tap, double, wood, drop, rise, glass, soft, pulse

    static let defaultsOrder: [Self] = [.tap, .soft, .drop, .wood, .glass, .rise, .pulse, .double]
    static let choices = defaultsOrder + [.silent]

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

    static func assignments(
        _ saved: [String: String], sources: [String], legacy: String?,
        first: String, second: String
    ) -> [String: String] {
        var values = saved
        let legacySound = LayoutSound(savedValue: legacy)
        if legacy != nil {
            for (id, sound) in [(first, LayoutSound.tap), (second, .soft)]
                where sources.contains(id) && values[id] == nil && legacySound == .automatic {
                values[id] = sound.rawValue
            }
        }
        for id in sources where !choices.contains(where: { $0.rawValue == values[id] }) {
            let used = Set(values.values)
            let available = defaultsOrder.first { !used.contains($0.rawValue) } ?? .tap
            values[id] = (values[id] == nil && legacySound != .automatic ? legacySound : available).rawValue
        }
        return values
    }

    @MainActor private static var clips: [String: NSSound] = [:]
    @MainActor private static var playing: NSSound?
    @MainActor private static var repeatWork: DispatchWorkItem?
    @MainActor private static var previewing = false

    @MainActor
    static func stop() {
        repeatWork?.cancel()
        repeatWork = nil
        playing?.stop()
        playing = nil
        previewing = false
    }

    @MainActor
    func play(twice: Bool = false, preview: Bool = false) {
        if preview, !Self.previewing, Self.playing?.isPlaying == true || Self.repeatWork != nil { return }
        Self.stop()
        guard Self.choices.contains(self), self != .silent, let clip = Self.loadClip(rawValue) else { return }
        Self.playing = clip
        Self.previewing = preview
        guard clip.play(), twice else { return }
        let repeatWork = DispatchWorkItem {
            Self.repeatWork = nil
            clip.stop()
            clip.play()
        }
        Self.repeatWork = repeatWork
        DispatchQueue.main.asyncAfter(deadline: .now() + clip.duration + 0.06, execute: repeatWork)
    }

    @MainActor private static func loadClip(_ name: String) -> NSSound? {
        if let clip = clips[name] { return clip }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "LayoutSounds"),
              let clip = NSSound(contentsOf: url, byReference: false) else { return nil }
        clips[name] = clip
        return clip
    }
}


// The first reading establishes a baseline. A later system notification for a
// switch already observed by auto-correction must not play another cue.
struct LayoutSoundTransition {
    private(set) var currentID: String?

    mutating func update(_ id: String) -> Bool {
        guard !id.isEmpty, id != currentID else { return false }
        let changed = currentID != nil
        currentID = id
        return changed
    }
}
