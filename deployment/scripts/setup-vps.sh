#!/bin/bash
# =============================================================================
# Trading Science Framework - VPS Setup Script
#
# Uso en VPS fresco (Ubuntu 22.04/24.04 LTS):
#   curl -fsSL https://raw.githubusercontent.com/DiegoAlejandroSaenzFalcon/Trading-Ciencia/main/deployment/scripts/setup-vps.sh | bash
#   O clona el repo y ejecuta: ./deployment/scripts/setup-vps.sh
#
# Requiere: root/sudo, Ubuntu 22.04+, 2GB RAM mínimo, 20GB disco
# ============================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Verificar root
if [[ $EUID -ne 0 ]]; then
    log_error "Este script debe ejecutarse como root (sudo)"
    exit 1
fi

# Configuración
TSF_USER="tsf"
TSF_DIR="/opt/tsf"
REPO_URL="https://github.com/DiegoAlejandroSaenzFalcon/Trading-Ciencia.git"
BRANCH="main"

log_info "=== Trading Science Framework - VPS Setup ==="
log_info "Usuario: $TSF_USER"
log_info "Directorio: $TSF_DIR"
log_info "Repo: $REPO_URL ($BRANCH)"

# 1. Actualizar sistema
log_info "Actualizando sistema..."
apt-get update && apt-get upgrade -y
log_ok "Sistema actualizado"

# 2. Instalar dependencias base
log_info "Instalando dependencias base..."
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    vim \
    htop \
    net-tools \
    ufw \
    fail2ban \
    logrotate \
    cron \
    systemd-timesyncd \
    python3 \
    python3-venv \
    python3-pip
log_ok "Dependencias base instaladas"

# 3. Configurar timezone y NTP (CRÍTICO para trading)
log_info "Configurando timezone UTC y NTP..."
timedatectl set-timezone UTC
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
# Verificar sincronización
sleep 2
timedatectl status
log_ok "Timezone UTC + NTP configurado"

# 4. Instalar Docker
log_info "Instalando Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
log_ok "Docker instalado"

# 5. Instalar Docker Compose standalone (más reciente)
log_info "Instalando Docker Compose standalone..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
log_ok "Docker Compose ${DOCKER_COMPOSE_VERSION} instalado"

# 6. Crear usuario tsf
log_info "Creando usuario $TSF_USER..."
if ! id "$TSF_USER" &>/dev/null; then
    useradd -r -s /bin/bash -d "$TSF_DIR" -m "$TSF_USER"
    usermod -aG docker "$TSF_USER"
    log_ok "Usuario $TSF_USER creado"
else
    log_warn "Usuario $TSF_USER ya existe"
fi

# 7. Clonar repositorio
log_info "Clonando repositorio..."
if [[ -d "$TSF_DIR/.git" ]]; then
    log_warn "Directorio ya existe, actualizando..."
    cd "$TSF_DIR"
    sudo -u "$TSF_USER" git fetch origin
    sudo -u "$TSF_USER" git checkout "$BRANCH"
    sudo -u "$TSF_USER" git pull origin "$BRANCH"
else
    sudo -u "$TSF_USER" git clone -b "$BRANCH" "$REPO_URL" "$TSF_DIR"
fi
log_ok "Repositorio clonado/actualizado"

# 8. Configurar firewall (UFW)
log_info "Configurando firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow 8000/tcp comment "TSF API (local only)"  # Solo si usas reverse proxy
ufw allow 9090/tcp comment "Prometheus (local only)"
ufw allow 3000/tcp comment "Grafana (local only)"
# NO exponer 5432, 6379, 3100 públicamente
ufw --force enable
log_ok "Firewall configurado"

# 9. Configurar fail2ban
log_info "Configurando fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
EOF
systemctl enable fail2ban
systemctl restart fail2ban
log_ok "fail2ban configurado"

# 10. Configurar logrotate para TSF
log_info "Configurando logrotate..."
cat > /etc/logrotate.d/tsf << 'EOF'
/opt/tsf/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 tsf tsf
    sharedscripts
    postrotate
        systemctl reload tsf > /dev/null 2>&1 || true
    endscript
}

/var/log/tsf/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 tsf tsf
}
EOF
log_ok "logrotate configurado"

# 11. Crear directorios y permisos
log_info "Creando estructura de directorios..."
mkdir -p \
    "$TSF_DIR/data"/{raw,pit,audits,manifests} \
    "$TSF_DIR/research"/{hypotheses,pipelines,backtests,evidence,adjudications,artifacts} \
    "$TSF_DIR/strategies" \
    "$TSF_DIR/lessons" \
    "$TSF_DIR/governance" \
    "$TSF_DIR/logs" \
    "$TSF_DIR/monitoring"/{prometheus,grafana/dashboards} \
    "$TSF_DIR/config" \
    "$TSF_DIR/deployment"/{docker,systemd,scripts}
chown -R "$TSF_USER:$TSF_USER" "$TSF_DIR"
chmod 750 "$TSF_DIR/data" "$TSF_DIR/research" "$TSF_DIR/lessons" "$TSF_DIR/governance" "$TSF_DIR/logs"
log_ok "Directorios creados"

# 12. Instalar systemd service
log_info "Instalando systemd service..."
cp "$TSF_DIR/deployment/systemd/tsf.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable tsf
log_ok "Systemd service instalado"

# 13. Generar secrets (si no existen)
log_info "Generando secrets..."
mkdir -p /run/secrets
chmod 700 /run/secrets

generate_secret() {
    local name="$1"
    local file="/run/secrets/$name"
    if [[ ! -f "$file" ]]; then
        openssl rand -base64 32 > "$file"
        chmod 600 "$file"
        chown root:root "$file"
        log_ok "Secret $name generado"
    else
        log_warn "Secret $name ya existe"
    fi
}

generate_secret "postgres_password"
generate_secret "redis_password"
generate_secret "grafana_admin_user"
generate_secret "grafana_admin_password"

# 14. Crear .env template (usuario debe completar)
log_info "Creando .env template..."
cat > "$TSF_DIR/.env.template" << 'EOF'
# =============================================================================
# TRADING SCIENCE FRAMEWORK - PRODUCTION ENVIRONMENT
# =============================================================================
# COPIA ESTE ARCHIVO A .env Y COMPLETA TUS VALORES REALES
# LOS SECRETS SE LEEN DESDE /run/secrets/ (Docker secrets)
# =============================================================================

# OANDA v20 API (DEMO primero, LIVE solo tras validación)
OANDA_ACCOUNT_ID=your-demo-account-id
OANDA_API_KEY=your-demo-api-key
OANDA_ENVIRONMENT=practice

# DATABASE (usa Docker secrets en prod)
POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
# DATABASE_URL=postgresql+asyncpg://tsf:${POSTGRES_PASSWORD}@postgres:5432/tsf

# REDIS
REDIS_PASSWORD_FILE=/run/secrets/redis_password
# REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0

# GRAFANA
GRAFANA_ADMIN_USER_FILE=/run/secrets/grafana_admin_user
GRAFANA_ADMIN_PASSWORD_FILE=/run/secrets/grafana_admin_password

# TRADING CONFIG
DEFAULT_SYMBOL=XAUUSD
DEFAULT_TIMEFRAME=M5
SESSION_START_HOUR=13
SESSION_END_HOUR=20

# RISK MANAGEMENT (CONSERVADOR)
DEFAULT_SIZING_MODE=2
DEFAULT_RISK_PCT_EQUITY=0.5
DEFAULT_MAX_LOTS=1.0
DEFAULT_SL_MULT_ATR=1.5
DEFAULT_TP_R_MULTIPLE=2.0
DEFAULT_COOLDOWN_MINUTES=10
DEFAULT_MAX_TRADES_PER_DAY=5
DEFAULT_DAILY_LOSS_LIMIT_PCT=2.0

# KALMAN (REFERENCIA HISTÓRICA)
KALMAN_BARS=50
KALMAN_Q=0.05
KALMAN_R=0.30
EMA_PERIOD=30
SIGNAL_SMOOTHING=3

# VOLATILIDAD
ATR_PERIOD=14
MIN_VOL_POINTS=50.0
MAX_SPREAD_PCT_ATR=0.35

# MAGIC NUMBER
MAGIC_NUMBER=482011

# LOGGING
LOG_LEVEL=INFO
LOG_FORMAT=json
EOF
cp "$TSF_DIR/.env.template" "$TSF_DIR/.env"
chown "$TSF_USER:$TSF_USER" "$TSF_DIR/.env" "$TSF_DIR/.env.template"
chmod 600 "$TSF_DIR/.env"
log_ok ".env template creado (DEBES EDITARLO con tus credenciales OANDA)"

# 15. Configurar Docker secrets para producción
log_info "Configurando Docker secrets..."
mkdir -p /opt/tsf/secrets
cp /run/secrets/* /opt/tsf/secrets/
chown -R "$TSF_USER:$TSF_USER" /opt/tsf/secrets
chmod 600 /opt/tsf/secrets/*

# 16. Build inicial de imagen Docker
log_info "Construyendo imagen Docker inicial (puede tardar 5-10 min)..."
cd "$TSF_DIR"
sudo -u "$TSF_USER" docker-compose -f docker-compose.yml -f docker-compose.prod.yml build --pull
log_ok "Imagen Docker construida"

# 17. Verificar configuración
log_info "Verificando configuración..."
sudo -u "$TSF_USER" docker-compose -f docker-compose.yml -f docker-compose.prod.yml config -q
log_ok "Configuración docker-compose válida"

# 18. Resumen final
echo
echo "==============================================================================="
log_ok "=== VPS SETUP COMPLETADO ==="
echo "==============================================================================="
echo
echo "PRÓXIMOS PASOS OBLIGATORIOS:"
echo
echo "1. EDITAR CONFIGURACIÓN:"
echo "   nano $TSF_DIR/.env"
echo "   # Poner tus credenciales OANDA DEMO reales"
echo
echo "2. VERIFICAR SECRETS:"
echo "   cat /opt/tsf/secrets/postgres_password"
echo "   # Copiar a Docker secrets si usas swarm, o mantener en /run/secrets/"
echo
echo "3. PROBAR CONEXIÓN OANDA:"
echo "   cd $TSF_DIR && sudo -u $TSF_USER docker-compose run --rm app tsf data fetch --count 10"
echo
echo "4. EJECUTAR DEMOS TOOLCHAIN:"
echo "   sudo -u $TSF_USER docker-compose run --rm app tsf demo --phase 0"
echo
echo "5. INICIAR SERVICIO:"
echo "   systemctl start tsf"
echo "   systemctl status tsf"
echo "   journalctl -u tsf -f"
echo
echo "MONITOREO:"
echo "  - Grafana: http://TU_VPS_IP:3000 (admin / secret en /run/secrets/grafana_admin_password)"
echo "  - Prometheus: http://TU_VPS_IP:9090"
echo "  - Logs: journalctl -u tsf -f"
echo
echo "COMANDOS ÚTILES:"
echo "  systemctl restart tsf     # Reiniciar stack completo"
echo "  systemctl stop tsf        # Parar stack completo"
echo "  docker-compose -f docker-compose.yml -f docker-compose.prod.yml logs -f app  # Logs app"
echo "  docker-compose -f docker-compose.yml -f docker-compose.prod.yml exec app tsf --check-config"
echo
log_warn "IMPORTANTE: Configura reverse proxy (nginx/traefik) + TLS para exponer Grafana/API de forma segura"
log_warn "NO expongas puertos 5432, 6379, 3100, 9090, 3000 directamente a Internet"
echo
log_ok "Setup completado. ¡A investigar científicamente!"