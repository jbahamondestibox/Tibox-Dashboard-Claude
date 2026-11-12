# Genera el informe en PDF: arma un HTML autocontenido (gráficos en SVG, sin internet)
# y lo imprime con Microsoft Edge en modo headless, que viene instalado en Windows.

$script:Col = @{ blue = '#2a78d6'; orange = '#eb6834'; aqua = '#1baf7a'; yellow = '#eda100'; magenta = '#e87ba4'; violet = '#6250d6'; gray = '#b4b2a9' }
$script:Series = @('#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#6250d6')
$script:Dollar = [char]36

function Esc($s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Money($v) {
  if ($null -eq $v) { return '—' }
  $n = if ($v -ge 100) { F0 $v } else { F1 $v }
  return 'US' + $script:Dollar + $n
}
function Pct($p) { if ($p -lt 1) { return '&lt;1%' } else { return (F0 ([math]::Round($p))) + '%' } }
function FechaLarga($d) { return ([DateTime]::Parse($d)).ToString('d MMM yyyy', $script:CI) }
function Num($x) { return ([double]$x).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }

# Nombres cortos para las categorías del costo
function ShortCat([string]$name) {
  $n = $name.Replace('Herramienta: Read', 'Archivos leídos').Replace('Generación de Claude', 'Respuestas generadas')
  $n = $n.Replace('Código escrito por Claude (Write/Edit)', 'Código escrito').Replace('Respuestas de Claude (texto)', 'Texto de Claude')
  $n = $n -replace '^Herramienta: (Bash|PowerShell)$', 'Comandos' -replace '^Herramienta: (Grep|Glob)$', 'Búsquedas' -replace '^Herramienta: ', ''
  return $n.Replace('Subagentes (trabajo interno)', 'Subagentes')
}

function StackedBar($categories) {
  $m = [ordered]@{}
  foreach ($c in $categories) { $k = ShortCat $c.name; if ($m.Contains($k)) { $m[$k] += $c.pct } else { $m[$k] = $c.pct } }
  $all = @($m.Keys | ForEach-Object { @{ name = $_; pct = $m[$_] } } | Sort-Object -Property @{ Expression = { $_.pct }; Descending = $true })
  $segs = @($all | Select-Object -First 5)
  $rest = 0.0; foreach ($x in ($all | Select-Object -Skip 5)) { $rest += $x.pct }
  if ($rest -gt 0.5) { $segs += @{ name = 'Otros'; pct = $rest; other = $true } }
  $total = 0.0; foreach ($s in $segs) { $total += $s.pct }; if (-not $total) { $total = 1 }
  $bar = ''; $lg = ''
  for ($i = 0; $i -lt $segs.Count; $i++) {
    $color = if ($segs[$i].other) { $script:Col.gray } else { $script:Series[$i] }
    $bar += "<div style=`"width:$(Num ($segs[$i].pct / $total * 100))%;background:$color`"></div>"
    $lg += "<span><i style=`"background:$color`"></i>$(Esc $segs[$i].name) <b>$(Pct $segs[$i].pct)</b></span>"
  }
  return "<div class=`"stack`">$bar</div><div class=`"legend`">$lg</div>"
}

# Barras verticales en SVG (consumo diario, actividad por hora)
function Columns($values, $labels, [string]$color, [scriptblock]$fmt, [int]$every = 1, [int]$h = 120) {
  $w = 440; $n = [math]::Max(1, $values.Count)
  $max = 0.0; foreach ($v in $values) { if ($v -gt $max) { $max = $v } }; if (-not $max) { $max = 1 }
  $pad = 18; $step = $w / $n; $bw = [math]::Min(16, $step * 0.7)
  $s = "<svg viewBox=`"0 0 $w $($h + $pad)`" width=`"100%`" height=`"$($h + $pad)`" preserveAspectRatio=`"none`">"
  $s += "<line x1=`"0`" x2=`"$w`" y1=`"$h`" y2=`"$h`" stroke=`"#c3c2b7`" stroke-width=`"1`"/>"
  $iMax = 0
  for ($i = 0; $i -lt $values.Count; $i++) {
    $v = [double]$values[$i]; if ($v -eq $max) { $iMax = $i }
    $bh = ($v / $max) * ($h - 14); $x = $i * $step + ($step - $bw) / 2; $y = $h - $bh
    if ($v -gt 0) { $s += "<rect x=`"$(Num $x)`" y=`"$(Num $y)`" width=`"$(Num $bw)`" height=`"$(Num $bh)`" rx=`"2`" fill=`"$color`"/>" }
    if ($i % $every -eq 0) { $s += "<text x=`"$(Num ($i * $step + $step / 2))`" y=`"$($h + 13)`" font-size=`"8`" text-anchor=`"middle`" fill=`"#898781`">$(Esc $labels[$i])</text>" }
  }
  $s += "<text x=`"$(Num ($iMax * $step + $step / 2))`" y=`"11`" font-size=`"8.5`" text-anchor=`"middle`" fill=`"#52514e`">$(Esc (& $fmt $max))</text>"
  return $s + '</svg>'
}

# Barras horizontales con valor (modelos, proyectos, skills, MCP)
function HBars($rows, [string]$color, [scriptblock]$value) {
  $rows = @($rows)
  if (-not $rows.Count) { return '<p class="muted">Sin datos en el período.</p>' }
  if (-not $value) { $value = { param($r) Pct $r.pct } }
  $max = 1.0; foreach ($r in $rows) { if ($r.pct -gt $max) { $max = $r.pct } }
  $out = '<div class="hbars">'
  foreach ($r in $rows) {
    $out += "<div class=`"hb`"><span class=`"hb-l`">$(Esc $r.name)</span><span class=`"hb-t`"><span style=`"width:$(Num ($r.pct / $max * 100))%;background:$color`"></span></span><span class=`"hb-v`">$(& $value $r)</span></div>"
  }
  return $out + '</div>'
}

function Kpi($label, $value, $sub) { return "<div class=`"kpi`"><p class=`"kl`">$(Esc $label)</p><p class=`"kv`">$(Esc $value)</p><p class=`"ks`">$(Esc $sub)</p></div>" }

$script:Sev = @{ alta = @('#fcebeb', '#a32d2d'); media = @('#faeeda', '#854f0b'); baja = @('#eef0f3', '#52514e') }
function Pill($sev) { return "<span class=`"pill`" style=`"background:$($script:Sev[$sev][0]);color:$($script:Sev[$sev][1])`">$sev</span>" }
function Impact($f, [string]$style = '') {
  if ($null -ne $f.impactUsd -and $f.impactUsd -gt 0.05) { return "<span class=`"imp`" $style>$(Money $f.impactUsd) · $(Pct $f.pct)</span>" }
  return ''
}

$script:ModeNames = @{ default = 'Apruebas cada acción'; acceptEdits = 'Ediciones automáticas'; auto = 'Modo automático'; plan = 'Modo plan'; bypassPermissions = 'Sin permisos' }

# Lectura del perfil: frases cortas según los datos, cada una con su sugerencia.
function ProfileInsights($r) {
  $p = $r.profile; $T = $r.totals
  $out = New-Object System.Collections.Generic.List[object]
  $maxH = ($p.hours | Measure-Object -Maximum).Maximum
  if ($maxH -gt 0) {
    $peak = [array]::IndexOf($p.hours, [double]$maxH)
    $out.Add(@("Tu hora de más actividad es entre las ${peak}:00 y las $($peak + 1):00.", 'Si haces pausas largas en medio de una sesión grande, al volver abre una sesión nueva con un resumen: la caché vence a la hora.'))
  }
  $sug = if ($T.avgContext -gt 100000) { "Tu contexto promedio es de $(Tok $T.avgContext) tokens: separar tareas en sesiones distintas es la mejora más directa." } else { 'Mantienes sesiones de tamaño razonable.' }
  $out.Add(@("Una sesión típica tuya tiene $(F0 $p.medianPrompts) mensajes y $(F0 $p.medianCalls) llamadas al modelo, y cuesta $(Money $p.medianUsd).", $sug))
  $manual = $p.permissionModes | Where-Object { $_.name -eq 'default' } | Select-Object -First 1
  if ($manual -and $manual.pct -ge 40) {
    $out.Add(@("En el $(Pct $manual.pct) de tus mensajes apruebas cada acción a mano.", 'Para tareas que ya entiendes, activar ediciones automáticas (Shift+Tab) te ahorra interrupciones sin perder control: igual revisas el resultado.'))
  } elseif (@($p.permissionModes).Count) {
    $mp = if ($manual) { $manual.pct } else { 0 }
    $out.Add(@("Delegas bastante: en el $(Pct (100 - $mp)) de tus mensajes Claude edita sin pedir permiso.", 'Para cambios grandes, el modo plan (Shift+Tab) te deja revisar el enfoque antes de que toque código.'))
  }
  if ($p.highEffortPct -ge 20) { $out.Add(@("El $(Pct $p.highEffortPct) de tus llamadas usa esfuerzo xhigh o max.", 'Deja medium o high por defecto y sube solo para problemas difíciles.')) }
  $opus = $r.byModel | Where-Object { $_.model -match '(?i)opus' } | Select-Object -First 1
  if ($opus -and $opus.pct -gt 70) { $out.Add(@("El $(Pct $opus.pct) de tu consumo es con Opus.", 'Para preguntas y cambios chicos, Sonnet responde igual de bien y más rápido.')) }
  return , $out
}

function FindingBlock($f) {
  $ev = ''
  foreach ($e in @($f.evidence | Select-Object -First 4)) { $ev += "<tr><td><b>$(Esc $e.label)</b><br><span class=`"muted`">$(Esc $e.detail)</span></td><td class=`"num`">$(Esc $e.value)</td></tr>" }
  $acts = ($f.actions | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''
  $evTable = if ($ev) { "<table class=`"ev`">$ev</table>" } else { '' }
  return "<section class=`"finding`"><div class=`"fh`"><h3>$(Esc $f.title)</h3><div class=`"fhr`">$(Pill $f.severity)$(Impact $f)</div></div><p>$(Esc $f.what)</p>$evTable<p class=`"lbl`">Qué hacer</p><ul>$acts</ul></section>"
}

$script:Css = @'
@page { size: A4; margin: 14mm 14mm 16mm; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", system-ui, sans-serif; color: #1f1e1c; font-size: 10.5pt; line-height: 1.45; margin: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
h1 { font-size: 19pt; font-weight: 600; margin: 0; }
h2 { font-size: 12.5pt; font-weight: 600; margin: 16px 0 8px; }
h3 { font-size: 11pt; font-weight: 600; margin: 0; }
p { margin: 0 0 6px; }
.page { page-break-after: always; }
.page:last-child { page-break-after: auto; }
.head { display: flex; justify-content: space-between; align-items: baseline; border-bottom: 1px solid #e1e0d9; padding-bottom: 8px; margin-bottom: 12px; }
.muted { color: #6b6a65; font-size: 9pt; }
.kpis { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
.kpi { background: #f5f4f0; border-radius: 8px; padding: 10px 12px; }
.kl { font-size: 8.5pt; color: #52514e; margin: 0; }
.kv { font-size: 18pt; font-weight: 600; margin: 2px 0 0; font-variant-numeric: tabular-nums; }
.ks { font-size: 8.5pt; color: #898781; margin: 0; }
.stack { display: flex; height: 18px; border-radius: 4px; overflow: hidden; gap: 2px; }
.legend { display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 8.5pt; color: #52514e; margin-top: 6px; }
.legend i { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 4px; vertical-align: -1px; }
.legend b { color: #1f1e1c; font-weight: 600; }
.grid2 { display: grid; grid-template-columns: 1.5fr 1fr; gap: 18px; }
.grid2e { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
.hbars { display: flex; flex-direction: column; gap: 5px; }
.hb { display: grid; grid-template-columns: 38% 1fr 46px; align-items: center; gap: 6px; font-size: 8.5pt; }
.hb-l { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #52514e; }
.hb-t { height: 7px; background: #f0efec; border-radius: 4px; overflow: hidden; display: block; }
.hb-t span { display: block; height: 7px; border-radius: 4px; }
.hb-v { text-align: right; font-variant-numeric: tabular-nums; font-weight: 600; }
.top { border: 1px solid #e1e0d9; border-radius: 10px; padding: 8px 12px; margin-bottom: 6px; display: grid; grid-template-columns: 1fr auto; gap: 2px 12px; align-items: center; }
.top .act { font-size: 9pt; color: #52514e; }
.pill { font-size: 8pt; padding: 1px 8px; border-radius: 6px; font-weight: 600; }
.imp { font-size: 9.5pt; font-weight: 600; margin-left: 8px; font-variant-numeric: tabular-nums; }
.good { background: #eaf3de; color: #27500a; border-radius: 8px; padding: 8px 12px; font-size: 9.5pt; margin-top: 10px; }
.good li { margin: 2px 0; }
.ins { display: grid; grid-template-columns: 1fr; gap: 8px; }
.in { border-left: 3px solid #2a78d6; padding: 4px 0 4px 10px; }
.in p:first-child { font-weight: 600; margin-bottom: 2px; }
.in p:last-child { color: #52514e; font-size: 9.5pt; margin: 0; }
.finding { border: 1px solid #e1e0d9; border-radius: 10px; padding: 10px 14px; margin-bottom: 10px; page-break-inside: avoid; }
.fh { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
.fhr { white-space: nowrap; }
.ev { width: 100%; border-collapse: collapse; font-size: 8.8pt; margin: 4px 0 6px; }
.ev td { border-top: 1px solid #f0efec; padding: 4px 0; vertical-align: top; }
.ev td b { font-weight: 600; }
.num { text-align: right; white-space: nowrap; padding-left: 10px !important; font-variant-numeric: tabular-nums; }
.lbl { font-size: 8.5pt; color: #898781; text-transform: uppercase; letter-spacing: .04em; margin: 6px 0 2px; }
ul { margin: 0; padding-left: 16px; }
li { margin: 2px 0; }
.foot { font-size: 8pt; color: #898781; margin-top: 14px; border-top: 1px solid #e1e0d9; padding-top: 6px; }
'@

function Render-ReportHtml($r) {
  $T = $r.totals; $p = $r.profile
  $findings = @($r.findings | Where-Object { $_.severity -ne 'baja' -or ($_.pct -and $_.pct -ge 0.5) -or $null -eq $_.impactUnits })
  $top3 = @($findings | Select-Object -First 3)
  $from = if ($r.from) { FechaLarga $r.from } else { 'el inicio' }
  $to = FechaLarga $r.generatedAt
  $period = "$(Esc $from) – $(Esc $to)"
  $days = @($r.byDay | ForEach-Object { [double]$_.usd })
  $dayLabels = @($r.byDay | ForEach-Object { $_.day.Substring(8, 2) + '/' + $_.day.Substring(5, 2) })
  $projects = @($r.byProject | Select-Object -First 5 | ForEach-Object { @{ name = $_.project; pct = $_.pct } })
  $models = @($r.byModel | Where-Object { $_.pct -ge 0.5 } | ForEach-Object { @{ name = ($_.model -replace '^claude-', ''); pct = $_.pct } })
  $extras = @(@($p.skills | ForEach-Object { @{ name = "Skill: $($_.name)"; pct = $_.pct; usd = $_.usd } }) + @($p.mcps | ForEach-Object { @{ name = "MCP: $($_.name)"; pct = $_.pct; usd = $_.usd } }) |
    Sort-Object -Property @{ Expression = { $_.pct }; Descending = $true } | Select-Object -First 6)
  $insights = ProfileInsights $r

  # Actividad por hora: solo el rango con datos
  $first = -1; $last = -1
  for ($h = 0; $h -lt 24; $h++) { if ($p.hours[$h] -gt 0) { if ($first -lt 0) { $first = $h }; $last = $h } }
  $hoursHtml = '<p class="muted">Sin datos.</p>'
  if ($first -ge 0) {
    $a = [math]::Max(0, $first - 1); $b = [math]::Min(23, $last + 1)
    $hv = @($a..$b | ForEach-Object { $p.hours[$_] }); $hl = @($a..$b | ForEach-Object { "${_}h" })
    $hoursHtml = Columns $hv $hl $script:Col.violet { param($v) "$(F0 $v) llamadas" } 1 100
  }

  $every = [math]::Max(1, [math]::Ceiling($days.Count / 8))
  $dailyHtml = Columns $days $dayLabels $script:Col.blue { param($v) Money $v } $every 120

  $topHtml = ''
  foreach ($f in $top3) {
    $imp = ''
    if ($f.impactUsd -gt 0.05) { $imp = '<div class="imp" style="margin:4px 0 0">' + (Money $f.impactUsd) + ' · ' + (Pct $f.pct) + '</div>' }
    $topHtml += '<div class="top"><div><h3>' + (Esc $f.title) + '</h3><div class="act">' + (Esc $f.actions[0]) + '</div></div><div style="text-align:right">' + (Pill $f.severity) + $imp + '</div></div>'
  }
  if (-not $topHtml) { $topHtml = '<p class="muted">No encontramos problemas relevantes en este período.</p>' }
  $topTitle = if ($top3.Count -eq 1) { 'Tu mejora con más impacto' } else { "Tus $($top3.Count) mejoras con más impacto" }
  $goodHtml = if ($r.strengths.Count) { '<div class="good"><b>Lo que haces bien</b><ul>' + (($r.strengths | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul></div>' } else { '' }
  $insHtml = ($insights | ForEach-Object { "<div class=`"in`"><p>$(Esc $_[0])</p><p>$(Esc $_[1])</p></div>" }) -join ''
  $modesRows = @($p.permissionModes | ForEach-Object { @{ name = $(if ($script:ModeNames[$_.name]) { $script:ModeNames[$_.name] } else { $_.name }); pct = $_.pct } })
  $effortRows = @($p.efforts | ForEach-Object { @{ name = $_.name; pct = $_.pct } })
  $findingsHtml = ($findings | ForEach-Object { FindingBlock $_ }) -join ''
  if (-not $findingsHtml) { $findingsHtml = '<p class="muted">Sin recomendaciones para este período.</p>' }

  $costKpi = if ($T.hasCost) { Kpi 'Costo equivalente' (Money $T.cost) "$(Money $T.costPerPrompt) por mensaje" } else { Kpi 'Costo equivalente' '—' 'sin datos de costo' }
  $cacheSub = if ($T.cacheHitRate -ge 0.85) { 'muy bueno' } else { 'mejorable' }

  return @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Tu uso de Claude</title><style>$($script:Css)</style></head><body>
<div class="page">
  <div class="head"><h1>Tu uso de Claude</h1><span class="muted">$period · Claude Code</span></div>
  <div class="kpis">
    $costKpi
    $(Kpi 'Sesiones' (F0 $T.sessions) "$(F0 $T.prompts) mensajes · $($p.activeDays) días activos")
    $(Kpi 'Contexto promedio' (Tok $T.avgContext) 'tokens por llamada')
    $(Kpi 'Uso de caché' ((Pct ($T.cacheHitRate * 100)) -replace '&lt;', '<') $cacheSub)
  </div>
  <h2>¿En qué se va tu consumo?</h2>
  $(StackedBar $r.categories)
  <div class="grid2">
    <div><h2>Consumo diario</h2>$dailyHtml</div>
    <div><h2>Por modelo</h2>$(HBars $models $script:Col.blue $null)<h2 style="margin-top:12px">Por proyecto</h2>$(HBars $projects $script:Col.aqua $null)</div>
  </div>
  <h2>$topTitle</h2>
  $topHtml
  $goodHtml
</div>
<div class="page">
  <div class="head"><h1>Tu forma de trabajar</h1><span class="muted">$period</span></div>
  <div class="kpis">
    $(Kpi 'Claude trabajando' "$(F1 $p.claudeHours) h" "en $($p.timedSessions) sesiones con registro")
    $(Kpi 'Sesión típica' "$(F0 $p.medianPrompts) mensajes" "$(F0 $p.medianCalls) llamadas · $(Money $p.medianUsd)")
    $(Kpi 'Código' "+$(F0 $T.linesAdded)" "−$(F0 $T.linesRemoved) líneas")
    $(Kpi 'Días activos' "$($p.activeDays)" "de $($r.days) días del período")
  </div>
  <div class="grid2e">
    <div><h2>¿A qué hora trabajas con Claude?</h2>$hoursHtml</div>
    <div><h2>¿Cuánto delegas?</h2>$(HBars $modesRows $script:Col.orange $null)
      <h2 style="margin-top:12px">Nivel de esfuerzo</h2>$(HBars $effortRows $script:Col.yellow $null)</div>
  </div>
  <h2>Skills y MCP: cuánto te cuestan</h2>
  $(HBars $extras $script:Col.magenta { param($x) if ($null -ne $x.usd) { Money $x.usd } else { Pct $x.pct } })
  <h2>Lo que dicen tus datos</h2>
  <div class="ins">$insHtml</div>
</div>
<div class="page">
  <div class="head"><h1>Recomendaciones en detalle</h1><span class="muted">ordenadas por impacto</span></div>
  $findingsHtml
  <p class="foot">Generado por tibox-coach a partir de tus sesiones locales de Claude Code ($(Esc $r.claudeDir)). Los montos son el costo equivalente a precios de API; el reparto por categoría es una estimación ajustada al consumo real. Nada de esta información salió de tu equipo.</p>
</div>
</body></html>
"@
}

function Find-Edge {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

function Write-ReportPdf($report, [string]$outPath) {
  $outPath = [IO.Path]::GetFullPath($outPath)
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tibox-coach-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $tmp)
  $htmlPath = Join-Path $tmp 'informe.html'
  [IO.File]::WriteAllText($htmlPath, (Render-ReportHtml $report), (New-Object Text.UTF8Encoding($false)))
  $browser = Find-Edge
  if (-not $browser) {
    $fallback = [IO.Path]::ChangeExtension($outPath, '.html')
    Copy-Item -LiteralPath $htmlPath -Destination $fallback -Force
    return @{ pdf = $null; html = $fallback; reason = 'No encontré Microsoft Edge ni Chrome para generar el PDF. Abre el HTML y usa Imprimir > Guardar como PDF.' }
  }
  if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
  $url = ([Uri]$htmlPath).AbsoluteUri
  $edgeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    "`"--user-data-dir=$tmp\profile`"", '--no-pdf-header-footer', "`"--print-to-pdf=$outPath`"", "`"$url`"")
  $proc = Start-Process -FilePath $browser -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
  [void]$proc.WaitForExit(60000)
  # Edge puede terminar de escribir el archivo un instante después de que el proceso principal sale
  for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath $outPath); $i++) { Start-Sleep -Milliseconds 250 }
  try { Remove-Item -LiteralPath (Join-Path $tmp 'profile') -Recurse -Force -ErrorAction Stop } catch {}
  if (-not (Test-Path -LiteralPath $outPath)) { return @{ pdf = $null; html = $htmlPath; reason = 'El navegador no generó el PDF.' } }
  return @{ pdf = $outPath; html = $htmlPath }
}
