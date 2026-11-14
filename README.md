# EasyGate installer

Public installer for **EasyGate gateways** (Ubuntu Server 26.04 LTS, single network interface).
The script connects the gateway to the EasyGate server over an outbound WireGuard VPN.
It contains no secrets: the gateway's VPN key is generated on the gateway and never leaves it.

## Install a gateway

Always download a **tagged version** and check its SHA-256 against the value you received
from EasyTech before running it.

```bash
VER=v0.4.6
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
| `--restart-after <s>` | Restart the tunnel after this many seconds without reply from the server (90–3600, `0` = never); from v0.2.5 | `180` |
| `--tcp-port <n>` | TCP 443 fallback for sites that block UDP: the server's public TCP port (`0` = off on this gateway); from v0.4.0 | `443` |
| `--retry-every <s>` | While the server is lost: try UDP, then TCP 443, this often for the first `--retry-count` tries (120–3600); from v0.4.5 | `600` |
| `--retry-then <s>` | … then this often for `--retry-count` more tries (120–7200); from v0.4.5 | `1200` |
| `--retry-last <s>` | … then this often until the server answers (300–86400); from v0.4.5 | `3600` |
| `--retry-count <n>` | Tries at each of the first two intervals (1–50); from v0.4.5 | `5` |
| `--udp-check <s>` | On the TCP fallback: check whether UDP works again this often, doubling up to 4 h while UDP keeps failing (300–14400); from v0.4.5 | `1800` |

## TCP 443 fallback and lost connection (from v0.4.0, timers from v0.4.5)

If outbound UDP is blocked at the site, the gateway carries the same WireGuard tunnel inside a TLS connection to the
server (`--server`, port `--tcp-port`), which firewalls treat as normal HTTPS. WireGuard still encrypts and
authenticates everything. UDP is always the first choice. The tunnel watchdog decides by itself:

- **Tunnel started** (Restart tunnel in the portal, update, reboot): it checks UDP at once (a new handshake and an answer
  from the server, about 15 seconds) and switches to TCP 443 right away if UDP fails.
- **Connection lost** (no reply for `--restart-after` seconds, default 180, on UDP or TCP): it restarts the tunnel and
  tries UDP first, then TCP 443. If both fail it tries again every `--retry-every` seconds (default 10 min) for
  `--retry-count` tries (default 5), then every `--retry-then` seconds (default 20 min) for 5 more, then every
  `--retry-last` seconds (default 1 hour) until the server answers. Any reply in between ends the wait and the count.
- **On TCP 443:** every `--udp-check` seconds (default 1800, doubling up to 4 h while UDP keeps failing) it checks UDP
  (about 15 seconds without tunnel if UDP still fails) and goes back to UDP when it works.

The fallback is switched on or off for all customers on the EasyGate server (System → Settings), and is accepted only
from each customer's site IPs. The timers are set in the same place and reach the gateway with Update installer.
Logs: `journalctl -t easygate-watchdog` and `journalctl -u easygate-tcp`.

At the end the script prints an **enrollment code** (`EG1.…`). Paste it into the EasyGate
portal: it carries the gateway public key, the site public IP, the LAN and the gateway's SSH
host key (which the portal pins, so it only ever talks to this gateway). The code contains no
secrets. A checksum at the end rejects a mistyped or incomplete code.

## File services (from v0.3.0)

The gateway can serve files to the network devices at its site, for firmware updates and
config backups: **TFTP** (port 69), **HTTP** (port set in the portal, default 80, with a file
list) and **SFTP / SCP** (port 22, user `files`). Everything is **off** until an admin starts it
in the EasyGate portal (File services), which copies the chosen firmware files to the gateway,
opens the ports on the LAN only and sets a new password for `files`. The servers stop by
themselves after the chosen time, at Stop, or when the gateway reboots: ports closed, account
locked. Files stay on the gateway until they are deleted in the portal (from v0.3.2).

- Devices download from the top folder: `tftp://<gateway>/<file>`, `http://<gateway>/<file>`,
  `scp://files@<gateway>/<file>`.
- Devices upload into `received/` (TFTP, SCP, SFTP), e.g.
  `copy running-config tftp://<gateway>/received/router1-confg`. Uploaded files cannot be read
  back over TFTP or HTTP; the portal downloads them.
- `files` is locked into `/srv/easygate-sftp` (only `sh`, `scp` and `sftp-server` inside), cannot
  forward ports or open a terminal, and may write only into `received/`.
- The portal runs `/usr/local/sbin/easygate-files start|stop|status|list|put|get|delete` over the
  tunnel. Installs the `tftpd-hpa` package (disabled at boot).

## Remove a gateway (or start over)

`easygate-gateway-remove.sh` undoes the installer: it deletes the tunnel and its keys
(`/etc/wireguard`), the EasyGate firewall/NAT rules (the earlier firewall is restored),
IP forwarding, the EasyGate SSH rules, the file services (`files` account, `/srv/easygate-files`),
the `easyadmin` account and the WireGuard and TFTP packages.
The hostname, network settings and other users are not touched.

Run it on the gateway console or over SSH from the LAN (not over the tunnel), logged in
with the site's own admin account:

```bash
VER=v0.4.6
curl -fsSLO "https://raw.githubusercontent.com/dinos1979/easygate-installer/${VER}/easygate-gateway-remove.sh"
sha256sum easygate-gateway-remove.sh       # must match the published hash for ${VER}
sudo bash easygate-gateway-remove.sh       # asks you to type REMOVE
```

Options: `--yes` (no confirmation), `--keep-user` (keep the `easyadmin` account),
`--keep-packages` (keep `wireguard-tools` and `tftpd-hpa`).

To **start over**, run the installer again afterwards. It creates a new gateway key, so paste
the new enrollment code into the portal.

## Versions

The installer version is the same as the EasyGate server version: the portal flags a gateway
whose installer differs from the server.

| Version | SHA-256 |
|---|---|
| v0.4.6 | `easygate-gateway-setup.sh` `e4e34ac791b41152653d0eca90e3ddf38210f94c95d7c0490fefb1538dced1c3` — fix: the UDP check on the TCP fallback no longer cuts the tunnel (v0.4.5 reloaded the session with `wg syncconf`, which removed the tunnel's private key because wg0.conf does not hold it: the tunnel then sent nothing for about 3 minutes, until the watchdog restarted it, at every UDP check)<br>`easygate-gateway-remove.sh` `757db0927bb38e7762c87f8948120f21b8a03c0797234a937983718f63b01f23` — version number only |
| v0.4.5 | `easygate-gateway-setup.sh` `bfc40c9bf5ae16d984e1f88b0bf4836043583aedb06b3de39e7c21ef86f6edf7` — lost connection: the gateway tries UDP (restarted tunnel), then TCP 443, and repeats every 10 min (5 tries), then every 20 min (5 tries), then every hour; new options `--retry-every`, `--retry-then`, `--retry-last`, `--retry-count` and `--udp-check` (UDP check interval on TCP, default 1800); set in the portal (System → Settings)<br>`easygate-gateway-remove.sh` `2180166d3d80c09f1c2738b73e091cd22c6bd196a76dfcf7f4ad79fc4115c1e6` — version number only |
| v0.4.4 | `easygate-gateway-setup.sh` `bfe9446a5782873381fcf45a0333e0efc9366a42ff1cef736aad0307f3cc4723` — after every tunnel start (Restart tunnel in the portal, update, reboot) the gateway checks UDP at once (new handshake + server answer, about 15 s) and switches to the TCP fallback right away if UDP fails, instead of after 2½ minutes without reply<br>`easygate-gateway-remove.sh` `f507ac78248a03c22aeb16e6d96b9b8e1898bf0db4da6f1cb5e6386486d3acac` — version number only |
| v0.4.3 | `easygate-gateway-setup.sh` `bc163f05adbbd335bb3285c2fb8c03744e3dd0768427967c029cc7eb20e386c5` — fix: a stray server packet over UDP no longer stops the TCP fallback (WireGuard moved the tunnel to it and the watchdog took that for a restart: about 3 minutes without tunnel); the tunnel is pointed back to TCP and the event is logged<br>`easygate-gateway-remove.sh` `9d003bb536ff5b3ce3353881470a7381d4f1d506b26611271397b5ff76160fb0` — version number only |
| v0.4.2 | `easygate-gateway-setup.sh` `c2c219b294c121162444700aa5d63a261b25cbc32cfe3d28d6e7727ec09887d8` — fix: the UDP check now needs a new WireGuard handshake over UDP (some firewalls pass WireGuard data but drop the server's handshake reply: v0.4.1 then went back to UDP and lost the tunnel for about 3 minutes at every check)<br>`easygate-gateway-remove.sh` `ee0afd878807347bd806ec9c67ab31762a27d5528aa4f6ef40862d36d197eabc` — version number only |
| v0.4.1 | `easygate-gateway-setup.sh` `46dc6453886a4b8b6f20e734360deb18b6bae4eb4520dd44fea4bca2dc370ce8` — fix: the gateway now really goes back to UDP when it works again (the v0.4.0 check never sent anything over UDP); checks get rarer while UDP keeps failing; when the server does not answer over TCP the gateway stays on UDP instead of switching back and forth<br>`easygate-gateway-remove.sh` `e49128e217661709f3ca12c11ef8a6c2851f9b4c34de64c8be5fdf4e65455830` — version number only |
| v0.4.0 | `easygate-gateway-setup.sh` `3a25241f0d4071b107b5638e11713547ba3f83396fb2797e56dceeef977b52e4` — TCP 443 fallback for sites that block UDP (`--tcp-port`, `easygate-tcp`, watchdog switches automatically)<br>`easygate-gateway-remove.sh` `55873f18867f4fc878a3644da9041619f0a8b495675dcb9101348fa87a1a3045` — also removes the TCP fallback client |
| v0.3.2 | `easygate-gateway-setup.sh` `7b540791613405cc6f18968f1bba5c793b918c84a4c6c90b3587506b1ee23349` — files stay on the gateway when the servers stop (Stop, auto-stop, reboot): they are deleted only from the portal<br>`easygate-gateway-remove.sh` `bfb65d0a38e1c54c30f25b4117619acd0fe68cf6510ff91a54e7b02cfbdfe0fb` — version number only |
| v0.3.1 | `easygate-gateway-setup.sh` `e9832b69e62254f926319eb9dd08fd55bc2a6f714964e72ecebe072233c04f10` — file services for network devices: TFTP, HTTP and SFTP / SCP on the gateway, off until started in the portal (see above); same version number as the EasyGate server<br>`easygate-gateway-remove.sh` `bd4764af0655319bae6f6b8d070d007c5f0b340e14745106d033734aaa033382` — also removes the file services and their files |
| v0.3.0 | not to be used: its SHA256SUMS still lists the v0.2.5 hashes, and TFTP uploads and SCP did not work. Use v0.3.1 |
| v0.2.5 | `easygate-gateway-setup.sh` `00b0531ca5ea5d0950cfdf7a48215b09f0648236fffc539d5f38c18b5050ae51` — tunnel watchdog: when the server has not answered for `--restart-after` seconds (default 180, 0 = never) the tunnel restarts on a new UDP port, so firewalls build fresh sessions; waits double up to 30 min; restarts are counted for the portal. Replaces the re-resolve timer<br>`easygate-gateway-remove.sh` `4270fe46ac6b6fb10b6852b32560be2825e29e20200fbd354887c98eddd908d1` — also removes the watchdog and its counter |
| v0.2.4 | `easygate-gateway-setup.sh` `82b498bee86123b685e6f52195c1e0dd2a0467e81324cc7762dc94569afaa44d` — the gateway takes its time from the EasyGate server over the VPN (chrony source `100.96.N.1`, preferred; Ubuntu's time servers stay as fallback)<br>`easygate-gateway-remove.sh` `331b629b988aafa9c43572e977a0e0fad09b5f8d0fb0d38a1a60222cbf96a09d` — also removes that time source |
| v0.2.3 | `easygate-gateway-setup.sh` `aa0feb4a0c611e88e7297beb971d662aa9fcc6be4bc3ac86f3c0d5f09c40e3a1`<br>`easygate-gateway-remove.sh` `6d1549cdd466f0ee08b9c5e165ff01323b765df525dbc12eb47c354230da6371` — fix: no file is written with `install /dev/stdin` any more (fails with the Rust coreutils on current Ubuntu 26.04: "install: No such file or directory"). v0.2.0–v0.2.2 are affected; use v0.2.3 |
| v0.2.2 | `easygate-gateway-setup.sh` `31e579be32dab779c00b6c9062c151afab20102f3c759cacb0e5efef5ecd78db` — fix: v0.2.0/v0.2.1 stopped with "install: No such file or directory" on some Ubuntu 26.04 systems before printing the enrollment code<br>`easygate-gateway-remove.sh` unchanged (`b5abc4e3…cab1`) |
| v0.2.1 | `easygate-gateway-setup.sh` `5ab3de339e790f9d0bf8b74d4b8d977be96859dbe235398218863fae3a956601` — tunnel is a point-to-point `/30` (100.96.N.0/30: server .1, gateway .2) instead of `/24`<br>`easygate-gateway-remove.sh` unchanged from v0.2.0 (`b5abc4e3…cab1`) |
| v0.2.0 | `easygate-gateway-setup.sh` `dd565a8050470d67de1f2deffaabb53e1c752b6ec4631a50ab8234f6eff0f35a` — enrollment code, `--admin-key` (no management key built in), SSH host key in the code<br>`easygate-gateway-remove.sh` `b5abc4e3ef8d90d4cd6be2ec9dd699ff3406a8a908d1511cee02a449bf69cab1` — also removes `/etc/easygate-gateway.version` |
| v0.1.2 | `easygate-gateway-setup.sh` unchanged from v0.1.1 (`463ed4fd…f830`)<br>`easygate-gateway-remove.sh` `4cd6a2cbd6c959d9111c630ae2fb0a40b43cc7d2662e139b918f638442060e57` — new: removes the gateway configuration |
| v0.1.1 | `463ed4fd28086512cc3402df2cf7872c5ddec71c77fa7f27a0fa497eb6a1f830` — default server `easygate.easytech.com.cy`, boot retry, DNS re-resolve |
| v0.1.0 | `bf23080d8cd9d55c7451c9498ede680bf65e7359992da6fe7c569c8810b652a7` — initial (superseded) |

Always confirm the hash with EasyTech through a separate channel; a hash published only
in this repository protects against corrupted downloads, not against a compromised repository.
