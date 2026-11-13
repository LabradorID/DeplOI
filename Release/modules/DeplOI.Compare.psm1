# DeplOI.Compare.psm1 - Vergleich zweier Extrakt-DBs.
# Der Diff laeuft SQL-seitig (ATTACH + Join) und laedt nicht alles nach PowerShell.

$script:ObjectsDiffSql = @'
SELECT
    COALESCE(b.category, t.category) AS category,
    COALESCE(b.name, t.name)         AS name,
    COALESCE(b.path, t.path)         AS path,
    CASE
        WHEN t.id IS NULL THEN 'removed'
        WHEN b.content_hash = t.content_hash THEN 'unchanged'
        ELSE 'changed'
    END AS status,
    b.id AS id_b,
    t.id AS id_t
FROM objects b
LEFT JOIN tgt.objects t
    ON t.category = b.category
   AND t.name = b.name
   AND t.path = b.path
UNION ALL
SELECT
    t.category,
    t.name,
    t.path,
    'added',
    NULL,
    t.id
FROM tgt.objects t
LEFT JOIN objects b
    ON b.category = t.category
   AND b.name = t.name
   AND b.path = t.path
WHERE b.id IS NULL
ORDER BY 1, 2
'@

$script:PropertyDiffSql = @'
SELECT
    COALESCE(b."key", t."key") AS k,
    b."value" AS vb,
    t."value" AS vt,
    CASE
        WHEN b."key" IS NULL THEN 'added'
        WHEN t."key" IS NULL THEN 'removed'
        WHEN b."value" IS NOT t."value" THEN 'changed'
        ELSE 'unchanged'
    END AS status
FROM properties b
LEFT JOIN tgt.properties t
    ON t.object_id = @idT
   AND t."key" = b."key"
WHERE b.object_id = @idB
UNION ALL
SELECT
    t."key",
    NULL,
    t."value",
    'added'
FROM tgt.properties t
LEFT JOIN properties b
    ON b.object_id = @idB
   AND b."key" = t."key"
WHERE t.object_id = @idT
  AND b."key" IS NULL
ORDER BY 1
'@

function Get-ContentDiff {
    <#
    .SYNOPSIS
    Zeilenweiser LCS-Diff zweier Inhalte; Ergebnis: Liste von
    (Line, State=same|removed|added, Ln, Rn) fuer die side-by-side-Darstellung.
    #>
    [CmdletBinding()]
    param([string]$Left, [string]$Right)
    $l = @()
    $r = @()
    if ($Left)  { $l = @($Left -split "`r?`n") }
    if ($Right) { $r = @($Right -split "`r?`n") }
    if ($l.Count -eq 1 -and $l[0] -eq '') { $l = @() }
    if ($r.Count -eq 1 -and $r[0] -eq '') { $r = @() }
    $n = $l.Count
    $m = $r.Count
    if ($n -eq 0 -and $m -eq 0) { return ,@() }

    $result = New-Object System.Collections.Generic.List[object]

    # Fallback fuer sehr grosse Inhalte: keine Feinaufloesung.
    if ((($n + 1) * ($m + 1)) -gt 4000000) {
        foreach ($line in $l) {
            $result.Add([pscustomobject]@{ Line = $line; State = 'removed'; Ln = 0; Rn = 0 })
        }
        foreach ($line in $r) {
            $result.Add([pscustomobject]@{ Line = $line; State = 'added'; Ln = 0; Rn = 0 })
        }
        return ,$result.ToArray()
    }

    $dp = New-Object 'int[,]' -ArgumentList (($n + 1), ($m + 1))
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($l[$i] -ceq $r[$j]) {
                $dp[$i, $j] = $dp[($i + 1), ($j + 1)] + 1
            }
            else {
                $down = $dp[($i + 1), $j]
                $right2 = $dp[$i, ($j + 1)]
                if ($down -ge $right2) { $dp[$i, $j] = $down } else { $dp[$i, $j] = $right2 }
            }
        }
    }

    $i = 0; $j = 0; $ln = 1; $rn = 1
    while ($i -lt $n -and $j -lt $m) {
        if ($l[$i] -ceq $r[$j]) {
            $result.Add([pscustomobject]@{ Line = $l[$i]; State = 'same'; Ln = $ln; Rn = $rn })
            $i++; $j++; $ln++; $rn++
        }
        elseif ($dp[($i + 1), $j] -ge $dp[$i, ($j + 1)]) {
            $result.Add([pscustomobject]@{ Line = $l[$i]; State = 'removed'; Ln = $ln; Rn = 0 })
            $i++; $ln++
        }
        else {
            $result.Add([pscustomobject]@{ Line = $r[$j]; State = 'added'; Ln = 0; Rn = $rn })
            $j++; $rn++
        }
    }
    while ($i -lt $n) {
        $result.Add([pscustomobject]@{ Line = $l[$i]; State = 'removed'; Ln = $ln; Rn = 0 })
        $i++; $ln++
    }
    while ($j -lt $m) {
        $result.Add([pscustomobject]@{ Line = $r[$j]; State = 'added'; Ln = 0; Rn = $rn })
        $j++; $rn++
    }
    return ,$result.ToArray()
}

function Compare-Extracts {
    <#
    .SYNOPSIS
    Vergleicht zwei Extrakt-DBs (Baseline vs. Ziel) und liefert Status,
    Property-Diffs je geaendertem Objekt und eine Zusammenfassung je Kategorie.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineDb,
        [Parameter(Mandatory)][string]$TargetDb
    )
    if (-not (Test-Path -LiteralPath $BaselineDb)) { throw "Baseline-Extrakt nicht gefunden: $BaselineDb" }
    if (-not (Test-Path -LiteralPath $TargetDb)) { throw "Ziel-Extrakt nicht gefunden: $TargetDb" }
    $resolvedB = (Resolve-Path -LiteralPath $BaselineDb).Path
    $resolvedT = (Resolve-Path -LiteralPath $TargetDb).Path
    if ($resolvedB -ieq $resolvedT) { throw 'Baseline und Ziel sind identisch.' }

    $conn = Open-SqliteConnection -DatabasePath $resolvedB
    try {
        $escaped = $resolvedT.Replace("'", "''")
        Invoke-SqliteNonQuery -Connection $conn -Sql ("ATTACH DATABASE '" + $escaped + "' AS tgt;")

        $baselineMeta = Get-StoreMeta -Connection $conn
        $targetMeta = Get-StoreMeta -Connection $conn -TableExpr 'tgt.meta'

        # Statuslogging: Mengengeruest beider Extrakte anzeigen
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cntB = [long](Invoke-SqliteScalar -Connection $conn -Sql 'SELECT COUNT(*) FROM objects')
        $propB = [long](Invoke-SqliteScalar -Connection $conn -Sql 'SELECT COUNT(*) FROM properties')
        $cntT = [long](Invoke-SqliteScalar -Connection $conn -Sql 'SELECT COUNT(*) FROM tgt.objects')
        $propT = [long](Invoke-SqliteScalar -Connection $conn -Sql 'SELECT COUNT(*) FROM tgt.properties')
        Write-Log ('Vergleich: Baseline {0} Objekte / {1} Properties vs. Ziel {2} Objekte / {3} Properties' -f `
            $cntB, $propB, $cntT, $propT)

        Write-Log 'Ermittle Objekt-Differenzen (SQL-seitig) ...'
        $rows = Invoke-SqliteQuery -Connection $conn -Sql $script:ObjectsDiffSql
        $totalRows = $rows.Count
        Write-Log ('{0} Objektpaare ermittelt (SQL-Phase: {1:0.0}s) - Detailanalyse folgt' -f `
            $totalRows, $sw.Elapsed.TotalSeconds)

        $resultObjects = New-Object System.Collections.Generic.List[object]
        $summary = [ordered]@{}
        $total = @{ added = 0; removed = 0; changed = 0; unchanged = 0; objects = 0 }

        $loopSw = [System.Diagnostics.Stopwatch]::StartNew()
        $processed = 0
        $nextLogSec = 15.0
        foreach ($row in $rows) {
            if (-not $summary.Contains($row.category)) {
                $summary[$row.category] = @{ added = 0; removed = 0; changed = 0; unchanged = 0 }
            }
            $summary[$row.category][$row.status]++
            $total[$row.status]++
            $total['objects']++

            $idB = $row.id_b
            $idT = $row.id_t
            if ($idB -is [DBNull]) { $idB = $null }
            if ($idT -is [DBNull]) { $idT = $null }

            $propDiffs = @()
            $contentDiff = @()
            if ($row.status -eq 'changed') {
                # Bei geaenderten Objekten nur die geaenderten Attribute (plus display) anzeigen
                $allProps = Invoke-SqliteQuery -Connection $conn -Sql $script:PropertyDiffSql -Parameters @{
                    idB = [long]$idB
                    idT = [long]$idT
                }
                $propDiffs = @($allProps | Where-Object { $_.status -ne 'unchanged' -or $_.k -ieq 'display' })
                $contentB = Invoke-SqliteScalar -Connection $conn -Sql 'SELECT content FROM objects WHERE id = @id' -Parameters @{ id = [long]$idB }
                $contentT = Invoke-SqliteScalar -Connection $conn -Sql 'SELECT content FROM tgt.objects WHERE id = @id' -Parameters @{ id = [long]$idT }
                if ($null -ne $contentB -or $null -ne $contentT) {
                    # Get-ContentDiff liefert das Array als einzelnes Objekt (Komma-Trick);
                    # keine zusaetzliche @()-Verpackung, sonst entsteht ein verschachteltes Array.
                    $contentDiff = Get-ContentDiff -Left ([string]$contentB) -Right ([string]$contentT)
                }
            }
            elseif ($row.status -eq 'added') {
                # Neue Objekte: alle Attribute der Ziel-Seite anzeigen
                $rows = Invoke-SqliteQuery -Connection $conn -Sql 'SELECT "key" AS k, "value" AS v FROM tgt.properties WHERE object_id = @id' -Parameters @{ id = [long]$idT }
                $list = New-Object System.Collections.Generic.List[object]
                foreach ($r in $rows) {
                    $list.Add([pscustomobject]@{ k = [string]$r.k; vb = $null; vt = $r.v; status = 'added' })
                }
                $propDiffs = $list.ToArray()
                $contentT = Invoke-SqliteScalar -Connection $conn -Sql 'SELECT content FROM tgt.objects WHERE id = @id' -Parameters @{ id = [long]$idT }
                if ($null -ne $contentT) {
                    $contentDiff = Get-ContentDiff -Left '' -Right ([string]$contentT)
                }
            }
            elseif ($row.status -eq 'removed') {
                # Geloeschte Objekte: alle Attribute der Baseline-Seite anzeigen
                $rows = Invoke-SqliteQuery -Connection $conn -Sql 'SELECT "key" AS k, "value" AS v FROM properties WHERE object_id = @id' -Parameters @{ id = [long]$idB }
                $list = New-Object System.Collections.Generic.List[object]
                foreach ($r in $rows) {
                    $list.Add([pscustomobject]@{ k = [string]$r.k; vb = $r.v; vt = $null; status = 'removed' })
                }
                $propDiffs = $list.ToArray()
                $contentB = Invoke-SqliteScalar -Connection $conn -Sql 'SELECT content FROM objects WHERE id = @id' -Parameters @{ id = [long]$idB }
                if ($null -ne $contentB) {
                    $contentDiff = Get-ContentDiff -Left ([string]$contentB) -Right ''
                }
            }

            $resultObjects.Add([pscustomobject]@{
                Category      = $row.category
                Name          = $row.name
                Path          = $row.path
                Status        = $row.status
                PropertyDiffs = $propDiffs
                ContentDiff   = $contentDiff
            })

            # Fortschritt mit Restdauer-Schaetzung (alle 15s)
            $processed++
            if ($totalRows -gt 0 -and $loopSw.Elapsed.TotalSeconds -ge $nextLogSec) {
                $elapsed = $loopSw.Elapsed.TotalSeconds
                $rate = $processed / $elapsed
                $eta = 0.0
                if ($rate -gt 0) { $eta = ($totalRows - $processed) / $rate }
                Write-Log ('Vergleich: {0}/{1} ({2:P1}) | Geaendert bisher: {3} | Verstrichen: {4:mm\:ss} | Geschaetzte Restdauer: {5:mm\:ss}' -f `
                    $processed, $totalRows, ($processed / [double]$totalRows), $total['changed'],
                    $loopSw.Elapsed, [System.TimeSpan]::FromSeconds($eta))
                $nextLogSec = $elapsed + 15.0
            }
        }

        Write-Log ('Vergleich abgeschlossen: {0} Objekte in {1:mm\:ss} | Neu: {2} | Entfernt: {3} | Geaendert: {4} | Unveraendert: {5}' -f `
            $totalRows, $loopSw.Elapsed, $total['added'], $total['removed'], $total['changed'], $total['unchanged'])

        return [pscustomobject]@{
            BaselineDb   = $resolvedB
            TargetDb     = $resolvedT
            BaselineMeta = $baselineMeta
            TargetMeta   = $targetMeta
            Summary      = $summary
            Total        = $total
            Objects      = $resultObjects
        }
    }
    finally {
        try { Invoke-SqliteNonQuery -Connection $conn -Sql 'DETACH DATABASE tgt;' } catch { }
        $conn.Dispose()
    }
}
