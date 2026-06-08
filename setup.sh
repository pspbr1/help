#!/usr/bin/env bash

set -e

SSH_PORT="${SSH_PORT:-22}"

echo "[1/6] Instalando OpenSSH Server..."
apt update
apt install -y openssh-server

echo "[2/6] Habilitando serviço..."
systemctl enable ssh
systemctl restart ssh

echo "[3/6] Configurando SSH..."

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sed -i "s/^#Port.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config

grep -q "^Port ${SSH_PORT}$" /etc/ssh/sshd_config || \
echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config

grep -q "^PermitRootLogin" /etc/ssh/sshd_config \
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    || echo "PermitRootLogin no" >> /etc/ssh/sshd_config

grep -q "^PasswordAuthentication" /etc/ssh/sshd_config \
    && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

echo "[4/6] Testando configuração..."
sshd -t

echo "[5/6] Reiniciando SSH..."
systemctl restart ssh

echo "[6/6] Configurando firewall..."
ufw allow ${SSH_PORT}/tcp
ufw --force enable

echo
echo "====================================="
echo "SSH configurado com sucesso"
echo "Porta: ${SSH_PORT}"
echo "====================================="
echo

echo "IP local:"
hostname -I

echo
echo "Para acesso pela Internet você ainda precisa:"
echo "1. Descobrir o IP público."
echo "2. Fazer port forwarding no roteador."
echo "3. Liberar a porta no firewall do provedor (se existir)."