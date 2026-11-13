# DeplOI.Report.psm1 - HTML-Report (eigenstaendig: CSS/JS eingebettet, keine externen Abhaengigkeiten).

function ConvertTo-HtmlEsc {
    param($Text)
    if ($null -eq $Text) { return '' }
    return ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-StatusChipHtml {
    param([Parameter(Mandatory)][string]$Status)
    $labels = @{ added = 'New'; removed = 'Deleted'; changed = 'Changed'; unchanged = 'Unchanged' }
    $label = $labels[$Status]
    if (-not $label) { $label = $Status }
    return ('<span class="chip {0}">{1}</span>' -f (ConvertTo-HtmlEsc $Status), $label)
}

function Get-CountCellHtml {
    param([int]$Count)
    if ($Count -eq 0) { return '<td class="zero">0</td>' }
    return ('<td>{0}</td>' -f $Count)
}

function Get-CategoryAnchor {
    param([string]$Category)
    return ($Category -replace '[^A-Za-z0-9]+', '-')
}

function Get-ValueHtml {
    # HTML-escapte Zellausgabe; ueberlange Werte werden fuer die Darstellung gekuerzt.
    # Vergleich/Status basiert unabhaengig davon immer auf dem vollen Wert.
    param($Value, [int]$MaxChars = 1500)
    $s = [string]$Value
    if ($s.Length -gt $MaxChars) {
        return ('{0} <span class="dim">...[truncated, {1} chars total]</span>' -f `
            (ConvertTo-HtmlEsc $s.Substring(0, $MaxChars)), $s.Length)
    }
    return (ConvertTo-HtmlEsc $s)
}

function New-MetaCardHtml {
    param([string]$Title, [hashtable]$Meta)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="card"><h3>')
    [void]$sb.Append((ConvertTo-HtmlEsc $Title))
    [void]$sb.Append('</h3><table class="meta">')
    foreach ($k in @($Meta.Keys | Sort-Object)) {
        [void]$sb.Append(('<tr><td class="mk">{0}</td><td>{1}</td></tr>' -f (ConvertTo-HtmlEsc $k), (ConvertTo-HtmlEsc $Meta[$k])))
    }
    [void]$sb.Append('</table></div>')
    return $sb.ToString()
}

function New-DashboardHtml {
    param($Comparison)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="panel"><h2>Overview</h2>')
    [void]$sb.Append('<table class="dashboard"><thead><tr><th>Category</th><th>New</th><th>Deleted</th><th>Changed</th><th>Unchanged</th><th>Total</th></tr></thead><tbody>')
    foreach ($cat in @($Comparison.Summary.Keys | Sort-Object)) {
        $c = $Comparison.Summary[$cat]
        $total = $c['added'] + $c['removed'] + $c['changed'] + $c['unchanged']
        [void]$sb.Append(('<tr><td><a href="#cat-{0}">{1}</a></td>{2}{3}{4}{5}<td>{6}</td></tr>' -f `
            (Get-CategoryAnchor $cat), (ConvertTo-HtmlEsc $cat), `
            (Get-CountCellHtml $c['added']), (Get-CountCellHtml $c['removed']), `
            (Get-CountCellHtml $c['changed']), (Get-CountCellHtml $c['unchanged']), $total))
    }
    $t = $Comparison.Total
    [void]$sb.Append('</tbody><tfoot><tr><td>Total</td>')
    [void]$sb.Append((Get-CountCellHtml $t['added']))
    [void]$sb.Append((Get-CountCellHtml $t['removed']))
    [void]$sb.Append((Get-CountCellHtml $t['changed']))
    [void]$sb.Append((Get-CountCellHtml $t['unchanged']))
    [void]$sb.Append(('<td>{0}</td></tr></tfoot></table></div>' -f $t['objects']))
    return $sb.ToString()
}

function New-NavHtml {
    param($Comparison)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="nav">')
    foreach ($cat in @($Comparison.Summary.Keys | Sort-Object)) {
        $c = $Comparison.Summary[$cat]
        $diffs = $c['added'] + $c['removed'] + $c['changed']
        [void]$sb.Append(('<a href="#cat-{0}">{1}&nbsp;<span class="cnt">{2}</span></a>' -f `
            (Get-CategoryAnchor $cat), (ConvertTo-HtmlEsc $cat), $diffs))
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function New-ContentDiffHtml {
    param([object[]]$Lines, [string]$Title = 'Content (Baseline vs Target)')
    $sb = New-Object System.Text.StringBuilder
    if ($Title) {
        [void]$sb.Append('<div class="contenthead">')
        [void]$sb.Append((ConvertTo-HtmlEsc $Title))
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append('<div class="content-diff">')
    $i = 0
    foreach ($l in $Lines) {
        $i++
        if ($i -gt 4000) {
            [void]$sb.Append('<div class="diff-cut">Content truncated (more than 4000 lines)</div>')
            break
        }
        $ln = ''
        if ($l.Ln -gt 0) { $ln = [string]$l.Ln }
        $rn = ''
        if ($l.Rn -gt 0) { $rn = [string]$l.Rn }
        $text = ConvertTo-HtmlEsc $l.Line
        if ($l.State -eq 'removed') {
            [void]$sb.Append(('<div class="diff-line removed"><span class="ln">{0}</span><pre class="line l">{1}</pre><span class="ln"></span><pre class="line r"></pre></div>' -f $ln, $text))
        }
        elseif ($l.State -eq 'added') {
            [void]$sb.Append(('<div class="diff-line added"><span class="ln"></span><pre class="line l"></pre><span class="ln">{0}</span><pre class="line r">{1}</pre></div>' -f $rn, $text))
        }
        else {
            [void]$sb.Append(('<div class="diff-line"><span class="ln">{0}</span><pre class="line l">{1}</pre><span class="ln">{2}</span><pre class="line r">{1}</pre></div>' -f $ln, $text, $rn))
        }
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function New-ObjectDetailHtml {
    param($Object, [int]$MaxValueChars = 1500, [int]$MaxDiffLines = 60)
    # Bei REST-Extrakten ist Path = display (lesbares Label), Name = stabler uri-Schluessel.
    # Der Report zeigt bevorzugt das lesbare Label.
    $mainLabel = [string]$Object.Name
    $subLabel = [string]$Object.Path
    if ($Object.Path) { $mainLabel = [string]$Object.Path; $subLabel = [string]$Object.Name }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<details class="obj" data-status="')
    [void]$sb.Append((ConvertTo-HtmlEsc $Object.Status))
    [void]$sb.Append('" data-search="')
    [void]$sb.Append((ConvertTo-HtmlEsc (('{0} {1} {2}' -f $Object.Name, $Object.Path, $Object.Category))))
    [void]$sb.Append('"><summary>')
    [void]$sb.Append((Get-StatusChipHtml $Object.Status))
    [void]$sb.Append('<span class="objname">')
    [void]$sb.Append((ConvertTo-HtmlEsc $mainLabel))
    [void]$sb.Append('</span>')
    if ($subLabel) {
        [void]$sb.Append(('<span class="path">{0}</span>' -f (ConvertTo-HtmlEsc $subLabel)))
    }
    [void]$sb.Append('</summary><div class="objbody">')

    $props = @($Object.PropertyDiffs)
    if ($props.Count -gt 0) {
        [void]$sb.Append('<table class="propdiff"><thead><tr><th>Attribute</th><th>Baseline</th><th>Target</th><th>Status</th></tr></thead><tbody>')
        foreach ($p in $props) {
            $rowClass = ''
            if ($p.status -eq 'unchanged') { $rowClass = ' class="dim"' }
            $oldVal = Get-ValueHtml -Value $p.vb -MaxChars $MaxValueChars
            $newVal = Get-ValueHtml -Value $p.vt -MaxChars $MaxValueChars
            if ($oldVal -eq '') { $oldVal = '<span class="dim">&ndash;</span>' }
            if ($newVal -eq '') { $newVal = '<span class="dim">&ndash;</span>' }
            [void]$sb.Append(('<tr{0}><td>{1}</td><td class="col-old">{2}</td><td class="col-new">{3}</td><td>{4}</td></tr>' -f `
                $rowClass, (ConvertTo-HtmlEsc $p.k), $oldVal, $newVal, (Get-StatusChipHtml $p.status)))

            # Geaenderte mehrzeilige Werte: zeilengenauer Diff (welche Zeilen dazu/weg).
            # Nur bis zu einer Zeilenzahlgrenze (report.maxLineDiffLines) - der LCS-Aufwand
            # waere bei grossen Werten in PS 5.1 unpraktikabel.
            if ($p.status -eq 'changed') {
                $sOld = [string]$p.vb
                $sNew = [string]$p.vt
                if ($sOld -match '\r|\n' -or $sNew -match '\r|\n') {
                    $l1 = @($sOld -split '\r?\n').Count
                    $l2 = @($sNew -split '\r?\n').Count
                    if (($l1 -le $MaxDiffLines) -and ($l2 -le $MaxDiffLines)) {
                        $lines = Get-ContentDiff -Left $sOld -Right $sNew
                        [void]$sb.Append(('<tr><td colspan="4" class="propdiff-detail">{0}</td></tr>' -f `
                            (New-ContentDiffHtml -Lines $lines -Title '')))
                    }
                }
            }
        }
        [void]$sb.Append('</tbody></table>')
    }

    $contentLines = @($Object.ContentDiff)
    if ($contentLines.Count -gt 0) {
        [void]$sb.Append((New-ContentDiffHtml -Lines $contentLines))
    }

    [void]$sb.Append('</div></details>')
    return $sb.ToString()
}

function New-CategorySectionHtml {
    # Schreibt den Abschnitt einer Kategorie direkt in den StreamWriter (kein Riesenstring im Speicher).
    param([string]$Category, $Objects, [Parameter(Mandatory)]$Writer, [int]$MaxValueChars = 1500, [int]$MaxDiffLines = 60)
    $order = @{ added = 0; removed = 1; changed = 2 }
    $diffObjs = @($Objects | Where-Object { $_.Status -ne 'unchanged' } | Sort-Object @{ Expression = { $order[$_.Status] } }, Name)
    $sameObjs = @($Objects | Where-Object { $_.Status -eq 'unchanged' } | Sort-Object Name)

    [void]$Writer.WriteLine(('<section class="cat" id="cat-{0}"><h2>{1}</h2>' -f (Get-CategoryAnchor $Category), (ConvertTo-HtmlEsc $Category)))
    if ($diffObjs.Count -eq 0) {
        [void]$Writer.WriteLine('<p class="dim">No differences in this category.</p>')
    }
    foreach ($o in $diffObjs) {
        [void]$Writer.WriteLine((New-ObjectDetailHtml -Object $o -MaxValueChars $MaxValueChars -MaxDiffLines $MaxDiffLines))
    }
    if ($sameObjs.Count -gt 0) {
        [void]$Writer.WriteLine(('<details class="obj" data-status="unchanged"><summary><span class="chip unchanged">Unchanged</span><span class="path">{0} unchanged objects</span></summary><ul class="samelist">' -f $sameObjs.Count))
        foreach ($o in $sameObjs) {
            [void]$Writer.WriteLine(('<li>{0}</li>' -f (ConvertTo-HtmlEsc $o.Name)))
        }
        [void]$Writer.WriteLine('</ul></details>')
    }
    [void]$Writer.WriteLine('</section>')
}

function New-CompareReport {
    <#
    .SYNOPSIS
    Erzeugt einen eigenstaendigen HTML-Report (eine Datei, eingebettetes CSS/JS).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)][string]$OutPath
    )
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $css = @'
:root { --added:#15803d; --removed:#b91c1c; --changed:#b45309; --muted:#6b7280; --border:#e5e7eb; }
* { box-sizing: border-box; }
body { margin:0; font-family:"Segoe UI",Arial,sans-serif; background:#f6f8fa; color:#111827; }
header { background:#0b2b4b; color:#fff; padding:18px 32px; }
header h1 { margin:0; font-size:20px; font-weight:600; }
header .sub { color:#b8c7d9; font-size:12px; margin-top:4px; }
main { max-width:1240px; margin:0 auto; padding:24px 32px 80px; }
.cards { display:flex; gap:16px; flex-wrap:wrap; margin:8px 0 20px; }
.card { background:#fff; border:1px solid var(--border); border-radius:8px; padding:12px 16px; flex:1; min-width:280px; }
.card h3 { margin:0 0 6px; font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
.card table.meta { font-size:12px; }
.card td { padding:2px 8px 2px 0; vertical-align:top; border:0; }
.card td.mk { color:var(--muted); white-space:nowrap; }
.panel { background:#fff; border:1px solid var(--border); border-radius:8px; padding:16px 20px; margin-bottom:24px; }
.panel h2 { margin:0 0 12px; font-size:16px; }
table.dashboard { border-collapse:collapse; width:100%; font-size:13px; }
table.dashboard th, table.dashboard td { padding:6px 10px; border-bottom:1px solid var(--border); text-align:right; }
table.dashboard th:first-child, table.dashboard td:first-child { text-align:left; }
table.dashboard tfoot td { font-weight:600; }
.dim { color:var(--muted); }
.zero { color:var(--muted); opacity:.45; }
.nav { display:flex; gap:8px; flex-wrap:wrap; margin:0 0 28px; }
.nav a { text-decoration:none; background:#fff; border:1px solid #d1d5db; border-radius:14px; padding:3px 12px; font-size:12px; color:#111827; }
.nav a:hover { border-color:#9ca3af; }
.nav .cnt { color:var(--muted); }
.filterrow { margin-bottom:12px; display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
.filterrow input { width:320px; padding:6px 10px; border:1px solid #d1d5db; border-radius:6px; font-size:13px; }
.statusfilter button { margin-right:6px; padding:4px 12px; border:1px solid #d1d5db; border-radius:14px; background:#fff; font-size:12px; color:#111827; cursor:pointer; }
.statusfilter button.active { background:#111827; color:#fff; border-color:#111827; }
section.cat { margin-bottom:36px; }
section.cat h2 { font-size:16px; border-bottom:2px solid var(--border); padding-bottom:6px; }
details.obj { background:#fff; border:1px solid var(--border); border-radius:8px; margin:10px 0; }
details.obj > summary { padding:10px 14px; cursor:pointer; display:flex; align-items:center; gap:10px; list-style:none; }
details.obj > summary::-webkit-details-marker { display:none; }
details.obj[open] > summary { border-bottom:1px solid var(--border); }
.objname { font-weight:600; font-family:Consolas,monospace; }
.path { color:var(--muted); font-size:12px; }
.objbody { padding:12px 16px; }
table.propdiff { border-collapse:collapse; width:100%; font-size:12px; margin-bottom:10px; }
table.propdiff th, table.propdiff td { border:1px solid var(--border); padding:4px 8px; text-align:left; vertical-align:top; word-break:break-word; }
table.propdiff th { background:#f3f4f6; }
td.propdiff-detail { border-top:0; padding:0; background:#fff; }
.col-old { background:#fef2f2; }
.col-new { background:#f0fdf4; }
tr.dim td { color:var(--muted); }
tr.dim .col-old, tr.dim .col-new { background:transparent; }
.chip { display:inline-block; padding:1px 9px; border-radius:10px; font-size:11px; font-weight:600; color:#fff; white-space:nowrap; }
.chip.added { background:var(--added); }
.chip.removed { background:var(--removed); }
.chip.changed { background:var(--changed); }
.chip.unchanged { background:var(--muted); }
.contenthead { font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:10px 0 4px; }
.content-diff { display:grid; grid-template-columns:44px 1fr 44px 1fr; font-family:Consolas,"Courier New",monospace; font-size:12px; border:1px solid var(--border); border-radius:6px; overflow:hidden; }
.diff-line { display:contents; }
.diff-line.removed .l { background:#fde8e8; }
.diff-line.added .r { background:#e6f4ea; }
.ln { color:var(--muted); text-align:right; padding:0 6px; user-select:none; background:#fafafa; font-size:11px; }
pre.line { margin:0; padding:0 8px; white-space:pre-wrap; word-break:break-word; }
.diff-cut { grid-column:1 / -1; padding:6px 10px; color:var(--muted); background:#fffbeb; }
.samelist { font-size:12px; margin:4px 0; padding-left:20px; }
footer { margin-top:40px; font-size:12px; }
'@

    $js = @'
var filterStatus = '';
function applyFilters() {
    var q = (document.getElementById('objfilter').value || '').toLowerCase();
    var items = document.querySelectorAll('details.obj');
    for (var i = 0; i < items.length; i++) {
        var hay = (items[i].getAttribute('data-search') || '').toLowerCase();
        var st = items[i].getAttribute('data-status') || '';
        var show = (!q || hay.indexOf(q) >= 0) && (!filterStatus || st === filterStatus);
        items[i].style.display = show ? '' : 'none';
    }
}
function filterObjects(el) { applyFilters(); }
function setStatusFilter(btn) {
    filterStatus = btn.getAttribute('data-status') || '';
    var btns = document.querySelectorAll('.statusfilter button');
    for (var i = 0; i < btns.length; i++) { btns[i].className = ''; }
    btn.className = 'active';
    applyFilters();
}
'@

    # Anzeigelimit fuer Attributwerte (config.json -> report.maxValueDisplayChars, Default 1500)
    # und Zeilenzahlgrenze fuer den zeilengenauen Attribut-Diff (report.maxLineDiffLines, Default 60)
    $maxValueChars = 1500
    $maxDiffLines = 60
    $config = Get-DeplOIConfig
    if ($config.PSObject.Properties['report'] -and $config.report) {
        if ($config.report.maxValueDisplayChars) { $maxValueChars = [int]$config.report.maxValueDisplayChars }
        if ($config.report.maxLineDiffLines) { $maxDiffLines = [int]$config.report.maxLineDiffLines }
    }

    # Statuslogging: Mengengeruest des Reports
    $t = $Comparison.Total
    $totalObjects = $t['objects']
    $catCount = @($Comparison.Summary.Keys).Count
    Write-Log ('Report: {0} Objekte in {1} Kategorien (Neu: {2} | Entfernt: {3} | Geaendert: {4} | Unveraendert: {5})' -f `
        $totalObjects, $catCount, $t['added'], $t['removed'], $t['changed'], $t['unchanged'])

    # Objekte EINMAL nach Kategorien gruppieren (statt je Kategorie die Gesamtliste zu filtern)
    $swGroup = [System.Diagnostics.Stopwatch]::StartNew()
    $objectsByCategory = @{}
    foreach ($o in $Comparison.Objects) {
        $cat = [string]$o.Category
        if (-not $objectsByCategory.ContainsKey($cat)) {
            $objectsByCategory[$cat] = New-Object System.Collections.Generic.List[object]
        }
        $objectsByCategory[$cat].Add($o)
    }
    Write-Log ('Report: Objekte nach Kategorien gruppiert ({0:0.0}s)' -f $swGroup.Elapsed.TotalSeconds)

    # Direktes Schreiben per StreamWriter (kein Riesenstring im Speicher)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($OutPath, $false, $utf8)
    $loopSw = [System.Diagnostics.Stopwatch]::StartNew()
    $rendered = 0
    $nextLogSec = 15.0
    try {
        [void]$writer.WriteLine('<!DOCTYPE html>')
        [void]$writer.WriteLine('<html lang="en">')
        [void]$writer.WriteLine('<head>')
        [void]$writer.WriteLine('<meta charset="utf-8">')
        [void]$writer.WriteLine('<title>DeplOI Portable &ndash; System comparison</title>')
        [void]$writer.WriteLine('<style>')
        [void]$writer.WriteLine($css)
        [void]$writer.WriteLine('</style>')
        [void]$writer.WriteLine('</head>')
        [void]$writer.WriteLine('<body>')
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
        [void]$writer.WriteLine('<header><h1>DeplOI Portable &ndash; System comparison</h1><div class="sub">Created on ' + $now + '</div></header>')
        [void]$writer.WriteLine('<main>')
        [void]$writer.WriteLine('<div class="cards">')
        [void]$writer.WriteLine((New-MetaCardHtml -Title 'Baseline' -Meta $Comparison.BaselineMeta))
        [void]$writer.WriteLine((New-MetaCardHtml -Title 'Target' -Meta $Comparison.TargetMeta))
        [void]$writer.WriteLine('</div>')
        [void]$writer.WriteLine((New-DashboardHtml -Comparison $Comparison))
        [void]$writer.WriteLine((New-NavHtml -Comparison $Comparison))
        [void]$writer.WriteLine('<div class="filterrow"><input id="objfilter" type="text" placeholder="Filter objects (name, category) ..." onkeyup="filterObjects(this)"><div class="statusfilter"><button class="active" data-status="" onclick="setStatusFilter(this)">All</button><button data-status="added" onclick="setStatusFilter(this)">New</button><button data-status="removed" onclick="setStatusFilter(this)">Deleted</button><button data-status="changed" onclick="setStatusFilter(this)">Changed</button></div></div>')

        $cats = @($Comparison.Summary.Keys | Sort-Object)
        for ($ci = 0; $ci -lt $cats.Count; $ci++) {
            $cat = [string]$cats[$ci]
            # Achtung PS 5.1: @() direkt auf List[object] wirft ArgumentException -
            # [object[]]-Cast oder ToArray() verwenden.
            $objs = [object[]]$objectsByCategory[$cat]
            New-CategorySectionHtml -Category $cat -Objects $objs -Writer $writer -MaxValueChars $maxValueChars -MaxDiffLines $maxDiffLines
            $rendered += $objs.Count

            # Fortschritt mit Restdauer-Schaetzung (alle 15s)
            if ($totalObjects -gt 0 -and $loopSw.Elapsed.TotalSeconds -ge $nextLogSec) {
                $elapsed = $loopSw.Elapsed.TotalSeconds
                $rate = $rendered / $elapsed
                $eta = 0.0
                if ($rate -gt 0) { $eta = ($totalObjects - $rendered) / $rate }
                $sizeMB = 0.0
                try { $sizeMB = (Get-Item -LiteralPath $OutPath).Length / 1MB } catch { }
                Write-Log ('Report: Kategorie {0}/{1} | {2}/{3} Objekte ({4:P1}) | Verstrichen: {5:mm\:ss} | Geschaetzte Restdauer: {6:mm\:ss} | {7:0.0} MB geschrieben' -f `
                    ($ci + 1), $cats.Count, $rendered, $totalObjects, ($rendered / [double]$totalObjects),
                    $loopSw.Elapsed, [System.TimeSpan]::FromSeconds($eta), $sizeMB)
                $nextLogSec = $elapsed + 15.0
            }
        }

        [void]$writer.WriteLine(('<footer class="dim">Created with DeplOI Portable v{0}</footer>' -f (Get-DeplOIToolVersion)))
        [void]$writer.WriteLine('</main>')
        [void]$writer.WriteLine('<script>')
        [void]$writer.WriteLine($js)
        [void]$writer.WriteLine('</script>')
        [void]$writer.WriteLine('</body>')
        [void]$writer.WriteLine('</html>')
    }
    finally {
        $writer.Dispose()
    }

    $sizeMB = 0.0
    try { $sizeMB = (Get-Item -LiteralPath $OutPath).Length / 1MB } catch { }
    Write-Log ('Report abgeschlossen: {0} Objekte in {1:mm\:ss} | Datei: {2} ({3:0.0} MB)' -f `
        $rendered, $loopSw.Elapsed, $OutPath, $sizeMB)
    return $OutPath
}
