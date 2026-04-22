# HA Dynamic VPN — AWS Transit Gateway + On-Premises BGP Routing

> **A complete walkthrough of building, breaking, debugging, and fixing a production-grade HA Site-to-Site VPN with BGP route propagation on AWS.**

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Breakdown](#2-component-breakdown)
3. [Network Design & CIDR Plan](#3-network-design--cidr-plan)
4. [Build Phases](#4-build-phases)
5. [Stage 4 — FRRouting Installation (Where Everything Broke)](#5-stage-4--frrouting-installation-where-everything-broke)
6. [Root Cause Analysis — Every Error Explained](#6-root-cause-analysis--every-error-explained)
7. [The Complete Error Timeline](#7-the-complete-error-timeline)
8. [What Copilot Got Wrong](#8-what-copilot-got-wrong)
9. [How the Errors Were Actually Fixed](#9-how-the-errors-were-actually-fixed)
10. [The Final Working Script](#10-the-final-working-script)
11. [BGP Configuration Commands](#11-bgp-configuration-commands)
12. [Verification — Proof It Works](#12-verification--proof-it-works)
13. [Key Lessons Learned](#13-key-lessons-learned)
14. [Concepts Reference](#14-concepts-reference)

---

## 1. Architecture Overview

This project implements **Adrian Cantrill's Advanced HA Dynamic VPN** demo — a fully redundant, BGP-driven Site-to-Site VPN between an AWS VPC and a simulated on-premises environment.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS GLOBAL NETWORK                                 │
│                                                                               │
│  ┌──────────────────┐        ┌──────────┐        ┌───────────────────────┐  │
│  │  A4L PRIVATE VPC │        │   TGW    │        │  Accelerated VPN      │  │
│  │                  │        │          │        │  Endpoints            │  │
│  │  ┌────────────┐  │        │ ┌──────┐ │        │  ┌────────────────┐   │  │
│  │  │ A4L-EC2-A  │  │◄──────►│ │Route │ │◄──────►│  │ VPN Conn 1     │   │  │
│  │  │  (AZA)     │  │        │ │Table │ │        │  │ Tunnel 1 ✅ Up │   │  │
│  │  └────────────┘  │        │ └──────┘ │        │  │ Tunnel 2 ✅ Up │   │  │
│  │                  │        │          │        │  │ 2 BGP ROUTES   │   │  │
│  │  ┌────────────┐  │        │ BGP ASN  │        │  └────────────────┘   │  │
│  │  │ A4L-EC2-B  │  │        │  64512   │        │  ┌────────────────┐   │  │
│  │  │  (AZB)     │  │        │          │◄──────►│  │ VPN Conn 2     │   │  │
│  │  └────────────┘  │        └──────────┘        │  │ Tunnel 1 ✅ Up │   │  │
│  │                  │                             │  │ Tunnel 2 ✅ Up │   │  │
│  │  CIDR:           │                             │  │ 2 BGP ROUTES   │   │  │
│  │  10.16.0.0/16    │                             │  └────────────────┘   │  │
│  └──────────────────┘                             └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │  BGP Routes Exchanged
                                       │  AWS advertises: 10.16.0.0/16
                                       │  OnPrem advertises: 192.168.x.x/24
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PUBLIC INTERNET                                        │
│                                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    ANIMALS4LIFE (On-Premises VPC)                      │   │
│  │                                                                         │   │
│  │   ┌─────────────────────┐        ┌─────────────────────┐              │   │
│  │   │      CGW1           │        │      CGW2           │              │   │
│  │   │  (ONPREM-ROUTER1)   │        │  (ONPREM-ROUTER2)   │              │   │
│  │   │  BGP ASN: 65016     │        │  BGP ASN: 65016     │              │   │
│  │   │  FRR + strongSwan   │        │  FRR + strongSwan   │              │   │
│  │   │  VPN Conn 1 EIP     │        │  VPN Conn 2 EIP     │              │   │
│  │   └─────────┬───────────┘        └───────────┬─────────┘              │   │
│  │             │                                 │                         │   │
│  │   ┌─────────▼───────────────────────────────▼─────────┐              │   │
│  │   │              Internal LAN                           │              │   │
│  │   │                                                      │              │   │
│  │   │  ┌──────────────────┐    ┌──────────────────┐       │              │   │
│  │   │  │   ONPREM-SERVER1  │    │   ONPREM-SERVER2  │       │              │   │
│  │   │  │  192.168.10.0/24 │    │  192.168.11.0/24 │       │              │   │
│  │   │  └──────────────────┘    └──────────────────┘       │              │   │
│  │   └─────────────────────────────────────────────────────┘              │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Final Proof — Both Tunnels Up with BGP Routes

```
VPN Connection 1:
  Tunnel 1 → Status: UP | 2 BGP ROUTES ✅
  Tunnel 2 → Status: UP | 2 BGP ROUTES ✅

VPN Connection 2:
  Tunnel 1 → Status: UP | 2 BGP ROUTES ✅
  Tunnel 2 → Status: UP | 2 BGP ROUTES ✅
```

---

## 2. Component Breakdown

| Component | Type | Purpose |
|---|---|---|
| **A4L Private VPC** | AWS VPC `10.16.0.0/16` | AWS-side workload network |
| **A4L-EC2-A** | EC2 (Amazon Linux) in AZA | AWS test instance |
| **A4L-EC2-B** | EC2 (Amazon Linux) in AZB | AWS test instance (HA pair) |
| **Transit Gateway (TGW)** | AWS TGW | Hub connecting VPC and VPN connections |
| **VPN Connection 1** | Site-to-Site VPN (Accelerated) | AWS → CGW1, 2 tunnels |
| **VPN Connection 2** | Site-to-Site VPN (Accelerated) | AWS → CGW2, 2 tunnels |
| **CGW1** | Customer Gateway object | Points to ONPREM-ROUTER1's EIP |
| **CGW2** | Customer Gateway object | Points to ONPREM-ROUTER2's EIP |
| **Animals4Life VPC** | AWS VPC simulating on-prem | On-premises environment simulation |
| **ONPREM-ROUTER1** | EC2 + strongSwan + FRR | IPsec endpoint + BGP speaker |
| **ONPREM-ROUTER2** | EC2 + strongSwan + FRR | IPsec endpoint + BGP speaker (HA) |
| **ONPREM-SERVER1** | EC2 `192.168.10.x` | On-prem test server |
| **ONPREM-SERVER2** | EC2 `192.168.11.x` | On-prem test server |

---

## 3. Network Design & CIDR Plan

```
AWS Side:
  A4L VPC:              10.16.0.0/16
    Private Subnet AZA: 10.16.X.0/24
    Private Subnet AZB: 10.16.X.0/24

On-Premises Side (simulated):
  Animals4Life VPC:     192.168.0.0/16
    ONPREM-SERVER1:     192.168.10.0/24
    ONPREM-SERVER2:     192.168.11.0/24

BGP ASNs:
  AWS TGW:              64512  (AWS default)
  On-Prem Routers:      65016  (private ASN range)

VPN Tunnel Inside IPs:
  Assigned automatically by AWS per tunnel
  Used as BGP peer IPs between TGW and routers
```

### How Traffic Flows (End-to-End)

```
A4L-EC2-A
    │
    ▼ (route table: 192.168.0.0/16 → TGW)
Transit Gateway
    │
    ▼ (TGW route table: BGP-learned 192.168.10.0/24 → VPN Conn 1)
IPsec Tunnel (encrypted)
    │
    ▼
ONPREM-ROUTER1 (decrypts, routes internally)
    │
    ▼
ONPREM-SERVER1
```

---

## 4. Build Phases

### Phase 1 — A4L Private VPC
- Create VPC CIDR `10.16.0.0/16`
- Create private subnets in AZA and AZB
- Launch A4L-EC2-A and A4L-EC2-B

### Phase 2 — On-Premises (Animals4Life) VPC
- Create VPC CIDR `192.168.0.0/16`
- Create public subnet for routers (needs EIP)
- Create private subnets for servers
- Attach Internet Gateway
- Launch ONPREM-ROUTER1 + ROUTER2 with Elastic IPs
- Launch ONPREM-SERVER1 + SERVER2
- **Disable source/destination check** on router EC2s

### Phase 3 — Transit Gateway
- Create TGW with BGP ASN `64512`
- Create TGW attachment to A4L VPC (both AZs)
- Update A4L VPC route tables to send `192.168.0.0/16` → TGW

### Phase 4 — Customer Gateways
- Create CGW1 → ONPREM-ROUTER1 EIP, BGP ASN `65016`
- Create CGW2 → ONPREM-ROUTER2 EIP, BGP ASN `65016`

### Phase 5 — VPN Connections
- Create VPN Conn 1: TGW attachment, CGW1, Dynamic routing, **Acceleration ON**
- Create VPN Conn 2: TGW attachment, CGW2, Dynamic routing, **Acceleration ON**
- Download config files (Generic/VyOS vendor)

### Phase 6 — Install FRR on Routers ← *Where all errors occurred*

### Phase 7 — Configure BGP

### Phase 8 — Verify End-to-End

---

## 5. Stage 4 — FRRouting Installation (Where Everything Broke)

The lab provides a script `ffrouting-install.sh` that builds FRR (FRRouting) from source. FRR provides the BGP daemon (`bgpd`) that forms BGP sessions with the Transit Gateway over the IPsec tunnels.

### What the Script Was Supposed to Do

```
1. Install system dependencies (gcc, cmake, autoconf, etc.)
2. Build libyang v1.0.184 from source  → Yang data modelling library
3. Build rtrlib v0.6.3 from source     → RPKI validation library
4. Clone FRR 7.x and build from source → The actual BGP routing suite
5. Install FRR as a systemd service
6. Enable bgpd daemon
7. Start FRR
```

### Why Building from Source is Fragile

All three components must be **version-pinned together**:

```
FRR version  ←——must match——→  libyang version  ←——must match——→  rtrlib version

If any one drifts → build fails with cryptic C compiler errors
```

The original script was written for Ubuntu 18.04 (Bionic) with specific library versions. AWS AMIs updated over time. Library versions on GitHub drifted. The carefully balanced dependency chain broke silently.

---

## 6. Root Cause Analysis — Every Error Explained

### Error 1 — `alloc_utils_private.h: No such file or directory`

```
fatal error: rtrlib/lib/alloc_utils_private.h: No such file or directory
 #include "rtrlib/lib/alloc_utils_private.h"
compilation terminated.
```

**What it means:** FRR's RPKI module (`bgpd/bgp_rpki.c`) includes a private header from rtrlib that only exists in rtrlib v0.6.x. In rtrlib v0.8.0+, this header was removed.

**Why it happened:** The script had a bug in the order of commands:

```bash
# WRONG — as written in original script:
cd /tmp
git clone https://github.com/rtrlib/rtrlib/
git checkout v0.6.3    ← runs in /tmp, NOT inside rtrlib directory!
cd rtrlib              ← cd happens AFTER checkout — too late

# What actually happened:
# git checkout ran in /tmp (not a git repo) → silently failed
# rtrlib stayed on master branch → v0.8.0 was installed
# v0.8.0 missing alloc_utils_private.h → FRR compile failed
```

**Proof from error log:**
```
-- Up-to-date: /usr/local/lib/librtr.so.0.8.0   ← v0.8.0 installed!
```

---

### Error 2 — `Makefile: *** missing target pattern. Stop.`

```
Makefile:9638: *** missing target pattern.  Stop.
```

**What it means:** FRR uses a custom code generator called **Clippy** (written in C with Python bindings) to auto-generate CLI command handler code. Clippy reads `.c` source files and generates `*_clippy.c` output files. When Clippy fails, it leaves incomplete Makefile dependency files (`.d` files) that contain broken rules — specifically rules with colons in the wrong place. When `make` runs and tries to include these files, it cannot parse the broken rule and aborts.

**Why it happened in `bgp_bfd.c`:**

```c
/* This is what bgp_bfd.c had — Clippy CANNOT parse this: */
#if HAVE_BFDD > 0
DEFUN_HIDDEN(           ← Clippy starts reading DEFUN macro...
#else
DEFUN(                  ← hits a CPP directive MID-ARGUMENT → crash
#endif /* HAVE_BFDD */
    neighbor_bfd_param,
    ...
```

Clippy's parser reads macro argument lists character by character. When it hits a `#if`/`#else`/`#endif` preprocessor directive **inside** an argument list, it has no idea what to do and throws:

```
ValueError: bgpd/bgp_bfd.c:733: cannot process CPP directive within argument list
```

This leaves `bgp_bfd_clippy.c` partially written with broken Makefile include rules.

**Why retrying without cleaning made it worse:** Every retry without `rm -rf /tmp/frr` reused the corrupted `.d` files. Even a fresh `./configure` didn't remove them. The broken Makefile rules persisted across attempts.

---

### Error 3 — `frr.service: Failed at step EXEC — No such file or directory`

```
ExecStart=/usr/lib/frr/frrinit.sh start (code=exited, status=203/EXEC)
Failed to execute command: No such file or directory
```

**What it means:** systemd could not find `/usr/lib/frr/frrinit.sh` — the FRR init script.

**Why it happened:** Because `make install` never completed (Clippy errors aborted it), the FRR binary and scripts were never placed into `/usr/lib/frr/`. The systemd unit file was installed (from `tools/frr.service`) but the files it points to were never placed on disk.

```
systemd unit file installed:      ✅ /etc/systemd/system/frr.service
frrinit.sh installed:             ❌ missing from /usr/lib/frr/
watchfrr installed:               ❌ missing from /usr/lib/frr/
bgpd binary installed:            ❌ missing from /usr/lib/frr/
```

---

### Error 4 — `watchfrr: Failed to start bgpd! / pid file not found`

```
watchfrr[9161]: Forked background command: watchfrr.sh restart bgpd
watchfrr.sh[9757]: Failed to start bgpd!
watchfrr.sh[9861]: Cannot stop bgpd: pid file not found
```

**What it means:** FRR's watchdog (`watchfrr`) was running and trying to start `bgpd`, but bgpd was crashing immediately before writing its PID file.

**Why it happened:** The `/etc/frr/daemons` file had been modified to include `-M rpki` in bgpd's options:

```
bgpd_options="   -A 127.0.0.1 -M rpki"
```

The `-M rpki` flag tells bgpd to load the RPKI module at startup. But the RPKI module (`.so` file) was not present in `/usr/lib/frr/modules/` because `make install` had been interrupted. bgpd found a flag pointing to a non-existent module → crash on startup → no PID file written → watchfrr retried every 10 minutes in an infinite loop.

---

## 7. The Complete Error Timeline

```
Attempt 1: Run ./ffrouting-install.sh
  └─► rtrlib checkout runs in /tmp (wrong directory)
  └─► rtrlib v0.8.0 installed silently
  └─► FRR compile: alloc_utils_private.h missing ❌

Attempt 2: Rebuild rtrlib, retry FRR
  └─► rtrlib still v0.8.0 (same bug in script)
  └─► Same header error ❌

Attempt 3: Manually copy headers
  └─► sudo cp -r /usr/local/include/rtrlib/rtrlib/lib/* ...
  └─► Clippy now runs, hits bgp_bfd.c:733 CPP directive ❌

Attempt 4: Add --disable-clippy to ./configure
  └─► Flag does not exist in FRR 7.x → ignored
  └─► Clippy runs anyway → same error ❌

Attempt 5: Downgrade FRR to 7.3.1
  └─► 7.3.1 has SAME Clippy bug at different line (602)
  └─► Error persists ❌

Attempt 6: Add CLIPPY=; (semicolon) to make
  └─► Wrong syntax — CLIPPY=; doesn't suppress Clippy
  └─► Makefile corruption remains ❌

Attempt 7: Add CLIPPY=: (colon) to make
  └─► Correct syntax but stale .d files already corrupted Makefile
  └─► missing target pattern error ❌

Attempt 8: Fix cd/checkout order + add rm -rf + CLIPPY=:
  └─► rtrlib v0.6.3 now correctly installed ✅
  └─► Tree is clean ✅
  └─► CLIPPY=: still can't fix the Makefile rule generation ❌

Attempt 9: Patch bgp_bfd.c with Python before ./configure
  └─► Clippy can now parse the file ✅
  └─► make completes ✅
  └─► make install completes ✅
  └─► bgpd crashes → RPKI module missing ❌

Attempt 10: Remove -M rpki from bgpd_options
  └─► bgpd starts cleanly ✅
  └─► BGP sessions form with TGW ✅
  └─► Routes exchanged ✅
  └─► All 4 tunnels UP with 2 BGP ROUTES each ✅ DONE
```

---

## 8. What Copilot Got Wrong

These are the suggestions from the Copilot conversation that caused wasted time or made things worse:

| Suggestion | Why It Was Wrong | What Actually Happened |
|---|---|---|
| `--disable-clippy` in `./configure` | This flag does not exist in FRR 7.3.1 or 7.5.1 | configure printed "unrecognized option" and ignored it — Clippy ran anyway |
| `CLIPPY=;` (semicolon) in make | Semicolon in shell means "end command and run next" — not the same as `:` | Build failed with "missing target pattern" |
| Downgrade to FRR 7.3.1 to fix Clippy | Both 7.3.1 and 7.5.1 have the same Clippy bug in `bgp_bfd.c` | Error moved from line 733 to line 602 — same root cause |
| Install rtrlib with `INSTALL_PRIVATE_HEADERS=ON` CMake flag | This flag does not exist in rtrlib's CMake | cmake ignored it silently |
| Copy headers manually from rtrlib source tree | Source tree has all headers; installed version only has public ones — copying private headers without the compiled library context is invalid | FRR compile moved past header error but hit deeper incompatibilities |
| Rebuild rtrlib repeatedly without fixing checkout order | The bug was `cd rtrlib` being after `git checkout` — rebuilding without fixing this installed v0.8.0 every single time | 5+ rebuild attempts all installed the wrong version |
| "Use Option 1 (reinstall via apt)" | Suggested but never followed through with a proper apt repo setup | Partial apt installs left broken state |

---

## 9. How the Errors Were Actually Fixed

### Fix 1 — rtrlib Version (the Silent Bug)

**The bug:**
```bash
# WRONG order in original script:
cd /tmp
git clone https://github.com/rtrlib/rtrlib/
git checkout v0.6.3    ← in /tmp, not in rtrlib/ → fails silently
cd rtrlib
```

**The fix:**
```bash
# CORRECT order:
cd /tmp
git clone https://github.com/rtrlib/rtrlib.git
cd rtrlib              ← cd FIRST
git checkout v0.6.3    ← NOW runs inside the git repo → works
```

**Effect:** rtrlib v0.6.3 correctly installed → `alloc_utils_private.h` present → first compile error resolved.

---

### Fix 2 — Always Start Clean (No Stale Artifacts)

**The problem:** Every retry reused the previous corrupted build tree.

**The fix:** Add cleanup at the top of each build section:
```bash
sudo rm -rf /tmp/frr
sudo rm -rf /tmp/rtrlib
sudo rm -rf /tmp/libyang
```

**Effect:** No stale `.d` Makefile dependency files → Makefile generated cleanly on every run.

---

### Fix 3 — Patch `bgp_bfd.c` Before Building (Bypass Clippy's Limitation)

**The problem:** Clippy (FRR's CLI code generator) cannot parse `#if/#else/#endif` directives **inside** a DEFUN macro's argument list in `bgp_bfd.c`.

**What Copilot tried:** `CLIPPY=:` on the make command — overrides the Clippy binary with a shell no-op. This does not work because Clippy's output files (`.d` dependency rules) are still expected by the Makefile. When they're not generated, the Makefile contains broken include rules.

**The actual fix — patch the source file with Python before `./configure` runs:**

```python
import re

filepath = '/tmp/frr/bgpd/bgp_bfd.c'
with open(filepath, 'r') as f:
    content = f.read()

# Replace the Clippy-incompatible conditional block:
#   #if HAVE_BFDD > 0
#   DEFUN_HIDDEN(
#   #else
#   DEFUN(              ← Clippy crashes here
#   #endif
# With just:
#   DEFUN(              ← Clippy parses this fine

content = re.sub(
    r'#if HAVE_BFDD > 0\nDEFUN_HIDDEN\(\n#else\nDEFUN\(\n#endif /\* HAVE_BFDD \*/',
    'DEFUN(',
    content
)

with open(filepath, 'w') as f:
    f.write(content)
```

**Why this is correct:** In this lab environment, `HAVE_BFDD=0` (BFD daemon not used), so the `DEFUN(` branch was always the correct one. Replacing the conditional with just `DEFUN(` produces identical compiled output with no functional change.

**Effect:** Clippy parses `bgp_bfd.c` successfully → no broken `.d` files → Makefile valid → `make` and `make install` complete → all FRR binaries placed in `/usr/lib/frr/`.

---

### Fix 4 — Remove `-M rpki` from bgpd Options

**The problem:** `/etc/frr/daemons` had:
```
bgpd_options="   -A 127.0.0.1 -M rpki"
```
The `-M rpki` flag loads the RPKI module at bgpd startup. The RPKI module `.so` was not installed (or was in the wrong path) → bgpd crashed before writing its PID file → watchfrr retried every 10 minutes.

**The fix:**
```bash
sudo sed -i \
  's/bgpd_options="   -A 127.0.0.1 -M rpki"/bgpd_options="   -A 127.0.0.1"/' \
  /etc/frr/daemons
sudo systemctl restart frr
```

**Effect:** bgpd starts cleanly → writes PID file → watchfrr happy → BGP sessions can form.

---

## 10. The Final Working Script (Run this sript on both the Routers)

Check the above script frr-install.sh.
After runnning this, also run the bgp.sh so that it can  turn on the service.

## 11. BGP Configuration Commands

Run these on **ONPREM-ROUTER1** after FRR is running:

```bash
sudo bash
vtysh
```

Inside vtysh:

```
conf t
frr defaults traditional
router bgp 65016
neighbor <CONN1_TUNNEL1_AWS_BGP_IP> remote-as 64512
neighbor <CONN1_TUNNEL2_AWS_BGP_IP> remote-as 64512
no bgp ebgp-requires-policy
address-family ipv4 unicast
redistribute connected
exit-address-family
exit
exit
wr
exit
```

```bash
sudo reboot
```

Run these on **ONPREM-ROUTER2** after FRR is running:

```
conf t
frr defaults traditional
router bgp 65016
neighbor <CONN2_TUNNEL1_AWS_BGP_IP> remote-as 64512
neighbor <CONN2_TUNNEL2_AWS_BGP_IP> remote-as 64512
no bgp ebgp-requires-policy
address-family ipv4 unicast
redistribute connected
exit-address-family
exit
exit
wr
exit
```

> Replace `CONN1_TUNNEL1_AWS_BGP_IP` etc. with the Inside IPv4 CIDR tunnel IPs from your VPN connection's Tunnel details tab in the AWS Console.

---

## 12. Verification — Proof It Works

### Check BGP Routes on Router

```bash
sudo bash
route                       # Shows kernel routing table with AWS routes
vtysh
show ip route               # Shows BGP-learned routes from TGW
show bgp summary            # Shows BGP neighbor state and prefix count
```

Expected output from `show bgp summary`:
```
Neighbor        V  AS   MsgRcvd  MsgSent  Up/Down  State/PfxRcd
169.254.x.x     4  64512   120     115    00:45:12        1
169.254.x.x     4  64512   118     113    00:44:55        1
```

### Test Connectivity

```bash
# From ONPREM-SERVER1, ping EC2-A
ping <IP_OF_A4L-EC2-A>

# From EC2-A, ping ONPREM-SERVER1
ping <IP_OF_ONPREM-SERVER1>
```

### AWS Console Verification

In **VPC → Site-to-Site VPN Connections → Tunnel details**:
```
Tunnel 1  Status: Up  |  2 BGP ROUTES  ✅
Tunnel 2  Status: Up  |  2 BGP ROUTES  ✅
```

In **TGW Route Tables**:
```
192.168.10.0/24  →  VPN Conn 1  (BGP propagated)  ✅
192.168.11.0/24  →  VPN Conn 2  (BGP propagated)  ✅
```

---

## 13. Key Lessons Learned

### Technical

| Lesson | Detail |
|---|---|
| **Order of `cd` and `git checkout` matters critically** | `git checkout` must run inside the cloned directory, not the parent |
| **Always verify the installed version, not just the command** | `ls /usr/local/lib/librtr.so.*` tells you the truth; the terminal doesn't |
| **`make` retries on a dirty tree reuse broken artifacts** | `rm -rf /tmp/<repo>` before every attempt is mandatory |
| **`CLIPPY=:` is not a supported flag** | It replaces the binary with a no-op but Makefile dependency rules still expect its output |
| **Patching source is cleaner than fighting the build system** | A 10-line Python patch on `bgp_bfd.c` solved what 10 build attempts couldn't |
| **`-M rpki` requires the RPKI module `.so` to be present** | Missing module = bgpd crash before PID file write = watchfrr restart loop |

### Process

| Lesson | Detail |
|---|---|
| **Share full error log AND the script together** | Context from both is required for accurate diagnosis |
| **AI tools hallucinate flags** | `--disable-clippy` and `INSTALL_PRIVATE_HEADERS=ON` don't exist — verify flags before trusting suggestions |
| **Going in circles is a signal to step back** | Same error at a different line number means wrong root cause was identified |
| **The original script's assumptions can be wrong** | Lab scripts written for specific AMI versions break silently when AMIs update |

---

## 14. Concepts Reference

### What is BGP (Border Gateway Protocol)?

BGP is the routing protocol that exchanges network reachability information between autonomous systems. In this lab:

- The TGW runs BGP with ASN `64512`
- The on-prem routers run BGP with ASN `65016`
- Each router **advertises** its local subnets to the TGW
- The TGW **advertises** the A4L VPC CIDR back to the routers
- Routes are dynamically installed in both routing tables — no manual route entries needed

### What is FRRouting?

FRR (Free Range Routing) is an open-source IP routing protocol suite. In this lab it provides:

- `bgpd` — the BGP daemon that forms sessions with the TGW
- `zebra` — the routing manager that installs BGP-learned routes into the Linux kernel
- `vtysh` — the CLI for configuring and inspecting routing state

### What is RTRlib?

RTRlib (RPKI-To-Router library) provides RPKI (Resource Public Key Infrastructure) support for BGP routers. RPKI validates that BGP route announcements come from legitimate origin ASes. FRR uses rtrlib as a library for its RPKI module. Version compatibility is strict — the private header `alloc_utils_private.h` exists in v0.6.x but was removed in v0.8.0.

### What is Route Propagation?

Route propagation is the automatic mechanism by which routers learn and share network paths. In this lab:

- **BGP propagation**: Routes are exchanged between TGW and on-prem routers via BGP sessions running inside IPsec tunnels
- **TGW route propagation**: When enabled on a TGW attachment, BGP-learned routes from VPN connections are automatically added to the TGW route table without manual entry
- **HA behaviour**: If one router fails, its BGP session drops, its routes are withdrawn, and traffic automatically reroutes through the other router — zero manual intervention

### What is Clippy (FRR context)?

Clippy in FRR is a custom C/Python code generator (unrelated to the Rust linter). It reads `.c` source files containing CLI command definitions (DEFUN macros) and generates C code that registers those commands with FRR's CLI framework. It is a mandatory build-time tool — FRR cannot be built without it. It fails when it encounters C preprocessor directives (`#if`/`#else`/`#endif`) inside a DEFUN macro's argument list.

---

*Built on AWS | FRRouting 7.3.1 | Ubuntu 18.04 | Transit Gateway with BGP | 4 Tunnels Active*
