#requires -Version 5.1
<#
DeplOI Portable - CLI
======================
Extraktion von Systemdaten aus One Identity Identity Manager (ab 9.x) ueber die
REST-API des App Servers, Speicherung in SQLite und Vergleich von Extrakt-Paaren
als HTML-Report.

Verwendung:
  .\DeplOI.ps1 extract -BaseUrl 'https://host/AppServer' -User viadmin -Password '...' [-SystemName PROD] [-OutDb pfad.db]
  .\DeplOI.ps1 mock-extract [-Variant 1|2] [-SystemName NAME] [-OutDb pfad.db]
  .\DeplOI.ps1 compare -Baseline a.db -Target b.db [-ReportPath out.html]
  .\DeplOI.ps1 demo
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('extract', 'mock-extract', 'compare', 'demo', 'help')]
    [string]$Command = 'help',

    [string]$BaseUrl,
    [string]$User,
    [string]$Password,
    [ValidateSet('DialogUser', 'OAuth', 'OAuthRoleBased')][string]$AuthenticationType = 'DialogUser',
    [string]$ClientID,
    [string]$ClientSecret,
    [string]$TokenURL,
    [string]$Scope = 'openid',
    [string]$RedirectURL,
    [string]$SystemName,
    [string]$OutDb,
    [int]$Variant = 1,
    [switch]$SkipDynamic,
    [switch]$SkipStatic,
    [string[]]$Tables = @(),
    [string]$Baseline,
    [string]$Target,
    [string]$ReportPath
)

$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

foreach ($m in @('DeplOI.Core', 'DeplOI.Store', 'DeplOI.Connector', 'DeplOI.Extract', 'DeplOI.Compare', 'DeplOI.Report','\PSAuthClient.PSAuthClient')) {
    Import-Module -Name (Join-Path $script:Root ('modules\' + $m + '.psm1')) -Force -DisableNameChecking
}

function New-DefaultExtractPath {
    param([string]$Name)
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    return (Join-Path $script:Root ('extracts\{0}_{1}.db' -f $Name, $ts))
}

function Write-CompareSummary {
    param($Comparison)
    $t = $Comparison.Total
    Write-Log ('Neu: {0} | Entfernt: {1} | Geaendert: {2} | Unveraendert: {3} | Gesamt: {4}' -f `
        $t['added'], $t['removed'], $t['changed'], $t['unchanged'], $t['objects'])
}

switch ($Command) {

    'extract' {
        if (-not $BaseUrl) {
            throw "extract: -BaseUrl ist erforderlich, z.B. 'https://host/AppServer'"
        }
        if (-not $SystemName) { $SystemName = 'IM' }
        if (-not $OutDb) { $OutDb = New-DefaultExtractPath -Name $SystemName }
        Write-Log ('Extraktion ueber App Server -> {0}' -f $OutDb)
        $imSession = Connect-ImSession -BaseUrl $BaseUrl -User $User -Password $Password -AuthenticationType $AuthenticationType -ClientID $ClientID -ClientSecret $ClientSecret -TokenURL $TokenURL -Scope $Scope -RedirectURL $RedirectURL
        try {
            $null = Invoke-Extraction -ImSession $imSession -OutDb $OutDb -SystemName $SystemName -SkipDynamic:$SkipDynamic -SkipStatic:$SkipStatic -Tables $Tables
        }
        finally {
            Disconnect-ImSession -ImSession $imSession
        }
        Write-Log ('Extrakt erstellt: {0}' -f $OutDb)
    }

    'mock-extract' {
        if (-not $SystemName) { $SystemName = ('MOCK-V{0}' -f $Variant) }
        if (-not $OutDb) { $OutDb = New-DefaultExtractPath -Name $SystemName }
        Write-Log ('Mock-Extraktion (Variante {0}) -> {1}' -f $Variant, $OutDb)
        $null = Invoke-Extraction -Mock -Variant $Variant -OutDb $OutDb -SystemName $SystemName
        Write-Log ('Extrakt erstellt: {0}' -f $OutDb)
    }

    'compare' {
        if (-not $Baseline -or -not $Target) {
            throw 'compare: -Baseline und -Target (Pfade zu Extrakt-DBs) sind erforderlich.'
        }
        if (-not $ReportPath) {
            $b1 = [System.IO.Path]::GetFileNameWithoutExtension($Baseline)
            $b2 = [System.IO.Path]::GetFileNameWithoutExtension($Target)
            $ReportPath = Join-Path $script:Root ('reports\compare_{0}_{1}.html' -f $b1, $b2)
        }
        Write-Log ('Vergleiche {0} -> {1}' -f $Baseline, $Target)
        $comparison = Compare-Extracts -BaselineDb $Baseline -TargetDb $Target
        $null = New-CompareReport -Comparison $comparison -OutPath $ReportPath
        Write-CompareSummary -Comparison $comparison
        Write-Log ('Report: {0}' -f $ReportPath)
    }

    'demo' {
        $v1 = Join-Path $script:Root 'extracts\mock_v1.db'
        $v2 = Join-Path $script:Root 'extracts\mock_v2.db'
        foreach ($p in @($v1, $v2)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
        Write-Log 'Demo: zwei Mock-Extrakte, Vergleich, HTML-Report.'
        $null = Invoke-Extraction -Mock -Variant 1 -OutDb $v1 -SystemName 'MOCK-V1'
        $null = Invoke-Extraction -Mock -Variant 2 -OutDb $v2 -SystemName 'MOCK-V2'
        $comparison = Compare-Extracts -BaselineDb $v1 -TargetDb $v2
        $report = Join-Path $script:Root 'reports\demo_compare.html'
        $null = New-CompareReport -Comparison $comparison -OutPath $report
        Write-CompareSummary -Comparison $comparison
        Write-Log ('Demo-Report: {0}' -f $report)
    }

    'help' {
        Write-Host @'
DeplOI Portable - Verwendung
  extract      Extrahiert Systemdaten ueber die REST-API des App Servers in eine neue Extrakt-DB.
               Beispiel: .\DeplOI.ps1 extract -BaseUrl 'https://host/AppServer' -User viadmin -Password '...' -SystemName PROD
               OAuth:   zusaetzlich -AuthenticationType OAuth -TokenURL <uri> -ClientID <id> -RedirectURL <uri> (interaktiv, benoetigt PSAuthClient)
  mock-extract Erzeugt einen Mock-Extrakt (Pipeline-Test ohne laufenden IM). -Variant 1 oder 2.
  compare      Vergleicht zwei Extrakt-DBs und erzeugt einen HTML-Report.
               Beispiel: .\DeplOI.ps1 compare -Baseline extracts\A.db -Target extracts\B.db
  demo         Zwei Mock-Extrakte + Vergleich + Report (End-to-End-Test).
'@
    }
}
