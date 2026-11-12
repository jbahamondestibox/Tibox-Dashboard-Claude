// Lee las transcripciones locales de Claude Code (~/.claude/projects/**/*.jsonl)
// y las convierte en sesiones con métricas. Todo ocurre en la máquina del usuario.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';

// Pesos de costo relativos al precio de input (iguales para todos los modelos Claude).
export const W = { input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5 };
const CW_DEFAULT = 1.5; // escritura de caché promedio cuando no sabemos el TTL

export const estTokens = (chars) => Math.round(chars / 4);

export function getClaudeDir(custom) {
  return custom || process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

export function findTranscripts(claudeDir) {
  const root = path.join(claudeDir, 'projects');
  const out = [];
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (depth < 4 && e.name !== 'memory' && e.name !== 'tool-results') walk(p, depth + 1);
      } else if (e.name.endsWith('.jsonl')) out.push(p);
    }
  };
  walk(root, 0);
  return out;
}

// Líneas que no aportan métricas y pueden ser enormes: se saltan sin parsear.
const SKIP_PREFIXES = [
  '{"type":"api-request', '{"type":"file-history', '{"type":"queue-operation',
  '{"type":"last-prompt"', '{"type":"agent-name"', '{"type":"mode"', '{"type":"atis-latch"',
];

function contentChars(c) {
  if (c == null) return 0;
  if (typeof c === 'string') return c.length;
  if (Array.isArray(c)) {
    let n = 0;
    for (const b of c) {
      if (!b) continue;
      if (b.type === 'text') n += (b.text || '').length;
      else if (b.type === 'image') n += 6000; // ~1.500 tokens por imagen
      else n += JSON.stringify(b).length;
    }
    return n;
  }
  return JSON.stringify(c).length;
}

function contentText(c) {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('\n');
  return '';
}

export function toolCategory(name) {
  if (!name) return 'Herramienta: desconocida';
  if (name.startsWith('mcp__')) {
    const [, server = '', tool = ''] = name.split('__');
    // Los conectores de claude.ai aparecen con un UUID como nombre: se muestra la herramienta.
    return 'MCP: ' + (/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(server) ? tool : server.replace(/^claude_ai_/, ''));
  }
  if (name === 'Agent' || name === 'Task') return 'Subagentes (respuestas)';
  return 'Herramienta: ' + name;
}

// Nombre legible de un servidor MCP. Los conectores de claude.ai llegan con un UUID: se usa la herramienta.
// Los servidores internos de la app de escritorio (ccd_*) no son elección del usuario y se omiten.
function mcpName(server, tool) {
  if (/^ccd_/.test(server)) return null;
  if (/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(server)) return tool ? String(tool).replace(/_[a-z]+$/, '') : 'conector';
  return server.replace(/^claude_ai_/, '');
}

function toolLabel(name, input) {
  if (!input || typeof input !== 'object') return name || '';
  const s = (v) => String(v ?? '').replace(/\s+/g, ' ').slice(0, 140);
  switch (name) {
    case 'Read': case 'Write': case 'Edit': case 'NotebookEdit':
      return s(input.file_path || input.notebook_path);
    case 'Bash': case 'PowerShell':
      return s(input.command);
    case 'Grep':
      return s(`"${input.pattern}"${input.path ? ' en ' + input.path : ''}${input.output_mode ? ' (' + input.output_mode + ')' : ''}`);
    case 'Glob':
      return s(input.pattern + (input.path ? ' en ' + input.path : ''));
    case 'WebFetch':
      return s(input.url);
    case 'WebSearch':
      return s(input.query);
    case 'Agent': case 'Task':
      return s(input.description || input.prompt);
    default:
      return s(Object.values(input).filter((v) => typeof v === 'string').join(' · ')) || name;
  }
}

const CORRECTION_RE = /^\s*(no[,.!]|no no|nop\b|eso no|no es as[ií]|no es eso|no era eso|no lo que|sigue (sin|igual|fallando|mal)|todav[ií]a (no|falla|sale)|otra vez|de nuevo|no funciona|no sirve|no era|est[aá] mal|te equivocaste|revierte|deshaz|vuelve a|wrong|that's not|still (not|broken|failing)|undo)/i;
const DEPS_RE = /(node_modules[\\/]|(^|[\\/])\.?venv[\\/]|site-packages[\\/]|(^|[\\/])dist[\\/]|[\\/]bin[\\/](Debug|Release)|(^|[\\/])obj[\\/]|(^|[\\/])\.git[\\/]|__pycache__[\\/]|(^|[\\/])build[\\/])/;

// ¿El resultado es mayormente rutas dentro de dependencias o carpetas generadas?
function looksLikeDeps(text) {
  const lines = text.slice(0, 40000).split(/\r?\n/).filter((l) => l.trim());
  if (lines.length < 5) return false;
  const hits = lines.filter((l) => DEPS_RE.test(l)).length;
  return hits >= 5 && hits / lines.length >= 0.2;
}

function dayKey(ts) { return ts ? ts.slice(0, 10) : null; }

function newFileState(file) {
  return {
    file,
    isSubagentFile: /[\\/]subagents[\\/]/.test(file),
    sessionId: null, cwd: null, title: null, entrypoint: null, version: null,
    start: null, end: null,
    calls: [],        // llamadas del hilo principal
    subCalls: [],     // llamadas de subagentes
    callIds: new Map(),
    items: [],        // contenido que entra al contexto del hilo principal
    toolUses: new Map(),
    toolResults: [],
    prompts: [],
    commands: {},
    cost: 0, linesAdded: 0, linesRemoved: 0,
    compactions: 0, interrupts: 0, apiErrors: 0,
    firstPromptTokens: null,
    apiMs: 0, toolMs: 0, wallMs: 0, // tiempos registrados por Claude Code (cost-state)
    permissionModes: {},
  };
}

function processRecord(st, o) {
  if (o.sessionId && !st.sessionId) st.sessionId = o.sessionId;
  if (o.cwd && !st.cwd) st.cwd = o.cwd;
  if (o.entrypoint && !st.entrypoint) st.entrypoint = o.entrypoint;
  if (o.version) st.version = o.version;
  if (o.timestamp) {
    if (!st.start || o.timestamp < st.start) st.start = o.timestamp;
    if (!st.end || o.timestamp > st.end) st.end = o.timestamp;
  }
  const side = !!o.isSidechain || st.isSubagentFile;
  const mainAt = st.calls.length;
  const addItem = (category, tokens, extra) => {
    if (side || tokens <= 0) return null;
    const it = { category, tokens, at: st.calls.length, end: null, ...extra };
    st.items.push(it);
    return it;
  };

  switch (o.type) {
    case 'custom-title':
      if (o.customTitle) st.title = o.customTitle;
      return;
    case 'summary':
      if (o.summary && !st.title) st.title = o.summary;
      return;
    case 'cost-state':
      if (typeof o.totalCostUSD === 'number' && o.totalCostUSD > st.cost) st.cost = o.totalCostUSD;
      if (o.totalLinesAdded > st.linesAdded) st.linesAdded = o.totalLinesAdded;
      if (o.totalLinesRemoved > st.linesRemoved) st.linesRemoved = o.totalLinesRemoved;
      if (o.totalAPIDuration > st.apiMs) st.apiMs = o.totalAPIDuration;
      if (o.totalToolDuration > st.toolMs) st.toolMs = o.totalToolDuration;
      if (o.totalDuration > st.wallMs) st.wallMs = o.totalDuration;
      return;
    case 'system':
      if (o.subtype && /compact/i.test(o.subtype)) markCompaction(st);
      if (o.subtype === 'api_error') st.apiErrors++;
      return;
    case 'assistant': {
      const msg = o.message || {};
      const u = msg.usage;
      if (!msg.model || msg.model === '<synthetic>') return;
      let call = st.callIds.get(msg.id);
      if (!call && u) {
        const cc = u.cache_creation || {};
        call = {
          ts: o.timestamp, model: msg.model, effort: o.effort || null,
          input: u.input_tokens || 0,
          cacheCreate: u.cache_creation_input_tokens || 0,
          cc1h: cc.ephemeral_1h_input_tokens || 0,
          cacheRead: u.cache_read_input_tokens || 0,
          output: u.output_tokens || 0,
          thinking: (u.output_tokens_details && u.output_tokens_details.thinking_tokens) || 0,
          side,
          skill: o.attributionSkill || null,
          mcp: o.attributionMcpServer ? mcpName(o.attributionMcpServer, o.attributionMcpTool) : null,
        };
        st.callIds.set(msg.id, call);
        (side ? st.subCalls : st.calls).push(call);
      } else if (call && u && (u.output_tokens || 0) > call.output) {
        call.output = u.output_tokens;
      }
      for (const b of Array.isArray(msg.content) ? msg.content : []) {
        if (b.type === 'tool_use') {
          st.toolUses.set(b.id, { name: b.name, input: b.input, side });
          const cat = ['Write', 'Edit', 'NotebookEdit'].includes(b.name) ? 'Código escrito por Claude (Write/Edit)' : toolCategory(b.name);
          addItem(cat, estTokens(JSON.stringify(b.input || {}).length) + 20, { kind: 'toolInput', tool: b.name });
        } else if (b.type === 'text') {
          addItem('Respuestas de Claude (texto)', estTokens((b.text || '').length));
        }
      }
      return;
    }
    case 'user': {
      const c = o.message && o.message.content;
      if (!side && o.permissionMode && o.turnOrigin === 'human') st.permissionModes[o.permissionMode] = (st.permissionModes[o.permissionMode] || 0) + 1;
      if (o.isCompactSummary) {
        markCompaction(st);
        addItem('Resúmenes de compactación', estTokens(contentChars(c)));
        return;
      }
      const handleText = (t) => {
        if (!t) return;
        if (t.startsWith('[Request interrupted')) { if (!side) st.interrupts++; return; }
        const cmd = t.match(/<command-name>\/?([^<]+)<\/command-name>/);
        if (cmd) { st.commands[cmd[1]] = (st.commands[cmd[1]] || 0) + 1; addItem('Comandos y su salida', estTokens(t.length)); return; }
        if (t.startsWith('<local-command') || t.startsWith('<bash-')) { addItem('Comandos y su salida', estTokens(t.length)); return; }
        if (o.isMeta) { addItem('Instrucciones inyectadas (skills, hooks)', estTokens(t.length)); return; }
        if (side) return;
        const tokens = estTokens(t.length);
        const clean = t.replace(/<pasted_content[^>]*>[\s\S]*?<\/pasted_content>/g, '[pegado]').trim();
        const it = addItem('Tus mensajes', tokens);
        const p = { ts: o.timestamp, tokens, text: clean.slice(0, 160), pasted: /<pasted_content/.test(t), correction: CORRECTION_RE.test(clean), item: it };
        st.prompts.push(p);
        if (st.firstPromptTokens == null) st.firstPromptTokens = tokens;
      };
      if (typeof c === 'string') { handleText(c); return; }
      if (!Array.isArray(c)) return;
      for (const b of c) {
        if (!b) continue;
        if (b.type === 'tool_result') {
          const tu = st.toolUses.get(b.tool_use_id) || {};
          const chars = contentChars(b.content);
          const tokens = estTokens(chars);
          const text = typeof b.content === 'string' ? b.content : contentText(b.content);
          const r = {
            tool: tu.name || 'desconocida', category: toolCategory(tu.name), label: toolLabel(tu.name, tu.input),
            tokens, isError: !!b.is_error, side, ts: o.timestamp,
            deps: ['Glob', 'Grep', 'Bash', 'PowerShell', 'LS'].includes(tu.name) && looksLikeDeps(text),
            hasRange: !!(tu.input && (tu.input.offset != null || tu.input.limit != null)),
            filePath: tu.name === 'Read' && tu.input ? tu.input.file_path : null,
          };
          r.item = addItem(r.category, tokens, { kind: 'toolResult' });
          st.toolResults.push(r);
        } else if (b.type === 'text') handleText(b.text);
        else if (b.type === 'image') addItem('Tus mensajes', 1500);
      }
      return;
    }
    case 'attachment': {
      const a = o.attachment || {};
      // Adjuntos que sí terminan en el contexto con contenido relevante
      if (a.type === 'file' || a.type === 'edited_text_file' || a.type === 'instructions' || a.type === 'hook_additional_context') {
        const chars = Array.isArray(o.rendered) ? o.rendered.reduce((n, r) => n + contentChars(r && r.content), 0) : contentChars(a.content);
        const cat = a.type === 'instructions' ? 'CLAUDE.md e instrucciones' : a.type === 'edited_text_file' ? 'Avisos de archivos editados' : a.type === 'file' ? 'Archivos adjuntos (@archivo)' : 'Instrucciones inyectadas (skills, hooks)';
        addItem(cat, estTokens(chars));
      }
      return;
    }
    default:
      void mainAt;
  }
}

function markCompaction(st) {
  st.compactions++;
  for (const it of st.items) if (it.end == null) it.end = st.calls.length;
}

export async function parseFile(file) {
  const st = newFileState(file);
  const rl = readline.createInterface({ input: fs.createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line || line.length < 2) continue;
    let skip = false;
    for (const p of SKIP_PREFIXES) if (line.startsWith(p)) { skip = true; break; }
    if (skip) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    processRecord(st, o);
  }
  return st;
}

// Convierte el estado crudo de un archivo en una sesión con métricas calculadas.
function finalizeSession(st) {
  const sumCalls = (arr) => arr.reduce((t, c) => {
    t.input += c.input; t.cacheCreate += c.cacheCreate; t.cacheRead += c.cacheRead; t.output += c.output; t.thinking += c.thinking;
    t.cc1h += c.cc1h; return t;
  }, { input: 0, cacheCreate: 0, cacheRead: 0, output: 0, thinking: 0, cc1h: 0 });
  const main = sumCalls(st.calls);
  const sub = sumCalls(st.subCalls);
  const N = st.calls.length;
  const cwRatio = main.cacheCreate > 0 ? main.cc1h / main.cacheCreate : 0.5;
  const cw = W.cacheWrite5m + (W.cacheWrite1h - W.cacheWrite5m) * cwRatio;

  const ctx = st.calls.map((c) => c.input + c.cacheCreate + c.cacheRead);
  const units = (t) => t.input * W.input + t.cacheCreate * cw + t.cacheRead * W.cacheRead + t.output * W.output;
  const totalUnits = units(main) + units(sub);
  const pricePerUnit = st.cost > 0 && totalUnits > 0 ? st.cost / totalUnits : null;

  // Peso de cada item: se escribe una vez en caché y se relee en cada llamada siguiente.
  for (const it of st.items) {
    const end = it.end == null ? N : it.end;
    it.remaining = Math.max(0, end - it.at);
    it.units = it.remaining > 0 ? it.tokens * (cw + W.cacheRead * (it.remaining - 1)) : 0;
  }
  const baseline = N > 0 ? Math.max(0, ctx[0] - (st.firstPromptTokens || 0)) : 0;
  const categories = {};
  categories['Contexto base'] =N > 0 ? baseline * (cw + W.cacheRead * (N - 1)) : 0;
  for (const it of st.items) categories[it.category] = (categories[it.category] || 0) + it.units;

  // Escalar las estimaciones al consumo real de contexto del hilo principal
  const realCtxUnits = main.input * W.input + main.cacheCreate * cw + main.cacheRead * W.cacheRead;
  const estCtxUnits = Object.values(categories).reduce((a, b) => a + b, 0);
  const scale = estCtxUnits > 0 ? realCtxUnits / estCtxUnits : 0;
  for (const k of Object.keys(categories)) categories[k] *= scale;
  for (const it of st.items) it.units *= scale;
  categories['Generación de Claude'] = main.output * W.output;
  if (st.subCalls.length) categories['Subagentes (trabajo interno)'] = units(sub);

  // Reanudaciones en frío: pausas largas que obligan a reescribir la caché
  const coldResumes = [];
  for (let i = 1; i < st.calls.length; i++) {
    const a = st.calls[i - 1], b = st.calls[i];
    const gapMin = (Date.parse(b.ts) - Date.parse(a.ts)) / 60000;
    const c = ctx[i];
    if (b.cacheCreate > 20000 && c > 0 && b.cacheCreate / c > 0.5) {
      const h = Math.round(gapMin / 60);
      const pausa = gapMin >= 90 ? `pausa de ${h} ${h === 1 ? 'hora' : 'horas'}` : `pausa de ${Math.round(gapMin)} minutos`;
      const reason = a.model !== b.model ? 'cambio de modelo' : gapMin > 5 ? pausa : 'caché invalidada';
      coldResumes.push({ ts: b.ts, tokens: b.cacheCreate, gapMin: Math.round(gapMin), reason, units: b.cacheCreate * (cw - W.cacheRead) });
    }
  }

  const models = {};
  for (const c of [...st.calls, ...st.subCalls]) {
    const t = models[c.model] || (models[c.model] = { calls: 0, tokens: 0, units: 0 });
    t.calls++; t.tokens += c.input + c.cacheCreate + c.cacheRead + c.output;
    t.units += c.input * W.input + c.cacheCreate * cw + c.cacheRead * W.cacheRead + c.output * W.output;
  }
  const byDay = {};
  for (const c of [...st.calls, ...st.subCalls]) {
    const d = dayKey(c.ts); if (!d) continue;
    const t = byDay[d] || (byDay[d] = { tokens: 0, units: 0 });
    t.tokens += c.input + c.cacheCreate + c.cacheRead + c.output;
    t.units += c.input * W.input + c.cacheCreate * cw + c.cacheRead * W.cacheRead + c.output * W.output;
  }
  const efforts = {};
  for (const c of st.calls) if (c.effort) efforts[c.effort] = (efforts[c.effort] || 0) + 1;

  // Costo atribuido por esfuerzo, skill y MCP, y actividad por hora del día (hora local)
  const callUnits = (c) => c.input * W.input + c.cacheCreate * cw + c.cacheRead * W.cacheRead + c.output * W.output;
  const effortUnits = {}, skillUnits = {}, mcpUnits = {};
  const hours = new Array(24).fill(0);
  for (const c of [...st.calls, ...st.subCalls]) {
    const u = callUnits(c);
    if (c.effort) effortUnits[c.effort] = (effortUnits[c.effort] || 0) + u;
    if (c.skill) skillUnits[c.skill] = (skillUnits[c.skill] || 0) + u;
    if (c.mcp) mcpUnits[c.mcp] = (mcpUnits[c.mcp] || 0) + u;
    if (c.ts) hours[new Date(c.ts).getHours()]++;
  }

  return {
    id: st.sessionId, file: st.file, title: st.title, cwd: st.cwd,
    project: st.cwd ? path.basename(st.cwd) : '(desconocido)',
    entrypoint: st.entrypoint, version: st.version, start: st.start, end: st.end,
    calls: N, subCalls: st.subCalls.length, main, sub, cw,
    totalTokens: main.input + main.cacheCreate + main.cacheRead + main.output + sub.input + sub.cacheCreate + sub.cacheRead + sub.output,
    totalUnits, pricePerUnit, cost: st.cost, linesAdded: st.linesAdded, linesRemoved: st.linesRemoved,
    ctx, maxContext: ctx.length ? Math.max(...ctx) : 0, avgContext: ctx.length ? ctx.reduce((a, b) => a + b, 0) / ctx.length : 0,
    baseline, categories, coldResumes, models, byDay, efforts, effortUnits, skillUnits, mcpUnits, hours,
    apiMs: st.apiMs, toolMs: st.toolMs, wallMs: st.wallMs, permissionModes: st.permissionModes,
    prompts: st.prompts.map(({ item, ...p }) => ({ ...p, units: item ? item.units : 0, remaining: item ? item.remaining : 0 })),
    toolResults: st.toolResults.map(({ item, ...r }) => ({ ...r, units: item ? item.units : 0, remaining: item ? item.remaining : 0 })),
    commands: st.commands, compactions: st.compactions, interrupts: st.interrupts, apiErrors: st.apiErrors,
  };
}

export async function loadSessions(claudeDir, onProgress) {
  const files = findTranscripts(claudeDir);
  const states = [];
  let i = 0;
  for (const f of files) {
    states.push(await parseFile(f));
    if (onProgress) onProgress(++i, files.length);
  }
  // Agrupar por sessionId: los archivos de subagentes se suman a su sesión; las copias duplicadas se descartan.
  const byId = new Map();
  for (const st of states) {
    if (!st.sessionId) continue;
    const isSub = st.isSubagentFile || (st.calls.length === 0 && st.subCalls.length > 0);
    const cur = byId.get(st.sessionId) || { main: null, subs: [] };
    if (isSub) cur.subs.push(st);
    else if (!cur.main || st.calls.length > cur.main.calls.length) cur.main = st;
    byId.set(st.sessionId, cur);
  }
  const sessions = [];
  for (const { main, subs } of byId.values()) {
    const st = main || subs[0];
    if (!st) continue;
    if (main) for (const s of subs) st.subCalls.push(...s.subCalls, ...s.calls.map((c) => ({ ...c, side: true })));
    if (st.calls.length + st.subCalls.length === 0) continue;
    sessions.push(finalizeSession(st));
  }
  sessions.sort((a, b) => (b.end || '').localeCompare(a.end || ''));
  return { sessions, files: files.length };
}
