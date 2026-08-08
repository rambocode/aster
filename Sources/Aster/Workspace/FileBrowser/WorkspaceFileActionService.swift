import AsterCore
import Foundation

enum WorkspaceFileActionError: LocalizedError, Equatable {
  case invalidName(FileItemNameError)
  case unsafeParent
  case unsafeItem
  case alreadyExists(String)
  case itemMissing(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidName: "The name is not valid."
    case .unsafeParent: "The target folder is unavailable or is a symbolic link."
    case .unsafeItem: "The selected item is unavailable, symbolic, or a special file."
    case .alreadyExists(let name): "“\(name)” already exists."
    case .itemMissing(let name): "“\(name)” no longer exists."
    case .operationFailed(let message): message
    }
  }
}

struct WorkspaceFileMutation: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case created, moved, trashed }
  let kind: Kind
  let oldURL: URL?
  let newURL: URL?
}

/// Files 菜单的唯一写入 seam。服务在任何写入前重新检查父目录与同名目标，
/// 因此菜单打开后文件树发生变化也不会意外覆盖新项目。
final class WorkspaceFileActionService {
  typealias TrashItem = (URL) throws -> URL

  private let fileManager: FileManager
  private let trashItem: TrashItem

  init(
    fileManager: FileManager = .default,
    trashItem: @escaping TrashItem = { url in
      var resultingURL: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
      return (resultingURL as URL?) ?? url
    }
  ) {
    self.fileManager = fileManager
    self.trashItem = trashItem
  }

  func createFile(named proposedName: String, in parent: URL) throws -> WorkspaceFileMutation {
    let name = try validatedName(proposedName)
    try validateParent(parent)
    let target = parent.appendingPathComponent(name, isDirectory: false)
    guard !fileManager.fileExists(atPath: target.path) else {
      throw WorkspaceFileActionError.alreadyExists(name)
    }
    do {
      try Data().write(to: target, options: .withoutOverwriting)
      return WorkspaceFileMutation(kind: .created, oldURL: nil, newURL: target)
    } catch {
      throw WorkspaceFileActionError.operationFailed(error.localizedDescription)
    }
  }

  func createDirectory(named proposedName: String, in parent: URL) throws
    -> WorkspaceFileMutation
  {
    let name = try validatedName(proposedName)
    try validateParent(parent)
    let target = parent.appendingPathComponent(name, isDirectory: true)
    guard !fileManager.fileExists(atPath: target.path) else {
      throw WorkspaceFileActionError.alreadyExists(name)
    }
    do {
      try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
      return WorkspaceFileMutation(kind: .created, oldURL: nil, newURL: target)
    } catch {
      throw WorkspaceFileActionError.operationFailed(error.localizedDescription)
    }
  }

  func rename(_ source: URL, to proposedName: String) throws -> WorkspaceFileMutation {
    try validateSource(source)
    let name = try validatedName(proposedName)
    let parent = source.deletingLastPathComponent()
    try validateParent(parent)
    let target = parent.appendingPathComponent(name)
    if target.standardizedFileURL == source.standardizedFileURL {
      return WorkspaceFileMutation(kind: .moved, oldURL: source, newURL: source)
    }
    guard !fileManager.fileExists(atPath: target.path) else {
      throw WorkspaceFileActionError.alreadyExists(name)
    }
    do {
      try fileManager.moveItem(at: source, to: target)
      return WorkspaceFileMutation(kind: .moved, oldURL: source, newURL: target)
    } catch {
      throw WorkspaceFileActionError.operationFailed(error.localizedDescription)
    }
  }

  func moveToTrash(_ source: URL) throws -> WorkspaceFileMutation {
    try validateSource(source)
    do {
      let destination = try trashItem(source)
      return WorkspaceFileMutation(kind: .trashed, oldURL: source, newURL: destination)
    } catch {
      throw WorkspaceFileActionError.operationFailed(error.localizedDescription)
    }
  }

  private func validatedName(_ proposed: String) throws -> String {
    do { return try FileItemNameValidator.validate(proposed) } catch let error as FileItemNameError
    { throw WorkspaceFileActionError.invalidName(error) } catch {
      throw WorkspaceFileActionError.operationFailed(error.localizedDescription)
    }
  }

  private func validateParent(_ parent: URL) throws {
    guard parent.isFileURL,
      let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true, values.isSymbolicLink != true
    else { throw WorkspaceFileActionError.unsafeParent }
  }

  private func validateSource(_ source: URL) throws {
    guard fileManager.fileExists(atPath: source.path) else {
      throw WorkspaceFileActionError.itemMissing(source.lastPathComponent)
    }
    guard source.isFileURL,
      let values = try? source.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]), values.isSymbolicLink != true,
      values.isDirectory == true || values.isRegularFile == true
    else { throw WorkspaceFileActionError.unsafeItem }
  }
}
