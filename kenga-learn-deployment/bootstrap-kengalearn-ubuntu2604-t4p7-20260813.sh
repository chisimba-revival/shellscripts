#!/usr/bin/env bash
# Provision the Kenga Learn production Docker host on Ubuntu 26.04 LTS.
# Run as Derek; sudo is used only for host-level provisioning.
set -Eeuo pipefail

stamp="$(date +%Y%m%d-%H%M%S)"
report="/home/derek/Downloads/killme-kengalearn-host-bootstrap-${stamp}.txt"
docker_keyring="/etc/apt/keyrings/docker.asc"
docker_sources="/etc/apt/sources.list.d/docker.sources"
docker_daemon="/etc/docker/daemon.json"
ssh_dropin="/etc/ssh/sshd_config.d/60-kengalearn.conf"
swap_file="/swapfile"

mkdir -p /home/derek/Downloads
: >"$report"
exec > >(tee -a "$report") 2>&1

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

printf 'Kenga Learn Ubuntu 26.04 production-host bootstrap\n'
printf 'Started: %s\n\n' "$(date -Is)"

[[ "$(id -un)" = derek ]] || fail 'This script must be run as derek'
[[ -r /etc/os-release ]] || fail '/etc/os-release is unavailable'
. /etc/os-release
[[ "${ID:-}" = ubuntu ]] || fail "Expected Ubuntu, found ${ID:-unknown}"
[[ "${VERSION_ID:-}" = 26.04 ]] || fail "Expected Ubuntu 26.04, found ${VERSION_ID:-unknown}"
[[ -s /home/derek/.ssh/authorized_keys ]] || fail 'Derek SSH authorised_keys is missing or empty'
pass 'Ubuntu 26.04 and Derek SSH-key access verified'

printf '\n=== SUDO AUTHENTICATION ===\n'
sudo -v
pass 'sudo authentication succeeded'

printf '\n=== OPERATING-SYSTEM UPDATE ===\n'
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
    ca-certificates curl git gnupg jq rsync unzip acl unattended-upgrades
pass 'base operating system and deployment tools updated'

printf '\n=== SWAP PROTECTION ===\n'
if swapon --noheadings --show=NAME | grep -Fxq "$swap_file"; then
    pass '2 GiB swap file is already active'
else
    if [[ ! -f "$swap_file" ]]; then
        if ! sudo fallocate -l 2G "$swap_file"; then
            sudo dd if=/dev/zero of="$swap_file" bs=1M count=2048 status=progress
        fi
    fi
    sudo chmod 600 "$swap_file"
    if ! sudo file "$swap_file" | grep -q 'swap file'; then
        sudo mkswap "$swap_file"
    fi
    sudo swapon "$swap_file"
    if ! grep -Eq '^/swapfile[[:space:]]' /etc/fstab; then
        printf '/swapfile none swap sw 0 0\n' | sudo tee -a /etc/fstab >/dev/null
    fi
    pass '2 GiB swap file created and made persistent'
fi

printf 'vm.swappiness=10\n' | sudo tee /etc/sysctl.d/60-kengalearn-memory.conf >/dev/null
sudo sysctl --system >/dev/null
pass 'production swappiness configured'

printf '\n=== OFFICIAL DOCKER ENGINE ===\n'
sudo install -m 0755 -d /etc/apt/keyrings
tmp_key="$(mktemp)"
trap 'rm -f "$tmp_key"' EXIT
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp_key"
sudo install -m 0644 "$tmp_key" "$docker_keyring"

architecture="$(dpkg --print-architecture)"
codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "$codename" ]] || fail 'Ubuntu codename could not be determined'
sudo tee "$docker_sources" >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: $docker_keyring
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker derek
pass 'Docker Engine and Compose installed from the official repository'

printf '\n=== DOCKER LOG RETENTION ===\n'
sudo install -m 0755 -d /etc/docker
if [[ -s "$docker_daemon" ]]; then
    if ! sudo jq -e . "$docker_daemon" >/dev/null; then
        fail "$docker_daemon contains invalid JSON"
    fi
    tmp_daemon="$(mktemp)"
    sudo jq '. + {
        "log-driver": "local",
        "log-opts": {
            "max-size": "10m",
            "max-file": "3"
        }
    }' "$docker_daemon" >"$tmp_daemon"
    sudo install -m 0644 "$tmp_daemon" "$docker_daemon"
    rm -f "$tmp_daemon"
else
    sudo tee "$docker_daemon" >/dev/null <<'JSON'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
fi
sudo systemctl restart docker
pass 'bounded Docker log retention configured'

printf '\n=== PRODUCTION DIRECTORY BOUNDARY ===\n'
if ! getent group kengalearn >/dev/null; then
    sudo groupadd --system kengalearn
fi
sudo usermod -aG kengalearn derek
sudo install -d -o derek -g kengalearn -m 2775 \
    /srv/kengalearn \
    /srv/kengalearn/app \
    /srv/kengalearn/releases \
    /srv/kengalearn/shared \
    /srv/kengalearn/shared/usrfiles
sudo install -d -o derek -g kengalearn -m 2770 \
    /srv/kengalearn/shared/config \
    /srv/kengalearn/backups
pass 'immutable releases and persistent production data have separate directories'

printf '\n=== AUTOMATIC SECURITY UPDATES ===\n'
sudo systemctl enable --now unattended-upgrades
pass 'automatic Ubuntu security updates enabled'

printf '\n=== SSH HARDENING ===\n'
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo tee "$ssh_dropin" >/dev/null <<'SSH'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
SSH
sudo sshd -t
sudo systemctl reload ssh
pass 'SSH restricted to public keys and routine root login disabled'

printf '\n=== VERIFICATION ===\n'
sudo docker version --format 'Docker server: {{.Server.Version}}'
sudo docker compose version
sudo docker run --rm hello-world >/dev/null
pass 'Docker daemon executed a verification container'

printf '\nMemory:\n'
free -h
printf '\nSwap:\n'
swapon --show
printf '\nRoot filesystem:\n'
df -h /
printf '\nKenga Learn directories:\n'
find /srv/kengalearn -maxdepth 2 -type d -printf '%M %u:%g %p\n' | sort

printf '\n=== RESULT ===\n'
printf 'KENGALEARN_HOST_BOOTSTRAP=PASS\n'
printf 'Report: %s\n' "$report"
if [[ -f /var/run/reboot-required ]]; then
    printf 'REBOOT_REQUIRED=YES\n'
else
    printf 'REBOOT_REQUIRED=NO\n'
fi
printf 'Log out and reconnect before using Docker without sudo.\n'
