# DeplOI.Connector.psm1 - REST-Anbindung an den One Identity App Server (Identity Manager 9.x/10.x).
#
# Grundlage: Harvester/DeplOIBase.psm1 (erprobter erster Versuch):
#   - Anmeldung:  POST {BaseUrl}/auth/apphost  mit {"authString": "Module=DialogUser;User=...;Password=..."}
#     bzw. interaktiv via OAuth2 (Modul PSAuthClient). Die Session laeuft ueber die
#     Cookies der WebRequestSession.
#   - Entities:   GET {BaseUrl}/api/entities/{Entity}?where=...&loadType=...&offset=...&limit=...
#   - Paging:     offset/limit bis eine Seite unvollstaendig zurueckkommt.
#
# Alle REST-Aufrufe laufen ausschliesslich ueber dieses Modul (Invoke-ImWebRequest,
# Get-ImEntities); die restlichen Module bleiben transportunabhaengig.

function Get-RestConfig {
    # Einstellungen aus config.json (rest) mit Defaults.
    $config = Get-DeplOIConfig
    $pageSize = 500
    $timeoutSec = 60
    $maxRetries = 5
    $trustAll = $false
    if ($config.PSObject.Properties['rest'] -and $config.rest) {
        if ($config.rest.pageSize) { $pageSize = [int]$config.rest.pageSize }
        if ($config.rest.timeoutSec) { $timeoutSec = [int]$config.rest.timeoutSec }
        if ($config.rest.maxRetries) { $maxRetries = [int]$config.rest.maxRetries }
        if ($config.rest.trustAllCertificates) { $trustAll = [bool]$config.rest.trustAllCertificates }
    }
    return @{
        pageSize          = $pageSize
        timeoutSec        = $timeoutSec
        maxRetries        = $maxRetries
        trustAll          = $trustAll
    }
}

function Connect-ImSession {
    <#
    .SYNOPSIS
    Meldet sich am App Server an und liefert die Session (WebRequestSession mit Cookies).
    .NOTES
    TODO (VERIFY, IM 9.x/10.x): exakte Antwort der Auth-Endpunkts gegen das Zielsystem pruefen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [string]$User = '',
        [string]$Password = '',
        [ValidateSet('DialogUser', 'OAuth', 'OAuthRoleBased')][string]$AuthenticationType = 'DialogUser',
        [string]$ClientID = '',
        [string]$ClientSecret = '',
        [string]$TokenURL = '',
        [string]$Scope = 'openid',
        [string]$RedirectURL = '',
        [string]$OAuthResponseType = 'code'
    )
    $rest = Get-RestConfig

    # TLS 1.2 erzwingen (PS 5.1 Default reicht nicht immer).
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    if ($rest.trustAll) {
        Write-Log 'TLS-Zertifikatspruefung deaktiviert (config.json: rest.trustAllCertificates).' -Level Warn
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    $base = $BaseUrl.TrimEnd('/')
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    switch ($AuthenticationType) {
        'DialogUser' {
            $authString = ('Module=DialogUser;User={0};Password={1}' -f $User, $Password)
        }
        { $_ -in @('OAuth', 'OAuthRoleBased') } {
            if (-not (Get-Module -ListAvailable -Name PSAuthClient)) {
                throw 'PSAuthClient-Modul ist nicht verfuegbar: interaktiver OAuth-Login nicht moeglich.'
            }
            $OAuthParam = @{
                response_type = $OAuthResponseType
                uri           = $TokenURL
                client_id     = $ClientID
                scope         = $Scope
                redirect_uri  = $RedirectURL
                usePkce       = $false
            }


            $signin = Invoke-OAuth2AuthorizationEndpoint @OAuthParam
            $authString = ('Module={0};Code={1};AppUrl={2};ClientId={3};Nonce={4};RedirectUri={5}' -f `
                $AuthenticationType, $signin.code, $base, $signin.client_id, $signin.nonce, $signin.redirect_uri)
        }
        default {
            throw "AuthenticationType '$AuthenticationType' wird nicht unterstuetzt."
        }
    }

    $authUrl = '{0}/auth/apphost' -f $base
    $body = @{ authString = $authString } | ConvertTo-Json -Depth 2
    $attempt = 0
    while ($true) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $authUrl -Body $body -ContentType 'application/json; charset=UTF-8' -WebSession $webSession -UseBasicParsing -TimeoutSec $rest.timeoutSec
            break
        }
        catch {
            $attempt++
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            # 5xx: App Server moeglicherweise gerade im Neustart (z.B. HTTP 500.30 beim Kaltstart des Pools)
            if ($status -ge 500 -and $attempt -lt 3) {
                Write-Log ('Anmeldung: HTTP {0} - App Server moeglicherweise im Neustart, neuer Versuch in 20s ({1}/3)' -f $status, $attempt) -Level Warn
                Start-Sleep -Seconds 20
                continue
            }
            $detail = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = (' Detail: {0}' -f $_.ErrorDetails.Message) }
            $msg = ('Anmeldung am App Server fehlgeschlagen: {0}.{1}' -f $_.Exception.Message, $detail) +
                ' BaseUrl/Authentifizierung pruefen (siehe DeplOI.Connector.psm1).'
            throw $msg
        }
    }

    Write-Log ('Angemeldet an {0} (User: {1})' -f $base, $(if ($User) { $User } else { '(OAuth)' }))

    return [pscustomobject]@{
        BaseUrl    = $base
        WebSession = $webSession
        User       = $User
        IsMock     = $false
    }
}

function Disconnect-ImSession {
    [CmdletBinding()]
    param($ImSession)
    if (-not $ImSession) { return }
    $ImSession.WebSession = $null
}

function Invoke-ImWebRequest {
    <#
    .SYNOPSIS
    Wrapper fuer Invoke-WebRequest: Fehlerbehandlung mit Retry auf HTTP 429,
    UTF-8-Dekodierung der Antwort (aus Harvester/DeplOIBase.psm1 uebernommen).
    .OUTPUTS
    Antwort als String (UTF-8-dekodiert).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImSession,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Put', 'Delete')][string]$Method = 'Get',
        [string]$Body
    )
    $rest = Get-RestConfig
    $attempt = 0
    while ($true) {
        try {
            $params = @{
                Uri        = $Uri
                Method     = $Method
                WebSession = $ImSession.WebSession
                UseBasicParsing = $true
                TimeoutSec = $rest.timeoutSec
            }
            if ($Body) {
                $params['Body'] = $Body
                $params['ContentType'] = 'application/json; charset=UTF-8'
            }
            $response = Invoke-WebRequest @params
            break
        }
        catch {
            $attempt++
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            # Retry bei Rate-Limit (429) und bei 5xx (App Server evtl. im Neustart, z.B. 500.30 beim Kaltstart)
            $retryable = ($status -eq 429) -or ($status -ge 500)
            if ($retryable -and $attempt -lt $rest.maxRetries) {
                $wait = 0
                if ($status -eq 429) { $wait = Get-Random -Minimum 5 -Maximum 15 }
                else { $wait = Get-Random -Minimum 15 -Maximum 30 }
                Write-Log ('HTTP {0} - warte {1}s (Versuch {2}/{3})' -f $status, $wait, $attempt, $rest.maxRetries) -Level Warn
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = (' Detail: {0}' -f $_.ErrorDetails.Message) }
            $msg = ("REST-Aufruf fehlgeschlagen (HTTP {0}): {1}.{2}" -f $status, $_.Exception.Message, $detail) +
                (" Uri: {0}" -f $Uri)
            throw $msg
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
}

function Get-ImEntities {
    <#
    .SYNOPSIS
    Liest Entities einer Tabelle ueber die REST-API mit Paging (offset/limit).
    .OUTPUTS
    Array von Entity-Objekten (uri, display, values).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImSession,
        [Parameter(Mandatory)][string]$Entity,
        [string]$Where = '',
        [string]$LoadType = 'BulkReadOnly',
        [int]$PageSize = 0,
        [int]$Maximum = 0
    )
    $rest = Get-RestConfig
    if ($PageSize -le 0) { $PageSize = $rest.pageSize }
    if ($Maximum -gt 0 -and $PageSize -gt $Maximum) { $PageSize = $Maximum }

    $url = '{0}/api/entities/{1}' -f $ImSession.BaseUrl, $Entity
    if ($Where) {
        $url = '{0}?where={1}' -f $url, [uri]::EscapeDataString($Where)
        $url = '{0}&loadType={1}' -f $url, $LoadType
    }
    else {
        $url = '{0}?loadType={1}' -f $url, $LoadType
    }

    $startIndex = 0
    $all = New-Object System.Collections.Generic.List[object]
    $keys = New-Object 'System.Collections.Generic.HashSet[string]'
    $dropped = 0
    while ($true) {
        $pageUrl = '{0}&offset={1}&limit={2}' -f $url, $startIndex, $PageSize
        $raw = Invoke-ImWebRequest -ImSession $ImSession -Uri $pageUrl
        # PS 5.1: ConvertFrom-Json rollt ein JSON-Array nicht aus - das Array kommt
        # als EIN Objekt durch. Explizit entpacken, sonst entsteht ein verschachteltes Array.
        $page = @($raw | ConvertFrom-Json)
        if ($page.Count -eq 1 -and $page[0] -is [object[]]) { $page = @($page[0]) }
        $fetchedCount = $page.Count
        # Ungueltige Eintraege herausfiltern (null / ohne uri / ohne values)
        $page = @($page | Where-Object { $_ -and $_.uri -and $_.values })
        $dropped += ($fetchedCount - $page.Count)
        foreach ($o in $page) {
            $key = [string]$o.uri
            # Duplikate vermeiden (Objekt waehrend des Lesevorgangs verschoben)
            if (-not $keys.Contains($key)) {
                [void]$keys.Add($key)   # HashSet.Add liefert $true - [void] verhindert Pipeline-Pollution!
                [void]$all.Add($o)
            }
        }
        $startIndex += $fetchedCount
        if ($fetchedCount -lt $PageSize) { break }
        if ($Maximum -gt 0 -and $all.Count -ge $Maximum) { break }
    }
    if ($dropped -gt 0) {
        Write-Log ('{0}: {1} ungueltige Entities herausgefiltert' -f $Entity, $dropped) -Level Warn
    }
    return ,$all.ToArray()
}

function Get-ImDatabaseId {
    <#
    .SYNOPSIS
    Liest die UID der verbundenen Datenbank (Entity DialogDatabase).
    Primaerspalte ist UID_DialogDatabase; aeltere/abweichende API-Antworten
    liefern UID_Database; letzter Fallback ist die GUID aus der uri.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ImSession)
    $entities = Get-ImEntities -ImSession $ImSession -Entity 'DialogDatabase' -LoadType 'Default'
    if ($entities.Count -eq 0) { throw 'DialogDatabase konnte nicht gelesen werden (keine Entities zurueckgegeben).' }
    $first = $entities[0]
    $dbId = $null
    if ($first.values) {
        foreach ($prop in @('UID_DialogDatabase', 'UID_Database')) {
            if ($first.values.PSObject.Properties[$prop]) {
                $dbId = [string]$first.values.$prop
                if ($dbId) { break }
            }
        }
    }
    if (-not $dbId) {
        # Fallback: Primaerschluessel-GUID aus der uri des Entity
        if ([string]$first.uri -match '/([^/]+)$') { $dbId = $Matches[1] }
    }
    if (-not $dbId) { throw 'UID_DialogDatabase konnte aus DialogDatabase nicht ermittelt werden.' }
    return $dbId
}

function Get-ImEncryptedColumns {
    <#
    .SYNOPSIS
    Ermittelt alle verschluesselten Spalten (DialogColumn mit isCrypted=1) und liefert
    eine Hashtabelle "TabellenName.SpaltenName" -> $true (aus Harvester/Set-CacheEncryptedColumns).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ImSession)
    $tables = Get-ImEntities -ImSession $ImSession -Entity 'DialogTable' -LoadType 'Default'
    $tableNames = @{}
    foreach ($t in $tables) {
        $uid = [string]$t.values.UID_DialogTable
        $name = [string]$t.values.TableName
        if ($uid -and $name -and -not $tableNames.ContainsKey($uid)) { $tableNames[$uid] = $name }
    }

    $encrypted = @{}
    $cols = Get-ImEntities -ImSession $ImSession -Entity 'DialogColumn' -Where 'isCrypted=1' -LoadType 'Default'
    foreach ($c in $cols) {
        $tname = $tableNames[[string]$c.values.UID_DialogTable]
        $cname = [string]$c.values.ColumnName
        if ($tname -and $cname) {
            $encrypted[('{0}.{1}' -f $tname, $cname)] = $true
        }
    }
    return $encrypted
}

function Get-ImQbmConfigTables {
    <#
    .SYNOPSIS
    Ermittelt die QBM-Konfigurationstabellen dynamisch aus DialogTable
    (aus Harvester/Get-QBMTables). Liefert die DialogTable-Entities.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImSession,
        [string]$Where = '',
        [string[]]$ExcludeTables = @()
    )
    if (-not $Where) {
        # Standard: Konfigurationstabellen plus ausgewaehlte QBM-Sondertabellen
        $Where = "UID_DialogTable LIKE 'QBM-T-%' AND TableType='T'" +
            " AND (UsageType = 'CONFIGURATION' OR TableName IN (" +
            "'QBMFileHasDeployTarget','QBMGroupHasLimitedSQL','QBMLimitedSQL','QBMLock'," +
            "'QBMModuleDependCollection','QBMPwdPolicy','QBMServerHasDeployTarget'))"
    }
    $tables = Get-ImEntities -ImSession $ImSession -Entity 'DialogTable' -Where $Where -LoadType 'Default'
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tables) {
        $name = [string]$t.values.TableName
        if ($ExcludeTables -and $ExcludeTables -contains $name) { continue }
        $result.Add($t)
    }
    return ,$result.ToArray()
}
