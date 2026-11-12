---
name: mi-coach
description: Genera el informe personal de uso de Claude Code en PDF (costo, en qué se van los tokens, forma de trabajar y recomendaciones para gastar menos). Úsala cuando la persona pida su informe, su coach, su analítica de uso de Claude o cómo mejorar su consumo de tokens.
---

# Mi coach de Claude

Genera un informe en PDF con el uso de Claude Code de la persona y lo comenta en pocas líneas.
Todo se calcula en su equipo con PowerShell y Microsoft Edge: no se instala nada ni se envían datos.

## Pasos

1. Ejecuta el script que está en la carpeta `scripts/` de esta skill (usa la ruta base de la skill):

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<carpeta de esta skill>\scripts\tibox-coach.ps1"
   ```

   Opciones, solo si la persona las pide:
   - `-Days 7` para otro período (por defecto 30 días; `0` = todo el historial).
   - `-Out "C:\ruta\informe.pdf"` para guardarlo en otra parte (por defecto en Documentos).
   - `-NoOpen` si no quiere que se abra el PDF.

   Tarda entre 5 y 30 segundos según cuántas sesiones haya.

2. El script abre el PDF y deja en su salida un resumen con líneas `RESUMEN`, `MEJORA` y `BIEN`.
   Con eso, responde en español y en no más de 6 líneas:
   - dónde quedó el PDF;
   - la mejora con más impacto y qué hacer distinto, en una frase concreta;
   - una cosa que la persona hace bien.

   No leas ni pegues el PDF ni el JSON completo: el resumen alcanza y así el comentario cuesta pocos tokens.

## Si algo falla

- "No encontré sesiones de Claude Code": la persona no ha usado Claude Code en este equipo o usa otra carpeta de configuración. Pregunta si tiene `CLAUDE_CONFIG_DIR` y pásala con `-Dir`.
- "No encontré Microsoft Edge ni Chrome": el script deja un HTML; indica que lo abra y use Imprimir > Guardar como PDF.
- La política de ejecución bloquea el script incluso con `-ExecutionPolicy Bypass`: la organización restringe PowerShell; explica que debe consultarlo con TI.
- Esta skill solo funciona en Windows y desde Claude Code (terminal o pestaña Code de la app). En Cowork no tiene acceso a la carpeta `~/.claude`.
