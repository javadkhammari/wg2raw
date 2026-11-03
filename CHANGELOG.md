# Changelog

## 2.0.0

First public release.

- Menu-driven installer and manager for WireGuard over udp2raw (faketcp).
- One-line `wg2raw:` connection code: the server generates the client's keys, so nothing is copied back and forth.
- Automatic udp2raw install for the CPU architecture, with a local-file fallback.
- Status screen with services, last handshake, traffic, peer ping and udp2raw "huge packet" warnings.
- Settings menu for MTU, keepalive, `--fix-gro`, NIC offloads and NAT; all configs are regenerated from saved settings.
- MSS clamping and an iptables rule that stops kernel RSTs for the fake TCP traffic.
- Clean uninstall that removes services, configs and iptables rules.
