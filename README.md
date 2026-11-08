# EasyGate installer

Public installer for **EasyGate gateways** (Ubuntu Server 26.04 LTS, single network interface).
The script connects the gateway to the EasyGate server over an outbound WireGuard VPN.
It contains no secrets: the gateway's VPN key is generated on the gateway and never leaves it.

## Install a gateway

Always download a **tagged version** and check its SHA-256 against the value you received
from EasyTech before running it.

```bash
VER=v0.2.2
curl -fsSLO "https://raw.githubusercontent.com/dinos1979/easygate-installer/${VER}/easygate-gateway-setup.sh"
sha256sum easygate-gateway-setup.sh        # must match the published hash for ${VER}
sudo bash easygate-gateway-setup.sh \
  --server-pubkey <server public key for this customer> \
  --tenant <customer number> \
  --admin-key "<EasyGate portal SSH public key>" \
  --hostname easygate-gw-<customer>
```

The EasyGate portal shows this command with every value filled in: copy it from the customer's
Setup instructions.

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
| `--admin-key "ssh-ed25519 …"` | Public key allowed to manage the gateway over the VPN (the EasyGate portal's key); repeatable | required unless `--no-mgmt-ssh` |
| `--no-mgmt-ssh` | Disable management SSH over the VPN | enabled |

At the end the script prints an **enrollment code** (`EG1.…`). Paste it into the EasyGate
portal: it carries the gateway public key, the site public IP, the LAN and the gateway's SSH
host key (which the portal pins, so it only ever talks to this gateway). The code contains no
secrets. A checksum at the end rejects a mistyped or incomplete code.

## Remove a gateway (or start over)

`easygate-gateway-remove.sh` undoes the installer: it deletes the tunnel and its keys
(`/etc/wireguard`), the EasyGate firewall/NAT rules (the earlier firewall is restored),
IP forwarding, the EasyGate SSH rules, the `easyadmin` account and the WireGuard package.
The hostname, network settings and other users are not touched.

Run it on the gateway console or over SSH from the LAN (not over the tunnel), logged in
with the site's own admin account:

```bash
VER=v0.2.0
curl -fsSLO "https://raw.githubusercontent.com/dinos1979/easygate-installer/${VER}/easygate-gateway-remove.sh"
sha256sum easygate-gateway-remove.sh       # must match the published hash for ${VER}
sudo bash easygate-gateway-remove.sh       # asks you to type REMOVE
```

Options: `--yes` (no confirmation), `--keep-user` (keep the `easyadmin` account),
`--keep-packages` (keep `wireguard-tools`).

To **start over**, run the installer again afterwards. It creates a new gateway key, so paste
the new enrollment code into the portal.

## Versions

| Version | SHA-256 |
|---|---|
| v0.2.2 | `easygate-gateway-setup.sh` `31e579be32dab779c00b6c9062c151afab20102f3c759cacb0e5efef5ecd78db` — fix: v0.2.0/v0.2.1 stopped with "install: No such file or directory" on some Ubuntu 26.04 systems before printing the enrollment code<br>`easygate-gateway-remove.sh` unchanged (`b5abc4e3…cab1`) |
| v0.2.1 | `easygate-gateway-setup.sh` `5ab3de339e790f9d0bf8b74d4b8d977be96859dbe235398218863fae3a956601` — tunnel is a point-to-point `/30` (100.96.N.0/30: server .1, gateway .2) instead of `/24`<br>`easygate-gateway-remove.sh` unchanged from v0.2.0 (`b5abc4e3…cab1`) |
| v0.2.0 | `easygate-gateway-setup.sh` `dd565a8050470d67de1f2deffaabb53e1c752b6ec4631a50ab8234f6eff0f35a` — enrollment code, `--admin-key` (no management key built in), SSH host key in the code<br>`easygate-gateway-remove.sh` `b5abc4e3ef8d90d4cd6be2ec9dd699ff3406a8a908d1511cee02a449bf69cab1` — also removes `/etc/easygate-gateway.version` |
| v0.1.2 | `easygate-gateway-setup.sh` unchanged from v0.1.1 (`463ed4fd…f830`)<br>`easygate-gateway-remove.sh` `4cd6a2cbd6c959d9111c630ae2fb0a40b43cc7d2662e139b918f638442060e57` — new: removes the gateway configuration |
| v0.1.1 | `463ed4fd28086512cc3402df2cf7872c5ddec71c77fa7f27a0fa497eb6a1f830` — default server `easygate.easytech.com.cy`, boot retry, DNS re-resolve |
| v0.1.0 | `bf23080d8cd9d55c7451c9498ede680bf65e7359992da6fe7c569c8810b652a7` — initial (superseded) |

Always confirm the hash with EasyTech through a separate channel; a hash published only
in this repository protects against corrupted downloads, not against a compromised repository.
