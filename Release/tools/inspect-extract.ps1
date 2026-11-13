param([Parameter(Mandatory)][string]$BaselineDb, [Parameter(Mandatory)][string]$TargetDb)
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in @('DeplOI.Core', 'DeplOI.Store')) {
    Import-Module (Join-Path $root ('modules\' + $m + '.psm1')) -Force -DisableNameChecking
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$conn = Open-SqliteConnection -DatabasePath (Resolve-Path -LiteralPath $BaselineDb).Path
try {
    $escaped = (Resolve-Path -LiteralPath $TargetDb).Path.Replace("'", "''")
    Invoke-SqliteNonQuery -Connection $conn -Sql ("ATTACH DATABASE '" + $escaped + "' AS tgt;")
    $rows = Invoke-SqliteQuery -Connection $conn -Sql @'
SELECT
    CASE
        WHEN t.id IS NULL THEN 'removed'
        WHEN b.content_hash = t.content_hash THEN 'unchanged'
        ELSE 'changed'
    END AS status,
    COUNT(*) AS n
FROM objects b
LEFT JOIN tgt.objects t
    ON t.category = b.category AND t.name = b.name AND t.path = b.path
GROUP BY 1
UNION ALL
SELECT 'added', COUNT(*)
FROM tgt.objects t
LEFT JOIN objects b
    ON b.category = t.category AND b.name = b.name AND b.path = b.path
WHERE b.id IS NULL
'@
    Write-Host ('--- Objekt-Diff (SQL-aggregiert, {0:0.0}s):' -f $sw.Elapsed.TotalSeconds)
    foreach ($r in $rows) { Write-Host ('  {0} = {1}' -f $r.status, $r.n) }
    $contentRows = Invoke-SqliteScalar -Connection $conn -Sql 'SELECT COUNT(*) FROM objects WHERE content IS NOT NULL'
    Write-Host ('Objekte mit Content (Baseline): {0}' -f $contentRows)
}
finally {
    try { Invoke-SqliteNonQuery -Connection $conn -Sql 'DETACH DATABASE tgt;' } catch { }
    $conn.Dispose()
}
