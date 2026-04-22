<p align="center">
  <img src="assets/logo.png" alt="MGS logo" width="80">
</p>

# MGS - Magic GOAD Summoning ⛧ 🐐🕯️

> Deploy security labs with Docker Compose.  

*We got provisioning at home*

MGS packages Active Directory security labs as Docker Compose stacks, with Windows hosts running as QEMU/KVM guests inside containers.

The primary goal is deploying labs from start to finish with a simple `docker compose up`.
Nothing else is required, especially no host-side Terraform, Ansible, shell script to execute, or manual
network setup.

## Quick Start

```bash
git clone --recurse-submodules https://github.com/ripmge/mgs
cd mgs

# Deploy Game of Active Directory (GOAD)
docker compose up
```

Other available labs:

```bash
# NetExec Barbhack 2025 lab
docker compose -f compose.barbhack.yml up

# Kubernetes Goat lab
docker compose -f compose.k8sgoat.yml up

# GOAD Dracarys lab
# WIP: docker compose -f compose.dracarys.yml up
```

Use `-d` for detached runs after the initial deployment:

```bash
docker compose -f compose.barbhack.yml up -d
```

Stop an interactive run with `Ctrl+C`. For detached runs, stop the stack with:

```bash
docker compose -f <compose-file> down
```

## Requirements

Host requirements:

- Docker and Docker Compose
- Linux host with KVM support
- Access to `/dev/kvm` and `/dev/net/tun`
- Enough CPU, memory, disk, and download capacity for the selected lab
- Git submodules initialized, either through `--recurse-submodules` or
  `git submodule update --init --recursive`

The Windows labs mount `/dev/kvm`, `/dev/net/tun`, and `/dev/vhost-net`,
and add `NET_ADMIN` inside the containers so QEMU can bridge each guest onto the
lab subnet.

## Available Labs

| Lab | Compose file | Network | Initial runtime | Notes |
| --- | --- | --- | --- | --- |
| GOAD | `compose.yml` | `192.168.56.0/24` | 2-3 hours | Default stack |
| NetExec Barbhack 2025 | `compose.barbhack.yml` | `192.168.10.0/24` | 1-2 hours | AD pentest CTF lab |
| Kubernetes Goat | `compose.k8sgoat.yml` | `192.168.77.0/24` | 5-10 minutes | Single Ubuntu VM plus TCP proxy |
| GOAD Dracarys | `compose.dracarys.yml` | `192.168.10.0/24` | WIP | To be done... |

Runtime depends heavily on ISO/image download speed, CPU, disk IO, and whether
the named Docker volumes already contain initialized VM disks.

## Provisioning State

Provisioning is complete when the provisioner container prints:

```text
goad-provisioner  | [+] Provisioning completed successfully!
goad-provisioner  | [+] Marker file created. Future runs will be skipped.
```

Provisioner containers use named volumes to store a run-once marker. Subsequent
`docker compose up` runs reuse the stored VM disks and skip provisioning unless you
remove the relevant provisioner volume.

To remove containers while preserving VM disks and provisioner state:

```bash
docker compose -f <compose-file> down
```

To reset a lab from scratch, remove its named volumes:

```bash
docker compose -f <compose-file> down -v
```

That deletes VM disks and provisioning state for the selected lab.

## Access

MGS uses `dockurr/windows` and `qemux/qemu` containers to run VMs through
QEMU. These images expose a browser VNC console that is useful for checking VM status.

In each lab, a primary VM exposes VNC on:

```text
http://localhost:8006
```

There are two common access patterns.

### Access from the Docker Host

With Docker Engine and the default bridge configuration, the lab subnet is
reachable from the host. **Use the VM IPs (and ignore container IPs)** listed in the lab tables below.

Podman and non-default Docker network setups may behave differently.

### Access from the LAN

If you need to work from another machine on your LAN, either:

- Start the optional Kali container and use its browser session.
- Add an SSH jump container yourself and use `ssh -D` as a SOCKS proxy into the lab.

The labs come with an optional Kali container. Start it with the `kali` profile:

```bash
docker compose -f compose.barbhack.yml --profile kali up -d
```

Kali is then available via web-VNC:

```text
https://localhost:6901
```

Use your host's LAN IP instead of `localhost` when connecting from another LAN
client.

### Default Credentials

These credentials are for administrative or console access. Windows
credentials are not part of the lab challenges.

| System | Credentials |
| --- | --- |
| Kali | `kasm_user:password` |
| Windows | `Docker:admin` |
| Kubernetes Goat VM | `kubernetes:goat` |

## Architecture

Each Windows lab host is a Docker container running a QEMU/KVM VM. MGS injects
bridge/tap networking and bootstrap logic through a custom entrypoint while keeping the
original `dockurr/windows` image otherwise unchanged.

Key behavior:

- Container gets a fixed IP on the Docker network.
- Windows gets its own fixed VM IP on the same lab subnet.
- `/entrypoint-bridge.sh` prepares networking inside the container (brigde/tap).
- `install.bat` prepares each VM by enabling WinRM and setting static IP and firewall.
- `/storage` is a named Docker volume where the VM files live.
- The custom entrypoint hands over to the original entrypoint.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ HOST SYSTEM                                                          │
│----------------------------------------------------------------------│
│  docker compose up                                                   │
│        │                                                             │
│        ▼                                                             │
│  docker network: goad_bridge (192.168.56.0/24)                       │
│                                                                      │
│  container IP: 192.168.56.110                                        │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │ dc01 container (dockurr/windows)                             │   │
│   │--------------------------------------------------------------│   │
│   │ Original image runtime                                             │   │
│   │  - /run/entry.sh                                             │   │
│   │  - QEMU/KVM VM launcher                                      │   │
│   │                                                              │   │
│   │ MGS runtime injections                                       │   │
│   │  - /entrypoint-bridge.sh   <-- patched entrypoint            │   │
│   │  - /oem/install.bat        <-- per-VM bootstrap              │   │
│   │  - /storage                <-- persistent VM disk            │   │
│   │                                                              │   │
│   │ Internal container networking                                │   │
│   │--------------------------------------------------------------│   │
│   │                                                              │   │
│   │─── eth0 (Docker veth, promisc)                               │   │
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
│ Other lab nodes and the provisioner are on the same Docker subnet.  │
└──────────────────────────────────────────────────────────────────────┘
```

## Design Constraints

MGS exists because  other lab deployment options felt heavier and more cumbersome than needed
for local, repeatable practice environments targeting a single user, or up to a hand full of users.

1. **Self-contained deployment:** `docker compose up` should be enough. No
   Terraform, host-side Ansible, or additional orchestration should be required.
2. **No host network preparation:** MGS should not require shell scripts or
   persistent host network configuration. This doesn't mean you don't have to review things. You should still check out compose
   files before running them, especially bind mounts, devices, capabilities, and
   published ports.
3. **Daily-driver friendly:** The labs should be resumable with
   `docker compose up/down` so they can live on a primary workstation without
   dedicating separate hardware.
4. **Reuse upstream images:** The stacks reuse existing container images and
   configure them through custom entrypoints and environment variables.
   I don't want to maintain a bunch of images.

## Entrypoint Hot Patch

The default `qemux/qemu` and `dockurr/windows` networking path uses NAT. Active
Directory does not behave well in that model.

Domain controllers register the guest's internal QEMU/NAT IP in DNS. Other lab
machines then resolve the DC to an address that is unreachable from the Docker
lab network.

MGS replaces that path with bridge/tap networking inside the container:

- `entrypoint-bridge.sh` prepares the bridge and tap device.
- The script exports QEMU network arguments expected by the upstream entrypoint.
- QEMU attaches the VM NIC to the container bridge.
- The guest VM receives a stable IP on the Docker lab subnet.

This avoids requiring host-side `macvlan` setup, which is a common solution for
`dockurr/windows` but conflicts with the no-host-preparation constraint.

## Security Notes

These labs intentionally run vulnerable workloads. Treat them as hostile.

The VM containers receive direct access to kernel virtualization and networking
interfaces:

- `/dev/kvm`
- `/dev/net/tun`
- `/dev/vhost-net` for Windows lab stacks
- `NET_ADMIN` inside the container

Important implications:

- `/dev/kvm` does not grant host filesystem access by itself. Host file access
  depends on bind mounts, named volumes, and exposed block devices.
- VM code still runs as guest code mediated by the host kernel and KVM.
- CPU, RAM, and disk IO exhaustion are a potential threat without Docker resource
  limits.
- Kernel escape bugs in KVM, vhost-net, tun/tap, or related networking paths are
  your main risk in regards to isolation.
- Routing or bridging the lab network into a real LAN is the most practical
  operational footgun.

Do not share access to a lab running on your primary system with people you do
not trust. For multi-user or shared environments, consider a dedicated host or a
purpose-built lab platform such as [Ludus](https://ludus.cloud/).

## Lab Details

The lab ranges below come from their respective upstream authors. This repository
does not create the lab scenarios; it provides Docker-based deployment wrappers.

### GOAD

Game of Active Directory
([Orange-Cyberdefense/GOAD](https://github.com/Orange-Cyberdefense/GOAD)) is an
Active Directory lab for pentesting practice. It includes multiple
domains/servers and intentionally vulnerable configurations for learning common
AD attacks.

Additional writeups are available from
[mayfly277](https://mayfly277.github.io/categories/goad/).

#### GOAD Requirements

`dockurr/windows` downloads ISOs at container creation time. Expect roughly 25 GB
of downloads in addition to the upstream GOAD requirements.

| Component | Minimum | Notes |
| --- | --- | --- |
| CPU | ~8+ cores | 5 VMs x 2 vCPU recommended; fewer works, but slower |
| RAM | 24 GB+ | 5 VMs x 4 GB plus overhead |
| Disk | 200 GB+ | 5 VMs x 40 GB storage |
| Time | 2-3 hours | Depends on download speed, CPU, and disk IO |

#### GOAD Hosts

| Role | Service | Hostname | Container IP | VM IP |
| --- | --- | --- | --- | --- |
| Domain Controller | `dc01` | `kingslanding` | `192.168.56.110` | `192.168.56.10` |
| Domain Controller | `dc02` | `winterfell` | `192.168.56.111` | `192.168.56.11` |
| Domain Controller | `dc03` | `meereen` | `192.168.56.112` | `192.168.56.12` |
| Member server | `srv01` | `castelblack` | `192.168.56.122` | `192.168.56.22` |
| Member server | `srv02` | `braavos` | `192.168.56.123` | `192.168.56.23` |
| Provisioner | `provisioner` | - | `192.168.56.100` | - |
| Web VNC Kali | `goad-kali` | - | `192.168.56.50` | - |

Docker network: `goad_bridge` = `192.168.56.0/24`

### NetExec Barbhack 2025

The NetExec Barbhack 2025 lab comes from
[Pennyw0rth/NetExec-Lab](https://github.com/Pennyw0rth/NetExec-Lab/tree/main/Barbhack-2025).
It focuses on using NetExec to compromise an Active Directory domain during an
internal pentest-style, pirate-themed scenario.

#### NetExec Requirements

`dockurr/windows` downloads ISOs at container creation time. Expect roughly 20 GB
of downloads in addition to the lab content.

| Component | Minimum | Notes |
| --- | --- | --- |
| CPU | ~6+ cores | 4 VMs x 2 vCPU recommended; fewer works, but slower |
| RAM | 20 GB+ | 4 VMs x 4 GB plus overhead |
| Disk | 160 GB+ | 4 VMs x 40 GB storage |
| Time | 1-2 hours | Depends on download speed, CPU, and disk IO |

#### NetExec Hosts

| Role | Service | Hostname | Container IP | VM IP |
| --- | --- | --- | --- | --- |
| Domain Controller | `barb-dc01` | `BLACKPEARL` | `192.168.10.110` | `192.168.10.10` |
| Member server | `barb-srv01` | `JOLLYROGER` | `192.168.10.111` | `192.168.10.11` |
| Member server | `barb-srv02` | `QUEENREV` | `192.168.10.112` | `192.168.10.12` |
| Member server | `barb-srv03` | `FLYINGDUTCHMAN` | `192.168.10.113` | `192.168.10.13` |
| Provisioner | `barb-provisioner` | - | `192.168.10.100` | - |
| Web VNC Kali | `barb-kali` | - | `192.168.10.50` | - |

Docker network: `barb_bridge` = `192.168.10.0/24`

### Kubernetes Goat

[Kubernetes Goat](https://github.com/madhuakula/kubernetes-goat) is an
intentionally vulnerable Kubernetes cluster for security learning and practice.
Its upstream documentation is available at
[madhuakula.com/kubernetes-goat](https://madhuakula.com/kubernetes-goat/).

The MGS stack runs a single Ubuntu cloud image VM through `qemux/qemu`, installs
Kubernetes Goat inside that VM, and exposes selected scenario ports through a
small `socat` proxy container. Keeping the scenarios inside a VM preserves
isolation for exercises such as container escape and host access.

#### Kubernetes Goat Requirements

These are estimates. If the host can run one VM comfortably, it should be enough
for this lab.

| Component | Minimum | Notes |
| --- | --- | --- |
| CPU | ~2+ cores | Single VM |
| RAM | 8 GB | 4 GB may work, but leaves little headroom |
| Disk | 30 GB+ | Backed by the `k3sgoat-storage` volume |
| Time | 5-10 minutes | Depends on download speed, CPU, and disk IO |

#### Kubernetes Goat Ports

| Port | Scenario |
| --- | --- |
| `1230` | Sensitive keys in codebases (`build-code`) |
| `1231` | DIND exploitation (`health-check`) |
| `1232` | SSRF in K8s world (`internal-proxy`) |
| `1233` | Container escape / host access (`system-monitor`) |
| `1234` | Kubernetes Goat home page |
| `1235` | Attacking private registry (`poor-registry`) |
| `1236` | DoS resources (`hunger-check`) |
| `2122` | SSH access to the Kubernetes Goat VM |

Docker network: `k3sgoat_bridge` = `192.168.77.0/24`
