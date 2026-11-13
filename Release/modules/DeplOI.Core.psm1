# DeplOI.Core.psm1 - Basisfunktionen: Pfade, Konfiguration, Logging, Async-Bruecke.

$script:Root = Split-Path -Parent $PSScriptRoot
$script:ToolVersion = '0.1.0'

function Get-DeplOIRoot {
    return $script:Root
}

function Get-DeplOIToolVersion {
    return $script:ToolVersion
}

function Get-DeplOIConfig {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:Root 'config.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Konfiguration nicht gefunden: $Path"
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{ Info = 'Gray'; Warn = 'Yellow'; Error = 'Red' }
    Write-Host ('[{0}] [{1}] {2}' -f $stamp, $Level, $Message) -ForegroundColor $colors[$Level]
}

function Invoke-ViAsync {
    # VI.DB stellt viele Methoden als Task (TAP) bereit; PowerShell 5.1 kennt kein await.
    # Diese Bruecke fuehrt Tasks synchron aus und entpackt das Ergebnis.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)
    $result = & $Action
    if ($null -ne $result -and $result -is [System.Threading.Tasks.Task]) {
        return $result.GetAwaiter().GetResult()
    }
    return $result
}
