# DeplOI.Extract.psm1 - Extraktion ueber die REST-API und Schreiben in die Extrakt-DB.
#
# Ansatz aus Harvester uebernommen:
#   - Objekt-Identitaet: uri des Entity (stabil), display als lesbares Label
#   - Hash: kanonisierte Werte ohne X*-Audit-Spalten (XDateInserted/XDateUpdated/XUserInserted/XUserUpdated)
#   - Verschluesselte Spalten (DialogColumn.isCrypted=1 bzw. DialogConfigParm.isCrypted):
#     Wert wird gehasht, nicht im Klartext gespeichert

function Get-ExtractorDefinition {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-DeplOIRoot) 'extractors.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Extractor-Definition fehlt: $Path"
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Get-ValueHash {
    # SHA256 (Hex, Grossbuchstaben) eines Einzelwerts - fuer verschluesselte Spaltenwerte.
    param($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function ConvertTo-CanonicalValue {
    # Strings bleiben Strings, komplexe Werte werden kanonisch als JSON abgelegt,
    # damit SQLite-Speicherung und Hashbildung deterministisch sind.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    return ($Value | ConvertTo-Json -Depth 5 -Compress)
}

function ConvertTo-ExtractRecord {
    <#
    .SYNOPSIS
    Bildet ein REST-Entity (uri/display/values) auf einen Store-Record ab.
    Name = stabler Schluessel aus der uri, Path = display (Lesbarkeit im Report).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entity,
        [Parameter(Mandatory)][string]$Category,
        [string]$NameColumn = 'uri',
        [string]$ContentColumn = '',
        [Parameter(Mandatory)][string]$TableName,
        [hashtable]$EncryptedColumns = @{},
        [string[]]$ExcludeColumns = @()
    )
    # Name: konfigurierte Spalte, sonst uri ("Tabelle/UID")
    $name = ''
    if ($NameColumn -and $NameColumn -ine 'uri') {
        if ($Entity.values.PSObject.Properties[$NameColumn]) {
            $name = [string]$Entity.values.$NameColumn
        }
    }
    if (-not $name) {
        $uri = [string]$Entity.uri
        if ($uri -match '/api/entity/(.+)$') { $name = $Matches[1] }
        else { $name = $uri }
    }

    $display = ''
    if ($Entity.PSObject.Properties['display']) { $display = [string]$Entity.display }

    $content = $null
    if ($ContentColumn -and $Entity.values.PSObject.Properties[$ContentColumn]) {
        $content = [string]$Entity.values.$ContentColumn
        # Ist die Content-Spalte verschluelt, wird auch der Content nur als Hash gespeichert
        # (Spaltenmarkierung via DialogColumn.isCrypted oder Objektmarkierung bei DialogConfigParm).
        if ($content) {
            $contentIsEncrypted = $false
            if ($EncryptedColumns -and $EncryptedColumns.ContainsKey(('{0}.{1}' -f $TableName, $ContentColumn))) {
                $contentIsEncrypted = $true
            }
            if ($TableName -ieq 'DialogConfigParm' -and $ContentColumn -ieq 'Value') {
                if ($Entity.values.PSObject.Properties['isCrypted']) {
                    if ([bool]$Entity.values.isCrypted) { $contentIsEncrypted = $true }
                }
            }
            if ($contentIsEncrypted) {
                $content = Get-ValueHash -Value $content
            }
        }
    }

    $props = [ordered]@{}
    foreach ($p in @($Entity.values.PSObject.Properties)) {
        $k = $p.Name
        if ($ExcludeColumns -contains $k) { continue }
        if ($ContentColumn -and $k -ieq $ContentColumn) { continue }
        $v = ConvertTo-CanonicalValue -Value $p.Value
        if ($EncryptedColumns -and $EncryptedColumns.ContainsKey(('{0}.{1}' -f $TableName, $k))) {
            $v = Get-ValueHash -Value $v
        }
        $props[$k] = $v
    }
    if ($display) { $props['display'] = $display }

    # Sonderfall aus Harvester/Set-HashEncryptedColumns:
    # DialogConfigParm kennzeichnet Verschluesselung am Objekt, nicht an der Spalte.
    if ($TableName -ieq 'DialogConfigParm') {
        $isCrypted = $false
        if ($Entity.values.PSObject.Properties['isCrypted']) { $isCrypted = [bool]$Entity.values.isCrypted }
        if ($isCrypted -and $props.Contains('Value')) {
            $props['Value'] = Get-ValueHash -Value $props['Value']
        }
    }

    return [pscustomobject]@{
        Category  = $Category
        Name      = $name
        Path      = $display
        Properties = $props
        Content   = $content
    }
}

function Invoke-TableExtractor {
    <#
    .SYNOPSIS
    Liest eine Systemtabelle ueber die REST-API und liefert Records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImSession,
        [Parameter(Mandatory)]$Definition,
        [string[]]$ExcludeColumns = @(),
        [hashtable]$EncryptedColumns = @{}
    )
    $loadType = 'BulkReadOnly'
    if ($Definition.loadType) { $loadType = [string]$Definition.loadType }
    $where = ''
    if ($Definition.where) { $where = [string]$Definition.where }
    $nameColumn = 'uri'
    if ($Definition.nameColumn) { $nameColumn = [string]$Definition.nameColumn }
    $contentColumn = ''
    if ($Definition.contentColumn) { $contentColumn = [string]$Definition.contentColumn }
    $category = [string]$Definition.category
    $table = [string]$Definition.table

    $entities = Get-ImEntities -ImSession $ImSession -Entity $table -Where $where -LoadType $loadType

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entities) {
        $records.Add((ConvertTo-ExtractRecord -Entity $e -Category $category -NameColumn $nameColumn -ContentColumn $contentColumn -TableName $table -EncryptedColumns $EncryptedColumns -ExcludeColumns $ExcludeColumns))
    }
    return ,$records.ToArray()
}

function Invoke-Extraction {
    <#
    .SYNOPSIS
    Fuehrt eine vollstaendige Extraktion durch und schreibt alles in eine neue Extrakt-DB.
    Reihenfolge: UID_Database -> verschluesselte Spalten -> dynamische QBM-Konfigurationstabellen
    -> statisch definierte Kategorien (extractors.json).
    .PARAMETER Mock
    Mock-Daten statt echter Session (fuer Demo/Test der Pipeline ohne laufenden IM).
    #>
    [CmdletBinding()]
    param(
        $ImSession,
        [Parameter(Mandatory)][string]$OutDb,
        [string]$SystemName = '',
        [int]$Variant = 1,
        [switch]$Mock,
        [switch]$SkipDynamic,
        [switch]$SkipStatic,
        [string[]]$Tables = @()
    )
    if (Test-Path -LiteralPath $OutDb) {
        throw "Ziel-DB existiert bereits: $OutDb (loeschen oder anderen Namen waehlen)."
    }
    # -File-Aufrufe geben Komma-Listen als EINEN String weiter: normalisieren.
    if ($Tables.Count -eq 1 -and $Tables[0] -like '*,*') {
        $Tables = @(($Tables[0] -split ',\s*') | Where-Object { $_ })
    }

    Write-Log ('Initialisiere Extrakt-DB: {0}' -f $OutDb)
    $conn = Initialize-ExtractStore -Path $OutDb
    try {
        $meta = [ordered]@{}
        $meta['system']       = $SystemName
        $meta['mode']         = 'mock'
        $meta['database']     = ('mock_v{0}' -f $Variant)
        $meta['created_at']   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $meta['tool_version'] = Get-DeplOIToolVersion
        $meta['connection']   = ''

        if (-not $Mock) {
            if (-not $ImSession) { throw 'Keine IM-Session uebergeben.' }
            $databaseId = Get-ImDatabaseId -ImSession $ImSession
            Write-Log ('Datenbank (UID_Database): {0}' -f $databaseId)
            $meta['mode']     = 'rest'
            $meta['database'] = $databaseId
            $meta['connection'] = ('{0} (User: {1})' -f $ImSession.BaseUrl, $ImSession.User)
        }
        Set-StoreMeta -Connection $conn -Values $meta

        if ($Mock) {
            $records = Invoke-MockExtraction -Variant $Variant
            Write-Log ('Mock-Extraktion: {0} Objekte (Variante {1})' -f $records.Count, $Variant)
            Write-ExtractRecords -Connection $conn -Records $records
        }
        else {
            $definitions = Get-ExtractorDefinition
            $globalExclude = @()
            if ($definitions.excludeColumns) { $globalExclude = @($definitions.excludeColumns) }
            # Fehler je Tabelle protokollieren und mit den restlichen Tabellen fortfahren
            $failures = New-Object System.Collections.Generic.List[string]

            # Verschluesselte Spalten ermitteln (Werte werden nur gehasht gespeichert)
            $encrypted = Get-ImEncryptedColumns -ImSession $ImSession
            Write-Log ('{0} verschluesselte Spalten ermittelt' -f $encrypted.Count)

            # Dynamischer Harvest der QBM-Konfigurationstabellen (Harvester-Ansatz)
            if (-not $SkipDynamic -and $definitions.dynamic -and $definitions.dynamic.enabled) {
                $dynWhere = ''
                if ($definitions.dynamic.where) { $dynWhere = [string]$definitions.dynamic.where }
                $dynExclude = @()
                if ($definitions.dynamic.excludeTables) { $dynExclude = @($definitions.dynamic.excludeTables) }
                $prefix = 'qbm.'
                if ($definitions.dynamic.categoryPrefix) { $prefix = [string]$definitions.dynamic.categoryPrefix }

                $qbmTables = Get-ImQbmConfigTables -ImSession $ImSession -Where $dynWhere -ExcludeTables $dynExclude
                Write-Log ('{0} QBM-Konfigurationstabellen ermittelt' -f $qbmTables.Count)
                foreach ($t in $qbmTables) {
                    $tname = [string]$t.values.TableName
                    if (-not $tname) {
                        # Kein Tabellenname -> Entity verwerfen (duerfte nicht vorkommen)
                        Write-Log ('QBM-Tabelle ohne TableName uebersprungen (uri: {0})' -f $t.uri) -Level Warn
                        continue
                    }
                    Write-Log ("Extrahiere Tabelle '{0}' ..." -f $tname)
                    try {
                        $records = Invoke-TableExtractor -ImSession $ImSession -ExcludeColumns $globalExclude -EncryptedColumns $encrypted -Definition @{
                            table    = $tname
                            category = ('{0}{1}' -f $prefix, $tname)
                            loadType = 'BulkReadOnly'
                        }
                        Write-Log ('  {0} Objekte' -f $records.Count)
                        Write-ExtractRecords -Connection $conn -Records $records
                    }
                    catch {
                        $failures.Add($tname)
                        Write-Log ("Tabelle '{0}' fehlgeschlagen: {1}" -f $tname, $_.Exception.Message) -Level Error
                    }
                }
            }

            # Statisch definierte Kategorien (optional nach Tabelle gefiltert)
            if (-not $SkipStatic) {
                foreach ($def in @($definitions.extractors)) {
                    if ($Tables.Count -gt 0 -and $Tables -notcontains [string]$def.table) { continue }
                    Write-Log ('Extrahiere "{0}" (Tabelle {1}) ...' -f $def.category, $def.table)
                    try {
                        $records = Invoke-TableExtractor -ImSession $ImSession -Definition $def -ExcludeColumns $globalExclude -EncryptedColumns $encrypted
                        Write-Log ('  {0} Objekte' -f $records.Count)
                        Write-ExtractRecords -Connection $conn -Records $records
                    }
                    catch {
                        $failures.Add([string]$def.table)
                        Write-Log ("Tabelle '{0}' fehlgeschlagen: {1}" -f $def.table, $_.Exception.Message) -Level Error
                    }
                }
            }

            if ($failures.Count -gt 0) {
                $msg = ('{0} Tabelle(n) fehlgeschlagen: {1}. Extrakt ist unvollstaendig!' -f $failures.Count, ($failures -join ', '))
                Write-Log $msg -Level Error
                throw $msg
            }
        }
    }
    finally {
        $conn.Dispose()
    }
    return $OutDb
}

function Invoke-MockExtraction {
    # Deterministische Testdaten in zwei Varianten; ermoeglicht einen end-to-end-Test
    # der Pipeline (Extrakt -> Vergleich -> Report) ohne laufenden Identity Manager.
    # Erwartung v1 -> v2: 2 neu, 2 entfernt, 4 geaendert, 3 unveraendert.
    param([int]$Variant = 1)
    $records = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Category, [string]$Name, [hashtable]$Props, [string]$Content)
        $records.Add([pscustomobject]@{
            Category = $Category; Name = $Name; Path = ''
            Properties = $Props; Content = $Content
        })
    }

    $loginScript = @'
Public Sub Login()
    ' Standard-Login fuer Portalbenutzer
    Dim user = Context.CurrentUser
    Log.Write("Login: " & user.DisplayName)
End Sub
'@
    $logoutScript = @'
Public Sub Logout()
    Session.Abandon()
    Log.Write("Logout")
End Sub
'@
    $orgChartV1 = @'
Public Sub BuildOrgChart()
    Dim root As Person = Person.Get("HEAD")
    For Each child In root.DirectReports
        Chart.AddNode(child)
    Next
End Sub
'@
    $orgChartV2 = @'
Public Sub BuildOrgChart()
    Dim root As Person = Person.Get("HEAD")
    For Each child In root.DirectReports
        Chart.AddNode(child, includePhotos)
    Next
    Chart.Refresh()
End Sub
'@
    $budgetScript = @'
public decimal CalcBudget(int year) {
    return Repository.Budgets.Sum(year);
}
'@
    $resetScript = @'
public void ResetCache() {
    Cache.Clear();
}
'@

    & $add 'script' 'Common_Login' @{ ScriptLanguage = 'VB.NET'; Description = 'Login-Handling' } $loginScript
    if ($Variant -eq 1) {
        & $add 'script' 'Common_Logout' @{ ScriptLanguage = 'VB.NET'; Description = 'Logout-Handling' } $logoutScript
    }
    $orgChart = $orgChartV1
    if ($Variant -eq 2) { $orgChart = $orgChartV2 }
    & $add 'script' 'HR_BuildOrgChart' @{ ScriptLanguage = 'VB.NET'; Description = 'Orgchart-Aufbau' } $orgChart
    $budgetDesc = 'Budget'
    if ($Variant -eq 2) { $budgetDesc = 'Quartalsbudget' }
    & $add 'script' 'Fin_CalcBudget' @{ ScriptLanguage = 'C#'; Description = $budgetDesc } $budgetScript
    if ($Variant -eq 2) {
        & $add 'script' 'IT_ResetCache' @{ ScriptLanguage = 'C#'; Description = 'Cache-Reset' } $resetScript
    }

    & $add 'process' 'P_OnStart' @{ Description = 'Startprozess'; Queue = 'QBMQueue'; RunsSingle = 'True' } $null
    $procQueue = 'QBMQueue'
    if ($Variant -eq 2) { $procQueue = 'QBMQueueSecondary' }
    # Mehrzeiliges Attribut fuer die Demo des zeilengenauen Attribut-Diffs
    $procDef = @'
Start()
    Load queue
    Notify owner
End()
'@
    if ($Variant -eq 2) {
        $procDef = @'
Start()
    Load queue
    Retry on error
    Notify owner
End()
'@
    }
    & $add 'process' 'P_OnPersonInserted' @{ Description = 'Person angelegt'; Queue = $procQueue; Definition = $procDef } $null

    & $add 'config.parameter' 'cfg.portal.url' @{ Value = 'https://portal.example.com'; Type = 'String' } $null
    $logLevel = 'Debug'
    if ($Variant -eq 2) { $logLevel = 'Info' }
    & $add 'config.parameter' 'cfg.log.level' @{ Value = $logLevel; Type = 'String' } $null
    if ($Variant -eq 1) {
        & $add 'config.parameter' 'cfg.legacy.mode' @{ Value = 'True'; Type = 'Bool' } $null
    }
    if ($Variant -eq 2) {
        & $add 'config.parameter' 'cfg.session.timeout' @{ Value = '120'; Type = 'Int' } $null
    }

    return ,$records.ToArray()
}
