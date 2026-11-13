#requires -Version 5.1
<#
Laedt die portablen System.Data.SQLite-Binaries (offizielle vorkompilierte
ZIPs von system.data.sqlite.org) in das bin/-Verzeichnis des Projekts.
Keine Installation, reines xcopy-Layout (bin\System.Data.SQLite.dll +
bin\x86\SQLite.Interop.dll + bin\x64\SQLite.Interop.dll).
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.118.0',
    [string]$InstallDir
)

$root = Split-Path -Parent $PSScriptRoot
if (-not $InstallDir) { $InstallDir = Join-Path $root 'bin' }
$base = "https://system.data.sqlite.org/downloads/$Version"

$zips = @(
    @{ Arch = 'x64'; Url = "$base/sqlite-netFx46-binary-x64-2015-$Version.zip" },
    @{ Arch = 'x86'; Url = "$base/sqlite-netFx46-binary-x86-2015-$Version.zip" }
)

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($z in $zips) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('deplOI_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zipPath = Join-Path $tmp 'bundle.zip'
    Write-Host ('Lade {0} ...' -f $z.Url)
    try {
        Invoke-WebRequest -Uri $z.Url -OutFile $zipPath -UseBasicParsing
    }
    catch {
        if ($z.Arch -eq 'x64') { throw }
        $msg = ('Download fuer {0} fehlgeschlagen ({1}) - wird uebersprungen. ' -f $z.Arch, $_.Exception.Message) +
            'Hinweis: PowerShell 5.1 x64 benoetigt nur die x64-Interop-DLL.'
        Write-Warning $msg
        continue
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tmp)

    $managed = Get-ChildItem -Path $tmp -Recurse -Filter 'System.Data.SQLite.dll' | Select-Object -First 1
    if (-not $managed) { throw 'System.Data.SQLite.dll im Archiv nicht gefunden.' }
    $interop = Get-ChildItem -Path $tmp -Recurse -Filter 'SQLite.Interop.dll' | Select-Object -First 1
    if (-not $interop) { throw 'SQLite.Interop.dll im Archiv nicht gefunden.' }

    Copy-Item $managed.FullName (Join-Path $InstallDir 'System.Data.SQLite.dll') -Force
    $archDir = Join-Path $InstallDir $z.Arch
    New-Item -ItemType Directory -Path $archDir -Force | Out-Null
    Copy-Item $interop.FullName (Join-Path $archDir 'SQLite.Interop.dll') -Force

    Remove-Item -Recurse -Force $tmp
}

Get-ChildItem -Path $InstallDir -Recurse -File | Unblock-File
Write-Host ('Fertig. SQLite-Binaries liegen in: {0}' -f $InstallDir)
