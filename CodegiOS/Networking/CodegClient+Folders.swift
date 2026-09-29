import Foundation

/// Folder-detail server calls — browsing a folder's files and reading its git
/// history. Kept in an extension so `CodegClient.swift` stays focused on the
/// chat/session core. All ride the same `POST /api/<name>` transport. Request
/// bodies are camelCase (encoded verbatim, matching the server's
/// `rename_all = "camelCase"` param structs); responses are snake_case and
/// decoded with `.convertFromSnakeCase`, except `git_diff`/`git_show_diff` which
/// return a bare JSON string (the unified-diff text).
extension CodegClient {
    // MARK: - Files

    /// Immediate children of `path` (directories *and* files), for the folder
    /// file browser. `path` is an absolute server path; each item's `path` is
    /// absolute too.
    func listDirectoryWithFiles(path: String) async throws -> [DirectoryItem] {
        try await postJSON("list_directory_with_files", PathBody(path: path))
    }

    /// Flat, gitignore-aware listing of every file/dir under `path` (a workspace
    /// root). One request for the whole tree, pruned of ignored directories
    /// server-side — see ``WorkspaceFileEntry``. Used by the composer's
    /// References picker, which searches it in memory.
    func listWorkspaceFiles(path: String) async throws -> [WorkspaceFileEntry] {
        try await postJSON("list_workspace_files", PathBody(path: path))
    }

    // MARK: - Alias

    /// Set (or clear) a folder's display alias, returning the updated folder.
    ///
    /// `alias: nil` — or a blank/whitespace-only string — clears it (the server
    /// normalizes too). Purely cosmetic: the alias never changes `path` or any
    /// filesystem/git behaviour, it only leads the label as `alias [ name ]`.
    /// Mirrors the web's `updateFolderAlias`.
    func updateFolderAlias(folderId: Int, alias: String?) async throws -> FolderDetail {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return try await postJSON(
            "update_folder_alias",
            UpdateFolderAliasBody(folderId: folderId, alias: normalized)
        )
    }

    /// Text content of a file under `rootPath`. **`path` must be relative to
    /// `rootPath`** — the server rejects absolute paths and `..` traversal. Use
    /// ``FolderPaths/relative(_:to:)`` to derive it from a browser item's
    /// absolute path.
    func readFilePreview(rootPath: String, path: String) async throws -> FilePreviewContent {
        try await postJSON("read_file_preview", ReadFilePreviewBody(rootPath: rootPath, path: path))
    }

    // MARK: - Git history

    /// Commit history for the repo at `path`. `limit` caps the count (server
    /// default 100); `branch`/`remote` scope it (nil = current branch).
    func gitLog(path: String, limit: Int? = nil, branch: String? = nil, remote: String? = nil) async throws -> GitLogResult {
        try await postJSON("git_log", GitLogBody(path: path, limit: limit, branch: branch, remote: remote))
    }

    /// Working-tree changes (porcelain status) for the repo at `path`. Pass
    /// `showAllUntracked` to list every untracked file individually rather than
    /// collapsing untracked directories.
    func gitStatus(path: String, showAllUntracked: Bool? = nil) async throws -> [GitStatusEntry] {
        try await postJSON("git_status", GitStatusBody(path: path, showAllUntracked: showAllUntracked))
    }

    /// Unified diff of the working tree against HEAD. `file` (relative repo path)
    /// scopes it to one file; nil diffs everything. Returns the raw diff text.
    func gitDiff(path: String, file: String? = nil) async throws -> String {
        try await postJSON("git_diff", GitDiffBody(path: path, file: file))
    }

    /// Unified diff introduced by a single `commit`. `file` (relative repo path)
    /// scopes it to one file; nil shows the whole commit. Returns the raw diff text.
    func gitShowDiff(path: String, commit: String, file: String? = nil) async throws -> String {
        try await postJSON("git_show_diff", GitShowDiffBody(path: path, commit: commit, file: file))
    }

    // MARK: - Git branches

    /// All branches for the repo at `path`: local, remote, and the local branches
    /// already checked out in another worktree (`worktreeBranches`).
    func gitListAllBranches(path: String) async throws -> GitBranchList {
        try await postJSON("git_list_all_branches", PathBody(path: path))
    }

    /// The repo's current branch (`get_git_branch`), or nil for a detached HEAD /
    /// non-git path. Returns a bare JSON string (or `null`).
    func gitCurrentBranch(path: String) async throws -> String? {
        let data = try await send("get_git_branch", body: PathBody(path: path))
        if Self.isJSONNull(data) { return nil }
        return try? CodegJSON.decoder.decode(String.self, from: data)
    }

    /// Check out an existing local or remote branch in the working tree at `path`.
    /// Response is `null`.
    func gitCheckout(path: String, branchName: String) async throws {
        _ = try await send("git_checkout", body: GitCheckoutBody(path: path, branchName: branchName))
    }

    /// Create a new branch off `startPoint` (nil = current HEAD) and check it out.
    /// Response is `null`.
    func gitNewBranch(path: String, branchName: String, startPoint: String? = nil) async throws {
        _ = try await send("git_new_branch", body: GitNewBranchBody(path: path, branchName: branchName, startPoint: startPoint))
    }

    // MARK: - Git operations (commit / remote / working tree)

    /// Commit `files` (repo-root-relative paths) with `message`. The server
    /// **stages the listed files itself** (`git add -- …`), so untracked paths can
    /// be committed directly without a separate `gitAddFiles`. `folderId` lets the
    /// server broadcast a commit-succeeded event to other workspace clients.
    func gitCommit(path: String, message: String, files: [String], folderId: Int?) async throws -> GitCommitResult {
        try await postJSON("git_commit", GitCommitBody(folderId: folderId, path: path, message: message, files: files))
    }

    /// Push the current branch to `remote` (nil = the branch's upstream / default).
    /// `credentials` is optional — the server falls back to stored GitHub accounts
    /// and surfaces an `authentication_failed` error when none match.
    func gitPush(path: String, remote: String? = nil, credentials: GitCredentials? = nil, folderId: Int? = nil) async throws -> GitPushResult {
        try await postJSON("git_push", GitPushBody(folderId: folderId, path: path, remote: remote, credentials: credentials))
    }

    /// Pull (fetch + merge) the current branch's upstream. The result reports how
    /// many files changed and, if the merge conflicted, a ``GitConflictInfo``.
    func gitPull(path: String, credentials: GitCredentials? = nil) async throws -> GitPullResult {
        try await postJSON("git_pull", GitPullBody(path: path, credentials: credentials))
    }

    /// Fetch all remotes. Returns the raw fetch summary text (bare JSON string).
    func gitFetch(path: String, credentials: GitCredentials? = nil) async throws -> String {
        try await postJSON("git_fetch", GitFetchBody(path: path, credentials: credentials))
    }

    /// Branch + remotes + tracking remote for the repo at `path` — drives the
    /// Commits tab push header and the no-remote disabled state.
    func gitPushInfo(path: String) async throws -> GitPushInfo {
        try await postJSON("git_push_info", PathBody(path: path))
    }

    /// The repo's configured remotes (`git_list_remotes`). Used to resolve the
    /// origin host when prompting for credentials.
    func gitListRemotes(path: String) async throws -> [GitRemote] {
        try await postJSON("git_list_remotes", PathBody(path: path))
    }

    /// Discard a tracked file's working-tree + staged changes (`git restore
    /// --source=HEAD`). Untracked files have no HEAD version to restore — delete
    /// them with ``deleteFileTreeEntry(rootPath:path:)`` instead. Response is `null`.
    func gitRollbackFile(path: String, file: String) async throws {
        _ = try await send("git_rollback_file", body: PathFileBody(path: path, file: file))
    }

    /// Stage (`git add`) untracked/modified `files` so they start being tracked.
    /// Commit doesn't require this (it stages internally), but it lets a user begin
    /// tracking a file without committing. Response is `null`.
    func gitAddFiles(path: String, files: [String]) async throws {
        _ = try await send("git_add_files", body: GitAddFilesBody(path: path, files: files))
    }

    /// Delete a file (or directory) under `rootPath` from disk. **`path` is
    /// relative to `rootPath`** (same rule as ``readFilePreview``). Response is
    /// `null`. Used to remove an untracked file from the Changes tab.
    func deleteFileTreeEntry(rootPath: String, path: String) async throws {
        _ = try await send("delete_file_tree_entry", body: DeleteFileTreeEntryBody(rootPath: rootPath, path: path))
    }

    // MARK: - Worktrees

    /// Where `branch` is currently checked out across the repo's worktrees. See
    /// ``WorktreeResolution`` for the path/folderId matrix. `repoPath` is any path
    /// inside the repo (the active folder's path).
    func resolveWorktreeFolder(repoPath: String, branch: String) async throws -> WorktreeResolution {
        try await postJSON("resolve_worktree_folder", ResolveWorktreeFolderBody(repoPath: repoPath, branch: branch))
    }

    /// Register an existing worktree directory as a folder, parented to the root
    /// repo (`sourceFolderId` is the active folder; the server flattens grandchild
    /// worktrees back to the root). Returns the new ``FolderDetail``.
    func openWorktreeFolder(path: String, sourceFolderId: Int) async throws -> FolderDetail {
        try await postJSON("open_worktree_folder", OpenWorktreeFolderBody(path: path, sourceFolderId: sourceFolderId))
    }

    /// Create a new git worktree at `worktreePath` on a new `branchName` (off the
    /// repo at `path`). Creates the worktree + branch only — register it as a
    /// folder afterward with ``openWorktreeFolder(path:sourceFolderId:)``.
    /// Response is `null`.
    func gitWorktreeAdd(path: String, branchName: String, worktreePath: String) async throws {
        _ = try await send("git_worktree_add", body: GitWorktreeAddBody(path: path, branchName: branchName, worktreePath: worktreePath))
    }
}

// MARK: - Request bodies (camelCase keys; nil optionals are omitted)

/// Body for `read_file_preview` — `path` relative to `rootPath`.
struct ReadFilePreviewBody: Encodable, Sendable {
    let rootPath: String
    let path: String
}

/// Body for `git_log`.
struct GitLogBody: Encodable, Sendable {
    let path: String
    var limit: Int?
    var branch: String?
    var remote: String?
}

/// Body for `git_status`.
struct GitStatusBody: Encodable, Sendable {
    let path: String
    var showAllUntracked: Bool?
}

/// Body for `git_diff`.
struct GitDiffBody: Encodable, Sendable {
    let path: String
    var file: String?
}

/// Body for `git_show_diff`.
struct GitShowDiffBody: Encodable, Sendable {
    let path: String
    let commit: String
    var file: String?
}

/// Body for `git_checkout`.
struct GitCheckoutBody: Encodable, Sendable {
    let path: String
    let branchName: String
}

/// Body for `git_new_branch`. `startPoint` (nil = current HEAD) is the ref the
/// new branch is created from; the server creates and checks it out.
struct GitNewBranchBody: Encodable, Sendable {
    let path: String
    let branchName: String
    var startPoint: String?
}

/// Body for `resolve_worktree_folder`.
struct ResolveWorktreeFolderBody: Encodable, Sendable {
    let repoPath: String
    let branch: String
}

/// Body for `open_worktree_folder`. `sourceFolderId` is the active folder; the
/// server records the new folder's parent as that folder's root.
struct OpenWorktreeFolderBody: Encodable, Sendable {
    let path: String
    let sourceFolderId: Int
}

/// Body for `git_worktree_add`.
struct GitWorktreeAddBody: Encodable, Sendable {
    let path: String
    let branchName: String
    let worktreePath: String
}

/// Body for `git_commit`. `folderId` (nil omitted) lets the server broadcast a
/// commit event to other workspace clients.
struct GitCommitBody: Encodable, Sendable {
    var folderId: Int?
    let path: String
    let message: String
    let files: [String]
}

/// Body for `git_push`. All of `folderId` / `remote` / `credentials` are optional
/// (nil omitted → server resolves the default remote / stored credentials).
struct GitPushBody: Encodable, Sendable {
    var folderId: Int?
    let path: String
    var remote: String?
    var credentials: GitCredentials?
}

/// Body for `git_pull`.
struct GitPullBody: Encodable, Sendable {
    let path: String
    var credentials: GitCredentials?
}

/// Body for `git_fetch`.
struct GitFetchBody: Encodable, Sendable {
    let path: String
    var credentials: GitCredentials?
}

/// Body for `git_add_files`.
struct GitAddFilesBody: Encodable, Sendable {
    let path: String
    let files: [String]
}

/// Body for `git_rollback_file` / other `{path, file}` git calls.
struct PathFileBody: Encodable, Sendable {
    let path: String
    let file: String
}

/// Body for `delete_file_tree_entry` — `path` relative to `rootPath`.
struct DeleteFileTreeEntryBody: Encodable, Sendable {
    let rootPath: String
    let path: String
}

// MARK: - Path helpers

/// Path math for the folder file browser. The directory listing returns
/// absolute server paths, but `read_file_preview` wants a path relative to the
/// folder root — these bridge the two.
enum FolderPaths {
    /// `absPath` expressed relative to `root` (no leading slash). Falls back to
    /// the last path component when `absPath` isn't under `root`.
    static func relative(_ absPath: String, to root: String) -> String {
        var base = root
        if !base.hasSuffix("/") { base += "/" }
        if absPath == root { return "" }
        if absPath.hasPrefix(base) { return String(absPath.dropFirst(base.count)) }
        return (absPath as NSString).lastPathComponent
    }

    /// Human-readable file size ("1.2 KB", "—" for directories / unknown).
    static func size(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
