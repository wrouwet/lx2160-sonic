# SONiC on the LX2160ARDB: bring-up notes

How the `nxp-lx2160` SONiC image (`sonic-nxp-lx2160-arm64.bin`) is built,
installed, booted and tested, and what went wrong the first time.

The LX2160A is the switch's control-plane CPU. The switch ASIC is emulated by
SAI-VS (SONiC's virtual switch SAI), which binds each emulated front-panel
port to a real DPAA2 interface. That way real traffic on the board's copper
ports goes through SONiC's full control path (orchagent → syncd → SAI). The
SAI-VS dataplane runs in software, so its performance is not representative.
A real Marvell or Broadcom ASIC with its vendor SAI replaces SAI-VS later.

## Pieces

| Piece | Where |
|---|---|
| Platform `nxp-lx2160` (rules, syncd-vs docker without DASH, one-image, FIT) | `patches/sonic-buildimage/0002`, `0003`, `0004` |
| Device `arm64-nxp_lx2160ardb-r0`, HWSKU `NXP-LX2160ARDB-VS` | `patches/sonic-buildimage/0002` |
| syncd: `asic_type nxp-lx2160` uses the SAI-VS setup | `patches/sonic-buildimage/src/sonic-sairedis/0001` |
| Interface names (udev rule + boot service) | `sonic-platform-nxp-lx2160ardb` package, `0002` + `0004` |
| Platform API (`sonic_platform`: EEPROM, thermals, watchdog), `platform.json`/`hwsku.json`, system-health config | `0006` |
| U-Boot A/B installer (`platform_arm64.conf`) | `0006` |
| DPAA2 layout (5 DPNIs) | `scripts/mk-dpl.py`, in NOR at 0xd00000 |
| First install without ONIE | `scripts/sonic-lx2160-install.sh` |

Ports:

| SONiC | Lanes | SAI-VS netdev | DPAA2 | Board port |
|---|---|---|---|---|
| Ethernet0 | 1 | dpmac17 | dpni.0 | DPMAC17 (1G RGMII), test host A |
| Ethernet4 | 5 | dpmac18 | dpni.2 | DPMAC18 (1G RGMII), test host B |
| Ethernet8 | 9 | dpmac3 | dpni.3 | DPMAC3 (10GBASE-T) |
| Ethernet12 | 13 | dpmac4 | dpni.4 | DPMAC4 (10GBASE-T) |
| eth0 (mgmt) | — | — | dpni.1 | DPMAC2 (placeholder) |

## Build

On the board (Debian, native arm64, about 7 h from scratch):

    cd /srv/build/work && setsid nohup env W=/srv/build/work PLATFORM=nxp-lx2160 \
        ./sonic-build.sh > logs/sonic-build-runner.log 2>&1 < /dev/null &

`make` only notices changed inputs that are listed as dependencies. After you
change a platform file or a patch, move the affected outputs out of
`target/` so they get rebuilt. Moving `debs/trixie/libsairedis_1.0.0_arm64.deb`
rebuilds sairedis together with its syncd-vs packages.

## Install and boot

The U-Boot environment has to be saved once first. Stop autoboot, then run
`saveenv` at the prompt (not after `env default -a`: that drops the
`bootcmd`/`mcinitcmd` that NXP's board code sets for XSPI boot). Then, on
the board under Debian:

    sudo apt install libubootenv-tool        # fw_printenv / fw_setenv
    sudo ./sonic-lx2160-install.sh --uboot-env=once target/sonic-nxp-lx2160-arm64.bin /srv/build

This unpacks the image into `/srv/build/image-<version>/` and puts it in
U-Boot slot 1, using the image's own installer hooks (`platform.conf`).
The previous slot-1 image moves to slot 2. `once` boots it on the next
reboot only; afterwards the board returns to `boot_next`, which is Debian
(`debian_boot`, NXP's original boot command). `--uboot-env=default` makes
SONiC the default instead. From a running SONiC, `sonic-installer`
manages the same two slots.

U-Boot prints a menu at each boot:

    1: SONiC-OS-<version> (run sonic_image_1)
    2: SONiC-OS-<older version> (run sonic_image_2)
    3: run debian_boot

Each `sonic_image_N` applies the DPL from NOR (`lx2160_dpl`), sets the
bootargs, loads the FIT from the SSD and runs `bootm`. NXP's default
environment already fills about 7.9 of the 8 KiB `CONFIG_ENV_SIZE`, so the
layout is kept compact. A bigger environment comes with the ONIE U-Boot.

Without `--uboot-env`, the script prints commands to boot the image by
hand from the U-Boot prompt instead.

## ONIE and the eMMC install (current flow)

The board now boots like a switch: TF-A, then U-Boot, then ONIE or the
installed SONiC. Debian is only used as a build host.

- **NOR chip 0:** firmware, then U-Boot's environment at 0x500000 (64 KiB),
  ONIE at 0x1000000 (`onie` partition, 0xfe0000), and the ONIE TlvInfo
  system EEPROM at 0x1fe0000 (`hw-info`). The full chip was backed up before
  the first ONIE write (`firmware/nor-backup/`, not in git).
- **U-Boot:** NXP's, built with `lx2160ardb_tfa_onie_defconfig`
  (`patches/u-boot/0001`):

      UBOOT_DEFCONFIG=lx2160ardb_tfa_onie_defconfig scripts/build-all.sh uboot atf

  Its default environment runs ONIE's `bootcmd` (`check_boot_reason`,
  `nos_bootcmd`, `onie_bootcmd`). It also saves that environment once when
  `onie_env_saved` is missing (first boot, or after an ONIE uninstall), so
  `fw_setenv` works from ONIE and from SONiC. `run debian_boot` at the
  U-Boot prompt still boots Debian from the SD card.
- **ONIE:** machine `nxp_lx2160ardb` (`patches/onie/0001`, against
  opencomputeproject/onie): kernel 6.12.41, DPAA2 networking, and U-Boot
  from the NXP BSP (`UBOOT_EXTERNAL=yes`). It's built in ONIE's Debian 9
  build env plus python3, on x86 or natively on the board.
- **Installing SONiC:** from ONIE (installer mode, the default when no OS is
  installed), run:

      onie-nos-install http://<server>/sonic-nxp-lx2160-arm64.bin

  The installer (`platform_arm64.conf`, patch 0006) wipes the eMMC and
  creates one SONiC-OS GPT partition. It installs the image and sets
  `nos_bootcmd` to the two-slot menu: 1 and 2 are the SONiC images, 3 is
  ONIE rescue. ONIE's `bootcmd` stays in place.

Tested 2026-11-22 (`logs/onie-sonic-install-2-emmc.log`): SONiC booted from
`mmcblk1p1` with no failed units and system-health OK. Gateway ping, VLAN
transit, iperf3 (288 Mbit/s) and BGP with test host A all passed. ONIE sees
all five DPAA2 ports, both USB 3 controllers, the SD card, the eMMC and the
SATA SSD.

## First boot: what failed and the fixes

1. **"fsl-mc: ERROR: Bad DPL image (bad header)" at `bootm`.** The FIT
   kernel loaded at 0x80200000 and is about 40 MB, so it overwrote the DPL
   that U-Boot had staged at 0x80d00000. U-Boot only applies the DPL after
   loading the images. Fix (`0004`): the kernel now loads at 0x82000000. The
   installer also stages the DPL at 0xb0000000, which works for images built
   before the fix.
2. **syncd exited immediately (status 1).** `syncd_init_common.sh` selects its
   SAI setup by `asic_type`. It didn't know `nxp-lx2160`, so syncd started
   without the SAI-VS profile. Fix: sairedis patch `0001` maps it to
   `config_syncd_vs`, the same way as `nokia-vs`.
3. **orchagent aborted (`std::invalid_argument`).** The `DEVICE_METADATA`
   mac was `None`, because there was no eth0 to take it from. dpni.1 should
   become eth0, but the kernel probes DPNIs in reverse order, so dpni.4 still
   held eth0 when dpni.1's udev rename ran. On the first boot the udev rule
   isn't installed yet anyway. Fix (`0004`): a boot service renames the
   front-panel DPNIs first, then dpni.1 to eth0.
4. Harmless: `systemd-sonic-generator: Failed to open .../platform.json`.
   The platform has no `platform.json` yet.

## Test results (2026-11-22)

From test host A (`scripts/test-host-setup.sh`: namespaces ns-v10 and ns-v20 on VLAN
subinterfaces of its wired port, cabled to DPMAC17). SONiC has Vlan10
(192.168.10.1/24) and Vlan20 (192.168.20.1/24), with Ethernet0 tagged in both.

| Test | Result |
|---|---|
| syncd (SAI-VS) + swss | running, stable |
| Ethernet0/4/8/12 | created, bound to dpmac17/18/3/4; Ethernet0 oper up |
| ns-v10 → 192.168.10.1, ns-v20 → 192.168.20.1 | 0% loss, ~0.65 ms |
| ns-v10 → ns-v20, routed by SONiC | 0% loss, TTL 63 |
| iperf3 ns-v10 → ns-v20 through SONiC | 267 Mbit/s (both directions on one 1G cable, software dataplane) |
| SONiC ARP / FRR / ASIC_DB | host A MAC learned in VLAN 10 and 20; connected routes; 4 neighbor entries |

The table above is from the first boot, with fixes 2 and 3 applied by
hand. The same traffic tests pass on the rebuilt images with no hand fixes
(logs/sonic-lx2160-boot-4.log onwards).

Platform API (patch 0006; image 202605.0-dirty-20261122.165104, booted
from U-Boot slot 1, logs/sonic-lx2160-boot-7):

| Check | Result |
|---|---|
| `systemctl --failed` | none |
| pmon `syseepromd`, `thermalctld` | running |
| `show platform syseeprom` / `decode-syseeprom` | TlvInfo EEPROM built in software: LX2160ARDB, base MAC = dpni.1 |
| `show platform temperature` | 11 sensors: 7 LX2160A TMU sites, 2x SA56004 local and remote |
| `watchdogutil` | SBSA watchdog; arm and disarm tested |
| `show system-health summary` | Services OK, Hardware OK (once monit's start delay has passed) |
| `show interfaces status` | ports from `platform.json`/`hwsku.json` |

Bugs found on the way, all fixed in 0006:
- The second install failed with "Error storing the env": the U-Boot
  environment was full, so the layout was made compact.
- `show interfaces status` crashed for non-root users: the software
  EEPROM used a file in `/tmp`; the EEPROM data is now kept in memory.
- `show system-health` needed the system-LED methods on the chassis.
- The platform deb needed `--buildsystem=none`: trixie has no
  python_distutils.

BGP (test host A `bgpd` in ns-v10, AS 65200, announcing 10.99.0.0/24; SONiC
AS 65100 on Vlan10): session Established with 1 prefix received; FRR
shows 10.99.0.0/24 via 192.168.10.2 on Vlan10; the route is in ASIC_DB as
a SAI-VS `ROUTE_ENTRY`. On Ubuntu, FRR's AppArmor profile only lets `bgpd`
read `/etc/frr/bgpd.conf` and write `/run/frr/bgpd.pid`, so the test
config has to use those names.

Feature tests (2026-11-22, image installed from ONIE onto the eMMC):

| Feature | Result |
|---|---|
| ONIE install | Unattended. Discovery found `onie-installer-arm64-nxp_lx2160ardb-r0` on a local disk partition and installed SONiC onto the eMMC with no prompts |
| SNMP | sysDescr/sysName; IF-MIB `ifDescr`/`ifName` for the four ports, plus 64-bit counters |
| gNMI (telemetry) | gets from CONFIG_DB (HwSKU) and live COUNTERS_DB values |
| mgmt-framework REST | `sonic-port` and OpenConfig `openconfig-interfaces` |
| mgmt-framework CLI | Commands crashed on the missing python3-six. Fixed in `src/sonic-mgmt-framework/0001` (upstream PR sonic-net/sonic-mgmt-framework#198). With the login fix (`src/sonic-mgmt-framework/0002`, upstream PR #199), `sonic-cli` asks for the password once per session; `show interface status` and `show interface counters` work with the default REST authentication |
| LLDP | test host A seen as neighbour on Ethernet0; the host receives SONiC's LLDP |
| teamd LAG / LACP | PortChannel01 (LACP active) with Ethernet0 as member, and test host A's Linux 802.3ad bond as the partner: LAG up with Ethernet0 selected, traffic across it both ways; LAG and LAG-member objects in ASIC_DB. When the partner stops sending LACPDUs (link kept up), the LAG goes down after about 60 s, within the 90 s slow timeout; when it resumes, the LAG is up within 1 s |
| Power loss | Power pulled while SONiC ran, then restored: U-Boot boots SONiC from the eMMC unattended; both ext4 file systems (eMMC partition, `/var/log` image) mount cleanly with no journal recovery needed; saved configuration unchanged (same checksum); 13 containers, no failed units, system health OK; VLAN routing works. `show reboot-cause` reports `Unknown` (the platform reads no hardware reset-cause register, and a power loss leaves no software record) |
| IPv6 routing | SVIs 2001:db8:10::1/64 (Vlan10) and 2001:db8:20::1/64 (Vlan20); test host A in both VLANs. Neighbor discovery (both hosts REACHABLE), pings to the gateways and routed between the VLANs (hop limit 63); a static route (`config route add prefix 2001:db8:99::1/128 nexthop 2001:db8:20::2`) in FRR and forwarded. ASIC_DB holds the IPv6 subnet, address and static route entries and both neighbors. iperf3 over IPv6 through SONiC: 277 Mbit/s |
| Jumbo frames | Ports default to MTU 9100; SAI-VS sets the DPAA2 netdev to MTU + 22 (9122). With test host A at MTU 9000 (its NIC's maximum): don't-fragment pings up to 9000-byte packets pass to SONiC's gateway and routed between VLANs (TTL 63), seen on the wire as 9018-byte tagged frames both ways. iperf3 through SONiC: 618 Mbit/s at MTU 9000 against 257 Mbit/s at 1500 (SAI-VS costs per packet). `config interface mtu Ethernet0 1500` is enforced: the DPAA2 netdev follows (1522) and jumbo packets are dropped, 1500-byte ones still pass |
| EVPN-VXLAN | VTEP on Loopback0, NVO, VLAN 10 → VNI 1010; kernel VXLAN device, SAI tunnel and map objects; FRR VNI and type-3 route; l2vpn evpn session with test host A, routes received by the host. VXLAN data traffic: test host A as a second VTEP (VNI 1030, FRR with zebra) learned via EVPN type-3; ping over the tunnel 5/5, with VXLAN packets between the VTEPs captured on the wire in both directions. `show vxlan remotevtep` reports `oper_down`, a status SAI-VS does not report |
| Warm reboot | `warm-reboot`: warm shutdown, kexec (no U-Boot), DPAA2 re-probe, syncd restore and every manager reconciled; BGP graceful restart. Traffic gap about 70 s, as expected with SAI-VS (the CPU forwards). Blocked by design while VXLAN tunnels are configured |

fast-reboot: kexec; the platform watchdog was armed and then disarmed after boot; about an 80 s traffic gap.

Release image: the `sonic-nxp-lx2160-arm64.bin` from the GitHub release,
downloaded and checked against `SHA256SUMS`, installed from ONIE over HTTP
(`onie-nos-install http://...`) onto the eMMC. It boots with all containers
up and no failed units; the platform checks and VLAN routing pass as above.

Two test hosts (test host A on DPMAC17/Ethernet0 with VLANs 10 and 20,
test host B on DPMAC18/Ethernet4 as a routed port, 192.168.50.0/24 and
2001:db8:50::/64, set up with `test-host-setup.sh b`):

| Test | Result |
|---|---|
| Routing between the hosts across two SONiC ports | IPv4 and IPv6, both directions, 0% loss, TTL/hop limit 63 |
| iperf3 between the hosts | 334 Mbit/s A to B, 308 Mbit/s B to A; 339 Mbit/s over IPv6 |
| LLDP on Ethernet4 | SONiC sees test host B, and test host B sees SONiC's Ethernet4 |

BGP was tested with test host A only (test host B's FRR packaging got in
the way, not SONiC).

## PMBus test target (lab only, not part of a standard RDB)

The reference board has no PSU under SONiC's control. For lab testing of
SONiC's PSU and PMBus path, an FRDM-MCXA153 running a PMBus target firmware
(MFR_MODEL `MCXA153-PMB-1`, address 0x58) was wired to the board's I2C, on
the segment behind the PCA9547 mux at 0x77, channel 7. Local patch `0007`
(not proposed upstream) adds:

- `lx2160-pmbus-test.service`: at boot, reads MFR_MODEL at 0x58 on that
  channel and binds the kernel `pmbus` driver only if it matches. On a
  standard RDB it finds nothing and does nothing.
- `sonic_platform/psu.py`: the chassis lists "PSU 1 (PMBus test target)"
  only when that hwmon device exists; `psud` is enabled (it runs with zero
  PSUs otherwise).

| Test | Result |
|---|---|
| PMBus reads from Linux (revision, status, VIN, temperatures) | match the target's own readings |
| PEC | reads with PEC OK; a write with a bad PEC is rejected (STATUS_CML 0x20, STATUS_WORD CML bit), CLEAR_FAULTS with a good PEC clears it; the kernel `pmbus` driver enables PEC by itself |
| Kernel `pmbus` hwmon | vin/vout, iin/iout, pin/pout, two temperatures |
| `show platform psustatus` | PSU 1, MCXA153-PMB-1, 12.00 V / 5.00 A / 60.00 W, OK |
| `show platform temperature` | PSU 1 Temp 1/2 with the target's limits (85/100 °C) |
| Without the target | no PSU listed, `psud` running, system health OK |

## Known issues

- **`sonic-cli` and REST login.** Upstream's REST server defaults to
  `client_auth user` (HTTP basic authentication against the SONiC users),
  but the community `sonic-cli` sent no credentials, so its commands
  returned `%Error: not authorized`. Fixed in
  `src/sonic-mgmt-framework/0002` (upstream PR
  sonic-net/sonic-mgmt-framework#199): `sonic-cli` asks for the user's
  password once per session. With the fix, keep the default `client_auth
  user`; `client_auth none` (no prompt, but the REST API open on port 443)
  is only for isolated lab boxes. The community `sonic-cli` `show` tree
  covers interface, ip, lldp, mclag, platform, system and tech-support; for
  VLANs use the regular `show vlan brief`.
- **REST/CLI configuration writes.** The REST server refuses writes with
  "Not an admin user" even for `admin`: it looks users up in the
  container's `/etc` instead of the host's (mounted at `/host_etc`). An
  upstream REST server bug; reads work.
- **Lab hosts with a LAG.** When a Linux test host enslaves its port to a
  bond, the kernel flushes routes through VLAN interfaces on that port
  (including ones in network namespaces); re-add them after the test.
