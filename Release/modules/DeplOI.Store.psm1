# DeplOI.Store.psm1 - SQLite-Persistenz der Extrakte (portabel, System.Data.SQLite aus bin/).

$script:SchemaVersion = '1'

$script:SchemaSql = @'
CREATE TABLE IF NOT EXISTS schema_info (
    "key"   TEXT PRIMARY KEY,
    "value" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
    "key"   TEXT PRIMARY KEY,
    "value" TEXT
);
CREATE TABLE IF NOT EXISTS objects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    category     TEXT NOT NULL,
    name         TEXT NOT NULL,
    path         TEXT NOT NULL DEFAULT '',
    content      TEXT,
    content_hash TEXT NOT NULL,
    UNIQUE (category, path, name)
);
CREATE TABLE IF NOT EXISTS properties (
    object_id INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    "key"     TEXT NOT NULL,
    "value"   TEXT,
    PRIMARY KEY (object_id, "key")
);
CREATE INDEX IF NOT EXISTS ix_objects_cat ON objects(category, name);
'@

function Import-SqliteAssembly {
    [CmdletBinding()]
    param()
    $loaded = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'System.Data.SQLite' }
    if ($loaded) { return }

    $config = Get-DeplOIConfig
    $relPath = $config.sqlite.assemblyRelativePath
    if (-not $relPath) { $relPath = 'bin/System.Data.SQLite.dll' }
    $full = Join-Path (Get-DeplOIRoot) $relPath
    if (-not (Test-Path -LiteralPath $full)) {
        $msg = ("System.Data.SQLite nicht gefunden: '{0}'. " -f $full) +
            "Bitte zuerst 'tools\install-sqlite.ps1' ausfuehren."
        throw $msg
    }
    Add-Type -Path $full -ErrorAction Stop
}

function Open-SqliteConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)
    Import-SqliteAssembly
    $builder = New-Object System.Data.SQLite.SQLiteConnectionStringBuilder
    $builder['Data Source'] = $DatabasePath
    $builder['Version'] = '3'
    $builder['Foreign Keys'] = 'True'
    $conn = New-Object System.Data.SQLite.SQLiteConnection($builder.ConnectionString)
    $conn.Open()
    return $conn
}

function Add-SqliteParameters {
    param($Command, [System.Collections.IDictionary]$Parameters)
    foreach ($key in @($Parameters.Keys)) {
        $p = $Command.CreateParameter()
        $p.ParameterName = ('@' + $key)
        $v = $Parameters[$key]
        if ($null -eq $v) { $p.Value = [DBNull]::Value } else { $p.Value = $v }
        [void]$Command.Parameters.Add($p)
    }
}

function Invoke-SqliteNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [System.Collections.IDictionary]$Parameters
    )
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = $Sql
        if ($Parameters) { Add-SqliteParameters -Command $cmd -Parameters $Parameters }
        [void]$cmd.ExecuteNonQuery()
    }
    finally { $cmd.Dispose() }
}

function Invoke-SqliteScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [System.Collections.IDictionary]$Parameters
    )
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = $Sql
        if ($Parameters) { Add-SqliteParameters -Command $cmd -Parameters $Parameters }
        $v = $cmd.ExecuteScalar()
        if ($v -is [DBNull]) { return $null }
        return $v
    }
    finally { $cmd.Dispose() }
}

function Invoke-SqliteQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [System.Collections.IDictionary]$Parameters
    )
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandText = $Sql
        if ($Parameters) { Add-SqliteParameters -Command $cmd -Parameters $Parameters }
        $rows = New-Object System.Collections.Generic.List[object]
        $reader = $cmd.ExecuteReader()
        try {
            do {
                while ($reader.Read()) {
                    $o = [ordered]@{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        if ($reader.IsDBNull($i)) { $o[$reader.GetName($i)] = $null }
                        else { $o[$reader.GetName($i)] = $reader.GetValue($i) }
                    }
                    $rows.Add([pscustomobject]$o)
                }
            } while ($reader.NextResult())
        }
        finally { $reader.Dispose() }
        return ,$rows.ToArray()
    }
    finally { $cmd.Dispose() }
}

function Initialize-ExtractStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $conn = Open-SqliteConnection -DatabasePath $Path
    Invoke-SqliteNonQuery -Connection $conn -Sql $script:SchemaSql
    $rows = Invoke-SqliteQuery -Connection $conn -Sql 'SELECT "value" AS v FROM schema_info WHERE "key" = @k' -Parameters @{ k = 'schema_version' }
    if ($rows.Count -eq 0) {
        Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO schema_info ("key", "value") VALUES (@k, @v)' -Parameters @{ k = 'schema_version'; v = $script:SchemaVersion }
    }
    elseif ([string]$rows[0].v -ne $script:SchemaVersion) {
        $conn.Dispose()
        throw ("Extrakt-DB '{0}' hat Schema-Version '{1}', erwartet wird '{2}'." -f $Path, $rows[0].v, $script:SchemaVersion)
    }
    return $conn
}

function Get-CanonicalHash {
    # Deterministischer Hash ueber die kanonisierten Properties + Inhalt.
    # Sortierung der Schluessel garantiert stabile Hashes unabhaengig von der Einfuegereihenfolge.
    [CmdletBinding()]
    param([hashtable]$Properties, [string]$Content)
    $sep1 = [char]1; $sep2 = [char]2; $sep3 = [char]3
    $h = @{}
    if ($null -ne $Properties) { $h = $Properties }
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in @($h.Keys | Sort-Object)) {
        [void]$sb.Append([string]$k).Append($sep1).Append([string]$h[$k]).Append($sep2)
    }
    if ($Content) { [void]$sb.Append($sep3).Append($Content) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Write-ExtractRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )
    if ($Records.Count -eq 0) { return }
    $tx = $Connection.BeginTransaction()
    $cmdObj = $Connection.CreateCommand()
    $cmdId = $Connection.CreateCommand()
    $cmdProp = $Connection.CreateCommand()
    $cmdObj.Transaction = $tx
    $cmdId.Transaction = $tx
    $cmdProp.Transaction = $tx
    # Parameter einmalig anlegen und im Loop nur die Werte setzen (Performance bei grossen Extraktionen)
    foreach ($n in @('category', 'name', 'path', 'content', 'hash')) {
        [void]$cmdObj.Parameters.Add($cmdObj.CreateParameter())
        $cmdObj.Parameters[($cmdObj.Parameters.Count - 1)].ParameterName = ('@' + $n)
    }
    foreach ($n in @('oid', 'key', 'value')) {
        [void]$cmdProp.Parameters.Add($cmdProp.CreateParameter())
        $cmdProp.Parameters[($cmdProp.Parameters.Count - 1)].ParameterName = ('@' + $n)
    }
    try {
        $cmdObj.CommandText = 'INSERT INTO objects (category, name, path, content, content_hash) VALUES (@category, @name, @path, @content, @hash)'
        $cmdId.CommandText = 'SELECT last_insert_rowid()'
        $cmdProp.CommandText = 'INSERT INTO properties (object_id, "key", "value") VALUES (@oid, @key, @value)'
        foreach ($r in $Records) {
            $path = ''
            if ($r.Path) { $path = [string]$r.Path }
            $props = @{}
            if ($null -ne $r.Properties) { $props = $r.Properties }
            $hash = Get-CanonicalHash -Properties $props -Content ([string]$r.Content)
            $cmdObj.Parameters['@category'].Value = [string]$r.Category
            $cmdObj.Parameters['@name'].Value = [string]$r.Name
            $cmdObj.Parameters['@path'].Value = $path
            if ($null -ne $r.Content) { $cmdObj.Parameters['@content'].Value = [string]$r.Content }
            else { $cmdObj.Parameters['@content'].Value = [DBNull]::Value }
            $cmdObj.Parameters['@hash'].Value = $hash
            [void]$cmdObj.ExecuteNonQuery()
            $oid = [long]$cmdId.ExecuteScalar()
            foreach ($k in @($props.Keys)) {
                $v = $props[$k]
                $cmdProp.Parameters['@oid'].Value = $oid
                $cmdProp.Parameters['@key'].Value = [string]$k
                if ($null -ne $v) { $cmdProp.Parameters['@value'].Value = [string]$v }
                else { $cmdProp.Parameters['@value'].Value = [DBNull]::Value }
                [void]$cmdProp.ExecuteNonQuery()
            }
        }
        $tx.Commit()
    }
    catch {
        $tx.Rollback()
        throw
    }
    finally {
        $cmdObj.Dispose(); $cmdId.Dispose(); $cmdProp.Dispose()
    }
}

function Set-StoreMeta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    foreach ($k in @($Values.Keys)) {
        Invoke-SqliteNonQuery -Connection $Connection -Sql 'INSERT OR REPLACE INTO meta ("key", "value") VALUES (@k, @v)' -Parameters @{
            k = [string]$k
            v = [string]$Values[$k]
        }
    }
}

function Get-StoreMeta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [string]$TableExpr = 'meta'
    )
    $rows = Invoke-SqliteQuery -Connection $Connection -Sql ('SELECT "key" AS k, "value" AS v FROM ' + $TableExpr)
    $h = @{}
    foreach ($row in $rows) { $h[[string]$row.k] = $row.v }
    return $h
}
