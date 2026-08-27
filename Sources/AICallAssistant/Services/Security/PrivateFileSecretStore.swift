import Darwin
import Foundation

enum PrivateFileSecretStoreOperation: String, Equatable, Sendable {
    case prepareDirectory = "prepare directory"
    case read
    case write
    case delete
}

enum PrivateFileSecretStoreError: Error, Equatable, LocalizedError, Sendable {
    case applicationSupportDirectoryUnavailable
    case unsafeStorageLocation
    case operationFailed(operation: PrivateFileSecretStoreOperation, code: Int32)
    case invalidStoredData
    case secretTooLarge

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "The private credential storage directory is unavailable."
        case .unsafeStorageLocation:
            return "The private credential storage location is unsafe."
        case let .operationFailed(operation, code):
            return "Private credential storage could not \(operation.rawValue) (code \(code))."
        case .invalidStoredData:
            return "Private credential storage contained data in an unsupported format."
        case .secretTooLarge:
            return "The credential is too large for private local storage."
        }
    }
}

/// Stores app credentials in a user-only file without invoking Keychain UI.
///
/// The containing directory is restricted to `0700`, and each secret is
/// atomically replaced by a regular file created with mode `0600`. Errors are
/// deliberately expressed using only fixed text and numeric system codes so a
/// credential can never become part of an error or log message.
final class PrivateFileSecretStore: SecretStore, @unchecked Sendable {
    static let applicationSupportDirectoryName = "com.aicallassistant.desktop"
    static let secretsDirectoryName = "Secrets"

    private static let directoryMode: mode_t = S_IRWXU
    private static let fileMode: mode_t = S_IRUSR | S_IWUSR
    private static let maximumSecretBytes = 64 * 1_024

    private let fileManager: FileManager
    private let configuredDirectoryURL: URL?
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        configuredDirectoryURL = directoryURL ?? Self.defaultDirectoryURL(using: fileManager)
    }

    func readSecret(for identifier: SecretIdentifier) throws -> String? {
        try withLock {
            let directoryURL = try prepareDirectory()
            let path = secretFileURL(for: identifier, in: directoryURL).path
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)

            guard descriptor >= 0 else {
                if errno == ENOENT {
                    return nil
                }
                if errno == ELOOP {
                    throw PrivateFileSecretStoreError.unsafeStorageLocation
                }
                throw failure(.read)
            }
            defer { _ = Darwin.close(descriptor) }

            let fileStatus = try validateOpenFile(descriptor, operation: .read)
            guard fileStatus.st_size >= 0,
                  fileStatus.st_size <= Self.maximumSecretBytes else {
                throw PrivateFileSecretStoreError.secretTooLarge
            }
            guard Darwin.fchmod(descriptor, Self.fileMode) == 0 else {
                throw failure(.read)
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= Self.maximumSecretBytes else {
                        throw PrivateFileSecretStoreError.secretTooLarge
                    }
                    data.append(buffer, count: count)
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                throw failure(.read)
            }

            guard let secret = String(data: data, encoding: .utf8) else {
                throw PrivateFileSecretStoreError.invalidStoredData
            }
            return secret
        }
    }

    func writeSecret(_ secret: String, for identifier: SecretIdentifier) throws {
        try withLock {
            let secretData = Data(secret.utf8)
            guard secretData.count <= Self.maximumSecretBytes else {
                throw PrivateFileSecretStoreError.secretTooLarge
            }
            let directoryURL = try prepareDirectory()
            let destinationURL = secretFileURL(for: identifier, in: directoryURL)
            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(identifier.rawValue).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let temporaryPath = temporaryURL.path
            var shouldRemoveTemporaryFile = true
            defer {
                if shouldRemoveTemporaryFile {
                    _ = Darwin.unlink(temporaryPath)
                }
            }

            let descriptor = Darwin.open(
                temporaryPath,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                Self.fileMode
            )
            guard descriptor >= 0 else {
                throw failure(.write)
            }

            do {
                _ = try validateOpenFile(descriptor, operation: .write)
                guard Darwin.fchmod(descriptor, Self.fileMode) == 0 else {
                    throw failure(.write)
                }
                try writeAll(secretData, to: descriptor)
                guard Darwin.fsync(descriptor) == 0 else {
                    throw failure(.write)
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }

            guard Darwin.close(descriptor) == 0 else {
                throw failure(.write)
            }
            guard Darwin.rename(temporaryPath, destinationURL.path) == 0 else {
                throw failure(.write)
            }
            shouldRemoveTemporaryFile = false
            excludeFromBackup(destinationURL)
            synchronizeDirectory(at: directoryURL)
        }
    }

    func deleteSecret(for identifier: SecretIdentifier) throws {
        try withLock {
            let directoryURL = try prepareDirectory()
            let path = secretFileURL(for: identifier, in: directoryURL).path
            var fileStatus = stat()

            guard Darwin.lstat(path, &fileStatus) == 0 else {
                if errno == ENOENT {
                    return
                }
                throw failure(.delete)
            }
            guard isRegularFile(fileStatus), fileStatus.st_uid == Darwin.geteuid() else {
                throw PrivateFileSecretStoreError.unsafeStorageLocation
            }
            guard Darwin.unlink(path) == 0 else {
                throw failure(.delete)
            }
        }
    }

    private static func defaultDirectoryURL(using fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(secretsDirectoryName, isDirectory: true)
    }

    private func prepareDirectory() throws -> URL {
        guard let directoryURL = configuredDirectoryURL else {
            throw PrivateFileSecretStoreError.applicationSupportDirectoryUnavailable
        }

        var directoryStatus = stat()
        if Darwin.lstat(directoryURL.path, &directoryStatus) == 0 {
            try validateDirectory(directoryStatus)
        } else if errno == ENOENT {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Self.directoryMode)]
                )
            } catch {
                throw PrivateFileSecretStoreError.operationFailed(
                    operation: .prepareDirectory,
                    code: safeErrorCode(error)
                )
            }
        } else {
            throw failure(.prepareDirectory)
        }

        directoryStatus = stat()
        guard Darwin.lstat(directoryURL.path, &directoryStatus) == 0 else {
            throw failure(.prepareDirectory)
        }
        try validateDirectory(directoryStatus)
        guard Darwin.chmod(directoryURL.path, Self.directoryMode) == 0 else {
            throw failure(.prepareDirectory)
        }
        excludeFromBackup(directoryURL)
        return directoryURL
    }

    private func secretFileURL(
        for identifier: SecretIdentifier,
        in directoryURL: URL
    ) -> URL {
        directoryURL.appendingPathComponent(identifier.rawValue, isDirectory: false)
    }

    private func validateOpenFile(
        _ descriptor: Int32,
        operation: PrivateFileSecretStoreOperation
    ) throws -> stat {
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw failure(operation)
        }
        guard isRegularFile(fileStatus), fileStatus.st_uid == Darwin.geteuid() else {
            throw PrivateFileSecretStoreError.unsafeStorageLocation
        }
        return fileStatus
    }

    private func validateDirectory(_ directoryStatus: stat) throws {
        guard isDirectory(directoryStatus), directoryStatus.st_uid == Darwin.geteuid() else {
            throw PrivateFileSecretStoreError.unsafeStorageLocation
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if count > 0 {
                    bytesWritten += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw failure(.write)
            }
        }
    }

    private func isDirectory(_ fileStatus: stat) -> Bool {
        (fileStatus.st_mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ fileStatus: stat) -> Bool {
        (fileStatus.st_mode & S_IFMT) == S_IFREG
    }

    private func failure(
        _ operation: PrivateFileSecretStoreOperation
    ) -> PrivateFileSecretStoreError {
        .operationFailed(operation: operation, code: errno)
    }

    private func safeErrorCode(_ error: Error) -> Int32 {
        let code = (error as NSError).code
        guard code >= Int(Int32.min), code <= Int(Int32.max) else {
            return EIO
        }
        return Int32(code)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func synchronizeDirectory(at directoryURL: URL) {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
