[CmdletBinding()]
param(
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory ".."))
$solution = Join-Path $windowsRoot "Callya.slnx"
$project = Join-Path $windowsRoot "src\AICallAssistant.Desktop\AICallAssistant.Desktop.csproj"
$artifactsRoot = Join-Path $windowsRoot "artifacts"
$publishRoot = Join-Path $artifactsRoot "publish\$Runtime"
$packageRoot = Join-Path $artifactsRoot "package"
$zipPath = Join-Path $packageRoot "Callya-Windows-$Runtime.zip"
$checksumPath = "$zipPath.sha256"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET 10 SDK не найден. Установите его с https://dotnet.microsoft.com/download/dotnet/10.0"
}

$sdkVersion = dotnet --version
if (-not $sdkVersion.StartsWith("10.")) {
    throw "Нужен .NET 10 SDK; найден $sdkVersion."
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

dotnet restore $solution
if ($LASTEXITCODE -ne 0) { throw "dotnet restore завершился с ошибкой." }

if (-not $SkipTests) {
    dotnet test $solution --configuration $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw "Тесты завершились с ошибкой." }
}

if (Test-Path -LiteralPath $publishRoot) {
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}

dotnet publish $project `
    --configuration $Configuration `
    --runtime $Runtime `
    --self-contained true `
    --output $publishRoot `
    --no-restore `
    -p:PublishSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false
if ($LASTEXITCODE -ne 0) { throw "dotnet publish завершился с ошибкой." }

$executable = Join-Path $publishRoot "Callya.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Сборка не создала Callya.exe."
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $publishRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$hash  $(Split-Path -Leaf $zipPath)" -Encoding ascii

Write-Host "Готово: $zipPath"
Write-Host "SHA-256: $hash"
