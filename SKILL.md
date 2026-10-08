---
name: gcp-xray
description: >-
  End-to-end automated deployment, non-destructive live tuning, and router/client configuration generator
  for high-speed GCP Xray (VLESS + XTLS-Vision + Reality) nodes on e2-micro VMs.
  Use when the user asks to deploy a new GCP Xray/VLESS/Reality proxy node, upgrade or optimize existing
  GCP Xray nodes without breaking client links, export VLESS links or OpenWrt/PassWall/OpenClash router parameters,
  or troubleshoot cross-Pacific network throughput on GCE e2-micro instances. Triggered by /gcp-xray.
---

# GCP Xray (`VLESS + XTLS-Vision + Reality`) Deployment & Optimization Skill

Automates zero-touch deployment and non-destructive performance tuning of **Xray-core (`VLESS + xtls-rprx-vision + Reality`)** on Google Cloud Platform (`e2-micro`), engineered and verified via real trans-Pacific (`Taiwan -> US West`, `119.2ms` RTT) adversarial benchmarks.

## Core Capabilities

1. **Zero-Touch New Node Provisioning ([install.sh](./install.sh))**:
   - Enables `compute.googleapis.com` and creates the `allow-xray-443` (`tcp:443,udp:443`) firewall rule.
   - Provisions a lightweight `debian-12` `e2-micro` VM (`10GB pd-standard`) in the chosen region:
     - `US` (`us-west1-b`) — eligible for GCP Always Free tier (`$0/mo`)
     - `TW` (`asia-east1-b`)
     - `SG` (`asia-southeast1-b`)
     - `HK` (`asia-east2-a`)
     - `JP` (`asia-northeast1-b`)
   - Persists `UUID`, `PRI_KEY`, `PUB_KEY`, `SHORT_ID`, and `SNI` to `/usr/local/etc/xray/node_info.env` (`chmod 600`) so VM reboots reuse the exact same credentials without breaking client connections.
   - Uses `www.amd.com:443` by default (TLS 1.3 + HTTP/2 + Post-Quantum `X25519MLKEM768`, `3,291 B` cert chain, zero Xray warnings).

2. **Non-Destructive Live Node Upgrade ([scripts/upgrade_node.sh](./scripts/upgrade_node.sh))**:
   - Upgrades any existing GCP Xray VM in-place **without changing its IP, UUID, PrivateKey, PublicKey, ShortID, or SNI** (zero client-side changes required).

3. **Empirically Verified Cross-Pacific Kernel & Protocol Tuning (Config 3)**:
   - **`fq + bbr` + `32MB` Socket Buffers + `net.ipv4.tcp_mem = 65536 98304 131072`**:
     - Critical on 1 GB RAM `e2-micro` VMs: Linux defaults `net.ipv4.tcp_mem` to `41MB / 55MB / 82MB` (`10575 14103 21150` pages). Raising per-socket `tcp_rmem`/`tcp_wmem` max to `32MB` without raising `tcp_mem` causes 4-stream parallel downloads to hit `TcpExtTCPMemoryPressures` (`-33.5%` regression). Raising `tcp_mem` to `256MB / 384MB / 512MB` yields **`+39.0%` single-stream speed** (`15.05 MB/s` / `120.4 Mbps`) and **`387.5 Mbps` 4-stream throughput** across the Pacific with `0` memory pressure events.
   - **Zero Idle Slow-Start Reset (`net.ipv4.tcp_slow_start_after_idle = 0`)**:
     - Prevents BBR `cwnd` from resetting to slow-start after brief reading pauses (`-33.2%` post-idle TTFB).
   - **Expanded Initial Congestion & Receive Window (`initcwnd 32 initrwnd 32`)**:
     - Expands initial TCP window from `10 MSS` (`~14KB`) to `32 MSS` (`~45KB`), allowing TLS certificates and initial HTML payloads to complete in a single trans-Pacific RTT (`~100–117ms` faster first-screen page load).
   - **Pure OS IPv4 Resolution (`freedom` `"domainStrategy": "UseIPv4"` + `/etc/gai.conf`)**:
     - Calls GCP local metadata DNS (`169.254.169.254:53`) via OS `getaddrinfo(AF_INET)` in `~0.4ms`, skipping redundant `AAAA` queries.
     - **Important Gotcha**: Never combine Xray internal `"dns": {"servers": ["169.254.169.254"]}` with a `"routing"` rule blocking `geoip:private`, because `169.254.169.254` is RFC 3927 link-local (`169.254.0.0/16`) inside `geoip:private` and will blackhole Xray's own DNS packets for `4,000ms` per lookup.

---

## Standard Workflows

### Workflow 1: Deploy a New GCP Xray Node
Run [install.sh](./install.sh) in non-interactive mode (from the skill directory or directly via GitHub raw URL):

```bash
curl -fsSL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/install.sh | bash -s -- \
  --project <GCP_PROJECT_ID> \
  --region <US|TW|SG|HK|JP> \
  --sni www.amd.com
```

### Workflow 2: Upgrade an Existing GCP Xray Node (Zero Client Disruption)
1. Inspect existing instances in the user's GCP project:
   ```bash
   gcloud compute instances list --project=<GCP_PROJECT_ID>
   ```
2. Run [scripts/upgrade_node.sh](./scripts/upgrade_node.sh) against the target instance:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/scripts/upgrade_node.sh | bash -s -- \
     --project <GCP_PROJECT_ID> \
     --zone <ZONE> \
     --instance <INSTANCE_NAME>
   ```
3. Also update the GCE instance's `startup-script` metadata (using the startup script body from `install.sh` with the instance's `SNI` and `PREFIX`) so future GCE hardware maintenance reboots preserve `/usr/local/etc/xray/node_info.env`.

### Workflow 3: Output Client Link & Router Configuration
When delivering a node configuration to the user, always provide:
1. **Standalone `vless://` URI** (for one-click import into Shadowrocket, v2rayNG, v2rayN, NekoBox).
2. **Decomposed Router Parameters** (for OpenWrt PassWall, SSR Plus, OpenClash, ShellCrash manual forms):
   - **Protocol**: `VLESS`
   - **Address (IP)**: `<EXTERNAL_IP>`
   - **Port**: `443`
   - **UUID**: `<UUID>`
   - **Flow**: `xtls-rprx-vision`
   - **Encryption**: `none`
   - **Transport (Network)**: `tcp` (`headerType: none`)
   - **TLS / Security**: `reality`
   - **SNI (ServerName)**: `<SNI>` (`www.amd.com` or existing SNI)
   - **Fingerprint (uTLS)**: `chrome`
   - **PublicKey (`pbk`)**: `<PUB_KEY>`
   - **ShortID (`sid`)**: `<SHORT_ID>`
