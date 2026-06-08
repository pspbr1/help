#!/usr/bin/env bash
# =============================================================================
#  setup-servidor.sh
#  Pré-configuração de servidor Ubuntu para:
#    • Site institucional (HTML/PHP ou proxy reverso)
#    • Sistema de Agendamento de Serviços e Veículos
#  Autor  : gerado para uso municipal
#  Testado: Ubuntu 22.04 LTS / 24.04 LTS
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC}  $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
         echo -e "${BOLD}  $*${NC}"; \
         echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }

# ── Verificações iniciais ─────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Execute como root:  sudo bash $0"

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "0")
[[ "$UBUNTU_VER" == "22.04" || "$UBUNTU_VER" == "24.04" ]] \
  || warn "Script otimizado para Ubuntu 22.04/24.04. Versão detectada: $UBUNTU_VER"

# ── Variáveis configuráveis ───────────────────────────────────────────────────
DOMINIO_SITE="${DOMINIO_SITE:-site.prefeitura.gov.br}"
DOMINIO_AGENDA="${DOMINIO_AGENDA:-agenda.prefeitura.gov.br}"
EMAIL_ADMIN="${EMAIL_ADMIN:-ti@prefeitura.gov.br}"
APP_USER="${APP_USER:-webadmin}"
APP_DIR_SITE="/var/www/${DOMINIO_SITE}"
APP_DIR_AGENDA="/var/www/${DOMINIO_AGENDA}"
DB_NAME_AGENDA="${DB_NAME_AGENDA:-agendamento_db}"
DB_USER_AGENDA="${DB_USER_AGENDA:-agenda_user}"
DB_PASS_AGENDA="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"
SWAP_SIZE="2G"
SSH_PORT="${SSH_PORT:-22}"          # troque para outra porta se quiser
FUSO_HORARIO="America/Sao_Paulo"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════╗
 ║         SETUP SERVIDOR MUNICIPAL  —  v1.0               ║
 ║   Site Institucional + Sistema de Agendamento           ║
 ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "  Domínio site    : ${YELLOW}${DOMINIO_SITE}${NC}"
echo -e "  Domínio agenda  : ${YELLOW}${DOMINIO_AGENDA}${NC}"
echo -e "  E-mail admin    : ${YELLOW}${EMAIL_ADMIN}${NC}"
echo -e "  Usuário app     : ${YELLOW}${APP_USER}${NC}"
echo ""
read -rp "  Confirma as configurações acima? [s/N] " CONFIRMA
[[ "${CONFIRMA,,}" == "s" ]] || err "Abortado pelo usuário."

# ════════════════════════════════════════════════════════════════════════════
step "1/12 · Sistema base e fuso horário"
# ════════════════════════════════════════════════════════════════════════════
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone "$FUSO_HORARIO"
log "Fuso horário: $FUSO_HORARIO"

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  software-properties-common apt-transport-https \
  unzip zip git vim nano htop net-tools dnsutils \
  ufw fail2ban logrotate cron rsync \
  build-essential openssl
log "Pacotes base instalados"

# ════════════════════════════════════════════════════════════════════════════
step "2/12 · Swap (${SWAP_SIZE})"
# ════════════════════════════════════════════════════════════════════════════
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swap.conf
  log "Swap de ${SWAP_SIZE} configurado"
else
  info "Swap já existente — pulando"
fi

# ════════════════════════════════════════════════════════════════════════════
step "3/12 · Nginx"
# ════════════════════════════════════════════════════════════════════════════
apt-get install -y -qq nginx
systemctl enable nginx
systemctl start nginx

# Ajuste de performance no nginx.conf
NGINX_WORKERS=$(nproc)
sed -i "s/worker_processes .*/worker_processes ${NGINX_WORKERS};/" /etc/nginx/nginx.conf

# Parâmetros extras de segurança e performance
cat > /etc/nginx/conf.d/security.conf <<'EOF'
# Segurança
server_tokens off;
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "strict-origin-when-cross-origin";

# Performance
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_types text/plain text/css text/xml application/json
           application/javascript application/rss+xml
           application/atom+xml image/svg+xml;

# Timeouts
client_body_timeout 12;
client_header_timeout 12;
keepalive_timeout 15;
send_timeout 10;

# Limite de upload (ajuste conforme necessidade)
client_max_body_size 20M;
EOF

log "Nginx instalado e configurado"

# ════════════════════════════════════════════════════════════════════════════
step "4/12 · PHP 8.2 (para o sistema de agendamento)"
# ════════════════════════════════════════════════════════════════════════════
add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
apt-get update -qq
apt-get install -y -qq \
  php8.2-fpm php8.2-cli php8.2-common \
  php8.2-mysql php8.2-pgsql php8.2-sqlite3 \
  php8.2-curl php8.2-mbstring php8.2-xml \
  php8.2-zip php8.2-gd php8.2-intl php8.2-bcmath

# PHP-FPM: ajuste de segurança
PHP_INI="/etc/php/8.2/fpm/php.ini"
sed -i 's/^expose_php.*/expose_php = Off/'              "$PHP_INI"
sed -i 's/^;date.timezone.*/date.timezone = America\/Sao_Paulo/' "$PHP_INI"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/' "$PHP_INI"
sed -i 's/^post_max_size.*/post_max_size = 22M/'        "$PHP_INI"
sed -i 's/^memory_limit.*/memory_limit = 256M/'         "$PHP_INI"
sed -i 's/^max_execution_time.*/max_execution_time = 60/' "$PHP_INI"

systemctl enable php8.2-fpm
systemctl start php8.2-fpm
log "PHP 8.2-FPM configurado"

# ════════════════════════════════════════════════════════════════════════════
step "5/12 · MariaDB (banco de dados)"
# ════════════════════════════════════════════════════════════════════════════
apt-get install -y -qq mariadb-server mariadb-client

systemctl enable mariadb
systemctl start mariadb

# Hardening do MariaDB (equivalente a mysql_secure_installation não-interativo)
ROOT_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 40)"

mysql -u root <<SQL
  -- Senha root
  ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';
  -- Remove usuários anônimos
  DELETE FROM mysql.user WHERE User='';
  -- Remove banco de teste
  DROP DATABASE IF EXISTS test;
  DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
  -- Desabilita login root remoto
  DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
  FLUSH PRIVILEGES;
SQL

# Banco do sistema de agendamento
mysql -u root -p"${ROOT_PASS}" <<SQL
  CREATE DATABASE IF NOT EXISTS \`${DB_NAME_AGENDA}\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '${DB_USER_AGENDA}'@'localhost'
    IDENTIFIED BY '${DB_PASS_AGENDA}';
  GRANT ALL PRIVILEGES ON \`${DB_NAME_AGENDA}\`.* TO '${DB_USER_AGENDA}'@'localhost';
  FLUSH PRIVILEGES;
SQL

# Salva credenciais em arquivo protegido
CRED_FILE="/root/.db_credentials"
cat > "$CRED_FILE" <<CREDS
# Credenciais do banco — MANTENHA SEGURO
# Gerado em: $(date)

MariaDB root password : ${ROOT_PASS}
Database              : ${DB_NAME_AGENDA}
DB User               : ${DB_USER_AGENDA}
DB Password           : ${DB_PASS_AGENDA}
CREDS
chmod 600 "$CRED_FILE"
log "MariaDB configurado. Credenciais salvas em ${CRED_FILE}"

# ════════════════════════════════════════════════════════════════════════════
step "6/12 · Certbot (SSL via Let's Encrypt)"
# ════════════════════════════════════════════════════════════════════════════
apt-get install -y -qq snapd
snap install --classic certbot 2>/dev/null || true
ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

# Renew automático via systemd timer (o snap já instala, mas garantimos o cron também)
if ! crontab -l 2>/dev/null | grep -q 'certbot renew'; then
  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
fi
log "Certbot instalado. SSL será gerado após DNS propagado."

# ════════════════════════════════════════════════════════════════════════════
step "7/12 · Virtual hosts Nginx"
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "${APP_DIR_SITE}/public" "${APP_DIR_AGENDA}/public"

# ── vhost: Site institucional ────────────────────────────────────────────
cat > "/etc/nginx/sites-available/${DOMINIO_SITE}.conf" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMINIO_SITE} www.${DOMINIO_SITE};

    root ${APP_DIR_SITE}/public;
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMINIO_SITE}.access.log;
    error_log  /var/log/nginx/${DOMINIO_SITE}.error.log warn;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
    location ~ /\.git { deny all; }

    # Cache de assets estáticos
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|svg)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
VHOST

# ── vhost: Sistema de Agendamento ────────────────────────────────────────
cat > "/etc/nginx/sites-available/${DOMINIO_AGENDA}.conf" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMINIO_AGENDA};

    root ${APP_DIR_AGENDA}/public;
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMINIO_AGENDA}.access.log;
    error_log  /var/log/nginx/${DOMINIO_AGENDA}.error.log warn;

    # Rate limiting para proteção do sistema
    limit_req_zone \$binary_remote_addr zone=agenda_limit:10m rate=20r/s;
    limit_req zone=agenda_limit burst=30 nodelay;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
    location ~ /\.git { deny all; }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|svg)$ {
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }
}
VHOST

# Ativa os vhosts
ln -sf "/etc/nginx/sites-available/${DOMINIO_SITE}.conf"   /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${DOMINIO_AGENDA}.conf" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
log "Virtual hosts configurados"

# ════════════════════════════════════════════════════════════════════════════
step "8/12 · Página index de boas-vindas (placeholder)"
# ════════════════════════════════════════════════════════════════════════════
cat > "${APP_DIR_SITE}/public/index.html" <<'HTML'
<!DOCTYPE html><html lang="pt-br"><head><meta charset="UTF-8">
<title>Site em construção</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
min-height:100vh;margin:0;background:#f0f4f8;}
.box{text-align:center;padding:2rem;border-radius:12px;background:#fff;box-shadow:0 4px 20px #0002;}
h1{color:#1a56db;}p{color:#555;}</style></head>
<body><div class="box"><h1>🏛️ Prefeitura</h1><p>Site em implantação.</p></div></body></html>
HTML

cat > "${APP_DIR_AGENDA}/public/index.html" <<'HTML'
<!DOCTYPE html><html lang="pt-br"><head><meta charset="UTF-8">
<title>Sistema de Agendamento — em implantação</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
min-height:100vh;margin:0;background:#f0f4f8;}
.box{text-align:center;padding:2rem;border-radius:12px;background:#fff;box-shadow:0 4px 20px #0002;}
h1{color:#0f766e;}p{color:#555;}</style></head>
<body><div class="box"><h1>📅 Agendamento</h1><p>Sistema em implantação.</p></div></body></html>
HTML

log "Páginas placeholder criadas"

# ════════════════════════════════════════════════════════════════════════════
step "9/12 · Usuário da aplicação"
# ════════════════════════════════════════════════════════════════════════════
if ! id "$APP_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G www-data "$APP_USER"
  log "Usuário '${APP_USER}' criado"
else
  info "Usuário '${APP_USER}' já existe — pulando criação"
fi

chown -R "${APP_USER}:www-data" "${APP_DIR_SITE}" "${APP_DIR_AGENDA}"
find "${APP_DIR_SITE}" "${APP_DIR_AGENDA}" -type d -exec chmod 750 {} \;
find "${APP_DIR_SITE}" "${APP_DIR_AGENDA}" -type f -exec chmod 640 {} \;
log "Permissões aplicadas"

# ════════════════════════════════════════════════════════════════════════════
step "10/12 · Firewall (UFW)"
# ════════════════════════════════════════════════════════════════════════════
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"   comment "SSH"
ufw allow 80/tcp              comment "HTTP"
ufw allow 443/tcp             comment "HTTPS"
ufw --force enable
log "UFW ativado (SSH:${SSH_PORT}, HTTP:80, HTTPS:443)"

# ════════════════════════════════════════════════════════════════════════════
step "11/12 · Fail2ban"
# ════════════════════════════════════════════════════════════════════════════
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 24h

[nginx-http-auth]
enabled  = true

[nginx-botsearch]
enabled  = true
logpath  = /var/log/nginx/*.error.log
maxretry = 2

[nginx-limit-req]
enabled  = true
logpath  = /var/log/nginx/*.error.log
maxretry = 10
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configurado e ativo"

# ════════════════════════════════════════════════════════════════════════════
step "12/12 · Ajustes finais do kernel e hardening"
# ════════════════════════════════════════════════════════════════════════════
cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTL'
# Rede — proteção contra ataques comuns
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Limitar log de mensagens desnecessárias
net.ipv4.conf.all.log_martians = 1
# Aumentar backlog de conexões
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
# Performance de arquivo (útil para Nginx)
fs.file-max = 100000
SYSCTL

sysctl --system > /dev/null 2>&1
log "Parâmetros de kernel aplicados"

# Desabilitar módulos desnecessários
if ! grep -q 'usb-storage' /etc/modprobe.d/blacklist.conf 2>/dev/null; then
  echo 'blacklist usb-storage' >> /etc/modprobe.d/blacklist.conf
fi

# ════════════════════════════════════════════════════════════════════════════
# RELATÓRIO FINAL
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}"
cat <<'REPORT'
 ╔══════════════════════════════════════════════════════════╗
 ║               SETUP CONCLUÍDO COM SUCESSO!              ║
 ╚══════════════════════════════════════════════════════════╝
REPORT
echo -e "${NC}"

echo -e "${BOLD}  📋 PRÓXIMOS PASSOS OBRIGATÓRIOS:${NC}"
echo ""
echo -e "  ${CYAN}1. Aguardar propagação do DNS Tipo A${NC}"
echo "     → Verifique: dig +short ${DOMINIO_SITE}"
echo "     → Verifique: dig +short ${DOMINIO_AGENDA}"
echo ""
echo -e "  ${CYAN}2. Emitir certificados SSL (após DNS propagado):${NC}"
echo "     sudo certbot --nginx -d ${DOMINIO_SITE} -d www.${DOMINIO_SITE} -m ${EMAIL_ADMIN} --agree-tos --no-eff-email"
echo "     sudo certbot --nginx -d ${DOMINIO_AGENDA} -m ${EMAIL_ADMIN} --agree-tos --no-eff-email"
echo ""
echo -e "  ${CYAN}3. Credenciais do banco de dados:${NC}"
echo "     → Arquivo protegido: /root/.db_credentials"
echo "     → cat /root/.db_credentials"
echo ""
echo -e "  ${CYAN}4. Deploy do sistema de agendamento:${NC}"
echo "     → Coloque os arquivos em: ${APP_DIR_AGENDA}/public/"
echo "     → Coloque o site em    : ${APP_DIR_SITE}/public/"
echo "     → Usuário responsável  : ${APP_USER}"
echo ""
echo -e "  ${CYAN}5. Configurar .env do sistema de agendamento:${NC}"
echo "     DB_HOST=localhost"
echo "     DB_NAME=${DB_NAME_AGENDA}"
echo "     DB_USER=${DB_USER_AGENDA}"
echo "     DB_PASS=(veja /root/.db_credentials)"
echo ""
echo -e "  ${YELLOW}⚠  SEGURANÇA:${NC}"
echo "     → Troque a porta SSH (atual: ${SSH_PORT}) se necessário: /etc/ssh/sshd_config"
echo "     → Configure backup automático do banco em /etc/cron.d/"
echo "     → Habilite autenticação por chave SSH e desative senha se possível"
echo ""
echo -e "  ${GREEN}✔ Serviços ativos: nginx, php8.2-fpm, mariadb, ufw, fail2ban${NC}"
echo ""
