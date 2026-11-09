# Builds the host-architecture Windows release archive:
#   dist\fourdform-windows-<arch>.zip  (fourdform.exe + the Swift/MSVC runtime DLLs it imports)
# Requires a Swift toolchain, Visual Studio C++ tools and the WebView2 Evergreen runtime.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$Name = "fourdform-windows-$Arch"

& "$PSScriptRoot\fetch-webview2.ps1" -Arch $Arch
swift build -c release --product fourdform
if ($LASTEXITCODE) { throw "swift build failed" }
$Bin = (swift build -c release --show-bin-path).Trim()

# Bundle only the runtime DLLs fourdform.exe (transitively) imports from the Swift runtime directory.
$Runtime = Split-Path -Parent (Get-Command swiftCore.dll).Source
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$Vs = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64, Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -requiresAny -property installationPath
$DumpBin = Get-ChildItem "$Vs\VC\Tools\MSVC\*\bin\Host*\*\dumpbin.exe" | Select-Object -First 1 -ExpandProperty FullName
if (-not $DumpBin) { throw "dumpbin.exe not found" }

$Package = Join-Path $Root "dist\$Name"
Remove-Item -Recurse -Force $Package -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Package | Out-Null
Copy-Item (Join-Path $Bin "fourdform.exe") $Package
# BSD-3-Clause notice for the statically linked WebView2 loader.
Copy-Item "Sources\CWebView2Raster\vendor\LICENSE.txt" (Join-Path $Package "WebView2-SDK-LICENSE.txt")
$Pending = [Collections.Generic.Queue[string]]::new()
$Pending.Enqueue((Join-Path $Package "fourdform.exe"))
$Seen = @{}
while ($Pending.Count) {
    $Image = $Pending.Dequeue()
    foreach ($Line in & $DumpBin /nologo /dependents $Image) {
        $Dll = $Line.Trim()
        if ($Dll -notmatch '\.dll$' -or $Seen.ContainsKey($Dll.ToLower())) { continue }
        $Seen[$Dll.ToLower()] = $true
        $Source = Join-Path $Runtime $Dll
        if (Test-Path $Source) {
            Copy-Item $Source $Package
            $Pending.Enqueue((Join-Path $Package $Dll))
        }
    }
}

python scripts\smoke.py (Join-Path $Package "fourdform.exe")
if ($LASTEXITCODE) { throw "smoke test failed" }

$Archive = Join-Path $Root "dist\$Name.zip"
Remove-Item -Force $Archive -ErrorAction SilentlyContinue
Compress-Archive -Path "$Package\*" -DestinationPath $Archive
Copy-Item release.json dist\release.json
$Hash = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $Root "dist\SHA256SUMS.$Arch"), "$Hash  $Name.zip`n")
