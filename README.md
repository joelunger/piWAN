# PiWAN

**PiWAN** is a terminal-based User Interface (TUI) for quickly converting a Raspberry Pi into various network modes. It allows for effortless switching between configurations like Access Point, WISP, or LAN Receiver, right from the terminal—no tedious manual editing of network config files required.

The controls are classic and dependable, using `whiptail` in a clean, organized menu structure. Under the hood, `NetworkManager` (`nmcli`) ensures that connection switching is seamless and robust.

---

## Operational Modes

PiWAN offers pre-configured profiles for the following scenarios:

| Mode | Description | Hardware Flow |
| :--- | :--- | :--- |
| **Access Point (AP)** | Classic Router | Ethernet (Internet) -> Pi -> WiFi (Broadcast) |
| **WISP** | WiFi Receiver & Sender | WiFi (Receive) -> Pi (NAT) -> WiFi (Broadcast) |
| **LAN Receiver** | WiFi to LAN Adapter | WiFi (Receive) -> Pi -> Ethernet (Out) |

---

## System Requirements

PiWAN is designed for Debian-based Raspberry Pi operating systems (Raspberry Pi OS, Ubuntu). The following packages are required (these are automatically checked and installed by the setup script):

* `whiptail` (For the terminal-based UI menu)
* `network-manager` (For network management via `nmcli`)
* `dnsmasq` (For DHCP/DNS logic in AP mode)
* `iptables` / `nftables` (For routing, masquerading, and NAT)
* `vnstat` (For persistent traffic monitoring and total data usage statistics)

---

## Installation

Clone the repository to your Raspberry Pi and run the installation script as Root:

```bash
# 1. Clone repository
git clone https://github.com/joelunger/piWAN.git
cd piWAN

# 2. Make scripts executable
chmod +x install.sh piwan.sh

# 3. Install PiWAN & check dependencies (Must be run as Root)
sudo ./install.sh
```

---

## Usage

Simply start PiWAN as Root (or via sudo) to open the dashboard:

```bash
sudo ./piwan.sh
```

### Navigating the Menu
* **Arrow Keys / Tab:** Navigate through the menu items.
* **Enter:** Confirm selection.
* **Esc:** Leave the menu or cancel.

---

## Technical Architecture

To achieve maximum flexibility, PiWAN utilizes the following background services:
* **Network Stack:** `NetworkManager` (`nmcli`). This is crucial because `nmcli` handles the transition between Client and Hotspot modes much more cleanly than manually editing `/etc/network/interfaces`.
* **Routing & NAT:** Automated setup using NetworkManager's `ipv4.method shared`, seamlessly establishing `dnsmasq` DHPC bridging.
* **Live Traffic Monitor:** An ASCII-rendered UI overlay wrapping `/proc/net/dev` parsing, `dnsmasq.leases`, and `vnstat` for flawless observability without flickering.
* **Snapshots:** PiWAN uses a simple file-system-based backup approach located at `/etc/piwan/snapshots/` to capture and restore known working connections.

---



## Version History (Changelog)

- **v1.5.0**:
  - Major Feature: Added `piwan-monitor` module! A stunning, non-flickering `tput`-based Live Traffic Monitor.
  - Exposes realtime IN/OUT kbit/s utilizing `/proc/net/dev`.
  - Automatically parses DHCP records to enumerate connected Hostnames, IPs, and MAC addresses.
  - Taps into `vnstat` for total traffic volume aggregation.
- **v1.0.4**:
  - UX Enhancement: Re-engineered the menu topology to introduce a dedicated `Repeater Wizard`.
  - Added deterministic routing prompts inside the wizard, forcing users to explicitly select between `LAN to WLAN` (Access Point) and `WLAN to WLAN` (WISP) topologies for absolute clarity.
- **v1.0.3**:
  - Resolved `whiptail` syntax crashes caused by specific hyphen (`--`) prefixes in list item texts.
  - Implemented hyper-resilient `read -p` pure-text UI fallback gracefully mitigating SSH terminal-rendering failures.
  - Revamped Dashboard: Consolidated all network deployment options into a single, clean "Configure Router Modes" sub-menu.
  - Enhanced mode clarity by explicitly exposing hardware network packet flow (e.g. `ETH -> Broadcast WLAN`, `Receive WLAN -> Output ETH`).
- **v1.0.2**:
  - Re-designed dashboard UI for a cleaner and more professional layout.
  - Implemented Phase 3: WISP setup (client connection + virtual AP) and LAN Receiver logic.
  - Implemented Phase 4: Snapshot Manager providing Backup, List, and Restore using `tar`.
  - Implemented Phase 5: Dashboard Refresh feature ('R') and Autostart instructions.
  - Translated the entire project (README, codebase, parameters) completely to English.
- **v1.0.1**:
  - Implemented Phase 2: Authentic `nmcli` background logic to generate the Hotspot. Included `ipv4.method shared` to automatically cover NAT and DHCP logic.
  - Interfaced polling metrics (`grep`, `iw`, `nmcli`) into the TUI.
- **v1.0.0**: 
  - Initial project scaffold created.
  - Implemented Phase 1: Dependency checker (`install.sh`) and core layout for `whiptail` menu.

---
*PiWAN – The elegant way to route your Pi.*
