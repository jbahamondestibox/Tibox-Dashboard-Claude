# tibox-coach

Coach personal de Claude Code. Analiza **tus** sesiones locales y genera un informe en PDF con tu consumo, tu forma de trabajar y recomendaciones concretas para gastar menos.

No hay que instalar nada: funciona con PowerShell y Microsoft Edge, que vienen con Windows.

## Instalación (una vez)

En Claude Code (terminal o pestaña Code de la app de escritorio):

```
/plugin marketplace add <usuario>/<repositorio>
/plugin install tibox-coach@tibox
```

## Uso

Pídele a Claude *"genera mi informe de uso"* o escribe `/mi-coach`. Claude ejecuta el análisis, abre el PDF (queda en tu carpeta Documentos) y te comenta en pocas líneas lo más importante.

También se puede correr directamente:

```
powershell -NoProfile -ExecutionPolicy Bypass -File skills\mi-coach\scripts\tibox-coach.ps1 [-Days 30] [-Out ruta.pdf] [-NoOpen] [-Json]
```

## Qué incluye el informe

1. **Resumen**: costo equivalente, sesiones, contexto promedio, uso de caché, en qué se va el consumo, consumo diario, por modelo y por proyecto, tus 3 mejoras con más impacto y lo que haces bien.
2. **Tu forma de trabajar**: horas de trabajo de Claude, sesión típica, a qué hora trabajas, cuánto delegas (modo de permisos), nivel de esfuerzo, costo por skill y MCP, y lo que dicen tus datos.
3. **Recomendaciones en detalle**: diagnóstico, ejemplos de tus propias sesiones y qué hacer.

## Privacidad

- Solo lee archivos de tu equipo: `~/.claude/projects/**/*.jsonl` (y el tamaño de tus `CLAUDE.md`).
- No se conecta a internet ni envía datos. El PDF queda solo en tu equipo.

## Requisitos y límites

- Windows con PowerShell 5.1 (incluido) y Microsoft Edge o Chrome.
- Solo analiza Claude Code. Las tareas de Cowork se ejecutan en la nube y no dejan registros de tokens en el equipo; los chats de claude.ai tampoco.
- Debe usarse desde Claude Code, no desde Cowork (Cowork no ve la carpeta `~/.claude`).

## Cómo se calcula

Claude Code registra los tokens de cada llamada al modelo: entrada, escritura en caché, lectura de caché y salida. El costo de cada sesión es el que calcula el mismo Claude Code (equivalente a precios de API).

La clave del análisis: **todo lo que entra al contexto se vuelve a enviar en cada llamada siguiente** de la sesión. Un archivo de 10k tokens leído al principio de una sesión de 200 llamadas se cobra una vez como escritura de caché y 199 veces como lectura de caché. Por eso cada contenido se pondera por cuántas llamadas permaneció en el contexto, y el total se ajusta al consumo real registrado.

Pesos relativos al precio de input: lectura de caché 0,1×, escritura de caché 1,25× (5 min) o 2× (1 h), salida 5×.

## Reglas del coach

| Regla | Qué detecta |
|---|---|
| Sesiones largas | Llamadas con más de 100k tokens de contexto |
| Caché vencida | Pausas largas o cambios de modelo que obligan a reescribir toda la caché |
| Contexto base alto | Proyectos con más contexto fijo por llamada (MCP, skills, CLAUDE.md) |
| Resultados grandes | Lecturas, comandos, búsquedas o MCPs que devuelven más de 5k tokens |
| Lecturas repetidas | El mismo archivo leído 3 o más veces en una sesión |
| Textos pegados | Mensajes de más de 3k tokens |
| Dependencias | Búsquedas que recorren node_modules, .venv, build, etc. |
| Correcciones | Muchas idas y vueltas ("no, eso no…") o interrupciones |
| Modelo | Opus usado para consultas muy cortas |
| Esfuerzo | Esfuerzo xhigh o max en el 20% de las llamadas o más |

Las reglas están en `skills/mi-coach/scripts/Analyze.ps1`; cada una es un bloque independiente.

## Estructura

```
.claude-plugin/            plugin.json y marketplace.json (lo que se instala)
skills/mi-coach/SKILL.md   instrucciones para Claude
skills/mi-coach/scripts/   Parse.ps1 (lectura), Analyze.ps1 (reglas), Report.ps1 (HTML y PDF), tibox-coach.ps1 (entrada)
bin/ src/ web/             versión original en Node.js con panel web local (opcional, para desarrollo)
```

Los scripts `.ps1` deben guardarse en UTF-8 **con BOM**; si no, PowerShell 5.1 lee mal las tildes.
