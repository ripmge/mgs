#!/bin/bash
# /ansible/entrypoint.sh

# Path to the marker file. 
# /barb/data must be a persistent volume shared with the host or named volume.
MARKER_FILE="/barb/data/.barb_provisioned"

echo "[*] BARB Ansible Provisioner Started"

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
TARGETS=("192.168.10.10" "192.168.10.11" "192.168.10.12" "192.168.10.13")

echo "[*] Waiting for WinRM reachability on all nodes..."
for IP in "${TARGETS[@]}"; do
    echo "    Waiting for $IP:5985..."
    # Loop until nc (netcat) successfully connects to port 5985
    while ! nc -z -w 5 $IP 5985; do
        echo "    - $IP not ready. Retrying in 30 seconds..."
        sleep 30
    done
    echo "    + $IP is ONLINE."
done

echo "[+] All Windows nodes are reachable."

# ---------------------------------------------------------
# Step 2: Prepare Inventory
# ---------------------------------------------------------
# We assume the user has mounted the inventory file or we generate one.
# For this solution, we assume a static inventory file mapped at /inventory.ini

# ---------------------------------------------------------
# Step 3: Run Ansible Playbooks
# ---------------------------------------------------------


echo "[*] Launching BARB Ansible Playbooks..."

# We usually run the 'build.yml' playbook from the GOAD repo.
# Adjust the path based on where the GOAD repo is mounted.
cd /barb/ansible

export ANSIBLE_COMMAND="ansible-playbook -i ../ad/BARBHACK/data/inventory -i /inventory/inventory.ini "
export LAB="BARBHACK"

../scripts/provisionning.sh

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