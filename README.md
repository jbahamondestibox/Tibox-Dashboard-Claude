<div align="center">

# 📊 tibox-coach

### Tu coach personal de Claude Code

Descubre en qué se van tus tokens, cómo trabajas con Claude<br>
y qué cambiar para gastar menos, en un informe PDF de 3 páginas.

<br>

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-D97757?style=flat-square)
![Sin instalaciones](https://img.shields.io/badge/instalaciones-ninguna-2ea44f?style=flat-square)
![Privado](https://img.shields.io/badge/datos-100%25%20locales-2ea44f?style=flat-square)

<br>

[**Instalar**](#-instalación) · [**Usar**](#-uso) · [**Qué incluye**](#-qué-incluye-el-informe) · [**Privacidad**](#-privacidad) · [**Problemas frecuentes**](#-problemas-frecuentes)

</div>

<br>

## ✨ Por qué usarlo

<table>
<tr>
<td width="33%" valign="top">

**💸 Entiende tu consumo**

Ve cuánto cuesta tu uso, qué parte se va en contexto fijo, archivos leídos, comandos o respuestas, y qué proyectos pesan más.

</td>
<td width="33%" valign="top">

**🧭 Conoce tu forma de trabajar**

A qué hora trabajas, cuánto delegas, qué nivel de esfuerzo usas y cuánto te cuestan tus skills y MCP.

</td>
<td width="33%" valign="top">

**🎯 Recibe recomendaciones**

Las mejoras con más impacto, con ejemplos de **tus propias sesiones** y acciones concretas.

</td>
</tr>
</table>

<br>

## 🚀 Instalación

> [!NOTE]
> Se hace **una sola vez** y tarda unos 2 minutos. No necesitas instalar Node.js, Python ni nada más: solo usa PowerShell y Microsoft Edge, que ya vienen con Windows.

### Opción A · Sin git <sup>(recomendada)</sup>

**1. Descarga el ZIP**

<a href="https://github.com/jbahamondestibox/Tibox-Dashboard-Claude/archive/refs/heads/main.zip"><img src="https://img.shields.io/badge/⬇%20Descargar%20ZIP-2ea44f?style=for-the-badge" alt="Descargar ZIP"></a>

**2. Descomprímelo en tu carpeta Documentos** con el nombre `tibox-coach`. Debe quedar así:

```
📁 Documentos
└── 📁 tibox-coach
    ├── 📁 .claude-plugin     ← estas carpetas deben estar
    ├── 📁 skills             ← directamente aquí
    └── 📄 README.md
```

> [!WARNING]
> Windows suele crear una carpeta extra al descomprimir (`tibox-coach\Tibox-Dashboard-Claude-main\...`). Si te pasa, mueve el contenido un nivel hacia arriba. Ver [problemas frecuentes](#-problemas-frecuentes).

**3. Agrégalo en Claude Code** (terminal o pestaña **Code** de la app de escritorio), reemplazando `TU-USUARIO`:

```
/plugin marketplace add C:\Users\TU-USUARIO\Documents\tibox-coach
```

```
/plugin install tibox-coach@tibox
```

> [!IMPORTANT]
> No borres ni muevas la carpeta `tibox-coach` después de instalar: Claude Code la usa como origen del plugin.

### Opción B · Con git

Si tienes [Git for Windows](https://git-scm.com/download/win) instalado, basta con:

```
/plugin marketplace add jbahamondestibox/Tibox-Dashboard-Claude
```

```
/plugin install tibox-coach@tibox
```

<br>

## 💬 Uso

Abre una sesión nueva en Claude Code y escribe:

```
/mi-coach
```

o simplemente pídelo con tus palabras: *"genera mi informe de uso de Claude"*.

En unos segundos:

1. ⚙️ Claude analiza tus sesiones de los **últimos 30 días**.
2. 📄 Se abre el **PDF**, que queda guardado en tu carpeta **Documentos**.
3. 💡 Claude te comenta en pocas líneas **tu mejora principal** y **lo que haces bien**.

<details>
<summary><b>Opciones avanzadas</b></summary>

<br>

Puedes pedirle a Claude otro período (*"genera mi informe de los últimos 7 días"*) o correr el script directamente:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\mi-coach\scripts\tibox-coach.ps1 -Days 7
```

| Parámetro | Qué hace | Por defecto |
|---|---|---|
| `-Days <n>` | Período a analizar en días (`0` = todo el historial) | `30` |
| `-Out <ruta>` | Dónde guardar el PDF | `Documentos\tibox-coach-<fecha>.pdf` |
| `-NoOpen` | No abrir el PDF al terminar | — |
| `-Json` | Imprimir los datos en JSON en vez de generar el PDF | — |
| `-Dir <ruta>` | Carpeta de configuración de Claude Code | `~\.claude` |

</details>

<br>

## 📑 Qué incluye el informe

| Página | Contenido |
|:---:|---|
| **1 · Tu uso de Claude** | Costo equivalente · sesiones · contexto promedio · uso de caché · en qué se va tu consumo · consumo diario · por modelo y proyecto · **tus 3 mejoras con más impacto** · lo que haces bien |
| **2 · Tu forma de trabajar** | Horas de trabajo de Claude · tu sesión típica · a qué hora trabajas · cuánto delegas · nivel de esfuerzo · costo de skills y MCP · **lo que dicen tus datos** |
| **3 · Recomendaciones en detalle** | Para cada problema: diagnóstico, ejemplos reales de tus sesiones y **qué hacer distinto** |

<br>

## 🔒 Privacidad

<table>
<tr><td>✅</td><td>Solo lee archivos de tu equipo: <code>~\.claude\projects\**\*.jsonl</code> y el tamaño de tus <code>CLAUDE.md</code>.</td></tr>
<tr><td>✅</td><td>No se conecta a internet ni envía datos a ningún lado.</td></tr>
<tr><td>✅</td><td>El PDF queda solo en tu equipo. Nadie más lo ve a menos que tú lo compartas.</td></tr>
<tr><td>✅</td><td>El código es abierto: puedes revisar línea por línea qué hace en <a href="skills/mi-coach/scripts"><code>skills/mi-coach/scripts</code></a>.</td></tr>
</table>

<br>

## 🔄 Actualizar

| Si instalaste... | Haz esto |
|---|---|
| **Sin git** | Descarga el ZIP nuevo, reemplaza el contenido de `Documentos\tibox-coach` y ejecuta `/plugin marketplace update tibox` |
| **Con git** | Ejecuta `/plugin marketplace update tibox` |

<br>

## 🛟 Problemas frecuentes

<details>
<summary><b>"No se encontró el marketplace" o "no hay plugins" al instalar</b></summary>

<br>

Casi siempre es la carpeta extra que crea Windows al descomprimir. Revisa que la ruta sea:

```
✅ Documentos\tibox-coach\.claude-plugin
❌ Documentos\tibox-coach\Tibox-Dashboard-Claude-main\.claude-plugin
```

Si ves la segunda, mueve todo lo que hay dentro de `Tibox-Dashboard-Claude-main` a `tibox-coach`, o usa esa ruta completa en el comando `/plugin marketplace add`.

</details>

<details>
<summary><b>"Command 'git' not found" al agregar el marketplace</b></summary>

<br>

Usaste la opción B sin tener git. Sigue la [opción A](#opción-a--sin-git-recomendada), que no lo necesita.

</details>

<details>
<summary><b>"No encontré sesiones de Claude Code"</b></summary>

<br>

No hay sesiones de Claude Code en este equipo, o tu configuración está en otra carpeta. Si usas la variable `CLAUDE_CONFIG_DIR`, el script la detecta sola; si no, pídele a Claude que use `-Dir` con la ruta correcta.

</details>

<details>
<summary><b>No se genera el PDF</b></summary>

<br>

El script usa Microsoft Edge (o Chrome) para crear el PDF. Si no encuentra ninguno, deja un archivo HTML: ábrelo y usa **Imprimir → Guardar como PDF**.

</details>

<details>
<summary><b>PowerShell bloquea el script</b></summary>

<br>

El script se ejecuta con `-ExecutionPolicy Bypass`, que normalmente basta. Si aun así se bloquea, tu organización restringe PowerShell y debes consultarlo con TI.

</details>

<details>
<summary><b>¿Funciona en Cowork o en el chat de claude.ai?</b></summary>

<br>

No. Solo analiza **Claude Code**: las tareas de Cowork se ejecutan en la nube y los chats no dejan registros de tokens en tu equipo. Además, la skill debe usarse desde Claude Code, porque Cowork no tiene acceso a la carpeta `~\.claude`.

</details>

<br>

## 🧠 Cómo se calcula

<details>
<summary><b>El costo</b></summary>

<br>

Claude Code registra los tokens de cada llamada al modelo: entrada, escritura en caché, lectura de caché y salida. El costo de cada sesión es el que calcula el mismo Claude Code, equivalente a precios de API.

La clave del análisis: **todo lo que entra al contexto se vuelve a enviar en cada llamada siguiente** de la sesión. Un archivo de 10 mil tokens leído al principio de una sesión de 200 llamadas se cobra una vez como escritura de caché y 199 veces como lectura de caché. Por eso cada contenido se pondera por cuántas llamadas permaneció en el contexto, y el total se ajusta al consumo real registrado.

| Tipo de token | Peso relativo al input |
|---|:---:|
| Lectura de caché | 0,1× |
| Escritura de caché (5 min) | 1,25× |
| Escritura de caché (1 h) | 2× |
| Salida | 5× |

</details>

<details>
<summary><b>Las reglas del coach</b></summary>

<br>

| Regla | Qué detecta |
|---|---|
| 📏 Sesiones largas | Llamadas con más de 100 mil tokens de contexto |
| 🧊 Caché vencida | Pausas largas o cambios de modelo que obligan a reescribir toda la caché |
| 🧱 Contexto base alto | Proyectos con mucho contexto fijo por llamada (MCP, skills, CLAUDE.md) |
| 📦 Resultados grandes | Lecturas, comandos, búsquedas o MCP que devuelven más de 5 mil tokens |
| 🔁 Lecturas repetidas | El mismo archivo leído 3 o más veces en una sesión |
| 📋 Textos pegados | Mensajes de más de 3 mil tokens |
| 🗂️ Dependencias | Búsquedas que recorren `node_modules`, `.venv`, `build`, etc. |
| ↩️ Correcciones | Muchas idas y vueltas ("no, eso no…") o interrupciones |
| 🧠 Modelo | Opus usado para consultas muy cortas |
| 🎚️ Esfuerzo | Esfuerzo `xhigh` o `max` en el 20% de las llamadas o más |

Cada regla es un bloque independiente en [`Analyze.ps1`](skills/mi-coach/scripts/Analyze.ps1), fácil de ajustar o ampliar.

</details>

<br>

## 🛠️ Para quienes desarrollan

<details>
<summary><b>Estructura del proyecto</b></summary>

<br>

```
📁 .claude-plugin/
   ├── plugin.json            nombre, versión y descripción del plugin
   └── marketplace.json       hace instalable el repositorio
📁 skills/mi-coach/
   ├── SKILL.md               instrucciones que sigue Claude
   └── 📁 scripts/
       ├── tibox-coach.ps1    punto de entrada
       ├── Parse.ps1          lectura de las sesiones
       ├── Analyze.ps1        métricas, perfil y reglas
       └── Report.ps1         HTML con gráficos SVG y PDF con Edge
📁 bin/ src/ web/              versión original en Node.js con panel web local (opcional)
```

</details>

<details>
<summary><b>Publicar una versión nueva</b></summary>

<br>

1. Sube el número de `version` en [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) (por ejemplo `0.2.0` → `0.2.1`). Claude Code lo usa para saber que hay una actualización.
2. Sube los cambios a GitHub.
3. Avisa al equipo que actualice (ver [Actualizar](#-actualizar)).

> [!CAUTION]
> Los archivos `.ps1` deben guardarse en **UTF-8 con BOM**. Si se guardan sin BOM, PowerShell 5.1 lee mal las tildes y el informe sale con caracteres extraños.

</details>

<br>

<div align="center">
<sub>Hecho en Tibox para trabajar mejor con Claude 🧡</sub>
</div>
