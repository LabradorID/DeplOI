param([string]$DbFile = '9.3Local.db', [int]$ScriptId = 1, [int]$ConfigId = 1)
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\DeplOI.Core.psm1') -Force
Import-Module (Join-Path $root 'modules\DeplOI.Store.psm1') -Force
$db = Join-Path (Join-Path $root 'extracts') $DbFile
$conn = Open-SqliteConnection -DatabasePath $db
try {
    $samples = @(
        @{ Label = "SKRIPT (category=script)"; Sql = "SELECT id, category, name, path, content, content_hash FROM objects WHERE category = 'script' ORDER BY id LIMIT 1" },
        @{ Label = "KONFIGURATIONSPARAMETER (category=config.parameter)"; Sql = "SELECT id, category, name, path, content, content_hash FROM objects WHERE category = 'config.parameter' AND path LIKE '%Password%' ORDER BY id LIMIT 1" }
    )
    foreach ($s in $samples) {
        $o = Invoke-SqliteQuery -Connection $conn -Sql $s.Sql
        if ($o.Count -eq 0) { Write-Host ("--- {0}: kein Datensatz gefunden" -f $s.Label); continue }
        $o = $o[0]
        Write-Host ('=============================== {0}' -f $s.Label)
        Write-Host ('objects-Zeile:')
        Write-Host ('  id           = {0}' -f $o.id)
        Write-Host ('  category     = {0}' -f $o.category)
        Write-Host ('  name         = {0}' -f $o.name)
        Write-Host ('  path         = {0}' -f $o.path)
        $content = [string]$o.content
        if ($content.Length -gt 300) { $content = $content.Substring(0, 300) + ('... [{0} Zeichen gesamt]' -f ([string]$o.content).Length) }
        Write-Host ('  content      = {0}' -f $(if ($content) { $content } else { '(leer)' }))
        Write-Host ('  content_hash = {0}' -f $o.content_hash)
        $props = Invoke-SqliteQuery -Connection $conn -Sql 'SELECT "key", "value" FROM properties WHERE object_id = @id ORDER BY "key"' -Parameters @{ id = [long]$o.id }
        Write-Host ('  properties ({0}):' -f $props.Count)
        foreach ($p in $props) {
            $v = [string]$p.'value'
            if ($v.Length -gt 90) { $v = $v.Substring(0, 90) + ('... [{0} Z.]' -f ([string]$p.'value').Length) }
            Write-Host ('    {0} = {1}' -f $p.'key', $v)
        }
        Write-Host ''
    }
}
finally { $conn.Dispose() }
