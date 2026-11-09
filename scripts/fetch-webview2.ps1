# Fetches the pinned Microsoft WebView2 SDK (BSD-3-Clause) used only at build
# time: headers plus WebView2LoaderStatic.lib for the requested architecture.
# The SDK is not committed; the runtime used is the system Evergreen WebView2.
param(
    [ValidateSet("arm64", "x64")]
    [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" })
)
$ErrorActionPreference = "Stop"
$Version = "1.0.4314.35"
$Sha256 = "90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4"
$Root = Split-Path -Parent $PSScriptRoot
$Vendor = Join-Path $Root "Sources\CWebView2Raster\vendor"
$Stamp = Join-Path $Vendor "$Version-$Arch.stamp"
if (Test-Path $Stamp) { exit 0 }

$Work = Join-Path ([IO.Path]::GetTempPath()) ("fourdform-sdk-" + [Guid]::NewGuid())
New-Item -ItemType Directory $Work | Out-Null
try {
    $Package = Join-Path $Work "webview2.zip"
    Invoke-WebRequest -UseBasicParsing -OutFile $Package `
        "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$Version/microsoft.web.webview2.$Version.nupkg"
    $Actual = (Get-FileHash -Algorithm SHA256 $Package).Hash
    if ($Actual -ne $Sha256) { throw "WebView2 SDK checksum mismatch: $Actual" }
    Expand-Archive $Package (Join-Path $Work "sdk")
    $Native = Join-Path $Work "sdk\build\native"
    if (Test-Path $Vendor) { Remove-Item -Recurse -Force $Vendor }
    New-Item -ItemType Directory (Join-Path $Vendor "include"), (Join-Path $Vendor "lib") | Out-Null
    Copy-Item (Join-Path $Native "include\WebView2.h"), (Join-Path $Native "include\WebView2EnvironmentOptions.h") `
        (Join-Path $Vendor "include")
    Copy-Item (Join-Path $Native "$Arch\WebView2LoaderStatic.lib") (Join-Path $Vendor "lib")
    Copy-Item (Join-Path $Work "sdk\LICENSE.txt") (Join-Path $Vendor "LICENSE.txt")
    Set-Content -Path $Stamp -Value "Microsoft.Web.WebView2 $Version $Arch sha256:$Sha256"
} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
