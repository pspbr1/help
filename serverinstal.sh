#!/usr/bin/env bash

set -Eeuo pipefail

#########################################
# CONFIGURAÇÕES
#########################################

SSH_PORT="2222"
ADMIN_USER="admin"

#########################################
# VERIFICAÇÕES
#########################################

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root."
    exit 1
fi

#########################################
# ATUALIZAÇÃO
#########################################

apt update
apt upgrade -y

#########################################
# PACOTES BÁSICOS
#########################################

apt install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    nginx \
    fail2ban \
    unattended-upgrades

#########################################
# USUÁRIO ADMIN
#########################################

if ! id "$ADMIN_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"

    echo
    echo "================================"
    echo "Defina uma senha para:"
    echo "$ADMIN_USER"
    echo "================================"
    passwd "$ADMIN_USER"
fi

#########################################
# SSH
#########################################

echo "[INFO] Configurando SSH..."

if ! dpkg -s openssh-server >/dev/null 2>&1; then
    echo "[INFO] Instalando OpenSSH Server..."
    apt update
    apt install -y openssh-server
fi

SSHD_BIN="$(command -v sshd || true)"

if [ -z "$SSHD_BIN" ]; then
    if [ -x /usr/sbin/sshd ]; then
        SSHD_BIN="/usr/sbin/sshd"
    else
        echo "[ERRO] sshd não encontrado."
        exit 1
    fi
fi

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF

echo "[INFO] Validando configuração SSH..."

if ! "$SSHD_BIN" -t; then
    echo "[ERRO] Configuração SSH inválida."

    rm -f /etc/ssh/sshd_config.d/99-hardening.conf

    echo "[INFO] Arquivo removido."

    exit 1
fi

echo "[INFO] Reiniciando SSH..."

if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl restart ssh
    systemctl enable ssh
elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl restart sshd
    systemctl enable sshd
else
    echo "[ERRO] Serviço SSH não encontrado."
    exit 1
fi

echo "[OK] SSH configurado."

#########################################
# FAIL2BAN
#########################################

cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled=true
port=${SSH_PORT}
maxretry=5
bantime=1h
findtime=10m
EOF

systemctl enable fail2ban
systemctl restart fail2ban

#########################################
# FIREWALL
#########################################

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable

#########################################
# DOCKER
#########################################

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
> /etc/apt/sources.list.d/docker.list

apt update

apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable docker
systemctl start docker

usermod -aG docker "$ADMIN_USER"

#########################################
# ESTRUTURA DE PROJETO
#########################################

mkdir -p /opt/prefeitura

mkdir -p /opt/prefeitura/nginx
mkdir -p /opt/prefeitura/postgres
mkdir -p /opt/prefeitura/backups
mkdir -p /opt/prefeitura/frontend
mkdir -p /opt/prefeitura/backend
mkdir -p /opt/prefeitura/logs

#########################################
# PÁGINA TEMPORÁRIA
#########################################

cat >/var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>Servidor Preparado</title>
</head>
<body>
<h1>Servidor pronto para implantação</h1>
<p>Aguardando apontamento DNS.</p>
</body>
</html>
EOF

#########################################
# NGINX
#########################################

rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf \
/etc/nginx/sites-available/default \
/etc/nginx/sites-enabled/default

nginx -t

systemctl enable nginx
systemctl restart nginx

#########################################
# ATUALIZAÇÕES AUTOMÁTICAS
#########################################

dpkg-reconfigure -f noninteractive unattended-upgrades

#########################################
# STATUS
#########################################

echo
echo "======================================="
echo "SERVIDOR PREPARADO"
echo "======================================="
echo "Docker instalado"
echo "Nginx instalado"
echo "Fail2Ban ativo"
echo "Firewall ativo"
echo "Atualizações automáticas ativas"
echo
echo "Próximas etapas:"
echo "1. Configurar DNS"
echo "2. Configurar containers"
echo "3. Configurar PostgreSQL"
echo "4. Emitir certificados TLS"
echo "5. Implantar aplicação"
echo "======================================="