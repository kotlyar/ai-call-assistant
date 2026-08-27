using System.IO;
using System.Security.Cryptography;
using System.Text;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Desktop.Services.Security;

public sealed class DpapiSecretStore : ISecretStore
{
    // This entropy is part of the encrypted-data format and must remain stable across renames.
    private static readonly byte[] OptionalEntropy =
        Encoding.UTF8.GetBytes("AI Call Assistant/openai-api-key/v1");

    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    private readonly SemaphoreSlim _gate = new(1, 1);

    public DpapiSecretStore(ApplicationPaths paths)
        : this(GetSecretFilePath(paths))
    {
    }

    public DpapiSecretStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        FilePath = Path.GetFullPath(filePath);
    }

    public string FilePath { get; }

    public async Task<bool> HasSecretAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return File.Exists(FilePath) && new FileInfo(FilePath).Length > 0;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string?> ReadSecretAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(FilePath))
            {
                return null;
            }

            var protectedBytes = await File.ReadAllBytesAsync(
                FilePath,
                cancellationToken).ConfigureAwait(false);
            byte[]? plainTextBytes = null;
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                plainTextBytes = ProtectedData.Unprotect(
                    protectedBytes,
                    OptionalEntropy,
                    DataProtectionScope.CurrentUser);
                return StrictUtf8.GetString(plainTextBytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(protectedBytes);
                if (plainTextBytes is not null)
                {
                    CryptographicOperations.ZeroMemory(plainTextBytes);
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task WriteSecretAsync(
        string value,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException("Секрет не может быть пустым.", nameof(value));
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var plainTextBytes = StrictUtf8.GetBytes(value);
            byte[]? protectedBytes = null;
            try
            {
                protectedBytes = ProtectedData.Protect(
                    plainTextBytes,
                    OptionalEntropy,
                    DataProtectionScope.CurrentUser);
                await WriteAtomicallyAsync(
                    protectedBytes,
                    cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plainTextBytes);
                if (protectedBytes is not null)
                {
                    CryptographicOperations.ZeroMemory(protectedBytes);
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task DeleteSecretAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            File.Delete(FilePath);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task WriteAtomicallyAsync(
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken)
    {
        var directoryPath = Path.GetDirectoryName(FilePath)
            ?? throw new InvalidOperationException("Путь к хранилищу секрета не содержит папку.");
        Directory.CreateDirectory(directoryPath);
        var temporaryPath = Path.Combine(
            directoryPath,
            $".{Path.GetFileName(FilePath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                new FileStreamOptions
                {
                    Mode = FileMode.CreateNew,
                    Access = FileAccess.Write,
                    Share = FileShare.None,
                    BufferSize = 4 * 1024,
                    Options = FileOptions.Asynchronous | FileOptions.WriteThrough
                }))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, FilePath, overwrite: true);
            temporaryPath = string.Empty;
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporaryPath))
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (IOException)
                {
                    // A failed cleanup must not hide the original persistence error.
                }
                catch (UnauthorizedAccessException)
                {
                    // A failed cleanup must not hide the original persistence error.
                }
            }
        }
    }

    private static string GetSecretFilePath(ApplicationPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return paths.SecretFilePath;
    }
}
