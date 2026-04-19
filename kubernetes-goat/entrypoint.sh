#!/usr/bin/env bash
set -euo pipefail

CLOUDINIT_USER=${CLOUDINIT_USER:-"ubuntu"}
CLOUDINIT_PASS=${CLOUDINIT_PASS:-"password"}
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-30G}"
DISK_SIZE="${DISK_SIZE:-1G}" # this is unneeded for cloud init images, if we resize boot disk instead

CLOUDINIT_DIR="/work/cloudinit"
INIT_DIR="/work/init"
#IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_PATH="${CLOUDINIT_DIR}/noble.qcow2"
SEED_PATH="${CLOUDINIT_DIR}/seed.img"
READY_MARKER="${CLOUDINIT_DIR}/.prepared"
NETWORK_CONFIG_RENDERED="${CLOUDINIT_DIR}/network-config"
USER_DATA_RENDERED="${CLOUDINIT_DIR}/user-data"
BOOTSTRAP_ENV_RENDERED="${CLOUDINIT_DIR}/bootstrap.env"

CONT_IF="${CONT_IF:-eth0}"
BR_IF="${BR_IF:-br0}"
TAP_IF="${TAP_IF:-tap0}"
ADAPTER="${ADAPTER:-virtio-net-pci}"
GOAT_REPO_URL="${GOAT_REPO_URL:-https://github.com/madhuakula/kubernetes-goat.git}"
GOAT_REPO_VERSION="${GOAT_REPO_VERSION:-v2.3.0}"
K3S_VERSION="${K3S_VERSION:-v1.35.0+k3s1}"
HELM_VERSION="${HELM_VERSION:-v3.19.1}"
DOCKER_INSTALL_SCRIPT_URL="${DOCKER_INSTALL_SCRIPT_URL:-https://releases.rancher.com/install-docker/28.0.sh}"
VM_DNS="${VM_DNS:-1.1.1.1,8.8.8.8}"
USER_PORTS="${USER_PORTS:-22}"
ARGUMENTS="${ARGUMENTS:--drive file=/work/cloudinit/seed.img,format=raw,media=cdrom}"

mkdir -p "${CLOUDINIT_DIR}" /storage

if [ -d "${IMAGE_PATH}" ]; then
  echo "[!] ${IMAGE_PATH} is a directory, but must be a file"
  exit 1
fi

render_network_config() {
  if [ -n "${VM_STATIC_IP:-}" ]; then
    echo "[*] Rendering static network-config"
    cat > "${NETWORK_CONFIG_RENDERED}" <<EOF
version: 2
ethernets:
  lan:
    match:
      name: "enp0s7"
    dhcp4: false
    addresses:
      - ${VM_STATIC_IP}/24
EOF

    if [ -n "${VM_GATEWAY:-}" ]; then
      cat >> "${NETWORK_CONFIG_RENDERED}" <<EOF
    routes:
      - to: default
        via: ${VM_GATEWAY}
EOF
    fi

    if [ -n "${VM_DNS:-}" ]; then
      IFS=',' read -r -a dns_array <<< "${VM_DNS}"
      {
        echo "    nameservers:"
        echo "      addresses:"
        for dns in "${dns_array[@]}"; do
          echo "        - ${dns}"
        done
      } >> "${NETWORK_CONFIG_RENDERED}"
    fi
  else
    echo "[*] Rendering DHCP network-config"
    cat > "${NETWORK_CONFIG_RENDERED}" <<'EOF'
version: 2
ethernets:
  lan:
    match:
      name: "en*"
    dhcp4: true
EOF
  fi
}

render_bootstrap_env() {
  sed \
    -e "s|__GOAT_REPO_URL__|${GOAT_REPO_URL}|g" \
    -e "s|__GOAT_REPO_VERSION__|${GOAT_REPO_VERSION}|g" \
    -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
    -e "s|__HELM_VERSION__|${HELM_VERSION}|g" \
    -e "s|__DOCKER_INSTALL_SCRIPT_URL__|${DOCKER_INSTALL_SCRIPT_URL}|g" \
    "${INIT_DIR}/bootstrap.env" > "${BOOTSTRAP_ENV_RENDERED}"
}

render_user_data() {
  render_bootstrap_env

  {
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        "__BOOTSTRAP_ENV__")
          sed 's/^/      /' "${BOOTSTRAP_ENV_RENDERED}"
          ;;
        "__BOOTSTRAP_SCRIPT__")
          sed 's/^/      /' "${INIT_DIR}/bootstrap-vm.sh"
          ;;
        *)
          line="${line//__CLOUDINIT_USER__/${CLOUDINIT_USER}}"
          line="${line//__CLOUDINIT_PASS__/${CLOUDINIT_PASS}}"
          printf '%s\n' "${line}"
          ;;
      esac
    done < "${INIT_DIR}/user-data"
  } > "${USER_DATA_RENDERED}"
}

if [ -f "${IMAGE_PATH}" ] && [ -f "${SEED_PATH}" ] && [ -f "${READY_MARKER}" ]; then
  echo "[*] Existing VM artifacts found, skipping preparation"
else
  echo "[*] Preparing VM artifacts..."

  if [ ! -f "${IMAGE_PATH}" ]; then
    echo "[*] Downloading cloud image..."
    wget -nv -O "${IMAGE_PATH}" "${IMAGE_URL}"
  else
    echo "[*] Cloud image already exists"
  fi

  render_network_config
  render_user_data
  cp "${INIT_DIR}/meta-data" ${CLOUDINIT_DIR}

  rm -f "${SEED_PATH}"
  genisoimage \
    -output "${SEED_PATH}" \
    -volid cidata \
    -rational-rock \
    -joliet \
    "${USER_DATA_RENDERED}" \
    "${CLOUDINIT_DIR}/meta-data" \
    "${NETWORK_CONFIG_RENDERED}"

  touch "${READY_MARKER}"
  echo "[*] Preparation complete"
fi

## bridge network stuff

if [[ -z "${TAP_MAC:-}" ]]; then
  h="$(printf '%s-tap' "$(hostname)" | md5sum | awk '{print $1}')"
  TAP_MAC="02:${h:0:2}:${h:2:2}:${h:4:2}:${h:6:2}:${h:8:2}"
fi
TAP_MAC="${TAP_MAC^^}"

IP_CIDR="$(
  { ip -4 addr show dev "${BR_IF}" 2>/dev/null || true; } |
  awk '/inet /{print $2; exit}'
)"

if [[ -z "${IP_CIDR}" ]]; then
  IP_CIDR="$(
    { ip -4 addr show dev "${CONT_IF}" 2>/dev/null || true; } |
    awk '/inet /{print $2; exit}'
  )"
fi

echo "IP_CIDR=${IP_CIDR}"
if [[ -z "${IP_CIDR}" ]]; then
  IP_CIDR="$(ip -4 addr show dev "${CONT_IF}" 2>/dev/null | awk '/inet /{print $2; exit}')"
fi
GW="$(ip route | awk '/default/{print $3; exit}')"
if [[ -z "${IP_CIDR}" || -z "${GW}" ]]; then
  echo "Could not determine container IP/GW (IP_CIDR='${IP_CIDR}', GW='${GW}')" >&2
  exit 1
fi

echo "Setting bridge interface"
ip link add "${BR_IF}" type bridge 2>/dev/null || true
ip link set "${BR_IF}" up

ip tuntap add dev "${TAP_IF}" mode tap 2>/dev/null || true
ip link set "${TAP_IF}" up

ip link set "${CONT_IF}" promisc on 2>/dev/null || true
ip link set "${CONT_IF}" master "${BR_IF}" 2>/dev/null || true
ip link set "${TAP_IF}" master "${BR_IF}" 2>/dev/null || true

# Only migrate the address if it is still on the container interface
if ip -4 addr show dev "${CONT_IF}" | grep -q 'inet '; then
  ip addr flush dev "${CONT_IF}"
  ip addr add "${IP_CIDR}" dev "${BR_IF}"
fi

ip route replace default via "${GW}" dev "${BR_IF}"

export ARGUMENTS="${ARGUMENTS} \
  -netdev tap,id=brnet0,ifname=${TAP_IF},script=no,downscript=no \
  -device ${ADAPTER},id=nic0,netdev=brnet0,romfile=,mac=${TAP_MAC}"


## disk checks

mkdir -p /cloudinit

test -f "${IMAGE_PATH}" || { echo "[!] source qcow missing"; exit 1; }
test -f "${SEED_PATH}" || { echo "[!] source seed missing"; exit 1; }

if [ ! -f /boot.qcow2 ]; then
  echo "[*] Installing boot disk to /boot.qcow2"
  cp "${IMAGE_PATH}" /boot.qcow2
  qemu-img resize /boot.qcow2 "${BOOT_DISK_SIZE}"
fi

cp -f "${SEED_PATH}" /cloudinit/seed.img

ls -l /boot.qcow2 /cloudinit/seed.img
test -f /boot.qcow2 || { echo "[!] /boot.qcow2 missing"; exit 1; }
test -f /cloudinit/seed.img || { echo "[!] /cloudinit/seed.img missing"; exit 1; }

sleep 2
exec /run/entry.sh
