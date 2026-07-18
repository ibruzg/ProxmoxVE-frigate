#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: community-scripts (Frigate VM variant of ct/frigate.sh)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/api.func) 2>/dev/null
source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/vm-core.func) 2>/dev/null
source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/cloud-init.func) 2>/dev/null || true

# ==============================================================================
# APP-SPECIFIC VARIABLES
# Frigate's install script hard-requires Debian 12 (Bookworm) - not user-selectable
# ==============================================================================
APP="Frigate"
APP_TYPE="vm"
NSAPP="frigate-vm"
OS_TYPE="debian"
OS_VERSION="12"
OS_CODENAME="bookworm"
OS_DISPLAY="Debian 12 (Bookworm)"
ARCH=$(dpkg --print-architecture)

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
DISK_SIZE="20G"
USE_CLOUD_INIT="no"
THIN="discard=on,ssd=1,"

load_functions

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

function get_image_url() {
  if [ "$USE_CLOUD_INIT" = "yes" ]; then
    echo "https://cloud.debian.org/images/cloud/${OS_CODENAME}/latest/debian-${OS_VERSION}-generic-${ARCH}.qcow2"
  else
    echo "https://cloud.debian.org/images/cloud/${OS_CODENAME}/latest/debian-${OS_VERSION}-nocloud-${ARCH}.qcow2"
  fi
}

# ==============================================================================
# SETTINGS - built from the shared vm_prompt_* helpers in misc/vm-core.func
# ==============================================================================
function default_settings() {
  USE_CLOUD_INIT="no"
  VMID=$(get_valid_nextid)
  FORMAT=""
  if [ "$ARCH" = "arm64" ]; then
    MACHINE=""
    CPU_TYPE=""
  else
    MACHINE=" -machine q35"
    CPU_TYPE=" -cpu host"
  fi
  DISK_CACHE=""
  DISK_SIZE="20G"
  HN="frigate"
  CORE_COUNT="8"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$([ "$ARCH" = "arm64" ] && echo "virt (ARM64)" || echo "Q35 (Modern)")${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${OS}${BOLD}${DGN}OS: ${BGN}${OS_DISPLAY}${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating a Frigate VM using the above settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"

  echo -e "${INFO}${BOLD}${DGN}Frigate installs itself on first boot regardless of Cloud-Init choice.${CL}"
  vm_prompt_cloud_init "root" || true

  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  vm_prompt_vmid "$VMID"

  if [ "$ARCH" = "arm64" ]; then
    FORMAT=""
    MACHINE=""
    echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}virt${CL}"
  else
    vm_prompt_machine_type "q35"
  fi

  vm_prompt_disk_size "$DISK_SIZE" "Set Disk Size in GiB (e.g., 20, 40)"
  vm_prompt_disk_cache "none"
  vm_prompt_hostname "frigate"

  if [ "$ARCH" = "arm64" ]; then
    CPU_TYPE=""
    echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Default${CL}"
  else
    vm_prompt_cpu_model "host"
  fi

  vm_prompt_cpu_cores "8"
  vm_prompt_ram "4096"
  vm_prompt_bridge "vmbr0"
  vm_prompt_mac "$GEN_MAC"
  vm_prompt_vlan
  vm_prompt_mtu
  vm_prompt_start_vm "yes"

  if vm_confirm_advanced_settings "Ready to create a Frigate VM?"; then
    echo -e "${CREATING}${BOLD}${DGN}Creating a Frigate VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if vm_choose_settings_mode "Use Default Settings?"; then
    header_info
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
header_info
check_root
arch_check
pve_check

if ! vm_confirm_new_vm "Frigate VM" "This will create a New Frigate VM (Debian 12).\n\nNote: hardware accelerators (Coral/Hailo-8) need manual PCI(e) passthrough after creation. Proceed?" 12 68; then
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

start_script
post_to_api_vm

# ==============================================================================
# STORAGE SELECTION (fills STORAGE, STORAGE_TYPE, DISK_EXT, DISK_REF, DISK_IMPORT_FORMAT, THIN, FORMAT)
# ==============================================================================
vm_select_storage "$HN"

# ==============================================================================
# PREREQUISITES
# ==============================================================================
if ! command -v virt-customize &>/dev/null; then
  msg_info "Installing libguestfs-tools"
  apt-get -qq update >/dev/null
  apt-get -qq install libguestfs-tools lsb-release -y >/dev/null
  apt-get -qq install dhcpcd-base -y >/dev/null 2>&1 || true
  msg_ok "Installed libguestfs-tools"
fi

# ==============================================================================
# IMAGE DOWNLOAD
# ==============================================================================
msg_info "Retrieving the URL for the ${OS_DISPLAY} Qcow2 Disk Image"
URL=$(get_image_url)
CACHE_DIR="/var/lib/vz/template/cache"
CACHE_FILE="$CACHE_DIR/$(basename "$URL")"
mkdir -p "$CACHE_DIR"
msg_ok "${CL}${BL}${URL}${CL}"

if [[ ! -s "$CACHE_FILE" ]]; then
  curl -f#SL -o "$CACHE_FILE" "$URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
else
  msg_ok "Using cached image ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
fi

# ==============================================================================
# IMAGE CUSTOMIZATION - BAKE IN FIRST-BOOT FRIGATE INSTALLER
#
# Frigate's install (compiling nginx, downloading models) takes too long to
# run inside the virt-customize appliance, so instead we bake in a first-boot
# systemd unit that re-uses the official, always-up-to-date
# install/frigate-install.sh + misc/install.func from the repo - the same
# script an LXC install runs via lxc-attach, just executed locally on boot.
# ==============================================================================
msg_info "Preparing ${OS_DISPLAY} image"

WORK_FILE=$(mktemp --suffix=.qcow2)
cp "$CACHE_FILE" "$WORK_FILE"

export LIBGUESTFS_BACKEND_SETTINGS=dns=8.8.8.8,1.1.1.1

virt-customize -a "$WORK_FILE" --install qemu-guest-agent,curl,ca-certificates,jq >/dev/null 2>&1 || true
msg_ok "Installed base packages"

virt-customize -q -a "$WORK_FILE" --hostname "${HN}" >/dev/null 2>&1 || true
virt-customize -q -a "$WORK_FILE" --run-command "truncate -s 0 /etc/machine-id" >/dev/null 2>&1 || true
virt-customize -q -a "$WORK_FILE" --run-command "rm -f /var/lib/dbus/machine-id" >/dev/null 2>&1 || true

if [ "$USE_CLOUD_INIT" = "yes" ]; then
  virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" >/dev/null 2>&1 || true
  virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" >/dev/null 2>&1 || true
else
  virt-customize -q -a "$WORK_FILE" --run-command "mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d" >/dev/null 2>&1 || true
  virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF' >/dev/null 2>&1 || true
fi
msg_ok "Finalized image"

if virt-customize -q -a "$WORK_FILE" --run-command 'cat > /root/install-frigate.sh << "FRIGATESCRIPT"
#!/bin/bash
exec > /var/log/install-frigate.log 2>&1
echo "[$(date)] Starting Frigate installation"

for i in {1..60}; do
  ping -c 1 8.8.8.8 >/dev/null 2>&1 && break
  sleep 2
done

apt-get update
apt-get install -y qemu-guest-agent curl ca-certificates
systemctl enable --now qemu-guest-agent || true

export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"
export DIAGNOSTICS="no"
export RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
export SESSION_ID="$(cat /proc/sys/kernel/random/uuid)"
export EXECUTION_ID="$(cat /proc/sys/kernel/random/uuid)"
export CACHER="no"
export CACHER_IP=""
export tz="$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)"
export APPLICATION="Frigate"
export app="frigate"
export PASSWORD=""
export VERBOSE="no"
export SSH_ROOT="no"
export CTID="0"
export CTTYPE="1"
export ENABLE_FUSE="no"
export ENABLE_TUN="no"
export PCT_OSTYPE="debian"
export PCT_OSVERSION="12"
export PCT_ARCH="$(dpkg --print-architecture)"
export PCT_DISK_SIZE="20"
export IPV6_METHOD="disable"
export ENABLE_GPU="no"

# Bring up Tor first (plain, direct connection - Tor itself cannot be
# fetched through Tor), then route everything downstream - fetching the
# installer and every apt/curl call it makes - through it via torsocks.
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
install_tor

echo "[$(date)] Routing Frigate install through Tor (torsocks)"
INSTALL_SCRIPT="$(torsocks curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/frigate-install.sh)"
torsocks bash -c "$INSTALL_SCRIPT"

touch /root/.frigate-installed
echo "[$(date)] Frigate installation completed"
FRIGATESCRIPT
chmod +x /root/install-frigate.sh' >/dev/null 2>&1; then

  virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/install-frigate.service << "FRIGATESERVICE"
[Unit]
Description=Install Frigate on First Boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/root/.frigate-installed

[Service]
Type=oneshot
ExecStart=/root/install-frigate.sh
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
FRIGATESERVICE
systemctl enable install-frigate.service' >/dev/null 2>&1 || true
  msg_ok "Frigate will install itself on first boot"
else
  msg_warn "virt-customize failed to bake in the installer. After first boot, run inside the VM:"
  msg_warn "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/frigate-install.sh)\""
fi

msg_info "Resizing disk image to ${DISK_SIZE}"
qemu-img resize "$WORK_FILE" "${DISK_SIZE}" >/dev/null 2>&1
msg_ok "Resized disk image"

# ==============================================================================
# VM CREATION
# ==============================================================================
msg_info "Creating Frigate VM shell"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script,nvr -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null
msg_ok "Created VM shell"

# ==============================================================================
# DISK IMPORT
# ==============================================================================
msg_info "Importing disk into storage ($STORAGE)"
if qm disk import --help >/dev/null 2>&1; then
  IMPORT_CMD=(qm disk import)
else
  IMPORT_CMD=(qm importdisk)
fi

IMPORT_OUT="$("${IMPORT_CMD[@]}" "$VMID" "$WORK_FILE" "$STORAGE" --format "${DISK_IMPORT_FORMAT:-raw}" 2>&1 || true)"
DISK_REF_IMPORTED="$(printf '%s\n' "$IMPORT_OUT" | sed -n "s/.*successfully imported disk '\([^']\+\)'.*/\1/p" | tr -d "\r\"'")"
[[ -z "$DISK_REF_IMPORTED" ]] && DISK_REF_IMPORTED="$(pvesm list "$STORAGE" | awk -v id="$VMID" '$5 ~ ("vm-"id"-disk-") {print $1":"$5}' | sort | tail -n1)"
[[ -z "$DISK_REF_IMPORTED" ]] && {
  msg_error "Unable to determine imported disk reference."
  echo "$IMPORT_OUT"
  exit 226
}
msg_ok "Imported disk (${CL}${BL}${DISK_REF_IMPORTED}${CL})"
rm -f "$WORK_FILE"

# ==============================================================================
# VM CONFIGURATION
# ==============================================================================
msg_info "Attaching EFI and root disk"
qm set "$VMID" \
  --efidisk0 "${STORAGE}:0,efitype=4m" \
  --scsi0 "${DISK_REF_IMPORTED},${DISK_CACHE}${THIN%,}" \
  --boot order=scsi0 \
  --serial0 socket >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
msg_ok "Attached EFI and root disk"

set_description

if [ "$USE_CLOUD_INIT" = "yes" ]; then
  msg_info "Configuring Cloud-Init"
  setup_cloud_init "$VMID" "$STORAGE" "$HN" "yes"
  msg_ok "Cloud-Init configured"
fi

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Frigate VM"
  qm start $VMID >/dev/null 2>&1
  msg_ok "Started Frigate VM"
fi

# ==============================================================================
# FINAL OUTPUT
# ==============================================================================
VM_IP=""
[ "$START_VM" == "yes" ] && VM_IP=$(get_vm_ip "$VMID" 30 || true)

echo -e "\n${INFO}${BOLD}${GN}Frigate VM Configuration Summary:${CL}"
echo -e "${TAB}${DGN}VM ID: ${BGN}${VMID}${CL}"
echo -e "${TAB}${DGN}Hostname: ${BGN}${HN}${CL}"
echo -e "${TAB}${DGN}OS: ${BGN}${OS_DISPLAY}${CL}"
[ -n "$VM_IP" ] && echo -e "${TAB}${DGN}IP Address: ${BGN}${VM_IP}${CL}"
echo -e "${TAB}${DGN}Frigate: ${BGN}Installing on first boot${CL}"
echo -e "${TAB}${DGN}Install traffic: ${BGN}routed through Tor (torsocks)${CL}"
echo -e "${TAB}${YW}⚠️  Tor routing makes the build noticeably slower and can occasionally${CL}"
echo -e "${TAB}${YW}   time out on large downloads (nginx source, models) - be patient or${CL}"
echo -e "${TAB}${YW}   re-run /root/install-frigate.sh manually inside the VM if it stalls${CL}"
echo -e "${TAB}${YW}⚠️  Build takes 10-20+ minutes normally, longer over Tor${CL}"
echo -e "${TAB}${YW}⚠️  Check progress inside the VM: ${BL}tail -f /var/log/install-frigate.log${CL}"
echo -e "${TAB}${YW}⚠️  Coral/Hailo-8 accelerators need manual PCI(e) passthrough (qm set $VMID -hostpciX ...)${CL}"
[ -n "$VM_IP" ] && echo -e "${TAB}${DGN}Once installed, access it at: ${BGN}http://${VM_IP}:5000${CL}"

if [ "$USE_CLOUD_INIT" = "yes" ]; then
  display_cloud_init_info "$VMID" "$HN" 2>/dev/null || true
fi

post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"
