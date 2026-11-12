// Agrega las sesiones de un período y aplica las reglas del coach.
// Los textos son plantillas: cada regla define su condición, su diagnóstico y sus acciones.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { W, toolCategory } from './parse.js';

// ---------- Formato de números para los textos ----------
const nf0 = new Intl.NumberFormat('es-CL', { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat('es-CL', { maximumFractionDigits: 1 });
export function tok(n) {
  n = Math.round(n || 0);
  if (n < 1000) return nf0.format(n);
  if (n < 100000) return nf0.format(Math.round(n / 100) * 100);
  if (n < 1e6) return nf0.format(Math.round(n / 1000)) + ' mil';
  if (n < 2e6) return nf1.format(n / 1e6) + ' millón';
  if (n < 1e9) return nf1.format(n / 1e6) + ' millones';
  return nf1.format(n / 1e9) + ' mil millones';
}
const pct = (x) => (x < 1 ? 'menos del 1' : nf0.format(Math.round(x)));
const fecha = (ts) => (ts ? new Date(ts).toLocaleString('es-CL', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false }) : '');
const veces = (n) => (n === 1 ? 'una vez' : `${nf0.format(n)} veces`);

const median = (arr) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };
const sessionName = (s) => s.title || `${s.project} · ${(s.start || '').slice(0, 10)}`;
const severityFor = (p) => (p >= 10 ? 'alta' : p >= 3 ? 'media' : 'baja');
const fileSize = (p) => { try { return fs.statSync(p).size; } catch { return null; } };
const toolName = (t) => (t.startsWith('mcp__') ? toolCategory(t) : t);

// Familias para el gráfico de distribución
export function categoryGroup(name) {
  if (/^Contexto base|^CLAUDE\.md|^Instrucciones inyectadas/.test(name)) return 'fijo';
  if (/^Generación|^Subagentes \(trabajo/.test(name)) return 'generacion';
  if (/^Tus mensajes|^Respuestas de Claude|^Código escrito|^Resúmenes/.test(name)) return 'conversacion';
  return 'herramientas';
}

// Revisa la configuración local que pesa en cada llamada (CLAUDE.md y servidores MCP).
function inspectConfig(claudeDir, cwds) {
  const out = { globalClaudeMd: fileSize(path.join(claudeDir, 'CLAUDE.md')), projects: {} };
  let cfg = null;
  for (const p of [path.join(os.homedir(), '.claude.json'), path.join(claudeDir, '.claude.json')]) {
    try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); break; } catch { /* sin config */ }
  }
  for (const cwd of cwds) {
    if (!cwd) continue;
    const md = fileSize(path.join(cwd, 'CLAUDE.md')) || fileSize(path.join(cwd, '.claude', 'CLAUDE.md'));
    let mcp = [];
    try { mcp = Object.keys(JSON.parse(fs.readFileSync(path.join(cwd, '.mcp.json'), 'utf8')).mcpServers || {}); } catch { /* sin .mcp.json */ }
    const projCfg = cfg && cfg.projects && (cfg.projects[cwd] || cfg.projects[cwd.replace(/\\/g, '/')]);
    if (projCfg && projCfg.mcpServers) mcp = mcp.concat(Object.keys(projCfg.mcpServers));
    out.projects[cwd] = { claudeMd: md, mcp };
  }
  return out;
}

export function buildReport(allSessions, { days = 30, claudeDir, files } = {}) {
  const now = Date.now();
  const from = days > 0 ? new Date(now - days * 86400000).toISOString() : '';
  const sessions = allSessions.filter((s) => (s.end || '') >= from);

  // Precio por unidad: el de cada sesión; si falta, el promedio del período.
  const priced = sessions.filter((s) => s.pricePerUnit);
  const avgPrice = priced.length ? priced.reduce((a, s) => a + s.cost, 0) / priced.reduce((a, s) => a + s.totalUnits, 0) : null;
  const usd = (units, s) => { const p = (s && s.pricePerUnit) || avgPrice; return p ? units * p : null; };

  const T = { sessions: sessions.length, calls: 0, subCalls: 0, prompts: 0, input: 0, cacheCreate: 0, cacheRead: 0, output: 0, thinking: 0, tokens: 0, units: 0, cost: 0, linesAdded: 0, linesRemoved: 0 };
  for (const s of sessions) {
    T.calls += s.calls; T.subCalls += s.subCalls; T.prompts += s.prompts.length;
    for (const k of ['input', 'cacheCreate', 'cacheRead', 'output', 'thinking']) T[k] += s.main[k] + s.sub[k];
    T.tokens += s.totalTokens; T.units += s.totalUnits;
    T.cost += s.cost || usd(s.totalUnits, s) || 0;
    T.linesAdded += s.linesAdded; T.linesRemoved += s.linesRemoved;
  }
  T.cacheHitRate = T.cacheRead / Math.max(1, T.cacheRead + T.cacheCreate + T.input);
  T.avgContext = T.calls ? sessions.reduce((a, s) => a + s.avgContext * s.calls, 0) / T.calls : 0;
  T.costPerPrompt = T.prompts ? T.cost / T.prompts : 0;
  T.hasCost = avgPrice != null;
  const pctOf = (units) => (T.units > 0 ? (units / T.units) * 100 : 0);

  // ¿En qué se va el costo?
  const catMap = {};
  for (const s of sessions) for (const [k, v] of Object.entries(s.categories)) {
    const c = catMap[k] || (catMap[k] = { units: 0, usd: 0 });
    c.units += v; c.usd += usd(v, s) || 0;
  }
  const categories = Object.entries(catMap)
    .map(([name, c]) => ({ name, group: categoryGroup(name), units: c.units, usd: T.hasCost ? c.usd : null, pct: pctOf(c.units) }))
    .filter((c) => c.pct >= 0.05).sort((a, b) => b.units - a.units);

  // Herramientas
  const toolMap = {};
  for (const s of sessions) for (const r of s.toolResults) {
    const t = toolMap[r.tool] || (toolMap[r.tool] = { tool: r.tool, calls: 0, tokens: 0, units: 0, usd: 0, errors: 0, max: 0 });
    t.calls++; t.tokens += r.tokens; t.units += r.units; t.usd += usd(r.units, s) || 0; t.errors += r.isError ? 1 : 0; t.max = Math.max(t.max, r.tokens);
  }
  const tools = Object.values(toolMap).map((t) => ({ ...t, display: toolName(t.tool), pct: pctOf(t.units), usd: T.hasCost ? t.usd : null })).sort((a, b) => b.units - a.units);

  // Por día / proyecto / modelo
  const dayMap = {};
  for (const s of sessions) for (const [d, v] of Object.entries(s.byDay)) {
    if (d < from.slice(0, 10)) continue;
    const t = dayMap[d] || (dayMap[d] = { day: d, tokens: 0, usd: 0 });
    t.tokens += v.tokens; t.usd += usd(v.units, s) || 0;
  }
  const byDay = Object.values(dayMap).sort((a, b) => a.day.localeCompare(b.day));

  const projMap = {};
  for (const s of sessions) {
    const key = s.cwd || s.project;
    const p = projMap[key] || (projMap[key] = { project: s.project, cwd: s.cwd, sessions: 0, calls: 0, tokens: 0, units: 0, usd: 0, baselines: [] });
    p.sessions++; p.calls += s.calls; p.tokens += s.totalTokens; p.units += s.totalUnits; p.usd += s.cost || usd(s.totalUnits, s) || 0;
    if (s.calls > 0) p.baselines.push(s.baseline);
  }
  const byProject = Object.values(projMap).map(({ baselines, ...p }) => ({ ...p, baseline: median(baselines), pct: pctOf(p.units) })).sort((a, b) => b.units - a.units);

  const modelMap = {};
  for (const s of sessions) for (const [m, v] of Object.entries(s.models)) {
    const t = modelMap[m] || (modelMap[m] = { model: m, calls: 0, tokens: 0, units: 0 });
    t.calls += v.calls; t.tokens += v.tokens; t.units += v.units;
  }
  const byModel = Object.values(modelMap).map((m) => ({ ...m, pct: pctOf(m.units) })).sort((a, b) => b.units - a.units);

  const config = inspectConfig(claudeDir, byProject.map((p) => p.cwd));

  // ---------- Perfil de trabajo ----------
  const profile = (() => {
    const sumMap = (key, toUsd) => {
      const m = {};
      for (const s of sessions) for (const [k, v] of Object.entries(s[key] || {})) {
        const e = m[k] || (m[k] = { name: k, value: 0, usd: 0 });
        e.value += v; if (toUsd) e.usd += usd(v, s) || 0;
      }
      return Object.values(m).sort((a, b) => b.value - a.value);
    };
    const effortCalls = sumMap('efforts');
    const effortTotal = effortCalls.reduce((a, e) => a + e.value, 0);
    const modes = sumMap('permissionModes');
    const modesTotal = modes.reduce((a, e) => a + e.value, 0);
    const hours = new Array(24).fill(0);
    for (const s of sessions) (s.hours || []).forEach((n, h) => { hours[h] += n; });
    const timed = sessions.filter((s) => s.apiMs > 0);
    const activeDays = new Set(sessions.flatMap((s) => Object.keys(s.byDay)).filter((d) => d >= from.slice(0, 10))).size;
    return {
      activeDays,
      claudeHours: timed.reduce((a, s) => a + s.apiMs + s.toolMs, 0) / 3600000,
      timedSessions: timed.length,
      medianCalls: median(sessions.filter((s) => s.calls).map((s) => s.calls)),
      medianPrompts: median(sessions.map((s) => s.prompts.length).filter((n) => n)),
      medianUsd: median(sessions.map((s) => s.cost || usd(s.totalUnits, s) || 0)),
      efforts: effortCalls.map((e) => ({ name: e.name, calls: e.value, pct: effortTotal ? (e.value / effortTotal) * 100 : 0 })),
      highEffortPct: effortTotal ? (effortCalls.filter((e) => e.name === 'xhigh' || e.name === 'max').reduce((a, e) => a + e.value, 0) / effortTotal) * 100 : 0,
      permissionModes: modes.map((e) => ({ name: e.name, prompts: e.value, pct: modesTotal ? (e.value / modesTotal) * 100 : 0 })),
      skills: sumMap('skillUnits', true).map((e) => ({ name: e.name, usd: T.hasCost ? e.usd : null, pct: pctOf(e.value) })),
      mcps: sumMap('mcpUnits', true).map((e) => ({ name: e.name, usd: T.hasCost ? e.usd : null, pct: pctOf(e.value) })),
      hours,
    };
  })();

  // ---------- Reglas ----------
  const findings = [];
  const add = (f) => {
    f.pct = f.impactUnits != null ? pctOf(f.impactUnits) : null;
    f.severity = f.severity || severityFor(f.pct || 0);
    findings.push(f);
  };
  const sumUsd = (list, unitsOf) => (T.hasCost ? list.reduce((a, x) => a + (usd(unitsOf(x), x.s) || 0), 0) : null);

  // 1. Sesiones que acumulan demasiado contexto
  {
    const LIMIT = 100000;
    const ev = [];
    for (const s of sessions) {
      let su = 0, sc = 0;
      for (const c of s.ctx) if (c > LIMIT) { su += (c - LIMIT) * W.cacheRead; sc++; }
      if (sc > 0) ev.push({ s, su, sc });
    }
    const calls = ev.reduce((a, x) => a + x.sc, 0);
    if (calls >= 5) {
      ev.sort((a, b) => b.su - a.su);
      const biggest = Math.max(...ev.map((x) => x.s.maxContext));
      add({
        id: 'sesiones-largas', title: 'Tus sesiones se alargan demasiado',
        impactUnits: ev.reduce((a, x) => a + x.su, 0), impactUsd: sumUsd(ev, (x) => x.su),
        what: `En ${nf0.format(calls)} llamadas el contexto superó los ${tok(LIMIT)} tokens, y tu sesión más grande llegó a ${tok(biggest)}. Claude reenvía todo el historial en cada mensaje: lo que pediste hace dos horas lo sigues pagando en cada respuesta nueva.`,
        evidence: ev.slice(0, 5).map(({ s, sc }) => ({
          label: sessionName(s),
          detail: `${nf0.format(s.calls)} llamadas · contexto promedio de ${tok(s.avgContext)} tokens${s.compactions ? ` · compactada ${veces(s.compactions)}` : ''}`,
          value: `máx. ${tok(s.maxContext)}`,
        })),
        actions: [
          'Haz /clear al terminar una tarea y antes de empezar otra. Si necesitas continuidad, pide primero "resume en 10 líneas lo hecho y lo pendiente" y pega ese resumen en la sesión nueva.',
          'Usa /compact indicando qué conservar, por ejemplo: "/compact conserva solo los cambios del endpoint de camiones".',
          'Revisa /context a mitad de sesión para ver qué está ocupando más espacio.',
          'Para exploraciones amplias ("busca dónde se usa X en todo el repo"), pide que lo haga un subagente. A tu sesión solo vuelve la conclusión.',
        ],
      });
    }
  }

  // 2. Reanudaciones en frío (caché vencida)
  {
    const cold = [];
    for (const s of sessions) for (const c of s.coldResumes) cold.push({ s, c });
    if (cold.length >= 2) {
      cold.sort((a, b) => b.c.tokens - a.c.tokens);
      const byModel = cold.some((x) => x.c.reason === 'cambio de modelo');
      add({
        id: 'cache-fria', title: 'Retomas sesiones con la caché vencida',
        impactUnits: cold.reduce((a, x) => a + x.c.units, 0), impactUsd: sumUsd(cold, (x) => x.c.units),
        what: `Claude tuvo que volver a cargar el contexto completo en caché ${veces(cold.length)}, casi siempre después de una pausa larga${byModel ? ' o de un cambio de modelo' : ''}. Escribir en caché cuesta entre 12 y 20 veces más que leer de ella, y en sesiones grandes la diferencia se nota.`,
        evidence: cold.slice(0, 6).map(({ s, c }) => ({
          label: sessionName(s),
          detail: `${fecha(c.ts)} · ${c.reason}`,
          value: `${tok(c.tokens)} tokens`,
        })),
        actions: [
          'Si vuelves a una sesión grande después de una hora o más, abre una nueva con un resumen corto de lo pendiente. Sale más barato que recargar todo el historial.',
          'Elige el modelo al empezar. Cambiarlo con /model a mitad de sesión descarta la caché.',
          'Antes de una pausa larga (almuerzo, reunión), cierra la tarea o pide un resumen de estado para retomar en limpio.',
        ],
      });
    }
  }

  // 3. Base fija alta por proyecto (CLAUDE.md, MCP, skills)
  {
    const withB = byProject.filter((p) => p.calls > 0 && p.baseline > 0);
    if (withB.length) {
      const minB = Math.min(...withB.map((p) => p.baseline));
      const maxB = Math.max(...withB.map((p) => p.baseline));
      const ref = Math.max(minB, 20000);
      let units = 0, money = 0;
      const ev = [];
      for (const p of withB) {
        const extra = p.baseline - ref;
        const cfg = config.projects[p.cwd] || {};
        let pu = 0;
        if (extra > 8000) for (const s of sessions) if ((s.cwd || s.project) === (p.cwd || p.project) && s.calls) {
          const u = extra * (s.cw + W.cacheRead * (s.calls - 1)); pu += u; money += usd(u, s) || 0;
        }
        units += pu;
        const det = [cfg.claudeMd ? `CLAUDE.md de ${tok(cfg.claudeMd / 4)} tokens` : 'sin CLAUDE.md', cfg.mcp && cfg.mcp.length ? `MCP: ${cfg.mcp.join(', ')}` : null].filter(Boolean).join(' · ');
        ev.push({ label: p.project, detail: det, value: `${tok(p.baseline)} por llamada`, pu });
      }
      if (units > 0 || median(withB.map((p) => p.baseline)) > 45000) {
        ev.sort((a, b) => b.pu - a.pu);
        const used = [...new Set(tools.filter((t) => t.tool.startsWith('mcp__')).map((t) => t.display.replace('MCP: ', '')))];
        add({
          id: 'base-fija', title: 'Cargas mucho contexto fijo en cada mensaje',
          impactUnits: units, impactUsd: T.hasCost ? money : null,
          what: `Antes de leer tu primer mensaje, Claude ya recibe sus instrucciones, las definiciones de herramientas, los servidores MCP, las skills y tu CLAUDE.md. En tus proyectos esa base va de ${tok(minB)} a ${tok(maxB)} tokens y viaja en cada llamada.${config.globalClaudeMd ? ` Tu CLAUDE.md global aporta unos ${tok(config.globalClaudeMd / 4)}.` : ''}`,
          evidence: ev.map(({ pu, ...e }) => e),
          actions: [
            'Corre /context al inicio de una sesión para ver cuánto ocupa cada MCP, skill y CLAUDE.md.',
            'Desactiva con /mcp los servidores que no usas en ese proyecto.' + (used.length ? ` En este período usaste: ${used.join(', ')}.` : ''),
            'Deja CLAUDE.md corto (menos de 200 líneas), con reglas y comandos clave. La documentación larga va en archivos aparte que Claude lee solo cuando los necesita.',
          ],
        });
      }
    }
  }

  // 4. Resultados de herramientas muy grandes
  {
    const MIN = 5000;
    const big = [];
    for (const s of sessions) for (const r of s.toolResults) if (!r.side && r.tokens >= MIN) big.push({ s, r });
    if (big.length) {
      const used = new Set(big.map((x) => x.r.tool));
      const actions = [];
      if (used.has('Read')) actions.push('Si el archivo es grande, pide solo lo que necesitas ("lee la función procesarCamion de app.py"). Claude puede leer por rangos de líneas.');
      if (used.has('Bash') || used.has('PowerShell')) actions.push('Cuando un comando genera mucha salida (tests, builds, logs), pide que la filtre ("muestra solo los errores", "| Select-Object -Last 30", "--quiet") o que la guarde en un archivo y busque ahí.');
      if (used.has('Grep') || used.has('Glob')) actions.push('En las búsquedas, indica la carpeta o un patrón más preciso ("busca solo en src/") para no traer cientos de coincidencias.');
      if ([...used].some((t) => t.startsWith('mcp__'))) actions.push('Con herramientas MCP (documentación, navegador, bases de datos), pide resultados acotados: menos filas, solo los campos necesarios, capturas solo cuando hagan falta.');
      actions.push('Cuando ya sacaste lo que necesitabas de un resultado grande, un /compact evita que lo sigas pagando el resto de la sesión.');
      big.sort((a, b) => b.r.units - a.r.units);
      add({
        id: 'resultados-grandes', title: 'Algunas herramientas devuelven resultados enormes',
        impactUnits: big.reduce((a, x) => a + x.r.units, 0), impactUsd: sumUsd(big, (x) => x.r.units),
        what: `${nf0.format(big.length)} resultados superaron los ${tok(MIN)} tokens. El tamaño es solo una parte del costo: cada resultado queda en el contexto y se reenvía en todas las llamadas siguientes de la sesión.`,
        evidence: big.slice(0, 8).map(({ s, r }) => ({
          label: `${toolName(r.tool)}: ${r.label || '(sin detalle)'}`,
          detail: `${sessionName(s)} · siguió en el contexto ${nf0.format(r.remaining)} llamadas`,
          value: `${tok(r.tokens)} tokens`,
        })),
        actions,
      });
    }
  }

  // 5. Archivos leídos varias veces en la misma sesión
  {
    const rep = [];
    for (const s of sessions) {
      const m = new Map();
      for (const r of s.toolResults) if (!r.side && r.tool === 'Read' && r.filePath) {
        const e = m.get(r.filePath) || { n: 0, units: 0 };
        if (e.n > 0) e.units += r.units;
        e.n++; m.set(r.filePath, e);
      }
      for (const [f, e] of m) if (e.n >= 3) rep.push({ s, f, ...e });
    }
    if (rep.length) {
      rep.sort((a, b) => b.units - a.units);
      add({
        id: 'lecturas-repetidas', title: 'Claude relee los mismos archivos',
        impactUnits: rep.reduce((a, x) => a + x.units, 0), impactUsd: sumUsd(rep, (x) => x.units),
        what: `${nf0.format(rep.length)} archivos se leyeron tres veces o más en una misma sesión. Cada lectura agrega una copia completa al contexto.`,
        evidence: rep.slice(0, 6).map((x) => ({ label: path.basename(x.f), detail: `${x.f} · ${sessionName(x.s)}`, value: `${x.n} lecturas` })),
        actions: [
          'Divide en módulos más chicos los archivos largos que editas seguido. Así Claude lee solo el que necesita.',
          'Después de un cambio, pide que verifique solo la parte modificada o que corra los tests, en vez de "revisa todo de nuevo".',
          'Si el archivo es una referencia fija (esquema, contrato de API), resume lo esencial una vez en CLAUDE.md.',
        ],
      });
    }
  }

  // 6. Textos enormes pegados en el chat
  {
    const big = [];
    for (const s of sessions) for (const p of s.prompts) if (p.tokens >= 3000) big.push({ s, p });
    if (big.length) {
      big.sort((a, b) => b.p.units - a.p.units);
      add({
        id: 'pegados', title: 'Pegas textos muy largos en el chat',
        impactUnits: big.reduce((a, x) => a + x.p.units, 0), impactUsd: sumUsd(big, (x) => x.p.units),
        what: `${nf0.format(big.length)} mensajes tuyos superaron los 3.000 tokens, con código, JSON o logs pegados. Ese texto queda en el contexto hasta que termina la sesión.`,
        evidence: big.slice(0, 6).map(({ s, p }) => ({
          label: p.text.replace(/\s+/g, ' ').slice(0, 90) || '(texto pegado)',
          detail: `${sessionName(s)} · siguió en el contexto ${nf0.format(p.remaining)} llamadas`,
          value: `${tok(p.tokens)} tokens`,
        })),
        actions: [
          'Guarda el contenido en un archivo del proyecto y menciónalo con @archivo. Claude lo lee cuando lo necesita y puede buscar solo la parte relevante.',
          'De un log, pega el error y unas pocas líneas alrededor.',
          'Para definiciones grandes (Logic Apps, OpenAPI, esquemas), pide primero un resumen y sigue trabajando desde ahí en una sesión nueva.',
        ],
      });
    }
  }

  // 7. Búsquedas que recorren dependencias o carpetas generadas
  {
    const hits = [];
    for (const s of sessions) for (const r of s.toolResults) if (r.deps && r.tokens >= 500) hits.push({ s, r });
    if (hits.length) {
      hits.sort((a, b) => b.r.tokens - a.r.tokens);
      add({
        id: 'dependencias', title: 'Tus búsquedas recorren carpetas de dependencias',
        impactUnits: hits.reduce((a, x) => a + x.r.units, 0), impactUsd: sumUsd(hits, (x) => x.r.units),
        what: `${nf0.format(hits.length)} búsquedas devolvieron sobre todo archivos de node_modules, .venv, build u otras carpetas generadas, que rara vez sirven para la tarea.`,
        evidence: hits.slice(0, 6).map(({ s, r }) => ({ label: `${r.tool}: ${r.label}`, detail: sessionName(s), value: `${tok(r.tokens)} tokens` })),
        actions: [
          'Agrega esas carpetas al .gitignore del proyecto. Las búsquedas de Claude Code lo respetan.',
          'Si no puedes ignorarlas en git, bloquea su lectura en .claude/settings.json: { "permissions": { "deny": ["Read(./node_modules/**)", "Read(./.venv/**)"] } }',
          'Al pedir una búsqueda, di dónde buscar: "en src/", no en todo el repo.',
        ],
      });
    }
  }

  // 8. Iteraciones de corrección e interrupciones
  {
    const corr = [];
    let interrupts = 0;
    for (const s of sessions) { interrupts += s.interrupts; for (const p of s.prompts) if (p.correction) corr.push({ s, p }); }
    const ratio = T.prompts ? corr.length / T.prompts : 0;
    if ((corr.length >= 3 && ratio >= 0.12) || interrupts >= 10) {
      add({
        id: 'correcciones', title: 'Das muchas vueltas de corrección',
        impactUnits: null, severity: ratio >= 0.25 ? 'alta' : 'media',
        what: `El ${pct(ratio * 100)}% de tus mensajes son correcciones del tipo "no, eso no" o "sigue fallando"${interrupts ? `, y detuviste a Claude ${veces(interrupts)}` : ''}. Cada vuelta reenvía todo el contexto.`,
        evidence: corr.slice(0, 6).map(({ s, p }) => ({ label: `"${p.text.slice(0, 100)}"`, detail: sessionName(s), value: '' })),
        actions: [
          'Para cambios no triviales, activa el modo plan (Shift+Tab) y revisa el enfoque antes de que Claude escriba código.',
          'En el primer mensaje, di cuándo está listo ("cuando el endpoint responda 200 con este JSON") y qué no debe tocar.',
          'Pide a Claude que corra los tests o el script antes de devolverte el control.',
          'Si después de dos o tres correcciones sigue mal, haz /clear y reformula el pedido con lo que aprendiste.',
        ],
      });
    }
  }

  // 9. Modelo más caro para tareas cortas
  {
    const top = byModel[0];
    if (top && /opus/i.test(top.model) && top.pct > 70) {
      const short = sessions.filter((s) => s.calls > 0 && s.calls <= 6 && Object.keys(s.models).some((m) => /opus/i.test(m)));
      if (short.length >= 3) {
        add({
          id: 'modelo', title: 'Usas el modelo más caro para consultas rápidas',
          impactUnits: null, severity: 'baja',
          what: `El ${pct(top.pct)}% de tu consumo fue con ${top.model}. ${nf0.format(short.length)} sesiones fueron consultas cortas, de seis llamadas o menos, donde Sonnet suele bastar.`,
          evidence: short.slice(0, 5).map((s) => ({ label: sessionName(s), detail: `${s.calls} ${s.calls === 1 ? 'llamada' : 'llamadas'}`, value: s.cost ? `US$${s.cost.toFixed(2).replace('.', ',')}` : '' })),
          actions: [
            'Para preguntas puntuales, explicaciones o cambios chicos, empieza la sesión con /model sonnet.',
            'Deja Opus para diseño, depuración difícil o cambios grandes en varios archivos.',
          ],
        });
      }
    }
  }

  // 10. Esfuerzo alto como opción por defecto
  if (profile.highEffortPct >= 20) {
    const top = sessions
      .map((s) => ({ s, n: (s.efforts.xhigh || 0) + (s.efforts.max || 0) }))
      .filter((x) => x.n > 0).sort((a, b) => b.n - a.n);
    add({
      id: 'esfuerzo', title: 'Usas esfuerzo alto con mucha frecuencia',
      impactUnits: null, severity: profile.highEffortPct >= 50 ? 'media' : 'baja',
      what: `El ${pct(profile.highEffortPct)}% de tus llamadas usó esfuerzo xhigh o max. Más esfuerzo significa más razonamiento por respuesta: más tokens de salida y respuestas más lentas, algo que solo compensa en problemas difíciles.`,
      evidence: top.slice(0, 5).map(({ s, n }) => ({ label: sessionName(s), detail: `${nf0.format(s.calls)} llamadas en total`, value: `${nf0.format(n)} con esfuerzo alto` })),
      actions: [
        'Deja medium o high como esfuerzo por defecto y sube a xhigh solo para depuración difícil, diseño o cambios grandes.',
        'Si cambias el esfuerzo para una tarea puntual, vuelve a bajarlo al terminarla.',
      ],
    });
  }

  const order = { alta: 0, media: 1, baja: 2 };
  findings.sort((a, b) => order[a.severity] - order[b.severity] || (b.impactUnits || 0) - (a.impactUnits || 0));

  // ---------- Lo que haces bien ----------
  const strengths = [];
  if (T.cacheHitRate >= 0.85) strengths.push(`Aprovechas bien la caché: el ${pct(T.cacheHitRate * 100)}% de tu contexto se leyó desde ahí, a una décima parte del precio normal.`);
  const clears = sessions.reduce((a, s) => a + (s.commands.clear || 0) + (s.commands.compact || 0), 0);
  if (clears >= 3) strengths.push(`Usas /clear o /compact (${veces(clears)}) para mantener tus sesiones livianas.`);
  if (T.prompts >= 10 && !findings.some((f) => f.id === 'correcciones')) strengths.push('Corriges poco: tus pedidos suelen salir bien a la primera.');
  if (!findings.some((f) => f.id === 'dependencias')) strengths.push('Tus búsquedas no recorren dependencias ni carpetas generadas.');
  if (T.subCalls >= 20) strengths.push(`Delegas trabajo a subagentes (${nf0.format(T.subCalls)} llamadas), lo que mantiene limpio tu contexto principal.`);

  const sessionsOut = sessions.map((s) => {
    const topCat = Object.entries(s.categories).filter(([k]) => !k.startsWith('Generación')).sort((a, b) => b[1] - a[1])[0];
    return {
      id: s.id, name: sessionName(s), project: s.project, start: s.start, end: s.end, calls: s.calls, subCalls: s.subCalls,
      prompts: s.prompts.length, tokens: s.totalTokens, usd: s.cost || usd(s.totalUnits, s), maxContext: s.maxContext, avgContext: s.avgContext,
      cacheHit: (s.main.cacheRead + s.sub.cacheRead) / Math.max(1, s.main.cacheRead + s.main.cacheCreate + s.main.input + s.sub.cacheRead + s.sub.cacheCreate + s.sub.input),
      topCategory: topCat ? topCat[0] : null, models: Object.keys(s.models), entrypoint: s.entrypoint,
    };
  }).sort((a, b) => (b.usd || 0) - (a.usd || 0) || b.tokens - a.tokens);

  return {
    generatedAt: new Date().toISOString(), days, from: from || null, claudeDir, files,
    totals: T, categories, findings, strengths, profile, byDay, byProject, byModel, tools, sessions: sessionsOut,
  };
}
