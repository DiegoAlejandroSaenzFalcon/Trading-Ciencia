# Auditoría inicial — Fenix / IQ Option

**Fecha:** 2026-10-05  
**Alcance:** material recuperado desde `Proyecto Fenix IQ Option` hacia Trading-Ciencia.  
**Método:** inventario filesystem, verificación de ZIP, lectura de fuentes/documentación, revisión de seguridad, compilación sintáctica y separación de históricos.

## 1. Resultado ejecutivo

**Estado:** AMBER / requiere investigación antes de declararlo reproducible.

El material contiene una base importante de desarrollo histórico de Fenix, múltiples generaciones del bot, librería `iqoptionapi`, modelos/datos, integraciones de Telegram, gestión monetaria y experimentos Bionic.

La estructura original mezclaba código vigente, backups, ZIP, entornos virtuales, bytecode, binarios extraídos y artefactos de experimentación. Se inició una separación no destructiva en Trading-Ciencia.

## 2. Inventario observado

### ZIP

Se localizaron:

- 5 ZIP principales en la raíz de Fenix.
- 6 ZIP de `Versiones Anteriores` de Fenix/IQOptionAPI.
- 2 ZIP internos derivados de `base_library.zip` dentro de material extraído.
- 17 ZIP dentro de `Versiones Estables` aproximadamente según el inventario observado.

Los cinco ZIP principales fueron comprobados con `zipfile.testzip()` y devolvieron **None**: no se detectaron errores CRC.

## 3. Código principal

La fuente actual recuperada contiene:

- `fenix.py` — 2444 líneas.
- `entrenar_ia.py` — 14765 bytes.
- `iqoptionapi/` — implementación local de la API.
- `cerebro_fenix.pkl` — artefacto de modelo.
- CSV de análisis/registro.
- `fenix_errors.log`.
- `iniciar_remoto.bat`.

### Validación sintáctica

- `fenix.py`: **PASS** con `python -m py_compile`.
- `entrenar_ia.py`: **PASS** con `python -m py_compile`.

Esto solo valida sintaxis; **no valida funcionamiento, API, estrategia ni rentabilidad**.

## 4. Hallazgos de seguridad

### CRÍTICO — credenciales en configuración histórica

El `config.txt` original contenía credenciales de varias cuentas y un token de Telegram.

Acción tomada:

- No se dejó el `config.txt` real en `01-source/current`.
- Se apartó en `00-audit/quarantine/`.
- Se creó `config.example.txt` sin secretos.
- El `.gitignore` excluye configuración real, claves y artefactos de cuarentena.

**Recomendación:** rotar/revocar todas las credenciales y el token que hayan sido usados con ese archivo antes de volver a ejecutar el sistema.

### ALTO — control remoto por Telegram

El código implementa control de sesión mediante Telegram, incluyendo selección de cuenta PRACTICE/REAL y acciones de inicio del sistema. Esto eleva el impacto de cualquier compromiso de credenciales/chat.

Debe auditarse autorización, identidad, replay, comandos permitidos, estado de cuenta y fail-closed antes de cualquier uso real.

### ALTO — licencia remota

El código consulta una URL externa para verificar una licencia. Esto introduce una dependencia operacional externa y un punto de fallo/control que debe quedar documentado y aislado de la lógica científica.

### MEDIO — gestión monetaria

El código contiene Martingala/SorosGale y Masaniello. Estas son reglas de gestión de riesgo/apuestas, no evidencia de ventaja estadística. Deben separarse de la señal y evaluarse con protocolos independientes.

## 5. Problemas de arquitectura observados

El código principal mezcla en un mismo proceso:

1. conexión IQ Option;
2. selección PRACTICE/REAL;
3. estrategia técnica;
4. gestión monetaria;
5. Telegram;
6. licenciamiento remoto;
7. IA/modelo;
8. presentación de terminal;
9. logging;
10. estado de sesión.

Para una futura investigación científica, estas responsabilidades deben separarse.

## 6. Material histórico

`Versiones Anteriores` contiene evidencia de múltiples intentos, incluyendo Bionic, fallidos, auditorías de ingeniería inversa y snapshots de Fenix.

No debe eliminarse ni mezclarse con la versión actual: es evidencia histórica.

Los artefactos compilados, entornos virtuales y ejecutables extraídos no deben convertirse automáticamente en fuente de verdad.

## 7. Principio de organización aplicado

La clasificación adoptada es:

`00-audit` → gobernanza/evidencia de auditoría  
`01-source` → código fuente  
`02-archives` → ZIP/snapshots originales  
`03-data` → datos  
`04-history` → histórico  
`05-evidence` → resultados verificables  
`06-analysis` → investigación y conclusiones

## 8. Lo que todavía NO se afirma

No se afirma:

- que Fenix sea rentable;
- que una versión sea la mejor;
- que una versión sea estable científicamente;
- que la IA mejore el resultado;
- que Martingala reduzca riesgo;
- que los históricos sean comparables;
- que los resultados antiguos sean reproducibles.

Todas esas afirmaciones requieren evidencia.

## 9. Próxima auditoría

La siguiente etapa debe ser una **auditoría de genealogía de versiones**:

`V1 → V6 → V14 → V15 → V17 → V19 → V20 → V21 → variantes → Fenix actual`

y, en paralelo:

`Fenix ↔ Fenix Fast ↔ Pro IA ↔ Inverso M1 ↔ Inverso CALLPUT ↔ Bionic`

Se compararán:

- lógica de entrada;
- indicadores;
- duración;
- payout;
- gestión monetaria;
- conexión/API;
- IA;
- Telegram;
- errores;
- cambios de configuración;
- regresiones;
- diferencias entre código fuente y ZIP.

**Regla:** ningún cambio de código debe hacerse durante esa comparación sin registrar primero la evidencia y establecer la versión de referencia.
