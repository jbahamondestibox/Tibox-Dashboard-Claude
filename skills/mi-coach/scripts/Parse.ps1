# Lee las transcripciones locales de Claude Code (~/.claude/projects/**/*.jsonl)
# y las convierte en sesiones con métricas. Todo ocurre en el equipo del usuario.

Add-Type -AssemblyName System.Web.Extensions
$script:JS = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:JS.MaxJsonLength = [int]::MaxValue
$script:JS.RecursionLimit = 1000

# Pesos de costo relativos al precio de input (iguales para todos los modelos Claude).
$script:W = @{ input = 1.0; cacheWrite5m = 1.25; cacheWrite1h = 2.0; cacheRead = 0.1; output = 5.0 }

function EstTokens([double]$chars) { return [math]::Round($chars / 4) }

function Get-ClaudeDir([string]$custom) {
  if ($custom) { return $custom }
  if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
  return (Join-Path $env:USERPROFILE '.claude')
}

function Find-Transcripts([string]$claudeDir) {
  $out = New-Object System.Collections.Generic.List[string]
  $walk = {
    param($dir, $depth)
    try { $entries = [IO.Directory]::GetFileSystemEntries($dir) } catch { return }
    foreach ($p in $entries) {
      $name = [IO.Path]::GetFileName($p)
      if ([IO.Directory]::Exists($p)) {
        if ($depth -lt 4 -and $name -ne 'memory' -and $name -ne 'tool-results') { & $walk $p ($depth + 1) }
      } elseif ($name.EndsWith('.jsonl')) { $out.Add($p) }
    }
  }
  & $walk (Join-Path $claudeDir 'projects') 0
  return , $out
}

# Líneas que no aportan métricas y pueden ser enormes: se saltan sin parsear.
$script:SkipPrefixes = @('{"type":"api-request', '{"type":"file-history', '{"type":"queue-operation',
  '{"type":"last-prompt"', '{"type":"agent-name"', '{"type":"mode"', '{"type":"atis-latch"')

function ContentChars($c) {
  if ($null -eq $c) { return 0 }
  if ($c -is [string]) { return $c.Length }
  if ($c -is [array]) {
    $n = 0
    foreach ($b in $c) {
      if ($null -eq $b) { continue }
      if ($b.type -eq 'text') { $n += ([string]$b.text).Length }
      elseif ($b.type -eq 'image') { $n += 6000 } # ~1.500 tokens por imagen
      else { $n += $script:JS.Serialize($b).Length }
    }
    return $n
  }
  return $script:JS.Serialize($c).Length
}

function ContentText($c) {
  if ($c -is [string]) { return $c }
  if ($c -is [array]) { return (($c | Where-Object { $null -ne $_ -and $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n") }
  return ''
}

$script:UuidRe = '^(?i)[0-9a-f]{8}-[0-9a-f-]{27}$'

function ToolCategory([string]$name) {
  if (-not $name) { return 'Herramienta: desconocida' }
  if ($name.StartsWith('mcp__')) {
    $parts = $name -split '__'
    $server = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $tool = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    # Los conectores de claude.ai aparecen con un UUID como nombre: se muestra la herramienta.
    if ($server -match $script:UuidRe) { return 'MCP: ' + $tool }
    return 'MCP: ' + ($server -replace '^claude_ai_', '')
  }
  if ($name -eq 'Agent' -or $name -eq 'Task') { return 'Subagentes (respuestas)' }
  return 'Herramienta: ' + $name
}

# Nombre legible de un servidor MCP. Los conectores de claude.ai llegan con un UUID: se usa la herramienta.
# Los servidores internos de la app de escritorio (ccd_*) no son elección del usuario y se omiten.
function McpName([string]$server, $tool) {
  if ($server -match '^ccd_') { return $null }
  if ($server -match $script:UuidRe) { if ($tool) { return ([string]$tool -replace '_[a-z]+$', '') } else { return 'conector' } }
  return ($server -replace '^claude_ai_', '')
}

function ToolLabel([string]$name, $inp) {
  if ($null -eq $inp -or $inp -isnot [System.Collections.IDictionary]) { if ($name) { return $name } else { return '' } }
  $s = { param($v) $t = ([string]$v) -replace '\s+', ' '; if ($t.Length -gt 140) { $t.Substring(0, 140) } else { $t } }
  switch ($name) {
    { $_ -in 'Read', 'Write', 'Edit', 'NotebookEdit' } { if ($inp.file_path) { return (& $s $inp.file_path) } else { return (& $s $inp.notebook_path) } }
    { $_ -in 'Bash', 'PowerShell' } { return (& $s $inp.command) }
    'Grep' {
      $t = '"' + $inp.pattern + '"'
      if ($inp.path) { $t += ' en ' + $inp.path }
      if ($inp.output_mode) { $t += ' (' + $inp.output_mode + ')' }
      return (& $s $t)
    }
    'Glob' { $t = [string]$inp.pattern; if ($inp.path) { $t += ' en ' + $inp.path }; return (& $s $t) }
    'WebFetch' { return (& $s $inp.url) }
    'WebSearch' { return (& $s $inp.query) }
    { $_ -in 'Agent', 'Task' } { if ($inp.description) { return (& $s $inp.description) } else { return (& $s $inp.prompt) } }
    default {
      $vals = @($inp.Values | Where-Object { $_ -is [string] })
      $t = & $s ($vals -join ' · ')
      if ($t) { return $t } else { return $name }
    }
  }
}

$script:CorrectionRe = '(?i)^\s*(no[,.!]|no no|nop\b|eso no|no es as[ií]|no es eso|no era eso|no lo que|sigue (sin|igual|fallando|mal)|todav[ií]a (no|falla|sale)|otra vez|de nuevo|no funciona|no sirve|no era|est[aá] mal|te equivocaste|revierte|deshaz|vuelve a|wrong|that''s not|still (not|broken|failing)|undo)'
$script:DepsRe = '(node_modules[\\/]|(^|[\\/])\.?venv[\\/]|site-packages[\\/]|(^|[\\/])dist[\\/]|[\\/]bin[\\/](Debug|Release)|(^|[\\/])obj[\\/]|(^|[\\/])\.git[\\/]|__pycache__[\\/]|(^|[\\/])build[\\/])'

# ¿El resultado es mayormente rutas dentro de dependencias o carpetas generadas?
function LooksLikeDeps([string]$text) {
  if ($text.Length -gt 40000) { $text = $text.Substring(0, 40000) }
  $lines = @($text -split "\r?\n" | Where-Object { $_.Trim() })
  if ($lines.Count -lt 5) { return $false }
  $hits = @($lines | Where-Object { $_ -match $script:DepsRe }).Count
  return ($hits -ge 5 -and ($hits / $lines.Count) -ge 0.2)
}

function New-FileState([string]$file) {
  return @{
    file = $file; isSubagentFile = ($file -match '[\\/]subagents[\\/]')
    sessionId = $null; cwd = $null; title = $null; entrypoint = $null; version = $null
    start = $null; end = $null
    calls = (New-Object System.Collections.Generic.List[object])     # llamadas del hilo principal
    subCalls = (New-Object System.Collections.Generic.List[object])  # llamadas de subagentes
    callIds = @{}
    items = (New-Object System.Collections.Generic.List[object])     # contenido que entra al contexto del hilo principal
    toolUses = @{}
    toolResults = (New-Object System.Collections.Generic.List[object])
    prompts = (New-Object System.Collections.Generic.List[object])
    commands = @{}
    cost = 0.0; linesAdded = 0; linesRemoved = 0
    compactions = 0; interrupts = 0; apiErrors = 0
    firstPromptTokens = $null
    apiMs = 0.0; toolMs = 0.0; wallMs = 0.0  # tiempos registrados por Claude Code (cost-state)
    permissionModes = @{}
  }
}

function Add-Item($st, [bool]$side, [string]$category, [double]$tokens, $extra) {
  if ($side -or $tokens -le 0) { return $null }
  $it = @{ category = $category; tokens = $tokens; at = $st.calls.Count; end = $null; units = 0.0; remaining = 0 }
  if ($extra) { foreach ($k in $extra.Keys) { $it[$k] = $extra[$k] } }
  $st.items.Add($it)
  return $it
}

function Set-Compaction($st) {
  $st.compactions++
  foreach ($it in $st.items) { if ($null -eq $it.end) { $it.end = $st.calls.Count } }
}

function Invoke-UserText($st, $o, [bool]$side, [string]$t) {
  if (-not $t) { return }
  if ($t.StartsWith('[Request interrupted')) { if (-not $side) { $st.interrupts++ }; return }
  if ($t -match '<command-name>/?([^<]+)</command-name>') {
    $cmd = $Matches[1]
    if ($st.commands.ContainsKey($cmd)) { $st.commands[$cmd]++ } else { $st.commands[$cmd] = 1 }
    [void](Add-Item $st $side 'Comandos y su salida' (EstTokens $t.Length) $null); return
  }
  if ($t.StartsWith('<local-command') -or $t.StartsWith('<bash-')) { [void](Add-Item $st $side 'Comandos y su salida' (EstTokens $t.Length) $null); return }
  if ($o.isMeta) { [void](Add-Item $st $side 'Instrucciones inyectadas (skills, hooks)' (EstTokens $t.Length) $null); return }
  if ($side) { return }
  $tokens = EstTokens $t.Length
  $clean = ([regex]::Replace($t, '<pasted_content[^>]*>[\s\S]*?</pasted_content>', '[pegado]')).Trim()
  $it = Add-Item $st $side 'Tus mensajes' $tokens $null
  $st.prompts.Add(@{
    ts = $o.timestamp; tokens = $tokens; text = $(if ($clean.Length -gt 160) { $clean.Substring(0, 160) } else { $clean })
    pasted = ($t -match '<pasted_content'); correction = ($clean -match $script:CorrectionRe); item = $it
  })
  if ($null -eq $st.firstPromptTokens) { $st.firstPromptTokens = $tokens }
}

function Invoke-Record($st, $o) {
  if ($o.sessionId -and -not $st.sessionId) { $st.sessionId = $o.sessionId }
  if ($o.cwd -and -not $st.cwd) { $st.cwd = $o.cwd }
  if ($o.entrypoint -and -not $st.entrypoint) { $st.entrypoint = $o.entrypoint }
  if ($o.version) { $st.version = $o.version }
  $ts = $o.timestamp
  if ($ts) {
    if (-not $st.start -or [string]::CompareOrdinal($ts, $st.start) -lt 0) { $st.start = $ts }
    if (-not $st.end -or [string]::CompareOrdinal($ts, $st.end) -gt 0) { $st.end = $ts }
  }
  $side = [bool]$o.isSidechain -or $st.isSubagentFile

  switch ($o.type) {
    'custom-title' { if ($o.customTitle) { $st.title = $o.customTitle }; return }
    'summary' { if ($o.summary -and -not $st.title) { $st.title = $o.summary }; return }
    'cost-state' {
      if ($null -ne $o.totalCostUSD -and [double]$o.totalCostUSD -gt $st.cost) { $st.cost = [double]$o.totalCostUSD }
      if ([double]$o.totalLinesAdded -gt $st.linesAdded) { $st.linesAdded = [double]$o.totalLinesAdded }
      if ([double]$o.totalLinesRemoved -gt $st.linesRemoved) { $st.linesRemoved = [double]$o.totalLinesRemoved }
      if ([double]$o.totalAPIDuration -gt $st.apiMs) { $st.apiMs = [double]$o.totalAPIDuration }
      if ([double]$o.totalToolDuration -gt $st.toolMs) { $st.toolMs = [double]$o.totalToolDuration }
      if ([double]$o.totalDuration -gt $st.wallMs) { $st.wallMs = [double]$o.totalDuration }
      return
    }
    'system' {
      if ($o.subtype -and $o.subtype -match '(?i)compact') { Set-Compaction $st }
      if ($o.subtype -eq 'api_error') { $st.apiErrors++ }
      return
    }
    'assistant' {
      $msg = $o.message
      if ($null -eq $msg -or -not $msg.model -or $msg.model -eq '<synthetic>') { return }
      $u = $msg.usage
      $call = if ($msg.id) { $st.callIds[$msg.id] } else { $null }
      if ($null -eq $call -and $null -ne $u) {
        $cc = $u.cache_creation
        $od = $u.output_tokens_details
        $call = @{
          ts = $ts; model = $msg.model; effort = $o.effort
          input = [double]$u.input_tokens
          cacheCreate = [double]$u.cache_creation_input_tokens
          cc1h = $(if ($cc) { [double]$cc.ephemeral_1h_input_tokens } else { 0.0 })
          cacheRead = [double]$u.cache_read_input_tokens
          output = [double]$u.output_tokens
          thinking = $(if ($od) { [double]$od.thinking_tokens } else { 0.0 })
          side = $side
          skill = $o.attributionSkill
          mcp = $(if ($o.attributionMcpServer) { McpName $o.attributionMcpServer $o.attributionMcpTool } else { $null })
        }
        if ($msg.id) { $st.callIds[$msg.id] = $call }
        if ($side) { $st.subCalls.Add($call) } else { $st.calls.Add($call) }
      } elseif ($null -ne $call -and $null -ne $u -and [double]$u.output_tokens -gt $call.output) {
        $call.output = [double]$u.output_tokens
      }
      if ($msg.content -is [array]) {
        foreach ($b in $msg.content) {
          if ($null -eq $b) { continue }
          if ($b.type -eq 'tool_use') {
            $st.toolUses[$b.id] = @{ name = $b.name; input = $b.input; side = $side }
            $cat = if ($b.name -in 'Write', 'Edit', 'NotebookEdit') { 'Código escrito por Claude (Write/Edit)' } else { ToolCategory $b.name }
            $inpLen = if ($null -ne $b.input) { $script:JS.Serialize($b.input).Length } else { 2 }
            [void](Add-Item $st $side $cat ((EstTokens $inpLen) + 20) @{ kind = 'toolInput'; tool = $b.name })
          } elseif ($b.type -eq 'text') {
            [void](Add-Item $st $side 'Respuestas de Claude (texto)' (EstTokens ([string]$b.text).Length) $null)
          }
        }
      }
      return
    }
    'user' {
      # Ojo: asignar desde un "if" desarma los arreglos de un elemento; por eso se asigna directo.
      $c = $null; if ($null -ne $o.message) { $c = $o.message.content }
      if (-not $side -and $o.permissionMode -and $o.turnOrigin -eq 'human') {
        $pm = $o.permissionMode
        if ($st.permissionModes.ContainsKey($pm)) { $st.permissionModes[$pm]++ } else { $st.permissionModes[$pm] = 1 }
      }
      if ($o.isCompactSummary) {
        Set-Compaction $st
        [void](Add-Item $st $side 'Resúmenes de compactación' (EstTokens (ContentChars $c)) $null)
        return
      }
      if ($c -is [string]) { Invoke-UserText $st $o $side $c; return }
      if ($c -isnot [array]) { return }
      foreach ($b in $c) {
        if ($null -eq $b) { continue }
        if ($b.type -eq 'tool_result') {
          $tu = $st.toolUses[$b.tool_use_id]
          $toolName = if ($tu) { $tu.name } else { $null }
          $tin = if ($tu) { $tu.input } else { $null }
          $tokens = EstTokens (ContentChars $b.content)
          $text = if ($b.content -is [string]) { $b.content } else { ContentText $b.content }
          $r = @{
            tool = $(if ($toolName) { $toolName } else { 'desconocida' }); category = (ToolCategory $toolName); label = (ToolLabel $toolName $tin)
            tokens = $tokens; isError = [bool]$b.is_error; side = $side; ts = $ts
            deps = (($toolName -in 'Glob', 'Grep', 'Bash', 'PowerShell', 'LS') -and (LooksLikeDeps $text))
            filePath = $(if ($toolName -eq 'Read' -and $tin) { $tin.file_path } else { $null })
          }
          $r.item = Add-Item $st $side $r.category $tokens @{ kind = 'toolResult' }
          $st.toolResults.Add($r)
        } elseif ($b.type -eq 'text') { Invoke-UserText $st $o $side ([string]$b.text) }
        elseif ($b.type -eq 'image') { [void](Add-Item $st $side 'Tus mensajes' 1500 $null) }
      }
      return
    }
    'attachment' {
      $a = $o.attachment
      if ($null -eq $a) { return }
      # Adjuntos que sí terminan en el contexto con contenido relevante
      if ($a.type -in 'file', 'edited_text_file', 'instructions', 'hook_additional_context') {
        $chars = 0
        if ($o.rendered -is [array]) { foreach ($x in $o.rendered) { if ($x) { $chars += ContentChars $x.content } } } else { $chars = ContentChars $a.content }
        $cat = switch ($a.type) { 'instructions' { 'CLAUDE.md e instrucciones' } 'edited_text_file' { 'Avisos de archivos editados' } 'file' { 'Archivos adjuntos (@archivo)' } default { 'Instrucciones inyectadas (skills, hooks)' } }
        [void](Add-Item $st $side $cat (EstTokens $chars) $null)
      }
      return
    }
  }
}

function Read-TranscriptFile([string]$file) {
  $st = New-FileState $file
  $reader = New-Object IO.StreamReader($file, [Text.Encoding]::UTF8)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if ($line.Length -lt 2) { continue }
      $skip = $false
      foreach ($p in $script:SkipPrefixes) { if ($line.StartsWith($p)) { $skip = $true; break } }
      if ($skip) { continue }
      try { $o = $script:JS.DeserializeObject($line) } catch { continue }
      if ($o -isnot [System.Collections.IDictionary]) { continue }
      Invoke-Record $st $o
    }
  } finally { $reader.Close() }
  return $st
}

function CallUnits($c, [double]$cw) {
  return $c.input * $script:W.input + $c.cacheCreate * $cw + $c.cacheRead * $script:W.cacheRead + $c.output * $script:W.output
}

function Sum-Calls($arr) {
  $t = @{ input = 0.0; cacheCreate = 0.0; cacheRead = 0.0; output = 0.0; thinking = 0.0; cc1h = 0.0 }
  foreach ($c in $arr) { foreach ($k in @('input', 'cacheCreate', 'cacheRead', 'output', 'thinking', 'cc1h')) { $t[$k] += $c[$k] } }
  return $t
}

function Add-To($map, $key, [double]$v) { if ($map.ContainsKey($key)) { $map[$key] += $v } else { $map[$key] = $v } }

# Convierte el estado crudo de un archivo en una sesión con métricas calculadas.
function Complete-Session($st) {
  $W = $script:W
  $main = Sum-Calls $st.calls
  $sub = Sum-Calls $st.subCalls
  $N = $st.calls.Count
  $cwRatio = if ($main.cacheCreate -gt 0) { $main.cc1h / $main.cacheCreate } else { 0.5 }
  $cw = $W.cacheWrite5m + ($W.cacheWrite1h - $W.cacheWrite5m) * $cwRatio

  $ctx = New-Object 'System.Collections.Generic.List[double]'
  foreach ($c in $st.calls) { $ctx.Add($c.input + $c.cacheCreate + $c.cacheRead) }
  $unitsOf = { param($t) $t.input * $W.input + $t.cacheCreate * $cw + $t.cacheRead * $W.cacheRead + $t.output * $W.output }
  $totalUnits = (& $unitsOf $main) + (& $unitsOf $sub)
  $pricePerUnit = if ($st.cost -gt 0 -and $totalUnits -gt 0) { $st.cost / $totalUnits } else { $null }

  # Peso de cada item: se escribe una vez en caché y se relee en cada llamada siguiente.
  foreach ($it in $st.items) {
    $end = if ($null -eq $it.end) { $N } else { $it.end }
    $it.remaining = [math]::Max(0, $end - $it.at)
    $it.units = if ($it.remaining -gt 0) { $it.tokens * ($cw + $W.cacheRead * ($it.remaining - 1)) } else { 0.0 }
  }
  $fp = if ($st.firstPromptTokens) { $st.firstPromptTokens } else { 0 }
  $baseline = if ($N -gt 0) { [math]::Max(0, $ctx[0] - $fp) } else { 0 }
  $categories = @{}
  $categories['Contexto base'] = if ($N -gt 0) { $baseline * ($cw + $W.cacheRead * ($N - 1)) } else { 0.0 }
  foreach ($it in $st.items) { Add-To $categories $it.category $it.units }

  # Escalar las estimaciones al consumo real de contexto del hilo principal
  $realCtxUnits = $main.input * $W.input + $main.cacheCreate * $cw + $main.cacheRead * $W.cacheRead
  $estCtxUnits = 0.0; foreach ($v in $categories.Values) { $estCtxUnits += $v }
  $scale = if ($estCtxUnits -gt 0) { $realCtxUnits / $estCtxUnits } else { 0 }
  foreach ($k in @($categories.Keys)) { $categories[$k] *= $scale }
  foreach ($it in $st.items) { $it.units *= $scale }
  $categories['Generación de Claude'] = $main.output * $W.output
  if ($st.subCalls.Count) { $categories['Subagentes (trabajo interno)'] = & $unitsOf $sub }

  # Reanudaciones en frío: pausas largas que obligan a reescribir la caché
  $coldResumes = New-Object System.Collections.Generic.List[object]
  for ($i = 1; $i -lt $st.calls.Count; $i++) {
    $a = $st.calls[$i - 1]; $b = $st.calls[$i]
    $c = $ctx[$i]
    if ($b.cacheCreate -gt 20000 -and $c -gt 0 -and ($b.cacheCreate / $c) -gt 0.5) {
      $gapMin = 0
      try { $gapMin = ([DateTime]::Parse($b.ts) - [DateTime]::Parse($a.ts)).TotalMinutes } catch {}
      $h = [math]::Round($gapMin / 60)
      $pausa = if ($gapMin -ge 90) { "pausa de $h $(if ($h -eq 1) { 'hora' } else { 'horas' })" } else { "pausa de $([math]::Round($gapMin)) minutos" }
      $reason = if ($a.model -ne $b.model) { 'cambio de modelo' } elseif ($gapMin -gt 5) { $pausa } else { 'caché invalidada' }
      $coldResumes.Add(@{ ts = $b.ts; tokens = $b.cacheCreate; gapMin = [math]::Round($gapMin); reason = $reason; units = $b.cacheCreate * ($cw - $W.cacheRead) })
    }
  }

  $models = @{}; $byDay = @{}; $efforts = @{}; $effortUnits = @{}; $skillUnits = @{}; $mcpUnits = @{}
  $hours = New-Object 'double[]' 24
  $allCalls = New-Object System.Collections.Generic.List[object]
  $allCalls.AddRange($st.calls); $allCalls.AddRange($st.subCalls)
  foreach ($c in $allCalls) {
    $u = CallUnits $c $cw
    $tokens = $c.input + $c.cacheCreate + $c.cacheRead + $c.output
    if (-not $models.ContainsKey($c.model)) { $models[$c.model] = @{ calls = 0; tokens = 0.0; units = 0.0 } }
    $m = $models[$c.model]; $m.calls++; $m.tokens += $tokens; $m.units += $u
    if ($c.ts) {
      $d = $c.ts.Substring(0, 10)
      if (-not $byDay.ContainsKey($d)) { $byDay[$d] = @{ tokens = 0.0; units = 0.0 } }
      $byDay[$d].tokens += $tokens; $byDay[$d].units += $u
      try { $hours[[DateTime]::Parse($c.ts).Hour]++ } catch {}
    }
    if ($c.effort) { Add-To $effortUnits $c.effort $u; if (-not $c.side) { Add-To $efforts $c.effort 1 } }
    if ($c.skill) { Add-To $skillUnits $c.skill $u }
    if ($c.mcp) { Add-To $mcpUnits $c.mcp $u }
  }

  $prompts = New-Object System.Collections.Generic.List[object]
  foreach ($p in $st.prompts) {
    $q = $p.Clone(); $q.Remove('item')
    $q.units = if ($p.item) { $p.item.units } else { 0.0 }; $q.remaining = if ($p.item) { $p.item.remaining } else { 0 }
    $prompts.Add($q)
  }
  $toolResults = New-Object System.Collections.Generic.List[object]
  foreach ($r in $st.toolResults) {
    $q = $r.Clone(); $q.Remove('item')
    $q.units = if ($r.item) { $r.item.units } else { 0.0 }; $q.remaining = if ($r.item) { $r.item.remaining } else { 0 }
    $toolResults.Add($q)
  }
  $maxC = 0.0; $sumC = 0.0; foreach ($v in $ctx) { if ($v -gt $maxC) { $maxC = $v }; $sumC += $v }

  return @{
    id = $st.sessionId; file = $st.file; title = $st.title; cwd = $st.cwd
    project = $(if ($st.cwd) { [IO.Path]::GetFileName($st.cwd.TrimEnd('\', '/')) } else { '(desconocido)' })
    entrypoint = $st.entrypoint; version = $st.version; start = $st.start; end = $st.end
    calls = $N; subCalls = $st.subCalls.Count; main = $main; sub = $sub; cw = $cw
    totalTokens = $main.input + $main.cacheCreate + $main.cacheRead + $main.output + $sub.input + $sub.cacheCreate + $sub.cacheRead + $sub.output
    totalUnits = $totalUnits; pricePerUnit = $pricePerUnit; cost = $st.cost; linesAdded = $st.linesAdded; linesRemoved = $st.linesRemoved
    ctx = $ctx; maxContext = $maxC; avgContext = $(if ($ctx.Count) { $sumC / $ctx.Count } else { 0 })
    baseline = $baseline; categories = $categories; coldResumes = $coldResumes; models = $models; byDay = $byDay
    efforts = $efforts; effortUnits = $effortUnits; skillUnits = $skillUnits; mcpUnits = $mcpUnits; hours = $hours
    apiMs = $st.apiMs; toolMs = $st.toolMs; wallMs = $st.wallMs; permissionModes = $st.permissionModes
    prompts = $prompts; toolResults = $toolResults
    commands = $st.commands; compactions = $st.compactions; interrupts = $st.interrupts; apiErrors = $st.apiErrors
  }
}

function Read-Sessions([string]$claudeDir, [scriptblock]$onProgress) {
  $files = Find-Transcripts $claudeDir
  $states = New-Object System.Collections.Generic.List[object]
  $i = 0
  foreach ($f in $files) {
    $states.Add((Read-TranscriptFile $f))
    $i++; if ($onProgress) { & $onProgress $i $files.Count }
  }
  # Agrupar por sessionId: los archivos de subagentes se suman a su sesión; las copias duplicadas se descartan.
  $byId = [ordered]@{}
  foreach ($st in $states) {
    if (-not $st.sessionId) { continue }
    $isSub = $st.isSubagentFile -or ($st.calls.Count -eq 0 -and $st.subCalls.Count -gt 0)
    if (-not $byId.Contains($st.sessionId)) { $byId[$st.sessionId] = @{ main = $null; subs = (New-Object System.Collections.Generic.List[object]) } }
    $cur = $byId[$st.sessionId]
    if ($isSub) { $cur.subs.Add($st) }
    elseif (-not $cur.main -or $st.calls.Count -gt $cur.main.calls.Count) { $cur.main = $st }
  }
  $sessions = New-Object System.Collections.Generic.List[object]
  foreach ($g in $byId.Values) {
    $st = if ($g.main) { $g.main } elseif ($g.subs.Count) { $g.subs[0] } else { $null }
    if (-not $st) { continue }
    if ($g.main) {
      foreach ($s in $g.subs) {
        foreach ($c in $s.subCalls) { $st.subCalls.Add($c) }
        foreach ($c in $s.calls) { $x = $c.Clone(); $x.side = $true; $st.subCalls.Add($x) }
      }
    }
    if ($st.calls.Count + $st.subCalls.Count -eq 0) { continue }
    $sessions.Add((Complete-Session $st))
  }
  $sorted = @($sessions | Sort-Object -Property @{ Expression = { [string]$_.end }; Descending = $true })
  return @{ sessions = $sorted; files = $files.Count }
}
