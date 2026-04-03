#!/bin/bash
# /ansible/entrypoint.sh

# Path to the marker file. 
# /goad/data must be a persistent volume shared with the host or named volume.
MARKER_FILE="/goad/data/.goad_provisioned"

echo "[*] GOAD Ansible Provisioner Started"

# Check if the marker exists
if [ -f "$MARKER_FILE" ]; then
    echo "[+] Setup marker found at $MARKER_FILE."
    echo "[+] The lab is already provisioned."
    echo "[*] Exiting."
    # We sleep to allow the user to docker exec in if they want to run manual playbooks later
    #exec sleep infinity
    exit 0
fi

echo "[-] No marker found. Starting provisioning sequence."

# ---------------------------------------------------------
# Step 1: Wait for Windows Nodes
# ---------------------------------------------------------
# We need to wait until the Windows Servers are actually listening on WinRM (5985).
# Since they are installing from ISO, this could take 15-30 minutes on first boot.

INV=/inventory/inventory.ini
SLEEP=60

echo "[*] Waiting for Ansible WinRM connectivity on all inventory hosts..."
while true; do
  if ansible -i "$INV" all \
    -m ansible.builtin.win_ping \
    >/dev/null; then
    echo "[+] All hosts respond to win_ping (WinRM ready)."
    break
  fi
  echo "[-] Not all hosts ready yet. Retrying in ${SLEEP}s..."
  sleep "$SLEEP"
done

# ---------------------------------------------------------
# Step 2: Prepare Inventory
# ---------------------------------------------------------
# We assume the user has mounted the inventory file or we generate one.
# For this solution, we assume a static inventory file mapped at /inventory.ini

# ---------------------------------------------------------
# Step 3: Run Ansible Playbooks
# ---------------------------------------------------------

#echo "[*] Running Pre-Flight DNS Checks..."
echo "[*] Skipping Pre-Flight DNS Checks..."
echo "[*] ..."
echo "[*] Let's see if these are still needed" 
sleep 3
#ansible-playbook -i /inventory/inventory.ini /ansible/bootstrap_dns.yml


echo "[*] Launching GOAD Ansible Playbooks..."

# We usually run the 'build.yml' playbook from the GOAD repo.
# Adjust the path based on where the GOAD repo is mounted.
cd /goad/ansible

ansible-playbook -i /inventory/inventory.ini main.yml -e '{"two_adapters": false}'

# Capture exit code
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

# Keep container running for debugging or manual usage
#exec sleep infinity
exit 0