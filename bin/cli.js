#!/usr/bin/env node
// tibox-coach: coach personal de Claude Code. Todo el análisis es local.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getClaudeDir, loadSessions } from '../src/parse.js';
import { buildReport } from '../src/analyze.js';
import { writePdf } from '../src/pdf.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const a = { port: 4477, days: 30, open: true, json: false, dir: null, help: false, pdf: null };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--port' || k === '-p') a.port = Number(argv[++i]);
    else if (k === '--days' || k === '-d') a.days = Number(argv[++i]);
    else if (k === '--dir') a.dir = argv[++i];
    else if (k === '--no-open') a.open = false;
    else if (k === '--json') a.json = true;
    else if (k === '--pdf') a.pdf = argv[i + 1] && !argv[i + 1].startsWith('-') ? argv[++i] : true;
    else if (k === '--help' || k === '-h') a.help = true;
  }
  return a;
}

const HELP = `
tibox-coach — tu coach personal de Claude Code

Uso:
  npx tibox-coach [opciones]

Opciones:
  -d, --days <n>   Período a analizar en días (por defecto 30; 0 = todo)
  -p, --port <n>   Puerto local (por defecto 4477)
      --dir <ruta> Carpeta de Claude Code (por defecto ~/.claude o CLAUDE_CONFIG_DIR)
      --pdf [ruta] Genera el informe en PDF (por defecto en tu carpeta Documentos) y lo abre
      --json       Imprime el reporte en JSON y termina (sin abrir el navegador)
      --no-open    No abre el navegador automáticamente
  -h, --help       Muestra esta ayuda

Privacidad: solo lee archivos de tu equipo. El servidor escucha únicamente en 127.0.0.1
y no envía datos a ningún lado.
`;

function openBrowser(url) {
  const cmd = process.platform === 'win32' ? 'cmd' : process.platform === 'darwin' ? 'open' : 'xdg-open';
  const args = process.platform === 'win32' ? ['/c', 'start', '""', url] : [url];
  try { spawn(cmd, args, { stdio: 'ignore', detached: true }).unref(); } catch { /* el usuario abre la URL manualmente */ }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log(HELP); return; }
  const claudeDir = getClaudeDir(args.dir);
  if (!fs.existsSync(path.join(claudeDir, 'projects'))) {
    console.error(`No encontré sesiones de Claude Code en ${path.join(claudeDir, 'projects')}.\nUsa --dir para indicar otra carpeta.`);
    process.exit(1);
  }

  const t0 = Date.now();
  const log = (s) => { if (!args.json) process.stderr.write(s); };
  log('Analizando tus sesiones de Claude Code...');
  let data = await loadSessions(claudeDir, (i, n) => log(`\rAnalizando tus sesiones de Claude Code... ${i}/${n}`));
  log(`\r${data.sessions.length} sesiones leídas en ${((Date.now() - t0) / 1000).toFixed(1)} s.            \n`);

  const report = (days) => buildReport(data.sessions, { days, claudeDir, files: data.files });

  if (args.json) { process.stdout.write(JSON.stringify(report(args.days), null, 2)); return; }

  if (args.pdf) {
    const docs = path.join(os.homedir(), 'Documents');
    const name = `tibox-coach-${new Date().toISOString().slice(0, 10)}.pdf`;
    const out = args.pdf === true ? path.join(fs.existsSync(docs) ? docs : process.cwd(), name) : args.pdf;
    const r = writePdf(report(args.days), out);
    if (r.pdf) {
      console.log(`Tu informe está en ${r.pdf}`);
      if (args.open) openBrowser(r.pdf);
    } else {
      console.error(r.reason + `\nHTML del informe: ${r.html}`);
      process.exitCode = 1;
    }
    return;
  }

  const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (url.pathname === '/api/report') {
        if (url.searchParams.get('refresh') === '1') data = await loadSessions(claudeDir);
        const days = url.searchParams.has('days') ? Number(url.searchParams.get('days')) : args.days;
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
        res.end(JSON.stringify(report(days)));
      } else if (url.pathname === '/') {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        res.end(html.replace('__DEFAULT_DAYS__', String(args.days)));
      } else {
        res.writeHead(404); res.end('No encontrado');
      }
    } catch (e) {
      res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('Error: ' + e.message);
    }
  });
  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') console.error(`El puerto ${args.port} está ocupado. Prueba con --port ${args.port + 1}`);
    else console.error(e.message);
    process.exit(1);
  });
  server.listen(args.port, '127.0.0.1', () => {
    const url = `http://localhost:${args.port}/`;
    console.log(`\nTu reporte está en ${url}\n(Ctrl+C para salir)`);
    if (args.open) openBrowser(url);
  });
}

main().catch((e) => { console.error(e); process.exit(1); });
