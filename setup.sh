#!/bin/bash

set -e

echo "  @@@@@@ @@@@@@@@ @@@@@@@ @@@  @@@ @@@@@@@ ";
echo " !@@     @@!        @@!   @@!  @@@ @@!  @@@";
echo "  !@@!!  @!!!:!     @!!   @!@  !@! @!@@!@! ";
echo "     !:! !!:        !!:   !!:  !!! !!:     ";
echo " ::.: :  : :: :::    :     :.:: :   :      ";
echo "                                           ";


#######################################
#       --- CONFIGURATION ---
#######################################
DEBUG="${DEBUG:-false}"

NEW_USER="${NEW_USER:-user}"
SSH_PORT="${SSH_PORT:-2222}"

KEY_SOURCE="${KEY_SOURCE:-manual}" # github | manual
GITHUB_USER="${GITHUB_USER:-}"
PUBKEY="${PUBKEY:-}"

ALLOW_HTTP="${ALLOW_HTTP:-false}"
ALLOW_HTTPS="${ALLOW_HTTPS:-false}"
ALLOW_FROM_CIDR="${ALLOW_FROM_CIDR:-}"
TIMEZONE="${TIMEZONE:-UTC}"


#######################################
#          --- FUNCTIONS ---
#######################################
log() {
  echo "[$(date '+%F %T')] [INFO] $*" | tee -a /var/log/server-setup.log
}

warn() {
  echo "[$(date '+%F %T')] [WARN] $*" >&2 | tee -a /var/log/server-setup.log
}

debug() {
  [[ "${DEBUG}" == "true" ]] && echo "[$(date '+%F %T')] [DEBUG] $*" >&2
}

die() {
  echo "[$(date '+%F %T')] [FATAL] $*" >&2 | tee -a /var/log/server-setup.log
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run the script as root"
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%F-%H%M%S)"
  fi
}

validate_pubkey() {
  case "${KEY_SOURCE}" in
    github)
      if [[ -z "${GITHUB_USER}" ]] || [[ "${GITHUB_USER}" == *"REPLACE_ME"* ]]; then
        die "Please enter the correct GITHUB_USER"
      fi
      ;;

    manual)
      if [[ -z "${PUBKEY}" ]] || [[ "${PUBKEY}" == *"REPLACE_ME"* ]]; then
        die "Please enter the correct PUBKEY"
      fi

      if ! printf '%s\n' "${PUBKEY}" | ssh-keygen -l -f - >/dev/null 2>&1; then
        die "PUBKEY is invalid"
      fi
      ;;

    *)
      die "Invalid KEY_SOURCE: ${KEY_SOURCE}. Use: github or manual"
      ;;
  esac
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Could not detect OS"
  fi
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "The script supports Ubuntu/Debian. Found: ${ID:-unknown}" ;;
  esac
}

install_public_keys() {
  local output_file="$1"

  case "${KEY_SOURCE}" in
    github)
      fetch_github_keys "${GITHUB_USER}" "${output_file}"
      ;;

    manual)
      log "Installing SSH public key from PUBKEY variable"
      printf '%s\n' "${PUBKEY}" > "${output_file}"
      ;;

    *)
      die "Invalid KEY_SOURCE: ${KEY_SOURCE}"
      ;;
  esac
}

fetch_github_keys() {
  local github_user="$1"
  local output_file="$2"
  local url="https://github.com/${github_user}.keys"

  log "Fetching SSH public keys from ${url}"

  curl -fsSL "${url}" -o "${output_file}"

  if [[ ! -s "${output_file}" ]]; then
    die "No SSH keys found for GitHub user: ${github_user}"
  fi

  if ! ssh-keygen -l -f "${output_file}" >/dev/null 2>&1; then
    die "Downloaded SSH keys are invalid"
  fi
}

#######################################
#	      --- HELP ---
#######################################
VERSION="1.2.0"

show_help() {
  cat <<EOF
Server Setup Script v${VERSION}

Usage: $0 [OPTIONS]

Options:
  --dry-run          Show what would be done without applying changes
  --debug            Enable verbose debug output
  --skip-apt         Skip package installation/update steps
  --help             Show this help message

Environment variables:
  NEW_USER           Username to create (default: user)
  SSH_PORT           SSH port (default: 2222)
  KEY_SOURCE         github|manual (default: github)
  GITHUB_USER        GitHub username for key fetch
  PUBKEY             Public key content (if KEY_SOURCE=manual)
  ALLOW_HTTP         Allow port 80 (default: false)
  ALLOW_HTTPS        Allow port 443 (default: false)
  ALLOW_FROM_CIDR    Restrict access to CIDR (optional)
  TIMEZONE           System timezone (default: UTC)

Example:
  sudo NEW_USER=user SSH_PORT=2222 GITHUB_USER=myuser $0
  sudo DRY_RUN=true DEBUG=true $0 --skip-apt
EOF
}

# Парсинг аргументов:
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --debug) DEBUG=true; shift ;;
    --skip-apt) SKIP_APT=true; shift ;;
    --help) show_help; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

######################################
#         ---   MAIN   ---
######################################
require_root
detect_os
validate_pubkey

export DEBIAN_FRONTEND=noninteractive

log "Updating packages"
apt-get -qq update 
apt-get -y -o Dpkg::Progress-Fancy="0" dist-upgrade


log "Installing basic packages"
apt-get install -y -qq \
  sudo \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  nano \
  git \
  htop \
  jq \
  rsyslog \
  logrotate \
  chrony \
  auditd \
  needrestart 


log "Setting timezone"
timedatectl set-timezone "${TIMEZONE}" || true

log "Enabling chrony"
systemctl enable --now chrony

#######################################
#         --- USER ---
#######################################
if id "${NEW_USER}" >/dev/null 2>&1; then
  log "User ${NEW_USER} already exists"
else
  log "Creating user ${NEW_USER}"
  adduser --disabled-password --gecos "" "${NEW_USER}"
fi

log "Adding ${NEW_USER} to sudo"
usermod -aG sudo "${NEW_USER}"

log "Setting up an SSH key for ${NEW_USER}"
install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "/home/${NEW_USER}/.ssh"

install_public_keys "/home/${NEW_USER}/.ssh/authorized_keys"

chown "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh/authorized_keys"
chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"


#######################################
# SSH hardening
#######################################
log "Configuring SSH"
backup_file /etc/ssh/sshd_config

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 2
TCPKeepAlive no
Compression no
AllowUsers ${NEW_USER}
EOF

sshd -t || die "Invalid SSH config"
systemctl reload ssh || systemctl reload sshd

#######################################
# sudo hardening
#######################################
log "Setting up sudo"
cat > /etc/sudoers.d/99-secure-defaults <<'EOF'
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults passwd_tries=3
Defaults timestamp_timeout=5
EOF
chmod 440 /etc/sudoers.d/99-secure-defaults
visudo -cf /etc/sudoers.d/99-secure-defaults || die "Invalid sudoers config"

#######################################
# UFW firewall
#######################################
log "Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

if [[ -n "${ALLOW_FROM_CIDR}" ]]; then
  ufw allow from "${ALLOW_FROM_CIDR}" to any port "${SSH_PORT}" proto tcp
else
  ufw allow "${SSH_PORT}"/tcp
fi

if [[ "${ALLOW_HTTP}" == "true" ]]; then
  ufw allow 80/tcp
fi

if [[ "${ALLOW_HTTPS}" == "true" ]]; then
  ufw allow 443/tcp
fi

ufw --force enable

#######################################
# fail2ban
#######################################
log "Configuring fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
EOF

systemctl enable --now fail2ban

#######################################
# Automatic security updates
#######################################
log "Setting up unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

dpkg-reconfigure -f noninteractive unattended-upgrades || true

#######################################
# Basic sysctl hardening
#######################################
log "Configuring sysctl"
cat > /etc/sysctl.d/99-security-hardening.conf <<'EOF'
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
EOF

sysctl --system

#######################################
# Home directory permissions
#######################################
log "Restricting home directory permissions"
chmod 750 "/home/${NEW_USER}"

#######################################
# auditd
#######################################
log "Enabling auditd"
systemctl enable --now auditd

#######################################
# Cleaning
#######################################
log "Cleaning up unused packages"
apt-get -y autoremove
apt-get -y autoclean

#######################################
# etc
#######################################
# for example
# curl -fsSL -o /tmp/vpn-setup.sh https://raw.githubusercontent.com/markreer/vpn/main/setup.sh
# chmod +x /tmp/vpn-setup.sh
# bash /tmp/vpn-setup.sh


#######################################
# Result
#######################################
IP_ADDR="$(hostname -I | awk '{print $1}')"

cat <<EOF

===========================================================================

Done.

Connection:
ssh -p ${SSH_PORT} ${NEW_USER}@${IP_ADDR:-YOUR_SERVER_IP}

Check:
  1. That your key actually works
  2. That the ${SSH_PORT} port is open on your provider/VPS firewall
  3. That root login is no longer required

Useful commands:
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo systemctl status ssh
sudo unattended-upgrade --dry-run -d

===========================================================================
EOF

