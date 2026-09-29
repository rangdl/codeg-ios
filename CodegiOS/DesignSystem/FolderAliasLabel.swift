import SwiftUI

/// A folder label that leads with the user-set alias and keeps the real folder
/// name visible beside it: `alias [ name ]`. With no alias (or a blank one) it
/// renders the bare `name`.
///
/// Port of the web's `FolderAliasLabel`. The bracketed half takes a *weaker*
/// shade than the alias so the chosen label and the real folder name read as
/// separate. The plain-string equivalent — for tooltips, accessibility labels and
/// the `folderNames` lookup dictionaries — is
/// ``FolderVisibility/label(name:alias:)``; keep the `alias [ name ]` spacing in
/// sync between the two.
struct FolderAliasLabel: View {
    let name: String
    let alias: String?
    var font: Font = .headline
    /// Color of the alias — the leading, user-chosen half.
    var color: Color = Theme.textPrimary
    /// Color of the `[ name ]` half; a shade weaker than `color`.
    var bracketColor: Color = Theme.textSecondary

    var body: some View {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            // One concatenated `Text` rather than an `HStack`: `lineLimit` and
            // truncation then apply to the label as a whole, and the two halves
            // can't drift apart at a line break.
            Text(alias).font(font).foregroundColor(color)
                + Text(" [ ").font(font).foregroundColor(bracketColor)
                + Text(name).font(font).foregroundColor(bracketColor)
                + Text(" ]").font(font).foregroundColor(bracketColor)
        } else {
            Text(name).font(font).foregroundColor(color)
        }
    }
}
