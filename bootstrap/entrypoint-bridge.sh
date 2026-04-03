#!/usr/bin/env bash
set -Eeuo pipefail

# ---- settings you can override via env ----
: "${TAP_IF:=tap0}"
: "${BR_IF:=br0}"
: "${CONT_IF:=eth0}"              # container NIC on docker bridge
: "${ADAPTER:=virtio-net-pci}"    # qemu device
: "${MAC:=}"                      # optional provide MAC
: "${VM_IP:?VM_IP must be set}" 
: "${VM_DNS:=8.8.8.8}" 

GW_IP="$(printf '%s\n' "$VM_IP" | awk -F. '{print $1"."$2"."$3".1"}')"

# Generate install.bat file
mkdir -p /oem
test -f /install.bat || { echo "/install.bat not mounted. Add it in compose"; exit 1; }

cp /install.bat /oem/install.bat

sed -i \
  -e "s/__VM_IP__/${VM_IP}/g" \
  -e "s/__GW_IP__/${GW_IP}/g" \
  -e "s/__VM_DNS__/${VM_DNS}/g" \
  /oem/install.bat

# Generate a stable locally-administered MAC if none provided
if [[ -z "${MAC}" ]]; then
  # same idea as dockur: hash hostname -> MAC, with 02: prefix
  h="$(hostname | md5sum | awk '{print $1}')"
  MAC="02:${h:0:2}:${h:2:2}:${h:4:2}:${h:6:2}:${h:8:2}"
fi
MAC="${MAC^^}"

# Grab current container IPv4 + default GW
IP_CIDR="$(ip -4 addr show dev "${CONT_IF}" | awk '/inet /{print $2; exit}')"
GW="$(ip route | awk '/default/{print $3; exit}')"

if [[ -z "${IP_CIDR}" || -z "${GW}" ]]; then
  echo "Could not determine container IP/GW on ${CONT_IF} (IP_CIDR='${IP_CIDR}', GW='${GW}')" >&2
  exit 1
fi

# ---- create bridge + tap, and move container IP to the bridge ----
ip link add "${BR_IF}" type bridge 2>/dev/null || true
ip link set "${BR_IF}" up

ip tuntap add dev "${TAP_IF}" mode tap 2>/dev/null || true
ip link set "${TAP_IF}" up

# allow multiple MACs to egress the container veth (guest MAC + container MAC)
ip link set "${CONT_IF}" promisc on

# enslave interfaces to bridge
ip link set "${CONT_IF}" master "${BR_IF}" || true
ip link set "${TAP_IF}" master "${BR_IF}" || true

# move container L3 config from eth0 -> br0
ip addr flush dev "${CONT_IF}"
ip addr add "${IP_CIDR}" dev "${BR_IF}"
ip route replace default via "${GW}" dev "${BR_IF}"

# ---- inject QEMU NIC through ARGUMENTS (config.sh appends it at the end) ----
# We also set script/no downscript/no to avoid QEMU helper scripts.
export ARGUMENTS="${ARGUMENTS:-} \
  -netdev tap,id=hostnet0,ifname=${TAP_IF},script=no,downscript=no,vhost=on \
  -device ${ADAPTER},id=net0,netdev=hostnet0,romfile=,mac=${MAC}"

# IMPORTANT: prevent dockur from adding its own NET_OPTS (slirp/passt/NAT)
export NETWORK="N"
export DHCP="N"
export DNSMASQ_DISABLE="Y"

# exec original entrypoint (you set this path in compose)
exec "$@"
