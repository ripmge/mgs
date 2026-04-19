# GOADURR ⛧ 🐐🕯️
> **Deploy security labs with docker.**  

*We got provisioning at home.*

## TLDR: How to use
- Setup Game of Active Directory ([link](https://github.com/Orange-Cyberdefense/GOAD)) with:
```bash
# Clone the repo
git clone --recurse-submodules https://github.com/ripmge/goadurr
cd goadurr

# Start GOADURR
docker compose up 
```
- deploy any of the **other available labs**:
```bash
# deploy netexec lab from barbhack 2025
docker compose -f compose.barbhack.yml up 

# deploy kubernetes-goat lab
docker compose -f compose.k8sgoat.yml up 

# deploy GOAD dracarys lab
# WIP: docker compose -f compose.dracarys.yml up 
```
Add `-d` if you dont need output, e.g. for consecutive runs after intial deployment. Example: `docker compose -f compose.barbhack.yml up -d`

**To stop the lab:** `ctrl + c` if you started it interactively. Else run `docker compose -f <LAB_RANGE_FILE> down`

---

### Provisioning done
**Provisioning is done** when the `provisioner` container shows the following output:

```bash
goad-provisioner  | [+] Provisioning completed successfully!
goad-provisioner  | [+] Marker file created. Future runs will be skipped.
```

Deployment time depends on lab:
- **GOAD**: approx. 2-3 hours
- **Netexec lab**: 1-2 hours
- **kubernetes-goat**: 5-10 minutes

### Connect to lab
> Note:  
This project is based on `dockurr/windows` container images ([link](https://github.com/dockur/windows)), which in turn is based on `qemus/qemu` ([link](https://github.com/qemus/qemu)). These projects use docker containers to run virtual machines using QEMU. They come with a web-based VNC viewer to check in on VM status.   
This is also available here. You can access http://localhost:8006 to check in on the primary VM.


Depending on your use case, there are generally 2 ways to access the labs.
- **Option A:** access from your host system
- **Option B:** access from local LAN

**Option A: access from your host**   
Is easiest and doesn't need further setup, when used with docker and default configs (podman default behaves differently). You can access the lab IP range from your host just fine.   
**See lab range info further down below for information on VM IPs.**

**Option B: access from local LAN**   
Multiple options here to make the ranges accessible. I recommend either:
- deploying the available Kali container via profile  
e.g. `docker compose -f compose.barbhack.yml --profile kali up -d`. 
Afterwards connect to Kali via web-vnc on `https://localhost:6901` or your LAN IP.
- add an SSH container and connect to it via `SSH -D` and socks proxy your traffic into the lab 

**Credentials:**   
For either option, these are the relevant lab credentials for administrative access.   
**Windows & Linux creds are not part of any lab, so don't spoil your fun by using them.**

| system | creds |
| -| -|
| kali | `kasm_user:password` |
| windows | `Docker:admin` | 
| linux (k8s) | `ubuntu:password` |


---

## Single container architecture overview
The following image shows what we are doing inside each container:  
- inject bridge/tap networking and bootstrap logic at runtime into otherwise unmodified `dockurr/windows` container
- expose windows guest on the lab subnet through bridge.
```
┌──────────────────────────────────────────────────────────────────────┐
│ HOST SYSTEM                                                          │
│----------------------------------------------------------------------│
│  docker compose up                                                   │
│        │                                                             │
│        │                                                             │
│        ▼                                                             │
│  docker network: goad_bridge (192.168.56.0/24)                       │
│                                                                      │
│  container IP: 192.168.56.110                                        │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │ dc01 container (dockurr/windows)                             │   │
│   │--------------------------------------------------------------│   │
│   │ Reused upstream runtime                                      │   │
│   │  - /run/entry.sh (original entrypoint)                       │   │
│   │  - QEMU/KVM VM launcher                                      │   │
│   │                                                              │   │
│   │ GOADURR runtime injections                                   │   │
│   │  - /entrypoint-bridge.sh   <-- hot-patched entrypoint        │   │
│   │  - /oem/install.bat        <-- per-VM bootstrap, sets IP     │   │
│   │  - /storage                <-- persistent VM disk            │   │
│   │                                                              │   │
│   │                                                              │   │
│   │ Internal container networking                                │   │
│   │--------------------------------------------------------------│   │
│   │                                                              │   │
│   │─── eth0 (docker veth, promisc)                               │   │
│   │      │                                                       │   │
│   │      ├───────────────┐                                       │   │
│   │      ▼               ▼                                       │   │
│   │    br0 <────────── tap0                                      │   │
│   │                      │                                       │   │
│   │                      ▼                                       │   │
│   │              qemu-system-x86_64                              │   │
│   │                      │                                       │   │
│   │                      ▼                                       │   │
│   │            ┌───────────────────────────────┐                 │   │
│   │            │ Windows VM (actual lab host)  │                 │   │
│   │            │-------------------------------│                 │   │
│   │            │  VM IP:    192.168.56.10      │                 │   │
│   │            │  Hostname: kingslanding       │                 │   │
│   │            └───────────────────────────────┘                 │   │
│   │                                                              │   │
│   └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│ Other lab nodes + provisioner live on same docker subnet             │
└──────────────────────────────────────────────────────────────────────┘
```


# Constraints
I wasn't happy with existing lab provisioning options and stumbled accross `dockurr/windows`. This led to the project being created under the following constraints:

1. **Be as self contained as possible:** `docker compose up` should be all that is needed. No terraform, ansible, ansible modules, or further dependencies should be required. 
2. **No host preparation:** No (shell) scripts or network config adjustements should be needed on the host. This also means you don't have to half-ass reading a bunch of shell scripts you have to run on your main system. Only docker compose is used. Though you should still check what is mounted in compose files and which additional privileges are given.
3. **Something for your primary system/daily driver:** Most people don't have spare workstations laying around. Even if you got the extra hardware, you might not want to run it 24/7 for the 10 minutes per week, that you actually use the lab. Suspending and resuming via `docker compose up/down` lowers the barrier of actually using a lab by removing the setup struggle.
4. **Reuse as much as possible:** Maintaining a bunch of container images, alternative ansible inventory files, etc. is annoying, so reuse as much as possible. This leads to a bunch of things being configurable through environment variables in the container. Environment variables are then picked up by a hot-patched entrypoint script, that prepares networking, exports QEMU arguments, disables dockur’s default networking path, and then execs the original entrypoint.  
This makes life easier for me, and you don't have to run container images from some random person on the internet. Instead you can put your trust (or lack thereof) in the hands of a 50k+ star repo.

### Entrypoint hot-patch reasoning
Default `qemus/qemu` & `dockurr/windows` containers use NAT, and Active Directory hates NAT.
- **Why:** Domain Controllers (DCs) register the internal QEMU VM IP (e.g., 172.x) in DNS. When other machines try to talk to the DC, they get the NAT'd IP, which is unreachable on the internal docker network, causing all kinds of headaches.
- **Solution:** Modifying the container entrypoint to set up a **bridge + tap** interface so the VM can bridge directly onto the Docker network. This avoids other options like setting up host-side `macvlan`, which is recommended by `dockurr/windows` but means we have to set it up on the host and thus violates constraint (2).
- To achieve this, we are setting up arguments for the qemu command in our custom script (`entrypoint-bridge.sh`), which gets passed to the original entrypoint, so that QEMU creates the right interface type.

### A word about /dev/kvm
> **Is it safe to use?** No clue, do your own research.  
At the minimum, I wouldn't use my main system to share a lab with a bunch of people I don't trust. 

If your use case is sharing lab access with a bunch of strangers, maybe take a look at ludus [link](https://ludus.cloud/).

Otherwise:
- **You cannot mount/browse the host filesystem** via `/dev/kvm`. File access only happens if you give cotainers host paths (bind mounts) or host block devices. The labs are just mounting named volumes + a few specific files, so no access to host file system.
- **No host takeover by default** just because it can run Windows VMs. VM code runs in guest mode; the host kernel still mediates everything.
- **Main practical host impact is DoS**: VM workloads can chew CPU/RAM/disk IO and make the host slow or unstable without Docker resource limits.
- **The main escape class is kernel bugs:** `/dev/kvm` and also `/dev/vhost-net` are kernel interfaces. Exploiting them would require a vulnerability, not just having access to the device. 
- **Networking additions (`NET_ADMIN` + tun) primarily affect the lab network.** The big footgun is routing/bridging from lab → your real LAN.  

# Lab Ranges
> **Note:** The lab ranges below come from their respective authors and upstream projects. I did not create the actual lab content, so all credit for the scenarios, design, and ideas goes to the original creators. This repository is only about making them easier to deploy and run.

## Lab: GOAD

### Requirements
Since dockurr container images download each ISO at the container creation, this adds **25GB** of downloads to the existing GOAD requirements.

**Hardware Specs:**
| Component | Minimum Req | Notes |
| :--- | :--- | :--- |
| **CPU** | ~8+ Cores | 5 VMs x 2 vCores recommended. <br> Works with less but slower |
| **RAM** | 24GB+ | 5 VMs x 4GB + Overhead |
| **Disk** | 200GB+ | 5 VMs x 40GB Storage |
| **Time** | 2-3 hours | Initial setup time. <br> Depends on download, CPU and disk speed |

### About the lab
Game of Active Directory [Orange-Cyberdefense/GOAD](https://github.com/Orange-Cyberdefense/GOAD) is an AD lab environment for pentesting practice. It features multiple domains/servers and intentionally vulnerable configurations to learn common AD attacks.

It consists of the following systems + a provisioner and an optional kali box:

| Role | Service | Hostname | Container IP | VM IP | 
|------|---------|----------|----|----|
| Domain Controller | `dc01` | `kingslanding` | `192.168.56.110` | `192.168.56.10` |
| Domain Controller | `dc02` | `winterfell` | `192.168.56.111` | `192.168.56.11` |
| Domain Controller | `dc03` | `meereen` | `192.168.56.112` | `192.168.56.12` |
| Member server | `srv01` | `castelblack` | `192.168.56.122` | `192.168.56.22` |
| Member server | `srv02` | `braavos` | `192.168.56.123` | `192.168.56.23` |
| Provisioner | `provisioner` | - | `192.168.56.100` | - |
| web-vnc Kali | `kali` | - | `192.168.56.50` | - |

Docker network: `goad_bridge` = `192.168.56.0/24`

   
> GOAD developer writeup available here [mayfly277](https://mayfly277.github.io/categories/goad/)


## Lab: Netexec - Barbhack-2025

### Requirements
Since dockurr container images download each ISO at the container creation, this adds **20GB** of downloads to the existing requirements.

**Hardware Specs:**
| Component | Minimum Req | Notes |
| :--- | :--- | :--- |
| **CPU** | ~6+ Cores | 4 VMs x 2 vCores recommended. <br> Works with less but slower |
| **RAM** | 20GB+ | 4 VMs x 4GB + Overhead |
| **Disk** | 160GB+ | 4 VMs x 40GB Storage |
| **Time** | 1-2 hours | Initial setup time. <br> Depends on download, CPU and disk speed |

### About the lab
This is CTF lab originally from Barbhack 2025 [link](https://github.com/Pennyw0rth/NetExec-Lab/tree/main/Barbhack-2025) focusing on using NetExec to compromise an Active Directory domain during an internal pentest.

It consists of the following systems + a provisioner and an optional kali box:

| Role | Service | Hostname | Container IP | VM IP | 
|------|---------|----------|----|----|
| Domain Controller | `dc01` | `BLACKPEARL` | `192.168.10.110` | `192.168.10.10` |
| Member server | `srv01` | `JOLLYROGER` | `192.168.10.111` | `192.168.56.11` |
| Member server | `srv02` | `QUEENREV` | `192.168.10.112` | `192.168.56.12` |
| Member server | `srv03` | `FLYINGDUTCHMAN` | `192.168.10.113` | `192.168.56.13` |
| Provisioner | `provisioner` | - | `192.168.10.100` | - |
| web-vnc Kali | `kali` | - | `192.168.10.50` | - |

Docker network: `barb_bridge` = `192.168.10.0/24`


## Lab: Kubernetes-goat

### Requirements
These are estimates. If you can deploy a single VM, you should be fine. This lab is by far the most resource friendly.
| Component | Minimum Req | Notes |
| :--- | :--- | :--- |
| **CPU** | ~2+ Cores | single VM |
| **RAM** | 8GB | 4GB might be fine |
| **Disk** | 20GB+ | guesstimate |
| **Time** | 5-10 min | Initial setup time. <br> Depends on download, CPU and disk speed |

### About the lab
Kubernetes-goat [link](https://github.com/madhuakula/kubernetes-goat) is an intentionally vulnerable kubernetes cluster for security learning and practice. It has extensive documentation and a guide available here [link](https://madhuakula.com/kubernetes-goat/).

The lab consists of 2 containers. One is a `qemus/qemu` image provisioning a cloudinit VM and installing the lab on it. This allows for enough isolation in scenarios such as ***Container escape / host access***. The other container is a simple socat container, taking care of port forwarding to the **following ports exposed on the host:**

| Port | Scenario |
|---|---|
| `1230` | Sensitive keys in codebases (`build-code`) |
| `1231` | DIND exploitation (`health-check`) |
| `1232` | SSRF in K8s world (`internal-proxy`) |
| `1233` | Container escape / host access (`system-monitor`) |
| `1234` | Kubernetes Goat home page |
| `1235` | Attacking private registry (`poor-registry`) |
| `1236` | DoS resources (`hunger-check`) |
| `2122` | **SSH access** to k8sgoat host |

These ports are exposed through a dedicated `socat` sidecar instead of the QEMU container itself. This allows the use of docker's port handling, while the QEMU container can repurpose the primary interface for the VM bridge.


## General troubleshooting
For ansible based labs, like GOAD, if a task fails (most often thanks to `Ansible`), simply restarting the provisioner usually fixes it:
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

## TODO:
- [ ] finish Dracarys integration
- [ ] test WSL
- [ ] networking howto when using podman

