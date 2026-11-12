# Agrega las sesiones de un período y aplica las reglas del coach.
# Cada regla es un bloque independiente: define su condición, su diagnóstico y sus acciones.

$script:CI = [Globalization.CultureInfo]::GetCultureInfo('es-CL')
function F0($n) { return ([double]$n).ToString('#,##0', $script:CI) }
function F1($n) { return ([double]$n).ToString('#,##0.#', $script:CI) }

function Tok($n) {
  $n = [math]::Round([double]$n)
  if ($n -lt 1000) { return (F0 $n) }
  if ($n -lt 100000) { return (F0 ([math]::Round($n / 100) * 100)) }
  if ($n -lt 1e6) { return (F0 ([math]::Round($n / 1000))) + ' mil' }
  if ($n -lt 2e6) { return (F1 ($n / 1e6)) + ' millón' }
  if ($n -lt 1e9) { return (F1 ($n / 1e6)) + ' millones' }
  return (F1 ($n / 1e9)) + ' mil millones'
}
function PctTxt($x) { if ($x -lt 1) { return 'menos del 1' } else { return (F0 ([math]::Round($x))) } }
function Fecha($ts) { if (-not $ts) { return '' }; return ([DateTime]::Parse($ts)).ToString('d MMM, HH:mm', $script:CI) }
function Veces($n) { if ($n -eq 1) { return 'una vez' } else { return "$(F0 $n) veces" } }
function Median($arr) { $s = @($arr | Sort-Object); if (-not $s.Count) { return 0 }; return $s[[math]::Floor($s.Count / 2)] }
function SessionName($s) { if ($s.title) { return $s.title } else { $d = if ($s.start) { $s.start.Substring(0, 10) } else { '' }; return "$($s.project) · $d" } }
function SeverityFor($p) { if ($p -ge 10) { 'alta' } elseif ($p -ge 3) { 'media' } else { 'baja' } }
function FileSize($p) { try { return (Get-Item -LiteralPath $p -ErrorAction Stop).Length } catch { return $null } }
function ToolName([string]$t) { if ($t.StartsWith('mcp__')) { return (ToolCategory $t) } else { return $t } }
function Basename($p) { return [IO.Path]::GetFileName([string]$p) }

# Familias para el gráfico de distribución
function CategoryGroup([string]$name) {
  if ($name -match '^(Contexto base|CLAUDE\.md|Instrucciones inyectadas)') { return 'fijo' }
  if ($name -match '^(Generación|Subagentes \(trabajo)') { return 'generacion' }
  if ($name -match '^(Tus mensajes|Respuestas de Claude|Código escrito|Resúmenes)') { return 'conversacion' }
  return 'herramientas'
}

# Revisa la configuración local que pesa en cada llamada (CLAUDE.md y servidores MCP).
function Get-LocalConfig([string]$claudeDir, $cwds) {
  $out = @{ globalClaudeMd = (FileSize (Join-Path $claudeDir 'CLAUDE.md')); projects = @{} }
  $cfg = $null
  foreach ($p in @((Join-Path $env:USERPROFILE '.claude.json'), (Join-Path $claudeDir '.claude.json'))) {
    try { $cfg = $script:JS.DeserializeObject([IO.File]::ReadAllText($p)); break } catch {}
  }
  foreach ($cwd in $cwds) {
    if (-not $cwd) { continue }
    $md = FileSize (Join-Path $cwd 'CLAUDE.md'); if (-not $md) { $md = FileSize (Join-Path $cwd '.claude\CLAUDE.md') }
    $mcp = New-Object System.Collections.Generic.List[string]
    try { $j = $script:JS.DeserializeObject([IO.File]::ReadAllText((Join-Path $cwd '.mcp.json'))); if ($j.mcpServers) { foreach ($k in $j.mcpServers.Keys) { $mcp.Add($k) } } } catch {}
    if ($cfg -and $cfg.projects) {
      $pc = $cfg.projects[$cwd]; if (-not $pc) { $pc = $cfg.projects[$cwd.Replace('\', '/')] }
      if ($pc -and $pc.mcpServers) { foreach ($k in $pc.mcpServers.Keys) { $mcp.Add($k) } }
    }
    $out.projects[$cwd] = @{ claudeMd = $md; mcp = $mcp }
  }
  return $out
}

function New-Evidence($label, $detail, $value) { return @{ label = [string]$label; detail = [string]$detail; value = [string]$value } }

function Build-Report($allSessions, [int]$days = 30, [string]$claudeDir, [int]$files) {
  $W = $script:W
  $from = if ($days -gt 0) { [DateTime]::UtcNow.AddDays(-$days).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { '' }
  $sessions = @($allSessions | Where-Object { [string]::CompareOrdinal([string]$_.end, $from) -ge 0 })

  # Precio por unidad: el de cada sesión; si falta, el promedio del período.
  $pc = 0.0; $pu = 0.0
  foreach ($s in $sessions) { if ($s.pricePerUnit) { $pc += $s.cost; $pu += $s.totalUnits } }
  $script:AvgPrice = if ($pu -gt 0) { $pc / $pu } else { $null }
  $usd = { param($units, $s) $p = if ($s -and $s.pricePerUnit) { $s.pricePerUnit } else { $script:AvgPrice }; if ($p) { $units * $p } else { $null } }

  $Tot = @{ sessions = $sessions.Count; calls = 0; subCalls = 0; prompts = 0; input = 0.0; cacheCreate = 0.0; cacheRead = 0.0; output = 0.0; thinking = 0.0; tokens = 0.0; units = 0.0; cost = 0.0; linesAdded = 0; linesRemoved = 0 }
  foreach ($s in $sessions) {
    $Tot.calls += $s.calls; $Tot.subCalls += $s.subCalls; $Tot.prompts += $s.prompts.Count
    foreach ($k in 'input', 'cacheCreate', 'cacheRead', 'output', 'thinking') { $Tot[$k] += $s.main[$k] + $s.sub[$k] }
    $Tot.tokens += $s.totalTokens; $Tot.units += $s.totalUnits
    $c = if ($s.cost) { $s.cost } else { & $usd $s.totalUnits $s }; if ($c) { $Tot.cost += $c }
    $Tot.linesAdded += $s.linesAdded; $Tot.linesRemoved += $s.linesRemoved
  }
  $Tot.cacheHitRate = $Tot.cacheRead / [math]::Max(1, $Tot.cacheRead + $Tot.cacheCreate + $Tot.input)
  $acc = 0.0; foreach ($s in $sessions) { $acc += $s.avgContext * $s.calls }
  $Tot.avgContext = if ($Tot.calls) { $acc / $Tot.calls } else { 0 }
  $Tot.costPerPrompt = if ($Tot.prompts) { $Tot.cost / $Tot.prompts } else { 0 }
  $Tot.hasCost = $null -ne $script:AvgPrice
  $pctOf = { param($u) if ($Tot.units -gt 0) { ($u / $Tot.units) * 100 } else { 0 } }

  # ¿En qué se va el costo?
  $catMap = @{}
  foreach ($s in $sessions) { foreach ($k in $s.categories.Keys) {
      if (-not $catMap.ContainsKey($k)) { $catMap[$k] = @{ units = 0.0; usd = 0.0 } }
      $v = $s.categories[$k]; $catMap[$k].units += $v; $x = & $usd $v $s; if ($x) { $catMap[$k].usd += $x }
    } }
  $categories = @($catMap.Keys | ForEach-Object { @{ name = $_; group = (CategoryGroup $_); units = $catMap[$_].units; usd = $(if ($Tot.hasCost) { $catMap[$_].usd } else { $null }); pct = (& $pctOf $catMap[$_].units) } } |
    Where-Object { $_.pct -ge 0.05 } | Sort-Object -Property @{ Expression = { $_.units }; Descending = $true })

  # Herramientas
  $toolMap = @{}
  foreach ($s in $sessions) { foreach ($r in $s.toolResults) {
      if (-not $toolMap.ContainsKey($r.tool)) { $toolMap[$r.tool] = @{ tool = $r.tool; calls = 0; tokens = 0.0; units = 0.0; usd = 0.0; errors = 0; max = 0.0 } }
      $t = $toolMap[$r.tool]; $t.calls++; $t.tokens += $r.tokens; $t.units += $r.units; $x = & $usd $r.units $s; if ($x) { $t.usd += $x }
      if ($r.isError) { $t.errors++ }; if ($r.tokens -gt $t.max) { $t.max = $r.tokens }
    } }
  $tools = @($toolMap.Values | ForEach-Object { $_.display = ToolName $_.tool; $_.pct = & $pctOf $_.units; $_ } | Sort-Object -Property @{ Expression = { $_.units }; Descending = $true })

  # Por día / proyecto / modelo
  $fromDay = if ($from) { $from.Substring(0, 10) } else { '' }
  $dayMap = @{}
  foreach ($s in $sessions) { foreach ($d in $s.byDay.Keys) {
      if ([string]::CompareOrdinal($d, $fromDay) -lt 0) { continue }
      if (-not $dayMap.ContainsKey($d)) { $dayMap[$d] = @{ day = $d; tokens = 0.0; usd = 0.0 } }
      $v = $s.byDay[$d]; $dayMap[$d].tokens += $v.tokens; $x = & $usd $v.units $s; if ($x) { $dayMap[$d].usd += $x }
    } }
  $byDay = @($dayMap.Values | Sort-Object -Property @{ Expression = { $_.day } })

  $projMap = [ordered]@{}
  foreach ($s in $sessions) {
    $key = if ($s.cwd) { $s.cwd } else { $s.project }
    if (-not $projMap.Contains($key)) { $projMap[$key] = @{ project = $s.project; cwd = $s.cwd; sessions = 0; calls = 0; tokens = 0.0; units = 0.0; usd = 0.0; baselines = (New-Object System.Collections.Generic.List[double]) } }
    $p = $projMap[$key]; $p.sessions++; $p.calls += $s.calls; $p.tokens += $s.totalTokens; $p.units += $s.totalUnits
    $x = if ($s.cost) { $s.cost } else { & $usd $s.totalUnits $s }; if ($x) { $p.usd += $x }
    if ($s.calls -gt 0) { $p.baselines.Add($s.baseline) }
  }
  $byProject = @($projMap.Values | ForEach-Object { $_.baseline = Median $_.baselines; $_.pct = & $pctOf $_.units; $_ } | Sort-Object -Property @{ Expression = { $_.units }; Descending = $true })

  $modelMap = @{}
  foreach ($s in $sessions) { foreach ($m in $s.models.Keys) {
      if (-not $modelMap.ContainsKey($m)) { $modelMap[$m] = @{ model = $m; calls = 0; tokens = 0.0; units = 0.0 } }
      $v = $s.models[$m]; $modelMap[$m].calls += $v.calls; $modelMap[$m].tokens += $v.tokens; $modelMap[$m].units += $v.units
    } }
  $byModel = @($modelMap.Values | ForEach-Object { $_.pct = & $pctOf $_.units; $_ } | Sort-Object -Property @{ Expression = { $_.units }; Descending = $true })

  $config = Get-LocalConfig $claudeDir @($byProject | ForEach-Object { $_.cwd })

  # ---------- Perfil de trabajo ----------
  $sumMap = {
    param($key, [bool]$toUsd)
    $m = @{}
    foreach ($s in $sessions) { $src = $s[$key]; if (-not $src) { continue }; foreach ($k in $src.Keys) {
        if (-not $m.ContainsKey($k)) { $m[$k] = @{ name = $k; value = 0.0; usd = 0.0 } }
        $m[$k].value += $src[$k]; if ($toUsd) { $x = & $usd $src[$k] $s; if ($x) { $m[$k].usd += $x } }
      } }
    return @($m.Values | Sort-Object -Property @{ Expression = { $_.value }; Descending = $true })
  }
  $effortCalls = & $sumMap 'efforts' $false
  $effortTotal = 0.0; foreach ($e in $effortCalls) { $effortTotal += $e.value }
  $modes = & $sumMap 'permissionModes' $false
  $modesTotal = 0.0; foreach ($e in $modes) { $modesTotal += $e.value }
  $hours = New-Object 'double[]' 24
  foreach ($s in $sessions) { for ($h = 0; $h -lt 24; $h++) { $hours[$h] += $s.hours[$h] } }
  $timed = @($sessions | Where-Object { $_.apiMs -gt 0 })
  $activeDays = @($sessions | ForEach-Object { $_.byDay.Keys } | Where-Object { [string]::CompareOrdinal($_, $fromDay) -ge 0 } | Sort-Object -Unique).Count
  $claudeMs = 0.0; foreach ($s in $timed) { $claudeMs += $s.apiMs + $s.toolMs }
  $high = 0.0; foreach ($e in $effortCalls) { if ($e.name -in 'xhigh', 'max') { $high += $e.value } }
  $profile = @{
    activeDays = $activeDays
    claudeHours = $claudeMs / 3600000
    timedSessions = $timed.Count
    medianCalls = (Median @($sessions | Where-Object { $_.calls } | ForEach-Object { $_.calls }))
    medianPrompts = (Median @($sessions | ForEach-Object { $_.prompts.Count } | Where-Object { $_ }))
    medianUsd = (Median @($sessions | ForEach-Object { $x = if ($_.cost) { $_.cost } else { & $usd $_.totalUnits $_ }; if ($x) { $x } else { 0 } }))
    efforts = @($effortCalls | ForEach-Object { @{ name = $_.name; calls = $_.value; pct = $(if ($effortTotal) { ($_.value / $effortTotal) * 100 } else { 0 }) } })
    highEffortPct = $(if ($effortTotal) { ($high / $effortTotal) * 100 } else { 0 })
    permissionModes = @($modes | ForEach-Object { @{ name = $_.name; prompts = $_.value; pct = $(if ($modesTotal) { ($_.value / $modesTotal) * 100 } else { 0 }) } })
    skills = @(& $sumMap 'skillUnits' $true | ForEach-Object { @{ name = $_.name; usd = $(if ($Tot.hasCost) { $_.usd } else { $null }); pct = (& $pctOf $_.value) } })
    mcps = @(& $sumMap 'mcpUnits' $true | ForEach-Object { @{ name = $_.name; usd = $(if ($Tot.hasCost) { $_.usd } else { $null }); pct = (& $pctOf $_.value) } })
    hours = [object[]]$hours
  }

  # ---------- Reglas ----------
  $findings = New-Object System.Collections.Generic.List[object]
  $add = {
    param($f)
    $f.pct = if ($null -ne $f.impactUnits) { & $pctOf $f.impactUnits } else { $null }
    if (-not $f.severity) { $f.severity = SeverityFor $(if ($f.pct) { $f.pct } else { 0 }) }
    $findings.Add($f)
  }
  $sumUsd = { param($list, [scriptblock]$unitsOf) if (-not $Tot.hasCost) { return $null }; $a = 0.0; foreach ($x in $list) { $v = & $usd (& $unitsOf $x) $x.s; if ($v) { $a += $v } }; return $a }
  $sumUnits = { param($list, [scriptblock]$unitsOf) $a = 0.0; foreach ($x in $list) { $a += & $unitsOf $x }; return $a }

  # 1. Sesiones que acumulan demasiado contexto
  $LIMIT = 100000
  $ev = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) {
    $su = 0.0; $sc = 0
    foreach ($c in $s.ctx) { if ($c -gt $LIMIT) { $su += ($c - $LIMIT) * $W.cacheRead; $sc++ } }
    if ($sc -gt 0) { $ev.Add(@{ s = $s; su = $su; sc = $sc }) }
  }
  $callsOver = 0; foreach ($x in $ev) { $callsOver += $x.sc }
  if ($callsOver -ge 5) {
    $ev = @($ev | Sort-Object -Property @{ Expression = { $_.su }; Descending = $true })
    $biggest = ($ev | ForEach-Object { $_.s.maxContext } | Measure-Object -Maximum).Maximum
    & $add @{
      id = 'sesiones-largas'; title = 'Tus sesiones se alargan demasiado'
      impactUnits = (& $sumUnits $ev { param($x) $x.su }); impactUsd = (& $sumUsd $ev { param($x) $x.su })
      what = "En $(F0 $callsOver) llamadas el contexto superó los $(Tok $LIMIT) tokens, y tu sesión más grande llegó a $(Tok $biggest). Claude reenvía todo el historial en cada mensaje: lo que pediste hace dos horas lo sigues pagando en cada respuesta nueva."
      evidence = @($ev | Select-Object -First 5 | ForEach-Object {
          $s = $_.s; $comp = if ($s.compactions) { " · compactada $(Veces $s.compactions)" } else { '' }
          New-Evidence (SessionName $s) "$(F0 $s.calls) llamadas · contexto promedio de $(Tok $s.avgContext) tokens$comp" "máx. $(Tok $s.maxContext)" })
      actions = @(
        'Haz /clear al terminar una tarea y antes de empezar otra. Si necesitas continuidad, pide primero "resume en 10 líneas lo hecho y lo pendiente" y pega ese resumen en la sesión nueva.',
        'Usa /compact indicando qué conservar, por ejemplo: "/compact conserva solo los cambios del endpoint de camiones".',
        'Revisa /context a mitad de sesión para ver qué está ocupando más espacio.',
        'Para exploraciones amplias ("busca dónde se usa X en todo el repo"), pide que lo haga un subagente. A tu sesión solo vuelve la conclusión.')
    }
  }

  # 2. Reanudaciones en frío (caché vencida)
  $cold = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) { foreach ($c in $s.coldResumes) { $cold.Add(@{ s = $s; c = $c }) } }
  if ($cold.Count -ge 2) {
    $cold = @($cold | Sort-Object -Property @{ Expression = { $_.c.tokens }; Descending = $true })
    $byModelChange = @($cold | Where-Object { $_.c.reason -eq 'cambio de modelo' }).Count -gt 0
    & $add @{
      id = 'cache-fria'; title = 'Retomas sesiones con la caché vencida'
      impactUnits = (& $sumUnits $cold { param($x) $x.c.units }); impactUsd = (& $sumUsd $cold { param($x) $x.c.units })
      what = "Claude tuvo que volver a cargar el contexto completo en caché $(Veces $cold.Count), casi siempre después de una pausa larga$(if ($byModelChange) { ' o de un cambio de modelo' }). Escribir en caché cuesta entre 12 y 20 veces más que leer de ella, y en sesiones grandes la diferencia se nota."
      evidence = @($cold | Select-Object -First 6 | ForEach-Object { New-Evidence (SessionName $_.s) "$(Fecha $_.c.ts) · $($_.c.reason)" "$(Tok $_.c.tokens) tokens" })
      actions = @(
        'Si vuelves a una sesión grande después de una hora o más, abre una nueva con un resumen corto de lo pendiente. Sale más barato que recargar todo el historial.',
        'Elige el modelo al empezar. Cambiarlo con /model a mitad de sesión descarta la caché.',
        'Antes de una pausa larga (almuerzo, reunión), cierra la tarea o pide un resumen de estado para retomar en limpio.')
    }
  }

  # 3. Base fija alta por proyecto (CLAUDE.md, MCP, skills)
  $withB = @($byProject | Where-Object { $_.calls -gt 0 -and $_.baseline -gt 0 })
  if ($withB.Count) {
    $minB = ($withB | ForEach-Object { $_.baseline } | Measure-Object -Minimum).Minimum
    $maxB = ($withB | ForEach-Object { $_.baseline } | Measure-Object -Maximum).Maximum
    $ref = [math]::Max($minB, 20000)
    $units = 0.0; $money = 0.0
    $ev = New-Object System.Collections.Generic.List[object]
    foreach ($p in $withB) {
      $extra = $p.baseline - $ref
      $cfg = $config.projects[$p.cwd]; if (-not $cfg) { $cfg = @{} }
      $pu = 0.0
      if ($extra -gt 8000) {
        foreach ($s in $sessions) {
          $sk = if ($s.cwd) { $s.cwd } else { $s.project }; $pk = if ($p.cwd) { $p.cwd } else { $p.project }
          if ($sk -eq $pk -and $s.calls) { $u = $extra * ($s.cw + $W.cacheRead * ($s.calls - 1)); $pu += $u; $x = & $usd $u $s; if ($x) { $money += $x } }
        }
      }
      $units += $pu
      $det = @()
      $det += $(if ($cfg.claudeMd) { "CLAUDE.md de $(Tok ($cfg.claudeMd / 4)) tokens" } else { 'sin CLAUDE.md' })
      if ($cfg.mcp -and $cfg.mcp.Count) { $det += 'MCP: ' + ($cfg.mcp -join ', ') }
      $ev.Add(@{ label = $p.project; detail = ($det -join ' · '); value = "$(Tok $p.baseline) por llamada"; pu = $pu })
    }
    if ($units -gt 0 -or (Median @($withB | ForEach-Object { $_.baseline })) -gt 45000) {
      $ev = @($ev | Sort-Object -Property @{ Expression = { $_.pu }; Descending = $true })
      $used = @($tools | Where-Object { $_.tool.StartsWith('mcp__') } | ForEach-Object { $_.display -replace '^MCP: ', '' } | Select-Object -Unique)
      $glob = if ($config.globalClaudeMd) { " Tu CLAUDE.md global aporta unos $(Tok ($config.globalClaudeMd / 4))." } else { '' }
      $usedTxt = if ($used.Count) { " En este período usaste: $($used -join ', ')." } else { '' }
      & $add @{
        id = 'base-fija'; title = 'Cargas mucho contexto fijo en cada mensaje'
        impactUnits = $units; impactUsd = $(if ($Tot.hasCost) { $money } else { $null })
        what = "Antes de leer tu primer mensaje, Claude ya recibe sus instrucciones, las definiciones de herramientas, los servidores MCP, las skills y tu CLAUDE.md. En tus proyectos esa base va de $(Tok $minB) a $(Tok $maxB) tokens y viaja en cada llamada.$glob"
        evidence = @($ev | ForEach-Object { New-Evidence $_.label $_.detail $_.value })
        actions = @(
          'Corre /context al inicio de una sesión para ver cuánto ocupa cada MCP, skill y CLAUDE.md.',
          ('Desactiva con /mcp los servidores que no usas en ese proyecto.' + $usedTxt),
          'Deja CLAUDE.md corto (menos de 200 líneas), con reglas y comandos clave. La documentación larga va en archivos aparte que Claude lee solo cuando los necesita.')
      }
    }
  }

  # 4. Resultados de herramientas muy grandes
  $MIN = 5000
  $big = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) { foreach ($r in $s.toolResults) { if (-not $r.side -and $r.tokens -ge $MIN) { $big.Add(@{ s = $s; r = $r }) } } }
  if ($big.Count) {
    $usedT = @($big | ForEach-Object { $_.r.tool } | Select-Object -Unique)
    $actions = New-Object System.Collections.Generic.List[string]
    if ($usedT -contains 'Read') { $actions.Add('Si el archivo es grande, pide solo lo que necesitas ("lee la función procesarCamion de app.py"). Claude puede leer por rangos de líneas.') }
    if ($usedT -contains 'Bash' -or $usedT -contains 'PowerShell') { $actions.Add('Cuando un comando genera mucha salida (tests, builds, logs), pide que la filtre ("muestra solo los errores", "| Select-Object -Last 30", "--quiet") o que la guarde en un archivo y busque ahí.') }
    if ($usedT -contains 'Grep' -or $usedT -contains 'Glob') { $actions.Add('En las búsquedas, indica la carpeta o un patrón más preciso ("busca solo en src/") para no traer cientos de coincidencias.') }
    if (@($usedT | Where-Object { $_.StartsWith('mcp__') }).Count) { $actions.Add('Con herramientas MCP (documentación, navegador, bases de datos), pide resultados acotados: menos filas, solo los campos necesarios, capturas solo cuando hagan falta.') }
    $actions.Add('Cuando ya sacaste lo que necesitabas de un resultado grande, un /compact evita que lo sigas pagando el resto de la sesión.')
    $big = @($big | Sort-Object -Property @{ Expression = { $_.r.units }; Descending = $true })
    & $add @{
      id = 'resultados-grandes'; title = 'Algunas herramientas devuelven resultados enormes'
      impactUnits = (& $sumUnits $big { param($x) $x.r.units }); impactUsd = (& $sumUsd $big { param($x) $x.r.units })
      what = "$(F0 $big.Count) resultados superaron los $(Tok $MIN) tokens. El tamaño es solo una parte del costo: cada resultado queda en el contexto y se reenvía en todas las llamadas siguientes de la sesión."
      evidence = @($big | Select-Object -First 8 | ForEach-Object {
          $lbl = if ($_.r.label) { $_.r.label } else { '(sin detalle)' }
          New-Evidence "$(ToolName $_.r.tool): $lbl" "$(SessionName $_.s) · siguió en el contexto $(F0 $_.r.remaining) llamadas" "$(Tok $_.r.tokens) tokens" })
      actions = $actions.ToArray()
    }
  }

  # 5. Archivos leídos varias veces en la misma sesión
  $rep = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) {
    $m = @{}
    foreach ($r in $s.toolResults) { if (-not $r.side -and $r.tool -eq 'Read' -and $r.filePath) {
        if (-not $m.ContainsKey($r.filePath)) { $m[$r.filePath] = @{ n = 0; units = 0.0 } }
        $e = $m[$r.filePath]; if ($e.n -gt 0) { $e.units += $r.units }; $e.n++
      } }
    foreach ($f in $m.Keys) { if ($m[$f].n -ge 3) { $rep.Add(@{ s = $s; f = $f; n = $m[$f].n; units = $m[$f].units }) } }
  }
  if ($rep.Count) {
    $rep = @($rep | Sort-Object -Property @{ Expression = { $_.units }; Descending = $true })
    & $add @{
      id = 'lecturas-repetidas'; title = 'Claude relee los mismos archivos'
      impactUnits = (& $sumUnits $rep { param($x) $x.units }); impactUsd = (& $sumUsd $rep { param($x) $x.units })
      what = "$(F0 $rep.Count) archivos se leyeron tres veces o más en una misma sesión. Cada lectura agrega una copia completa al contexto."
      evidence = @($rep | Select-Object -First 6 | ForEach-Object { New-Evidence (Basename $_.f) "$($_.f) · $(SessionName $_.s)" "$($_.n) lecturas" })
      actions = @(
        'Divide en módulos más chicos los archivos largos que editas seguido. Así Claude lee solo el que necesita.',
        'Después de un cambio, pide que verifique solo la parte modificada o que corra los tests, en vez de "revisa todo de nuevo".',
        'Si el archivo es una referencia fija (esquema, contrato de API), resume lo esencial una vez en CLAUDE.md.')
    }
  }

  # 6. Textos enormes pegados en el chat
  $bigP = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) { foreach ($p in $s.prompts) { if ($p.tokens -ge 3000) { $bigP.Add(@{ s = $s; p = $p }) } } }
  if ($bigP.Count) {
    $bigP = @($bigP | Sort-Object -Property @{ Expression = { $_.p.units }; Descending = $true })
    & $add @{
      id = 'pegados'; title = 'Pegas textos muy largos en el chat'
      impactUnits = (& $sumUnits $bigP { param($x) $x.p.units }); impactUsd = (& $sumUsd $bigP { param($x) $x.p.units })
      what = "$(F0 $bigP.Count) mensajes tuyos superaron los 3.000 tokens, con código, JSON o logs pegados. Ese texto queda en el contexto hasta que termina la sesión."
      evidence = @($bigP | Select-Object -First 6 | ForEach-Object {
          $t = ($_.p.text -replace '\s+', ' '); if ($t.Length -gt 90) { $t = $t.Substring(0, 90) }; if (-not $t) { $t = '(texto pegado)' }
          New-Evidence $t "$(SessionName $_.s) · siguió en el contexto $(F0 $_.p.remaining) llamadas" "$(Tok $_.p.tokens) tokens" })
      actions = @(
        'Guarda el contenido en un archivo del proyecto y menciónalo con @archivo. Claude lo lee cuando lo necesita y puede buscar solo la parte relevante.',
        'De un log, pega el error y unas pocas líneas alrededor.',
        'Para definiciones grandes (Logic Apps, OpenAPI, esquemas), pide primero un resumen y sigue trabajando desde ahí en una sesión nueva.')
    }
  }

  # 7. Búsquedas que recorren dependencias o carpetas generadas
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sessions) { foreach ($r in $s.toolResults) { if ($r.deps -and $r.tokens -ge 500) { $hits.Add(@{ s = $s; r = $r }) } } }
  if ($hits.Count) {
    $hits = @($hits | Sort-Object -Property @{ Expression = { $_.r.tokens }; Descending = $true })
    & $add @{
      id = 'dependencias'; title = 'Tus búsquedas recorren carpetas de dependencias'
      impactUnits = (& $sumUnits $hits { param($x) $x.r.units }); impactUsd = (& $sumUsd $hits { param($x) $x.r.units })
      what = "$(F0 $hits.Count) búsquedas devolvieron sobre todo archivos de node_modules, .venv, build u otras carpetas generadas, que rara vez sirven para la tarea."
      evidence = @($hits | Select-Object -First 6 | ForEach-Object { New-Evidence "$($_.r.tool): $($_.r.label)" (SessionName $_.s) "$(Tok $_.r.tokens) tokens" })
      actions = @(
        'Agrega esas carpetas al .gitignore del proyecto. Las búsquedas de Claude Code lo respetan.',
        'Si no puedes ignorarlas en git, bloquea su lectura en .claude/settings.json: { "permissions": { "deny": ["Read(./node_modules/**)", "Read(./.venv/**)"] } }',
        'Al pedir una búsqueda, di dónde buscar: "en src/", no en todo el repo.')
    }
  }

  # 8. Iteraciones de corrección e interrupciones
  $corr = New-Object System.Collections.Generic.List[object]
  $interrupts = 0
  foreach ($s in $sessions) { $interrupts += $s.interrupts; foreach ($p in $s.prompts) { if ($p.correction) { $corr.Add(@{ s = $s; p = $p }) } } }
  $ratio = if ($Tot.prompts) { $corr.Count / $Tot.prompts } else { 0 }
  if (($corr.Count -ge 3 -and $ratio -ge 0.12) -or $interrupts -ge 10) {
    $intTxt = if ($interrupts) { ", y detuviste a Claude $(Veces $interrupts)" } else { '' }
    & $add @{
      id = 'correcciones'; title = 'Das muchas vueltas de corrección'
      impactUnits = $null; severity = $(if ($ratio -ge 0.25) { 'alta' } else { 'media' })
      what = "El $(PctTxt ($ratio * 100))% de tus mensajes son correcciones del tipo `"no, eso no`" o `"sigue fallando`"$intTxt. Cada vuelta reenvía todo el contexto."
      evidence = @($corr | Select-Object -First 6 | ForEach-Object { $t = $_.p.text; if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }; New-Evidence "`"$t`"" (SessionName $_.s) '' })
      actions = @(
        'Para cambios no triviales, activa el modo plan (Shift+Tab) y revisa el enfoque antes de que Claude escriba código.',
        'En el primer mensaje, di cuándo está listo ("cuando el endpoint responda 200 con este JSON") y qué no debe tocar.',
        'Pide a Claude que corra los tests o el script antes de devolverte el control.',
        'Si después de dos o tres correcciones sigue mal, haz /clear y reformula el pedido con lo que aprendiste.')
    }
  }

  # 9. Modelo más caro para tareas cortas
  $top = if ($byModel.Count) { $byModel[0] } else { $null }
  if ($top -and $top.model -match '(?i)opus' -and $top.pct -gt 70) {
    $short = @($sessions | Where-Object { $_.calls -gt 0 -and $_.calls -le 6 -and @($_.models.Keys | Where-Object { $_ -match '(?i)opus' }).Count })
    if ($short.Count -ge 3) {
      & $add @{
        id = 'modelo'; title = 'Usas el modelo más caro para consultas rápidas'
        impactUnits = $null; severity = 'baja'
        what = "El $(PctTxt $top.pct)% de tu consumo fue con $($top.model). $(F0 $short.Count) sesiones fueron consultas cortas, de seis llamadas o menos, donde Sonnet suele bastar."
        evidence = @($short | Select-Object -First 5 | ForEach-Object {
            $v = if ($_.cost) { 'US' + [char]36 + ([double]$_.cost).ToString('0.00', $script:CI) } else { '' }
            New-Evidence (SessionName $_) "$($_.calls) $(if ($_.calls -eq 1) { 'llamada' } else { 'llamadas' })" $v })
        actions = @(
          'Para preguntas puntuales, explicaciones o cambios chicos, empieza la sesión con /model sonnet.',
          'Deja Opus para diseño, depuración difícil o cambios grandes en varios archivos.')
      }
    }
  }

  # 10. Esfuerzo alto como opción por defecto
  if ($profile.highEffortPct -ge 20) {
    $topE = @($sessions | ForEach-Object { @{ s = $_; n = ([double]$_.efforts['xhigh'] + [double]$_.efforts['max']) } } | Where-Object { $_.n -gt 0 } | Sort-Object -Property @{ Expression = { $_.n }; Descending = $true })
    & $add @{
      id = 'esfuerzo'; title = 'Usas esfuerzo alto con mucha frecuencia'
      impactUnits = $null; severity = $(if ($profile.highEffortPct -ge 50) { 'media' } else { 'baja' })
      what = "El $(PctTxt $profile.highEffortPct)% de tus llamadas usó esfuerzo xhigh o max. Más esfuerzo significa más razonamiento por respuesta: más tokens de salida y respuestas más lentas, algo que solo compensa en problemas difíciles."
      evidence = @($topE | Select-Object -First 5 | ForEach-Object { New-Evidence (SessionName $_.s) "$(F0 $_.s.calls) llamadas en total" "$(F0 $_.n) con esfuerzo alto" })
      actions = @(
        'Deja medium o high como esfuerzo por defecto y sube a xhigh solo para depuración difícil, diseño o cambios grandes.',
        'Si cambias el esfuerzo para una tarea puntual, vuelve a bajarlo al terminarla.')
    }
  }

  $order = @{ alta = 0; media = 1; baja = 2 }
  $sortedFindings = @($findings | Sort-Object -Property @{ Expression = { $order[$_.severity] } }, @{ Expression = { if ($_.impactUnits) { $_.impactUnits } else { 0 } }; Descending = $true })

  # ---------- Lo que haces bien ----------
  $strengths = New-Object System.Collections.Generic.List[string]
  if ($Tot.cacheHitRate -ge 0.85) { $strengths.Add("Aprovechas bien la caché: el $(PctTxt ($Tot.cacheHitRate * 100))% de tu contexto se leyó desde ahí, a una décima parte del precio normal.") }
  $clears = 0; foreach ($s in $sessions) { $clears += [int]$s.commands['clear'] + [int]$s.commands['compact'] }
  if ($clears -ge 3) { $strengths.Add("Usas /clear o /compact ($(Veces $clears)) para mantener tus sesiones livianas.") }
  $ids = @($sortedFindings | ForEach-Object { $_.id })
  if ($Tot.prompts -ge 10 -and $ids -notcontains 'correcciones') { $strengths.Add('Corriges poco: tus pedidos suelen salir bien a la primera.') }
  if ($ids -notcontains 'dependencias') { $strengths.Add('Tus búsquedas no recorren dependencias ni carpetas generadas.') }
  if ($Tot.subCalls -ge 20) { $strengths.Add("Delegas trabajo a subagentes ($(F0 $Tot.subCalls) llamadas), lo que mantiene limpio tu contexto principal.") }

  return @{
    generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); days = $days; from = $(if ($from) { $from } else { $null }); claudeDir = $claudeDir; files = $files
    totals = $Tot; categories = $categories; findings = $sortedFindings; strengths = $strengths.ToArray(); profile = $profile
    byDay = $byDay; byProject = $byProject; byModel = $byModel; tools = $tools
  }
}
