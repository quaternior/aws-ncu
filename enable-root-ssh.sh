#!/usr/bin/env bash
# enable_root_ssh.sh
# OpenSSH에서 root의 키 기반 로그인 허용 + 현재 사용자의 authorized_keys를 /root로 복사
# - PermitRootLogin prohibit-password
# - PasswordAuthentication no
# - PubkeyAuthentication yes
# - sshd 재시작
# 롤백: --rollback

set -euo pipefail

SSH_CFG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)"

service_name=""
detect_service() {
  # Ubuntu는 보통 ssh, Amazon Linux/RHEL/SUSE 등은 sshd
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    service_name="ssh"
  else
    service_name="sshd"
  fi
}

restart_sshd() {
  detect_service
  systemctl daemon-reload || true
  systemctl restart "$service_name"
  systemctl is-active --quiet "$service_name"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[!] Run as root: sudo $0"
    exit 1
  fi
}

backup_cfg() {
  cp -a "$SSH_CFG" "$BACKUP"
  echo "[*] Backup created: $BACKUP"
}

restore_cfg() {
  if [[ $# -ne 1 ]]; then
    echo "[!] Usage: $0 --rollback /path/to/backup"
    exit 1
  fi
  ensure_root
  cp -a "$1" "$SSH_CFG"
  restart_sshd
  echo "[*] Restored $SSH_CFG from $1 and restarted SSH."
  exit 0
}

set_conf() {
  local key="$1"
  local val="$2"
  # 주석/기존 설정 제거
  sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*$||g" "$SSH_CFG"
  # 맨 끝에 명시적으로 추가 (Match 블록 밖 가정)
  echo "${key} ${val}" >> "$SSH_CFG"
}

copy_authorized_keys_to_root() {
  local src_user="$1"
  local src_auth="/home/${src_user}/.ssh/authorized_keys"
  # Amazon Linux의 ec2-user 외, Ubuntu의 ubuntu 등 home 경로가 다를 수 있음
  if [[ ! -f "$src_auth" ]]; then
    # 로그인 사용자가 root가 아니고, HOME에 키가 있는 경우
    src_auth="${HOME}/.ssh/authorized_keys"
  fi
  if [[ ! -f "$src_auth" ]]; then
    echo "[!] authorized_keys not found for user '${src_user}'. Put your public key first."
    exit 1
  fi

  mkdir -p /root/.ssh
  cp -a "$src_auth" /root/.ssh/authorized_keys
  chown -R root:root /root/.ssh
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
  echo "[*] Copied ${src_auth} -> /root/.ssh/authorized_keys"
}

harden_basics() {
  # 안전을 위해 비밀번호/챌린지 응답 로그인 불가 + 키 로그인 허용
  set_conf "PasswordAuthentication" "no"
  set_conf "ChallengeResponseAuthentication" "no"
  set_conf "UsePAM" "yes"
  set_conf "PubkeyAuthentication" "yes"
  # root는 키만 허용 (비밀번호 금지)
  set_conf "PermitRootLogin" "prohibit-password"
  # 권장: 엄격 모드
  set_conf "StrictModes" "yes"
  # 호환: X11/포워딩 등 환경에 따라 추가 가능
}

# -------- main --------
if [[ "${1:-}" == "--rollback" ]]; then
  restore_cfg "${2:-}"
fi

ensure_root

if [[ ! -f "$SSH_CFG" ]]; then
  echo "[!] $SSH_CFG not found. Is OpenSSH server installed?"
  exit 1
fi

backup_cfg

# AWS 기본 계정 추정 (없으면 현재 sudo 호출자 사용)
DEFAULT_USER=""
for u in ec2-user ubuntu admin centos fedora opc; do
  if id "$u" &>/dev/null; then DEFAULT_USER="$u"; break; fi
done
if [[ -z "$DEFAULT_USER" ]]; then
  # sudo로 올린 경우 SUDO_USER가 원 사용자
  DEFAULT_USER="${SUDO_USER:-${USER}}"
fi
echo "[*] Using source user: $DEFAULT_USER"

# 구성 반영
harden_basics
copy_authorized_keys_to_root "$DEFAULT_USER"
restart_sshd

echo "[✓] Root SSH (key-only) enabled."
echo "    Try: ssh -i /path/to/key.pem root@<IP or DNS>"
echo "    To rollback: sudo $0 --rollback $BACKUP"
