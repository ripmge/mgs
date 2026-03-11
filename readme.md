# GOADURR 🏰🐳
> **Game of Active Directory in dockurr/windows.**

Updates: 
- added Netexec Lab Barbhack 2025 
- added DRACARYS GOAD Challenge Lab

## What is it?

Do you want to play around with **Micro$oft Active Directory** but get annoyed by setting up lab ranges?  
Do you dislike running a mini server 24/7 just for the **5 minutes per week that you'll actually use it**?
**Then this might be for you.**  

GOADURR sets up GOAD (Game of Active Directory - and some other AD ranges) through `docker compose`. It spawns QEMU/KVM containers that run the actual Windows VMs, handling all networking glue and machine provisioning so you don't have to dedicate extra hardware towards your lab.

## Target audience
* **People of culture:** Set up GOAD on your main device, which is Linux anyway... right? 
WSL probably works too.
* **Casual labbers:** Spin up your lab when you need it, and keep it powered down at all other times. Like a sane person.
* **Container bonanza fans:** Everything looks better inside a container.

---

## Quick Start

### 1. Requirements
Since dockurr container images download each ISO at the container creation, this adds **25GB** of downloads to the existing GOAD requirements.

**Hardware Specs:**
| Component | Minimum Req | Notes |
| :--- | :--- | :--- |
| **CPU** | ~8 Cores | 5 VMs x 2 vCores recommended. <br> Works with less but slower |
| **RAM** | 24GB+ | 5 VMs x 4GB + Overhead |
| **Disk** | 200GB+ | 5 VMs x 40GB Storage |
| **OS** | Linux / WSL2 | Must support KVM virtualization |
| **Time** | 2-3 hours | Initial setup time. <br> Depends on download, CPU and disk speed |

> [!Warning] Check power settings  
> Don’t let your host go to sleep during the first run.

### 2. Run it
```bash
# Clone the repo
git clone --recurse-submodules https://github.com/ripmge/goadurr
cd goadurr

# Start GOADURR
docker compose up 
```
**Provisioning is done** when the `provisioner` container shows the following output:

```bash
# shows the following after successful initial setup
goad-provisioner  | [+] Provisioning completed successfully!
goad-provisioner  | [+] Marker file created. Future runs will be skipped.
```

- if you also want to **deploy Kali**
```bash
docker compose --profile kali up 

## already got the lab and only want to bring up Kali
docker compose --profile kali up -d kali
```

- if you want to deploy **netexec lab from Barbhack 2025** [link](https://github.com/Pennyw0rth/NetExec-Lab/tree/main/Barbhack-2025)
```bash
docker compose -f compose.barbhack.yml up 
## deploy it all with kali
docker compose -f compose.barbhack.yml --profile kali up 
```

### 3. Connect to the lab
Containers expose local web UIs:
- DC01 console (for troubleshooting): `http://localhost:8006`
- Kali desktop (web VNC): `https://localhost:6901` 
- RDP from host to VM IPs (check table below for VM IP list)

Kali credentials: `kasm_user:password`  
Windows setup credentials: `Docker:admin`

> [!Warning] Exposure  
> For obvious reasons do **not** expose these ports to the internet, change passwords, etc.


## About GOAD
Game of Active Directory [Orange-Cyberdefense/GOAD](https://github.com/Orange-Cyberdefense/GOAD) is an AD lab environment for pentesting practice. It features multiple domains/servers and intentionally vulnerable configurations to learn common AD attacks.

It consists of the following systems + a provisioner and attacker box added for GOADURR:

| Role | Service | Hostname | Container IP | VM IP | 
|------|---------|----------|----|----|
| Domain Controller | `dc01` | `kingslanding` | `192.168.56.110` | `192.168.56.10` |
| Domain Controller | `dc02` | `winterfell` | `192.168.56.111` | `192.168.56.11` |
| Domain Controller | `dc03` | `meereen` | `192.168.56.112` | `192.168.56.12` |
| Member server | `srv01` | `castelblack` | `192.168.56.122` | `192.168.56.22` |
| Member server | `srv02` | `braavos` | `192.168.56.123` | `192.168.56.23` |
| Provisioner | `provisioner` | - | `192.168.56.100` | - |
| Attacker box | `kali` | - | `192.168.56.50` | - |

Docker network: `goad_bridge` = `192.168.56.0/24`

> [!Info] Help?   
> GOAD developer writeup available here [mayfly277](https://mayfly277.github.io/categories/goad/)

## Technical overview

The heavy lifting is done by [dockur/windows](https://github.com/dockur/windows). The project uses QEMU/KVM inside Docker containers to spin up Windows VMs. It is itself based on the [qemus/qemu](https://github.com/qemus/qemu) container project.

**Networking is hard:** default qemu/dockur containers use NAT, and Active Directory hates NAT.
- *Why?* Domain Controllers (DCs) register the internal QEMU VM IP (e.g., 172.x) in DNS. When other machines try to talk to the DC, they get the NAT'd, unreachable IP, causing all kinds of headaches.
- *Solution:* Modifying the container entrypoint to set up a **bridge + tap** interface so the VM can bridge directly onto the Docker network. This avoids host-side `macvlan` complexity and ensures domain controllers use the correct IP and DNS settings.

To achieve this, we are setting variables in an custom script(`entrypoint-bridge.sh`), which get passed to the original entrypoint script, so that QEMU creates the right interface type.
Additionally there are individual entrypoint scripts for each windows machine (e.g. `install_dc01.bat`), setting a static IP for the VM different from the compose assigned IP of the surrounding container. This step takes care of prepping machines for GOAD ansible setup.

## About /dev/kvm
In case you are as suspicious as I was about the implications of giving containers access to `/dev/kvm`:
- First off, they cannot mount/browse the host filesystem via /dev/kvm. File access only happens if you give cotainers host paths (bind mounts) or host block devices. We are just mounting named volumes + a few specific files, so no access to host file system.
- There is no host takeover by default just because it can run Windows VMs. VM code runs in guest mode; the host kernel still mediates everything.
- The main practical host impact is DoS: VM workloads can chew CPU/RAM/disk IO and make the host slow or unstable without Docker resource limits.
- The main escape class is kernel bugs: `/dev/kvm` and also `/dev/vhost-net` are kernel interfaces. Exploiting them would require a vulnerability, not just having access to the device.
- Networking additions (`NET_ADMIN` + tun) primarily affect the lab network. The big footgun is routing/bridging from lab → your real LAN.  

## Troubleshooting
As with the original GOAD, if a task fails (most often thanks to `Ansible`), simply restarting the provisioner usually fixes it:
```bash
docker compose up provisioner
```

**Useful Commands**  

Rerun Provisioner:
```bash
docker compose run --rm --entrypoint "rm -f /goad/data/.goad_provisioned" provisioner
docker compose up provisioner
```
Run manual Ansible command:
```bash
docker compose run --rm --entrypoint \
  "ansible dc02 -i /inventory/inventory.ini -m ansible.windows.win_shell -a \"Install-WindowsFeature RSAT-DNS-Server; Import-Module DnsServer\"" \
  provisioner
```

---
## References, once again:
This project is essentially duct taping together these two repos:

- **GOAD** [Orange-Cyberdefense/GOAD](https://github.com/Orange-Cyberdefense/GOAD)
- **Dockur Windows** [dockur/windows](https://github.com/dockur/windows)


---

## TODO:
- [ ] test WSL
- [ ] test podman
- [ ] fix 4x ISO download (e.g. by adding downloader side container and bind mounting ISO path)

