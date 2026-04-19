#!/bin/bash
# /ansible/entrypoint.sh

# Path to the marker file
# must be located at persistent or shared volume
MARKER_FILE="/provisioner/data/.goad_provisioned"


BASE="${BASE:-/goad/ad/GOAD/data}"
INVENTORY1="${INVENTORY1:-$BASE/inventory}"
INVENTORY2="${INVENTORY2:-$BASE/inventory_disable_vagrant}"
IP_RANGE="${IP_RANGE:-192.168.56}"
PROV_WORKDIR=/goad/ansible

# build inventory args
INV_ARGS=()

[[ -n "$INVENTORY1" ]] && INV_ARGS+=(-i "$INVENTORY1")
[[ -n "$INVENTORY2" ]] && INV_ARGS+=(-i "$INVENTORY2")

echo "[*] Ansible Provisioner Started"

# check if marker exists
if [ -f "$MARKER_FILE" ]; then
    echo "[+] Setup marker found at $MARKER_FILE."
    echo "[+] The lab is already provisioned."
    echo "[*] Exiting"
    # sleep for debug
    #exec sleep infinity
    exit 0
fi

echo "[-] No marker found. Starting provisioning sequence."

echo "[+] # ---------------------------------------------------------"
echo "[+] Step 1: Wait for Windows Nodes"
echo "[+] # ---------------------------------------------------------"

echo "[+] need to wait until the Windows Servers are actually listening on WinRM (5985)"
echo "[+] since they are installing from ISO, this could take 10-20 minutes on first boot"

SLEEP=60

# wait for WINRM loop
echo "[*] Waiting for Ansible WinRM connectivity on all inventory hosts..."
while true; do
  OUTPUT="$(
    ansible "${INV_ARGS[@]}" all \
      -m ansible.builtin.win_ping \
      -e "{  \
          ip_range: '$IP_RANGE',  \
          ansible_port: 5985,  \
          ansible_winrm_scheme: 'http',  \
          ansible_user: 'Docker',  \
          ansible_password: 'admin'  \
        }" 2>&1
    )"
  EXIT_CODE=$?
  UP_COUNT="$(grep -c 'SUCCESS' <<< "$OUTPUT" || true)"
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "[+] All hosts respond to win_ping (WinRM ready)."
    break
  else
    echo "[-] Hosts ready: ${UP_COUNT}"
    echo "[-] Not all hosts ready yet. Retrying in ${SLEEP}s..."
    sleep "$SLEEP"
  fi
done


cd $PROV_WORKDIR

echo "[+] # ---------------------------------------------------------"
echo "[+] Starting primary playbook"
echo "[+] # ---------------------------------------------------------"

ansible-playbook "${INV_ARGS[@]}" main.yml \
        -e "{  \
          ip_range: '$IP_RANGE',  \
          ansible_port: 5985,  \
          ansible_winrm_scheme: 'http',  \
          ansible_winrm_transport: 'basic', \
          ansible_user: 'Docker',  \
          ansible_password: 'admin',  \
          domain_adapter: 'Ethernet', \
          nat_adapter: 'Ethernet', \
          two_adapters: false \
        }"
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "[+] Provisioning completed successfully!"
    # Create the marker file
    touch "$MARKER_FILE"
    echo "[+] Marker file created. Future runs will be skipped."
else
    echo "[!] Provisioning FAILED with exit code $EXIT_CODE."
    echo "[!] Check logs. Marker file NOT created."
    exit $EXIT_CODE
fi

# keep container running for debugging
#exec sleep infinity
exit 0