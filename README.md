# EasyGate installer

Public installer for **EasyGate gateways** (Ubuntu Server 26.04 LTS, single network interface).
The script connects the gateway to the EasyGate server over an outbound WireGuard VPN.
It contains no secrets: the gateway's VPN key is generated on the gateway and never leaves it.

## Install a gateway

Always download a **tagged version** and check its SHA-256 against the value you received
from EasyTech before running it.

```bash
VER=v0.1.1
curl -fsSLO "https://raw.githubusercontent.com/dinos1979/easygate-installer/${VER}/easygate-gateway-setup.sh"
sha256sum easygate-gateway-setup.sh        # must match the published hash for ${VER}
sudo bash easygate-gateway-setup.sh \
  --server-pubkey <server public key for this customer> \
  --tenant <customer number> \
  --hostname easygate-gw-<customer>
```

Options:

| Option | Meaning | Default |
|---|---|---|
| `--server` | EasyGate server DNS name or public IP | `easygate.easytech.com.cy` |
| `--server-pubkey` | Server WireGuard public key for this customer | required |
| `--tenant` | Customer number (1–254) | `1` |
| `--port` | Server UDP port | `51000 + tenant` |
| `--approved "a/b c/d"` | Customer subnets the server may reach | the gateway's LAN subnet |
| `--mgmt-from "a/b"` | Extra subnets allowed to manage the gateway locally | — |
| `--hostname` | Set the gateway hostname | unchanged |
| `--no-mgmt-ssh` | Disable management SSH over the VPN | enabled |

At the end the script prints the **gateway public key** and the **site public IP**;
send both to EasyTech so the server can accept the connection.

## Versions

| Version | SHA-256 of `easygate-gateway-setup.sh` |
|---|---|
| v0.1.1 | `463ed4fd28086512cc3402df2cf7872c5ddec71c77fa7f27a0fa497eb6a1f830` — default server `easygate.easytech.com.cy`, boot retry, DNS re-resolve |
| v0.1.0 | `bf23080d8cd9d55c7451c9498ede680bf65e7359992da6fe7c569c8810b652a7` — initial (superseded) |

Always confirm the hash with EasyTech through a separate channel; a hash published only
in this repository protects against corrupted downloads, not against a compromised repository.
