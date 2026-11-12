<#
.SYNOPSIS
  tibox-coach: tu coach personal de Claude Code. Analiza tus sesiones locales y genera un informe en PDF.

.DESCRIPTION
  Solo lee archivos de tu equipo (~/.claude/projects/**/*.jsonl y el tamaño de tus CLAUDE.md).
  No se conecta a internet ni envía datos a ningún lado. Usa solo PowerShell y Microsoft Edge,
  que vienen con Windows.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tibox-coach.ps1
  powershell -ExecutionPolicy Bypass -File tibox-coach.ps1 -Days 7 -Out C:\temp\informe.pdf
#>
param(
  [int]$Days = 30,           # Período a analizar en días (0 = todo)
  [string]$Out,              # Ruta del PDF (por defecto en Documentos)
  [string]$Dir,              # Carpeta de Claude Code (por defecto ~/.claude o CLAUDE_CONFIG_DIR)
  [switch]$NoOpen,           # No abrir el PDF al terminar
  [switch]$Json              # Imprimir el reporte en JSON en vez de generar el PDF
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'Parse.ps1')
. (Join-Path $PSScriptRoot 'Analyze.ps1')
. (Join-Path $PSScriptRoot 'Report.ps1')

$claudeDir = Get-ClaudeDir $Dir
if (-not (Test-Path -LiteralPath (Join-Path $claudeDir 'projects'))) {
  Write-Error "No encontré sesiones de Claude Code en $(Join-Path $claudeDir 'projects'). Usa -Dir para indicar otra carpeta."
  exit 1
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$data = Read-Sessions $claudeDir { param($i, $n) if (-not $Json) { Write-Progress -Activity 'Analizando tus sesiones de Claude Code' -Status "$i de $n archivos" -PercentComplete ([math]::Min(100, $i * 100 / [math]::Max(1, $n))) } }
Write-Progress -Activity 'Analizando tus sesiones de Claude Code' -Completed
$report = Build-Report $data.sessions $Days $claudeDir $data.files

if ($Json) {
  $report | ConvertTo-Json -Depth 8 -Compress
  exit 0
}
Write-Host "$($data.sessions.Count) sesiones leídas en $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s."

if (-not $Out) {
  $docs = [Environment]::GetFolderPath('MyDocuments')
  if (-not $docs -or -not (Test-Path -LiteralPath $docs)) { $docs = (Get-Location).Path }
  $Out = Join-Path $docs ('tibox-coach-' + (Get-Date -Format 'yyyy-MM-dd') + '.pdf')
}
$res = Write-ReportPdf $report $Out
if ($res.pdf) {
  Write-Host "Tu informe está en $($res.pdf)"
  # Resumen breve para que Claude lo comente sin leer el informe completo
  $t = $report.totals
  Write-Host ''
  Write-Host "RESUMEN ($Days días): costo $(Money $t.cost) · $($t.sessions) sesiones · $($t.prompts) mensajes · contexto promedio $(Tok $t.avgContext) tokens · caché $(PctTxt ($t.cacheHitRate * 100))%"
  foreach ($f in @($report.findings | Select-Object -First 3)) {
    $imp = if ($f.impactUsd -gt 0.05) { " ($(Money $f.impactUsd), $(PctTxt $f.pct)% del consumo)" } else { '' }
    Write-Host "MEJORA [$($f.severity)] $($f.title)$imp -> $($f.actions[0])"
  }
  foreach ($s in $report.strengths) { Write-Host "BIEN: $s" }
  if (-not $NoOpen) { Invoke-Item -LiteralPath $res.pdf }
} else {
  Write-Host $res.reason
  Write-Host "HTML del informe: $($res.html)"
  exit 1
}
