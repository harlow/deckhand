/// Browse-menu configuration rows (menuItem / category / sort), matching a Rekordbox 7 export.
enum OneLibraryMenus {
    struct MenuItem { let id: Int; let kind: Int; let name: String }
    struct Category { let id: Int; let menuItemId: Int; let sequenceNo: Int; let isVisible: Bool }
    struct Sort { let id: Int; let menuItemId: Int; let sequenceNo: Int; let isVisible: Bool; let isSelectedAsSubColumn: Bool }

    /// Names are wrapped in U+FFFA … U+FFFB, which players replace with localized labels.
    private static func label(_ s: String) -> String { "\u{FFFA}\(s)\u{FFFB}" }

    static let menuItems: [MenuItem] = [
        (1, 128, "GENRE"), (2, 129, "ARTIST"), (3, 130, "ALBUM"), (4, 131, "TRACK"), (5, 133, "BPM"),
        (6, 134, "RATING"), (7, 135, "YEAR"), (8, 136, "REMIXER"), (9, 137, "LABEL"), (10, 138, "ORIGINAL ARTIST"),
        (11, 139, "KEY"), (12, 141, "CUE"), (13, 142, "COLOR"), (14, 146, "TIME"), (15, 147, "BITRATE"),
        (16, 148, "FILE NAME"), (17, 132, "PLAYLIST"), (18, 152, "HOT CUE BANK"), (19, 149, "HISTORY"),
        (20, 145, "SEARCH"), (21, 150, "COMMENTS"), (22, 140, "DATE ADDED"), (23, 151, "DJ PLAY COUNT"),
        (24, 144, "FOLDER"), (25, 161, "DEFAULT"), (26, 162, "ALPHABET"), (27, 170, "MATCHING"),
    ].map { MenuItem(id: $0.0, kind: $0.1, name: label($0.2)) }

    static let categories: [Category] = [
        (1, 1, 0, false), (2, 2, 1, true), (3, 3, 2, true), (4, 4, 3, true), (5, 17, 5, true),
        (6, 5, 0, false), (7, 6, 0, false), (8, 7, 0, false), (9, 8, 0, false), (10, 9, 0, false),
        (11, 10, 0, false), (12, 11, 4, true), (15, 13, 0, false), (17, 24, 9, true), (18, 20, 7, true),
        (19, 14, 0, false), (20, 15, 0, false), (21, 16, 0, false), (22, 19, 6, true), (23, 18, 0, false),
        (26, 27, 8, true), (27, 22, 10, true),
    ].map { Category(id: $0.0, menuItemId: $0.1, sequenceNo: $0.2, isVisible: $0.3) }

    static let sorts: [Sort] = [
        (0, 25, 1, true, false), (1, 26, 2, true, false), (2, 2, 3, true, false), (3, 3, 4, true, false),
        (4, 5, 5, true, false), (5, 6, 6, true, false), (6, 1, 0, false, false), (7, 21, 0, false, false),
        (8, 14, 0, false, false), (9, 8, 0, false, false), (10, 9, 0, false, false), (11, 10, 0, false, false),
        (12, 11, 7, true, true), (13, 15, 0, false, false), (15, 13, 0, false, false), (16, 23, 0, false, false),
        (17, 22, 0, false, false),
    ].map { Sort(id: $0.0, menuItemId: $0.1, sequenceNo: $0.2, isVisible: $0.3, isSelectedAsSubColumn: $0.4) }
}
