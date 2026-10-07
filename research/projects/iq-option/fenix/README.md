# Fenix — IQ Option

Repositorio histórico y de investigación del proyecto **Fenix** para IQ Option.

> Este directorio es una **zona de investigación/auditoría**. No se declara todavía ninguna versión como estrategia válida, estable científicamente ni apta para dinero real.

## Estructura

- `00-audit/` — auditorías, hallazgos, cuarentena y evidencia de revisión.
- `01-source/` — código fuente recuperado y versionado para análisis.
- `02-archives/` — ZIP originales preservados; no se modifican.
- `03-data/` — datos históricos asociados a las versiones estables.
- `04-history/` — versiones antiguas, fallidas y documentación histórica.
- `05-evidence/` — resultados/evidencia que se incorporen posteriormente.
- `06-analysis/` — análisis científico, comparativas, hipótesis y conclusiones.
- `.gitignore` — exclusiones de secretos, runtime y artefactos compilados.

## Estado de incorporación

**Fecha de organización:** 2026-10-05.

La incorporación fue **no destructiva respecto al origen**: los materiales originales permanecen en:

`C:\Users\Diego Saenz\OneDrive\Documentos Personales\Programas de Trading en Desarrollo\Proyecto Fenix IQ Option`

Se copiaron al proyecto los archivos necesarios para investigación y los ZIP fueron preservados como archivos de referencia.

## Fuente de verdad provisional

`01-source/current/` contiene la versión actualmente recuperada del código fuente principal. Esta clasificación es **provisional** hasta completar la comparación de todas las versiones y establecer una genealogía verificable.

No se debe modificar esta copia para experimentar sin registrar el cambio. Las futuras versiones deben entrar como snapshots identificables.

## Seguridad

No se deben almacenar credenciales reales, tokens, claves ni archivos de secretos en Git.

El `config.txt` original contenía credenciales reales y fue apartado a `00-audit/quarantine/`. En su lugar existe:

`01-source/current/config.example.txt`

El token de Telegram y las contraseñas existentes deben considerarse comprometidos por haber estado almacenados en el material histórico; antes de cualquier reutilización deberán **rotarse/revocarse**.

También se excluyen artefactos binarios sensibles o de procedencia no verificada.

## Validación inicial

- Los cinco ZIP principales recuperados fueron comprobados con ZIP CRC/test de integridad: **sin errores detectados**.
- `fenix.py`: compilación sintáctica Python correcta.
- `entrenar_ia.py`: compilación sintáctica Python correcta.
- No se ejecutó trading real durante esta auditoría.
- No se declara ninguna métrica de rentabilidad como válida sin un protocolo reproducible y evidencia.

## Próxima fase

1. Construir genealogía de versiones.
2. Comparar código entre ZIP/versiones estables/históricas.
3. Identificar qué versión es realmente la más completa.
4. Separar estrategia, ejecución, gestión monetaria, API, Telegram, IA y licenciamiento.
5. Registrar defectos conocidos y regresiones.
6. Recuperar evidencia de backtests/pruebas sin mezclarla con resultados no reproducibles.
7. Integrar el contexto de los demás proyectos cuando sea proporcionado por Diego.
