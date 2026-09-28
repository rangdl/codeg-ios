import Foundation

/// One subdirectory returned by `list_directory_entries` for the server-side
/// directory browser. The server lists directories only; `hasChildren` says
/// whether drilling in will reveal further subdirectories (drives the chevron).
struct DirectoryEntry: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let hasChildren: Bool

    var id: String { path }
}

/// One entry returned by `list_directory_with_files` — like ``DirectoryEntry``
/// but includes files too (Rust `DirectoryItem`, serialized camelCase). Powers
/// the folder file browser: directories drill in, files open a preview. `path`
/// is the entry's **absolute** server path; `size` is bytes (files only).
struct DirectoryItem: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDir: Bool
    /// Only meaningful for directories — whether drilling in reveals children.
    let hasChildren: Bool
    /// File size in bytes; `nil` for directories.
    let size: Int?

    var id: String { path }
}

/// One entry of the flat, gitignore-aware workspace listing
/// (`list_workspace_files` → Rust `WorkspaceFileEntry`).
///
/// Unlike ``DirectoryItem`` this is **not** a single directory listing: the
/// backend walks the whole workspace once, pruning ignored directories during
/// the walk and applying no depth cap, then returns every surviving file/dir as
/// a flat list. That is what makes it usable for in-memory search (the
/// composer's References picker) without a request per directory.
struct WorkspaceFileEntry: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    /// Path relative to the workspace root, always forward-slashed.
    let path: String
    /// `"file"` or `"dir"` on the wire. Kept as the raw string so an unknown
    /// kind from a newer server decodes instead of failing the whole listing.
    let kind: String

    var id: String { path }
    var isDirectory: Bool { kind == "dir" }
}

/// A file's text content (Rust `FilePreviewContent`), returned by
/// `read_file_preview`. `path` echoes the request's relative path.
struct FilePreviewContent: Decodable, Sendable {
    let path: String
    let content: String
}
