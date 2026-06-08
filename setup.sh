#!/usr/bin/env bash

set -Eeuo pipefail

#########################################
# CONFIGURAÇÕES
#########################################

SSH_PORT="2222"
ADMIN_USER="admin"

#########################################
# FUNÇÕES UTILITÁRIAS
#########################################

log()  { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERRO]  $*" >&2; exit 1; }

#########################################
# VERIFICAÇÕES INICIAIS
#########################################

[ "$(id -u)" -eq 0 ] || die "Execute como root."

# Ubuntu 24.04 (Noble) obrigatório
. /etc/os-release
[[ "${VERSION_CODENAME:-}" == "noble" ]] \
    || warn "Script otimizado para Ubuntu 24.04 (noble). Detectado: ${VERSION_CODENAME:-desconhecido}"

#########################################
# ATUALIZAÇÃO
#########################################

log "Atualizando sistema..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "Sistema atualizado."

#########################################
# PACOTES BÁSICOS
#########################################

log "Instalando pacotes básicos..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
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
    unattended-upgrades \
    apt-listchanges
ok "Pacotes básicos instalados."

#########################################
# USUÁRIO ADMIN
#########################################

if ! id "$ADMIN_USER" &>/dev/null; then
    log "Criando usuário $ADMIN_USER..."

    # --gecos "" evita perguntas interativas; sem --disabled-password
    # para que passwd funcione imediatamente em seguida
    adduser --gecos "" "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"

    ok "Usuário $ADMIN_USER criado e adicionado ao grupo sudo."
else
    warn "Usuário $ADMIN_USER já existe. Pulando criação."
fi

#########################################
# SSH
#########################################

log "Configurando SSH..."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

# Localiza o binário sshd com segurança
SSHD_BIN=""
for _bin in /usr/sbin/sshd /usr/bin/sshd; do
    [ -x "$_bin" ] && { SSHD_BIN="$_bin"; break; }
done
[ -n "$SSHD_BIN" ] || SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
[ -n "$SSHD_BIN" ] || die "sshd não encontrado após instalação."

mkdir -p /etc/ssh/sshd_config.d

# No Ubuntu 24.04 o arquivo principal pode ter Include já configurado;
# garantimos que o diretório está incluído
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
    log "Diretiva Include adicionada ao sshd_config principal."
fi

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PrintMotd no
EOF

log "Validando configuração SSH..."
"$SSHD_BIN" -t || {
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    die "Configuração SSH inválida. Arquivo removido."
}

# Ubuntu 24.04 usa o serviço 'ssh' (não 'sshd')
if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -q '^ssh\.service$'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files --no-legend | awk '{print $1}' | grep -q '^sshd\.service$'; then
    SSH_SERVICE="sshd"
else
    die "Serviço SSH não encontrado."
fi

systemctl enable "$SSH_SERVICE"
systemctl restart "$SSH_SERVICE"
ok "SSH configurado na porta ${SSH_PORT} (serviço: ${SSH_SERVICE})."

#########################################
# FAIL2BAN
#########################################

log "Configurando Fail2Ban..."

# Ubuntu 24.04: garante que o diretório exista
mkdir -p /etc/fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 5
bantime  = 1h
findtime = 10m
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban configurado."

#########################################
# FIREWALL (UFW)
#########################################

log "Configurando firewall..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Regras explícitas com comentários
ufw allow "${SSH_PORT}/tcp"   comment 'SSH customizado'
ufw allow 80/tcp              comment 'HTTP'
ufw allow 443/tcp             comment 'HTTPS'

ufw --force enable
ok "Firewall ativo."

#########################################
# DOCKER
#########################################

log "Instalando Docker..."

# Remove versões antigas se existirem
for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
            podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings

# Sobrescreve chave existente sem erro
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Ubuntu 24.04 (noble): o repositório Docker já suporta noble
# mas caso a distro retorne algo inesperado, usamos fallback para jammy
_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
# Fallback: se o codename não tiver repo Docker conhecido, usa jammy
case "$_CODENAME" in
    noble|jammy|focal|bionic) ;;
    *) warn "Codename '$_CODENAME' pode não ter repo Docker. Usando 'jammy' como fallback."
       _CODENAME="jammy" ;;
esac

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable docker
systemctl start docker

# Adiciona admin ao grupo docker apenas se o usuário existir
if id "$ADMIN_USER" &>/dev/null; then
    usermod -aG docker "$ADMIN_USER"
fi

ok "Docker instalado: $(docker --version)"

#########################################
# ESTRUTURA DE PROJETO
#########################################

log "Criando estrutura de diretórios..."

mkdir -p /opt/prefeitura/{nginx,postgres,backups,frontend,backend,logs}

# Permissão ao admin
chown -R "${ADMIN_USER}:${ADMIN_USER}" /opt/prefeitura 2>/dev/null || true

ok "Estrutura criada em /opt/prefeitura."

#########################################
# PÁGINA TEMPORÁRIA
#########################################

mkdir -p /var/www/html

cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
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

log "Configurando Nginx..."

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/prefeitura <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html;

    server_name _;

    # Segurança: oculta versão do nginx
    server_tokens off;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

ln -sf \
    /etc/nginx/sites-available/prefeitura \
    /etc/nginx/sites-enabled/prefeitura

nginx -t || die "Configuração do Nginx inválida."

systemctl enable nginx
systemctl restart nginx
ok "Nginx configurado."

#########################################
# ATUALIZAÇÕES AUTOMÁTICAS
#########################################

log "Configurando atualizações automáticas..."

# Método direto: mais confiável que dpkg-reconfigure em scripts não-interativos
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
ok "Atualizações automáticas configuradas."

#########################################
# RESUMO FINAL
#########################################

echo
echo "======================================="
echo " SERVIDOR PREPARADO COM SUCESSO"
echo "======================================="
echo " Sistema      : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo " Docker       : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
echo " Nginx        : $(nginx -v 2>&1 | cut -d'/' -f2)"
echo " SSH porta    : ${SSH_PORT}"
echo " Firewall     : ativo (UFW)"
echo " Fail2Ban     : ativo"
echo " Auto-updates : ativo"
echo "======================================="
echo
echo " Próximas etapas:"
echo "  1. Configurar DNS para este servidor"
echo "  2. Emitir certificados TLS (certbot)"
echo "  3. Subir containers via docker compose"
echo "  4. Configurar PostgreSQL"
echo "  5. Implantar aplicação"
echo "======================================="
echo
warn "Reconecte via SSH na porta ${SSH_PORT} antes de encerrar esta sessão!"
echo