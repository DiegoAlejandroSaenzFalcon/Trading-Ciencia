# Contribuir al Trading Science Framework

> **Gracias por contribuir a la ciencia honesta del trading.**

---

## Código de Conducta

Este proyecto sigue el [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
Al participar, te comprometes a mantener un entorno respetuoso, inclusivo y honesto.

---

## Cómo Contribuir

### 1. Reportar Bugs
- Usa el template de Issue: "Bug Report"
- Incluye: pasos para reproducir, versión, logs, config relevante
- **No incluyas secrets, API keys, datos personales**

### 2. Proponer Mejoras
- Usa el template: "Feature Request"
- Explica: qué problema resuelve, por qué es importante, alternativas consideradas
- Para cambios grandes: abre un Issue primero para discutir

### 3. Pull Requests

```bash
# 1. Fork del repo
# 2. Crear rama descriptiva
git checkout -b feat/mi-mejora
# o fix/mi-correccion, docs/mi-doc, refactor/mi-refactor, test/mi-test

# 3. Hacer cambios
# - Tests para nueva funcionalidad
# - Docs actualizadas
# - Types correctos (mypy pasa)

# 4. Verificar localmente
ruff check .
ruff format --check .
mypy tsf
pytest tests/ -x

# 5. Commit convencional
git commit -m "feat: add new validation metric for regime detection"
# Tipos: feat, fix, docs, refactor, test, chore, perf, ci

# 6. Push y PR
git push origin feat/mi-mejora
# Abre PR contra main
```

### 4. Estándares de Código

| Herramienta | Config | Comando |
|-------------|--------|---------|
| **Ruff** | Lint + Format | `ruff check . && ruff format --check .` |
| **MyPy** | Strict types | `mypy tsf` |
| **Pytest** | Tests unit + integración | `pytest tests/ -v` |
| **Pre-commit** | Auto en commit | `pre-commit install` |

---

## Qué NO Aceptamos

- ❌ Código sin tests
- ❌ Commits que rompen `main`
- ❌ Hardcoded secrets, API keys, IPs
- ❌ Cambios en `.env.example` sin justificación
- ❌ Promesas de rentabilidad, "edge garantizado", marketing
- ❌ Código que evita gates científicos (factor-qc, falsification-ledger, etc.)

---

## Áreas de Contribución Bienvenidas

| Área | Ejemplos |
|------|----------|
| **Documentación** | Tutoriales, traducir, clarificar, diagramas |
| **Tests** | Edge cases, property-based (hypothesis), integración |
| **Estrategias** | Nueva implementación BaseStrategy con validación completa |
| **Brokers** | Adaptadores para IBKR, Alpaca, FXCM, etc. |
| **Indicadores** | Nuevos indicadores vectorizados, benchmarks |
| **Risk Mgmt** | Nuevos modelos de sizing, breakers, portfolio risk |
| **Psicología** | Nuevas métricas lesson-book, premortems |
| **Infra** | Docker, systemd, monitoring, CI/CD |
| **Ciencia** | Papers replication, métricas estadísticas nuevas |

---

## Proceso de Revisión

1. **CI automático**: lint, types, tests, security scan
2. **Revisión humana**: 1+ maintainer aprueba
3. **Gates científicos**: Si tocas investigación, gates factor-qc/fl/gg deben pasar
4. **Merge**: Squash merge a main, rama eliminada

---

## Licencia

Al contribuir, aceptas que tu código se licencie bajo **MIT License** (igual que el proyecto).
Copyright de tus contribuciones: **tú** (reconocido en AUTHORS/CONTRIBUTORS).

---

## Contacto

- Issues: GitHub Issues (público, transparente)
- Discusiones: GitHub Discussions
- Seguridad: Security Advisory (privado)

---

**Recuerda**: Este framework es para **investigación honesta**.
Tu contribución ayuda a que más gente aprenda trading como ciencia, no como apuesta.