// Genera el informe en PDF: arma un HTML autocontenido (gráficos en SVG, sin internet)
// y lo imprime con Edge o Chrome en modo headless, que ya vienen instalados en el equipo.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { tok } from './analyze.js';

const C = { blue: '#2a78d6', orange: '#eb6834', aqua: '#1baf7a', yellow: '#eda100', magenta: '#e87ba4', violet: '#6250d6', gray: '#b4b2a9', red: '#d03b3b', amber: '#c98500', green: '#0c8a0c' };
const SERIES = [C.blue, C.orange, C.aqua, C.yellow, C.magenta, C.violet];

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const nf0 = new Intl.NumberFormat('es-CL', { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat('es-CL', { maximumFractionDigits: 1 });
const money = (v) => (v == null ? '—' : v >= 100 ? `US$${nf0.format(v)}` : `US$${nf1.format(v)}`);
const pctTxt = (p) => (p < 1 ? '<1%' : `${nf0.format(p)}%`);
const fechaLarga = (d) => new Date(d).toLocaleDateString('es-CL', { day: 'numeric', month: 'short', year: 'numeric' });

// Nombres cortos para las categorías del costo
function shortCat(name) {
  return name
    .replace('Herramienta: Read', 'Archivos leídos')
    .replace('Generación de Claude', 'Respuestas generadas')
    .replace('Código escrito por Claude (Write/Edit)', 'Código escrito')
    .replace('Respuestas de Claude (texto)', 'Texto de Claude')
    .replace(/^Herramienta: (Bash|PowerShell)$/, 'Comandos')
    .replace(/^Herramienta: (Grep|Glob)$/, 'Búsquedas')
    .replace(/^Herramienta: /, '')
    .replace('Subagentes (trabajo interno)', 'Subagentes');
}

function costSegments(categories) {
  const m = new Map();
  for (const c of categories) { const k = shortCat(c.name); m.set(k, (m.get(k) || 0) + c.pct); }
  const all = [...m.entries()].map(([name, pct]) => ({ name, pct })).sort((a, b) => b.pct - a.pct);
  const top = all.slice(0, 5);
  const rest = all.slice(5).reduce((a, x) => a + x.pct, 0);
  if (rest > 0.5) top.push({ name: 'Otros', pct: rest, other: true });
  return top;
}

function stackedBar(segs) {
  const total = segs.reduce((a, s) => a + s.pct, 0) || 1;
  const bar = segs.map((s, i) => `<div style="width:${(s.pct / total) * 100}%;background:${s.other ? C.gray : SERIES[i]}"></div>`).join('');
  const lg = segs.map((s, i) => `<span><i style="background:${s.other ? C.gray : SERIES[i]}"></i>${esc(s.name)} <b>${pctTxt(s.pct)}</b></span>`).join('');
  return `<div class="stack">${bar}</div><div class="legend">${lg}</div>`;
}

// Barras verticales en SVG (consumo diario, actividad por hora)
function columns(values, labels, { w = 440, h = 120, color = C.blue, fmt = (v) => nf0.format(v), every = 1 } = {}) {
  const n = values.length || 1, max = Math.max(...values, 0) || 1;
  const pad = 18, bw = Math.min(16, (w / n) * 0.7), step = w / n;
  let s = `<svg viewBox="0 0 ${w} ${h + pad}" width="100%" height="${h + pad}" preserveAspectRatio="none" role="img">`;
  s += `<line x1="0" x2="${w}" y1="${h}" y2="${h}" stroke="#c3c2b7" stroke-width="1"/>`;
  values.forEach((v, i) => {
    const bh = (v / max) * (h - 14), x = i * step + (step - bw) / 2, y = h - bh;
    if (v > 0) s += `<rect x="${x}" y="${y}" width="${bw}" height="${bh}" rx="2" fill="${color}"><title>${esc(labels[i])}: ${fmt(v)}</title></rect>`;
    if (i % every === 0) s += `<text x="${i * step + step / 2}" y="${h + 13}" font-size="8" text-anchor="middle" fill="#898781">${esc(labels[i])}</text>`;
  });
  const iMax = values.indexOf(max);
  s += `<text x="${iMax * step + step / 2}" y="${h - (h - 14) - 3}" font-size="8.5" text-anchor="middle" fill="#52514e">${fmt(max)}</text>`;
  return s + '</svg>';
}

// Barras horizontales con valor (modelos, proyectos, skills, MCP)
function hbars(rows, { color = C.blue, value = (r) => pctTxt(r.pct), width = (r) => r.pct } = {}) {
  if (!rows.length) return '<p class="muted">Sin datos en el período.</p>';
  const max = Math.max(...rows.map(width), 1);
  return `<div class="hbars">${rows.map((r) => `<div class="hb"><span class="hb-l">${esc(r.name)}</span><span class="hb-t"><span style="width:${(width(r) / max) * 100}%;background:${color}"></span></span><span class="hb-v">${value(r)}</span></div>`).join('')}</div>`;
}

function kpi(label, value, sub) {
  return `<div class="kpi"><p class="kl">${esc(label)}</p><p class="kv">${esc(value)}</p><p class="ks">${esc(sub)}</p></div>`;
}

const SEV = { alta: ['#fcebeb', '#a32d2d'], media: ['#faeeda', '#854f0b'], baja: ['#eef0f3', '#52514e'] };
const pill = (sev) => `<span class="pill" style="background:${SEV[sev][0]};color:${SEV[sev][1]}">${sev}</span>`;

const MODE_NAMES = { default: 'Apruebas cada acción', acceptEdits: 'Ediciones automáticas', auto: 'Modo automático', plan: 'Modo plan', bypassPermissions: 'Sin permisos' };

// Lectura del perfil: frases cortas según los datos, cada una con su sugerencia.
function profileInsights(r) {
  const p = r.profile, T = r.totals, out = [];
  const peak = p.hours.indexOf(Math.max(...p.hours));
  if (Math.max(...p.hours) > 0) out.push(['ti-clock', `Tu hora de más actividad es entre las ${peak}:00 y las ${peak + 1}:00.`, 'Si haces pausas largas en medio de una sesión grande, al volver abre una sesión nueva con un resumen: la caché vence a la hora.']);
  out.push(['ti-messages', `Una sesión típica tuya tiene ${nf0.format(p.medianPrompts)} mensajes y ${nf0.format(p.medianCalls)} llamadas al modelo, y cuesta ${money(p.medianUsd)}.`, T.avgContext > 100000 ? `Tu contexto promedio es de ${tok(T.avgContext)} tokens: separar tareas en sesiones distintas es la mejora más directa.` : 'Mantienes sesiones de tamaño razonable.']);
  const manual = p.permissionModes.find((m) => m.name === 'default');
  if (manual && manual.pct >= 40) out.push(['ti-hand-stop', `En el ${pctTxt(manual.pct)} de tus mensajes apruebas cada acción a mano.`, 'Para tareas que ya entiendes, activar ediciones automáticas (Shift+Tab) te ahorra interrupciones sin perder control: igual revisas el resultado.']);
  else if (p.permissionModes.length) out.push(['ti-hand-stop', `Delegas bastante: en el ${pctTxt(100 - (manual ? manual.pct : 0))}% de tus mensajes Claude edita sin pedir permiso.`, 'Para cambios grandes, el modo plan (Shift+Tab) te deja revisar el enfoque antes de que toque código.']);
  if (p.highEffortPct >= 20) out.push(['ti-brain', `El ${pctTxt(p.highEffortPct)} de tus llamadas usa esfuerzo xhigh o max.`, 'Deja medium o high por defecto y sube solo para problemas difíciles.']);
  const opus = r.byModel.find((m) => /opus/i.test(m.model));
  if (opus && opus.pct > 70) out.push(['ti-cpu', `El ${pctTxt(opus.pct)} de tu consumo es con Opus.`, 'Para preguntas y cambios chicos, Sonnet responde igual de bien y más rápido.']);
  return out;
}

function findingBlock(f) {
  const ev = (f.evidence || []).slice(0, 4).map((e) => `<tr><td><b>${esc(e.label)}</b><br><span class="muted">${esc(e.detail)}</span></td><td class="num">${esc(e.value)}</td></tr>`).join('');
  return `<section class="finding">
    <div class="fh"><h3>${esc(f.title)}</h3><div class="fhr">${pill(f.severity)}${f.impactUsd != null && f.impactUsd > 0.05 ? `<span class="imp">${money(f.impactUsd)} · ${pctTxt(f.pct)}</span>` : ''}</div></div>
    <p>${esc(f.what)}</p>
    ${ev ? `<table class="ev">${ev}</table>` : ''}
    <p class="lbl">Qué hacer</p>
    <ul>${f.actions.map((a) => `<li>${esc(a)}</li>`).join('')}</ul>
  </section>`;
}

export function renderReportHtml(r) {
  const T = r.totals, p = r.profile;
  const findings = r.findings.filter((f) => f.severity !== 'baja' || (f.pct || 0) >= 0.5 || f.impactUnits == null);
  const top3 = findings.slice(0, 3);
  const from = r.from ? fechaLarga(r.from) : 'el inicio';
  const to = fechaLarga(r.generatedAt);
  const days = r.byDay.map((d) => d.usd || 0);
  const dayLabels = r.byDay.map((d) => `${d.day.slice(8, 10)}/${d.day.slice(5, 7)}`);
  const projects = r.byProject.slice(0, 5).map((x) => ({ name: x.project, pct: x.pct, usd: x.usd }));
  const models = r.byModel.filter((m) => m.pct >= 0.5).map((m) => ({ name: m.model.replace(/^claude-/, ''), pct: m.pct }));
  const extras = [...p.skills.map((s) => ({ ...s, name: `Skill: ${s.name}` })), ...p.mcps.map((s) => ({ ...s, name: `MCP: ${s.name}` }))].sort((a, b) => b.pct - a.pct).slice(0, 6);
  const insights = profileInsights(r);
  const hoursFrom = p.hours.findIndex((n) => n > 0), hoursTo = 23 - [...p.hours].reverse().findIndex((n) => n > 0);
  const hSlice = hoursFrom >= 0 ? p.hours.slice(Math.max(0, hoursFrom - 1), Math.min(24, hoursTo + 2)) : [];
  const hLabels = hSlice.map((_, i) => `${Math.max(0, hoursFrom - 1) + i}h`);

  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Tu uso de Claude</title>
<style>
@page { size: A4; margin: 14mm 14mm 16mm; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", system-ui, -apple-system, Roboto, sans-serif; color: #1f1e1c; font-size: 10.5pt; line-height: 1.45; margin: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
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
.in { border-left: 3px solid ${C.blue}; padding: 4px 0 4px 10px; }
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
</style></head><body>

<div class="page">
  <div class="head"><h1>Tu uso de Claude</h1><span class="muted">${esc(from)} – ${esc(to)} · Claude Code</span></div>
  <div class="kpis">
    ${kpi('Costo equivalente', T.hasCost ? money(T.cost) : '—', T.hasCost ? `${money(T.costPerPrompt)} por mensaje` : 'sin datos de costo')}
    ${kpi('Sesiones', nf0.format(T.sessions), `${nf0.format(T.prompts)} mensajes · ${p.activeDays} días activos`)}
    ${kpi('Contexto promedio', tok(T.avgContext), 'tokens por llamada')}
    ${kpi('Uso de caché', pctTxt(T.cacheHitRate * 100), T.cacheHitRate >= 0.85 ? 'muy bueno' : 'mejorable')}
  </div>

  <h2>¿En qué se va tu consumo?</h2>
  ${stackedBar(costSegments(r.categories))}

  <div class="grid2">
    <div><h2>Consumo diario</h2>${columns(days, dayLabels, { fmt: (v) => money(v), every: Math.ceil(days.length / 8) })}</div>
    <div><h2>Por modelo</h2>${hbars(models)}<h2 style="margin-top:12px">Por proyecto</h2>${hbars(projects, { color: C.aqua })}</div>
  </div>

  <h2>Tus ${top3.length === 1 ? 'mejora' : `${top3.length} mejoras`} con más impacto</h2>
  ${top3.map((f) => `<div class="top"><div><h3>${esc(f.title)}</h3><div class="act">${esc(f.actions[0])}</div></div><div style="text-align:right">${pill(f.severity)}${f.impactUsd != null && f.impactUsd > 0.05 ? `<div class="imp" style="margin:4px 0 0">${money(f.impactUsd)} · ${pctTxt(f.pct)}</div>` : ''}</div></div>`).join('') || '<p class="muted">No encontramos problemas relevantes en este período.</p>'}

  ${r.strengths.length ? `<div class="good"><b>Lo que haces bien</b><ul>${r.strengths.map((s) => `<li>${esc(s)}</li>`).join('')}</ul></div>` : ''}
</div>

<div class="page">
  <div class="head"><h1>Tu forma de trabajar</h1><span class="muted">${esc(from)} – ${esc(to)}</span></div>
  <div class="kpis">
    ${kpi('Claude trabajando', `${nf1.format(p.claudeHours)} h`, `en ${p.timedSessions} sesiones con registro`)}
    ${kpi('Sesión típica', `${nf0.format(p.medianPrompts)} mensajes`, `${nf0.format(p.medianCalls)} llamadas · ${money(p.medianUsd)}`)}
    ${kpi('Código', `+${nf0.format(T.linesAdded)}`, `−${nf0.format(T.linesRemoved)} líneas`)}
    ${kpi('Subagentes', nf0.format(T.subCalls), 'llamadas delegadas')}
  </div>

  <div class="grid2e">
    <div><h2>¿A qué hora trabajas con Claude?</h2>${hSlice.length ? columns(hSlice, hLabels, { color: C.violet, fmt: (v) => `${nf0.format(v)} llamadas`, h: 100 }) : '<p class="muted">Sin datos.</p>'}</div>
    <div><h2>¿Cuánto delegas?</h2>${hbars(p.permissionModes.map((m) => ({ name: MODE_NAMES[m.name] || m.name, pct: m.pct })), { color: C.orange })}
      <h2 style="margin-top:12px">Nivel de esfuerzo</h2>${hbars(p.efforts.map((e) => ({ name: e.name, pct: e.pct })), { color: C.yellow })}</div>
  </div>

  <h2>Skills y MCP: cuánto te cuestan</h2>
  ${hbars(extras, { color: C.magenta, value: (x) => (x.usd != null ? money(x.usd) : pctTxt(x.pct)) })}

  <h2>Lo que dicen tus datos</h2>
  <div class="ins">${insights.map(([, t, s]) => `<div class="in"><p>${esc(t)}</p><p>${esc(s)}</p></div>`).join('')}</div>
</div>

<div class="page">
  <div class="head"><h1>Recomendaciones en detalle</h1><span class="muted">ordenadas por impacto</span></div>
  ${findings.map(findingBlock).join('') || '<p class="muted">Sin recomendaciones para este período.</p>'}
  <p class="foot">Generado por tibox-coach a partir de tus sesiones locales de Claude Code (${esc(r.claudeDir)}). Los montos son el costo equivalente a precios de API; el reparto por categoría es una estimación ajustada al consumo real. Nada de esta información salió de tu equipo.</p>
</div>
</body></html>`;
}

// Busca Edge o Chrome para imprimir el HTML a PDF.
export function findBrowser() {
  const env = process.env;
  const candidates = process.platform === 'win32' ? [
    path.join(env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Microsoft\\Edge\\Application\\msedge.exe'),
    path.join(env.ProgramFiles || 'C:\\Program Files', 'Microsoft\\Edge\\Application\\msedge.exe'),
    path.join(env.ProgramFiles || 'C:\\Program Files', 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Google\\Chrome\\Application\\chrome.exe'),
    env.LOCALAPPDATA && path.join(env.LOCALAPPDATA, 'Google\\Chrome\\Application\\chrome.exe'),
  ] : process.platform === 'darwin' ? [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ] : ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/microsoft-edge'];
  return candidates.find((p) => p && fs.existsSync(p)) || null;
}

export function writePdf(report, outPath) {
  const html = renderReportHtml(report);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tibox-coach-'));
  const htmlPath = path.join(tmp, 'informe.html');
  fs.writeFileSync(htmlPath, html, 'utf8');
  const browser = findBrowser();
  if (!browser) {
    const fallback = outPath.replace(/\.pdf$/i, '') + '.html';
    fs.copyFileSync(htmlPath, fallback);
    return { pdf: null, html: fallback, reason: 'No encontré Edge ni Chrome para generar el PDF. Abre el HTML y usa Imprimir → Guardar como PDF.' };
  }
  const res = spawnSync(browser, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${path.join(tmp, 'profile')}`, '--no-pdf-header-footer',
    `--print-to-pdf=${path.resolve(outPath)}`, pathToFileURL(htmlPath).href,
  ], { stdio: 'ignore', timeout: 60000 });
  try { fs.rmSync(path.join(tmp, 'profile'), { recursive: true, force: true }); } catch { /* el navegador puede tener archivos tomados un momento */ }
  if (!fs.existsSync(outPath)) return { pdf: null, html: htmlPath, reason: `El navegador no generó el PDF (código ${res.status}).` };
  return { pdf: path.resolve(outPath), html: htmlPath };
}
