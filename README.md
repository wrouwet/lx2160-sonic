# SONiC and ONIE on the NXP LX2160ARDB

A port of SONiC and ONIE to the NXP LX2160ARDB, with the LX2160A as the
switch's control-plane CPU, plus the scripts and patches to rebuild
everything from source.

The LX2160A is the control-plane CPU only; it isn't a switch ASIC. DPAA2
terminates Ethernet for management and control traffic. In a product,
forwarding is done by a switch ASIC (e.g. Marvell or Broadcom) through its
vendor SAI. On this board, SONiC's virtual switch (SAI-VS) stands in for the
ASIC for testing, so the control plane and real traffic on the board's ports
can be tested without switch hardware. Forwarding performance with SAI-VS is
software-only and not representative.

**To reproduce this on your own LX2160ARDB, follow
[docs/REPLICATE.md](docs/REPLICATE.md)**: a step-by-step guide from an
unmodified board to SONiC installed from ONIE. Prebuilt binaries (NOR
firmware, ONIE, the SONiC image) are on the
[releases](https://github.com/wrouwet/lx2160-sonic/releases) page.

## Upstream status

| Change | Pull request |
|---|---|
| SONiC platform `nxp-lx2160` and device `arm64-nxp_lx2160ardb-r0` | [sonic-buildimage#30968](https://github.com/sonic-net/sonic-buildimage/pull/30968) |
| syncd: `asic_type nxp-lx2160` uses the SAI-VS setup | [sonic-sairedis#2221](https://github.com/sonic-net/sonic-sairedis/pull/2221) |
| ONIE machine `nxp_lx2160ardb` and generic ONIE build fixes | [onie#1143](https://github.com/opencomputeproject/onie/pull/1143) |
| mgmt-framework CLI: `urllib.parse` instead of `six` | [sonic-mgmt-framework#198](https://github.com/sonic-net/sonic-mgmt-framework/pull/198) |
| mgmt-framework CLI: log in to the REST server as the CLI user | [sonic-mgmt-framework#199](https://github.com/sonic-net/sonic-mgmt-framework/pull/199) |
| arm64 cross-build fixes (draft) | [sonic-buildimage#30962](https://github.com/sonic-net/sonic-buildimage/pull/30962) |

## Scope: what this repository provides

| Part | What | Where |
|---|---|---|
| **SONiC image** | A full, installable SONiC image for the LX2160ARDB, `sonic-nxp-lx2160-arm64.bin`, from upstream sonic-buildimage `202605`. It has its own Debian 13 base, the SONiC kernel (6.12) and all SONiC containers. It installs from ONIE onto the eMMC and boots on its own; it isn't containers running on another Linux | `patches/sonic-buildimage/` |
| **SONiC platform** | Build platform `nxp-lx2160`, device `arm64-nxp_lx2160ardb-r0`, HwSKU `NXP-LX2160ARDB-VS`: four front-panel ports on DPAA2 (DPMAC17/18/3/4 as Ethernet0/4/8/12), interface naming, FIT boot image, DPL handling | patches `0002`–`0004`, `0006` |
| **Virtual switch (SAI-VS)** | `syncd-vs` with SAI-VS as the emulated ASIC: its lane map binds SONiC ports to the DPAA2 interfaces, so VLANs, routing and BGP routes go through SONiC's full pipeline down to the ASIC model | patches `0002`, `0003`, sairedis `0001` |
| **SONiC platform API** | `sonic_platform`: chassis, TlvInfo system EEPROM, 11 temperature sensors (SoC TMU, board sensors), SBSA watchdog, system LED state; `platform.json`/`hwsku.json`; pmon daemons; system-health config | patch `0006` |
| **SONiC installer** | U-Boot two-slot A/B images (`sonic-installer` compatible): ONIE install onto the eMMC, install from a running SONiC, and first install from another Linux | patch `0006`, `scripts/sonic-lx2160-install.sh` |
| **ONIE** | ONIE machine `nxp_lx2160ardb`: kernel 6.12, DPAA2 networking, NOR layout, TlvInfo EEPROM in NOR, updater; generic ONIE build fixes (`UBOOT_EXTERNAL`, arm64 build hosts, toolchain header pin) | `patches/onie/` (against opencomputeproject/onie) |
| **Firmware** | TF-A, U-Boot (NXP `lf-6.18.37`) with an ONIE default environment, MC firmware, DPL with interfaces for every copper port, NOR/SD images | `patches/u-boot/`, `scripts/` |
| **Build** | Native arm64 build on the board (Debian 13 build host) and x86 build paths; cross-build fixes, also proposed upstream as [sonic-buildimage#30962](https://github.com/sonic-net/sonic-buildimage/pull/30962) (draft) | `scripts/`, patch `0005` |

### Tested on the board

ONIE boots from NOR and installs SONiC onto the eMMC (from a local disk or
over HTTP, including the published release image). SONiC then boots from
the eMMC through ONIE's boot flow, with no failed services and system-health
OK. These all pass:
- the platform API: system EEPROM, temperatures, watchdog
- VLAN routing between a test host's two VLANs, IPv4 and IPv6 (incl. static
  routes), plus iperf3
- BGP (with graceful restart), with the learned route programmed into the
  SAI-VS ASIC model
- EVPN-VXLAN, control plane and data traffic through the tunnel
- LLDP, teamd LAG with an LACP partner, SNMP, gNMI and REST
- jumbo frames (MTU 9100 on the ports, 9000-byte packets routed)
- lab only: a PMBus test target (FRDM-MCXA153) on the board's I2C shows up
  as a PSU in SONiC (local patch `0007`, not on a standard RDB)
- warm reboot and fast reboot (kexec)
- ONIE install, rescue, update and uninstall

Details and results: [docs/sonic-lx2160-bringup.md](docs/sonic-lx2160-bringup.md).

Both 1G test ports (DPMAC17 and DPMAC18) are tested, with a test host on each. A real switch ASIC needs that vendor's SAI and a device directory
under its platform.

## Status (2026-11-22)

| Area | State |
|---|---|
| Board | LX2160ACE Rev2.0, RDB board version B |
| Memory | DDR4 UDIMMs, run at 2400 MT/s (DDR-2400 RCW) |
| Firmware | NXP `lf-6.18.37-2.1.0`: TF-A v2.14.1, U-Boot 2026.04 (ONIE default environment), MC 10.40.0, in FlexSPI NOR chip 0 |
| Boot | TF-A, then U-Boot, then ONIE (NOR 0x1000000) or the installed SONiC (eMMC) |
| Build host | Debian 13.8 with NXP kernel 6.18.37 on the SD card (`run debian_boot` at the U-Boot prompt) |
| SONiC | `nxp-lx2160` image (upstream `202605`, SONiC kernel, SAI-VS), installed from ONIE on the eMMC |

### DDR speed and the RCW

If BL2 stops with "DDR Clk is faster than DIMM can support", the RCW runs
memory faster than the installed DIMMs allow. For DDR4-2400 DIMMs use RCW
`rcw_2000_700_2400_19_5_2` (lx2160ardb_rev2): cores 2000 MHz, platform
700 MHz, DDR 2400 MT/s, SerDes 19/5/2. Only the PLL ratios differ from NXP's
3200 RCW. `build-all.sh` uses it by default (`RCW_NAME`).

## Decisions

- **Kernel: the SONiC kernel**, from `sonic-linux-kernel` (6.12, Debian 13
  based), not NXP's. That's the standard for SONiC platforms, and ASIC SDK
  kernel modules are built against it. Debian's arm64 config already enables
  `ARCH_LAYERSCAPE`, `FSL_MC_BUS`, `FSL_DPAA2_ETH`, `FSL_MC_DPIO`, eSDHC,
  `AHCI_QORIQ` and `SPI_NXP_FLEXSPI`. Anything the board needs beyond that
  goes in a `config.local/arm64/config.sonic-<platform>` fragment.
  Still to confirm: `PCI_LAYERSCAPE` (rev2 DesignWare PCIe, needed for the ASIC).
- **SONiC release: `202605`**, the newest stable branch, on Debian 13.
- **No DPAA2 dataplane offload.** Out of scope.

## Repository layout

```
scripts/
  setup-workspace.sh  clone NXP sources at lf-6.18.37-2.1.0, fetch + verify the Arm GNU 14.3 toolchain
  build-all.sh        build RCW, U-Boot, TF-A (SD + NOR), DPL/DPC, kernel, firmware images
  mk-fwimg.sh         assemble raw firmware images (MODE=sd or MODE=nor, DPL_NAME=sonic or nxp)
  mk-dpl.py           generate the SONiC DPL (all copper ports) from NXP's dpl-eth.19
  mk-rootfs.sh        Debian 13 arm64 rootfs tarball with mmdebstrap (run with sudo)
  mk-sdcard.sh        SD card image: firmware + Debian rootfs + kernel + extlinux (unprivileged)
  sonic-build.sh      unattended arm64 SONiC image build (upstream sonic-buildimage 202605)
  build-manifest.sh   content manifest of a SONiC build (debs, docker packages, image packages)
  compare-builds.sh   compare two manifests (laptop/qemu vs board/native) as a Markdown report
  board-build-host.sh turn the board into a native arm64 build host (WIPES its SATA SSD)
  kernel-docker.config kernel config fragment Docker needs (merged by build-all.sh)
```

Generated and downloaded content (`src/`, `toolchain/`, `out/`, `logs/`,
`sonic-buildimage/`) is not tracked.

## Host setup (Ubuntu 26.04)

```sh
sudo apt install -y bison flex libgnutls28-dev swig python3-pyelftools device-tree-compiler \
    mmdebstrap qemu-user-binfmt debian-archive-keyring \
    picocom tmux docker.io docker-buildx iperf3
sudo usermod -aG docker $USER        # then log out and back in
```

Do **not** enable the iperf3 daemon at boot. If the installer did, run
`sudo systemctl disable --now iperf3`.

## Rebuild from scratch

```sh
git clone https://github.com/wrouwet/lx2160-sonic.git ~/lx2160-workspace
cd ~/lx2160-workspace
scripts/setup-workspace.sh           # sources + toolchain (~6.5 GB)
scripts/build-all.sh                 # firmware + kernel -> out/lx2160ardb-{sd,nor}-fw.img
sudo scripts/mk-rootfs.sh 2>&1 | tee logs/rootfs-build.log
scripts/mk-sdcard.sh                 # -> out/lx2160ardb-sdcard.img
```

`mk-rootfs.sh` installs the invoking user's `~/.ssh/id_ed25519.pub` for SSH
and sets the default console logins. Change them after first boot.

## Overnight SONiC build

Upstream `sonic-buildimage` (branch `202605`), `marvell-prestera` arm64 image,
built on the x86 laptop under qemu. Upstream CI builds arm64 natively on arm64
hosts, so this is the less-travelled path.

```sh
git clone -b 202605 https://github.com/sonic-net/sonic-buildimage.git ~/lx2160-workspace/sonic-buildimage
(cd ~/lx2160-workspace/sonic-buildimage && make init)
python3 -m venv ~/.local/share/j2-venv && ~/.local/share/j2-venv/bin/pip install jinjanator
ln -sf ~/.local/share/j2-venv/bin/j2 ~/.local/bin/j2
```

`Makefile.work` starts its arm64 helper dockerd with `sudo`, once per build
environment (bookworm, then trixie, hours apart). For an unattended run, keep
your sudo credential cached for 36 hours, then start the build in tmux:

```sh
echo "Defaults:$USER timestamp_timeout=2160" | sudo tee /etc/sudoers.d/90-sonic-build-timeout
sudo chmod 440 /etc/sudoers.d/90-sonic-build-timeout && sudo visudo -c
tmux new -s sonic
sudo -v && ~/lx2160-workspace/scripts/sonic-build.sh   # inside tmux
```

Afterwards: `sudo rm /etc/sudoers.d/90-sonic-build-timeout`.

The qemu build also needs the host's static qemu registered **with the C
(credentials) flag**, so setuid arm64 binaries like `sudo` work inside the
build container. Ubuntu registers it without; install the override once:

```sh
sudo cp host/binfmt.d/qemu-aarch64.conf /etc/binfmt.d/
sudo sh -c 'echo -1 > /proc/sys/fs/binfmt_misc/status' && sudo systemctl restart systemd-binfmt
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64     # flags: POCF
```

`sonic-build.sh` refuses to start a qemu build without it, and passes
`DOCKER_MULTIARCH_CHECK=true` so SONiC doesn't replace it with its own old
qemu 7.2 (under which `py3compile` crashes). Qemu builds use the `vfs` slave
docker driver, like upstream CI; native builds use the host dockerd
(`SONIC_CONFIG_USE_NATIVE_DOCKERD_FOR_BUILD=y`) because the board's kernel
lacks the legacy iptables that the in-container dockerd needs.

`sonic-build.sh` runs `make configure` only on the first build (or when the
platform changes): `configure` rewrites `.platform`, which every package
depends on, so running it again makes SONiC rebuild everything from scratch.

If a qemu restart dies at "Starting docker build service..." with
`/tmp/dockerfs.log` showing "Device or resource busy", a killed helper dockerd
left a mount behind:
`sudo umount ~/lx2160-workspace/sonic-buildimage/dockerfs/var/lib/docker`.
Progress: `tail -f logs/sonic-build-latest.log`. The script blocks sleep
with `systemd-inhibit`; keep the laptop on mains power.

## Test setup

```
                 ┌────────── LX2160ARDB (SONiC, SAI-VS) ──────────┐
  host A ────────┤ DPMAC17  Ethernet0  data + in-band SSH         │
  host B ────────┤ DPMAC18  Ethernet4  data                       │
  host A UART ───┤ console  out-of-band management and recovery   │
                 │ eth0     DPMAC2 (40G QSFP), present, uncabled  │
                 │ DPMAC3/4 10GBASE-T, spare (3rd host / mgmt)    │
                 └────────────────────────────────────────────────┘
```

Management is the UART console (out-of-band, survives any test) plus in-band
SSH to a front-panel or loopback IP. Tooling, simple first: FRR (BGP), lldpd,
iperf3 and scapy on the test hosts; later a cut-down sonic-mgmt/PTF testbed
with test host A as test server.

### DPL: interfaces for every copper port

`firmware/dpl/dpl-lx2160ardb-sonic.dts`, generated by `scripts/mk-dpl.py` from
NXP's `dpl-eth.19`:

| DPNI | DPMAC | Port |
|---|---|---|
| dpni@0 | dpmac@17 | RGMII 1G (unchanged from NXP) |
| dpni@1 | dpmac@2 | 40G QSFP, SONiC `eth0` placeholder (unchanged) |
| dpni@2 | dpmac@18 | RGMII 1G |
| dpni@3 | dpmac@3 | AQR107 10GBASE-T |
| dpni@4 | dpmac@4 | AQR107 10GBASE-T |

Buffer pools go to 6 (one per DPNI) and DPCONs to 80 (16 cores × 5 DPNIs).
`mk-fwimg.sh` uses this DPL by default; `DPL_NAME=nxp` selects NXP's.

Test without touching NOR: stop autoboot at the U-Boot prompt, then

```
ext4load mmc 0:1 0x80d00000 /home/<user>/dpl-lx2160ardb-sonic.dtb
fsl_mc lazyapply dpl 0x80d00000
run distro_bootcmd
```

A plain reset returns to the DPL in flash.

### Comparing the two build paths

The laptop (qemu) and board (native) builds of the same commit should produce
the same content. Builds embed timestamps, so they are compared by content:

```sh
scripts/build-manifest.sh sonic-buildimage > logs/manifest-laptop.txt
# on the board: ./build-manifest.sh sonic-buildimage > logs/manifest-board.txt
scripts/compare-builds.sh logs/manifest-laptop.txt logs/manifest-board.txt laptop board
```

`build-manifest.sh` records each .deb's version and a digest of its file list
and sizes, the installed packages inside every docker image, and the packages
in the installer's root filesystem. `compare-builds.sh` reports anything that
is missing, a different version, or different content.

## Firmware image layout

Offsets are the same on SD and NOR, except for the PBL (RCW + BL2).

| Offset | SD | NOR | Contents |
|---|---|---|---|
| 0x0000000 | MBR | PBL | partition table / RCW + BL2 |
| 0x0001000 | PBL | | RCW + BL2 (`bl2_sd.pbl`) |
| 0x0100000 | ✓ | ✓ | `fip.bin` (BL31 + U-Boot) |
| 0x0500000 | ✓ | ✓ | U-Boot environment |
| 0x0800000 | ✓ | ✓ | `fip_ddr.bin` (DDR4 PHY training firmware) |
| 0x0a00000 | ✓ | ✓ | MC firmware 10.40.0 |
| 0x0d00000 | ✓ | ✓ | DPL (`dpl-lx2160ardb-sonic`, or NXP `dpl-eth.19`) |
| 0x0e00000 | ✓ | ✓ | DPC `dpc-usxgmii` |
| 64 MiB | p1 | | SD only: ext4 root filesystem |

## Board operation

- **Console:** UART1 at 115200 8N1 (PL2303 adapter, `/dev/ttyUSB0`).
  After each replug: `sudo setfacl -m u:$USER:rw /dev/ttyUSB0`.
  Shared session: `tmux new -s lx2160 'picocom -b 115200 --logfile logs/console.log /dev/ttyUSB0'`.
- **Boot source (SW1 bits 1-4 only, keep 5-8 as `1000`):**
  `1111 1000` = FlexSPI NOR (normal), `1000 1000` = SD (recovery).
- **Network:** cable from DPMAC17 to the build/test host and share that
  host's connection with NetworkManager, e.g.
  `nmcli con add type ethernet ifname <port> con-name <name> ipv4.method shared ipv6.method disabled`.
  The board gets a DHCP address from the host and internet through it. SSH
  in as the user created by `mk-rootfs.sh`.
- **NOR flash:** two 64 MB chips, `mtd0` (boot) and `mtd1`. U-Boot has no
  altbank support on this board. Update from Linux:
  `sudo flashcp -v out/lx2160ardb-nor-fw.img /dev/mtd0`.
  If it fails to boot, set SW1 to SD and reflash from there.
  The original LSDK-21.08 contents of both chips are backed up on the board's
  SD card in `/root/nor-backup/`.
- **Other storage on the board:** the eMMC (SONiC's install disk under
  ONIE) and an optional SATA SSD (the native build disk, see
  `board-build-host.sh`).

## Known issues / notes

- Only `dpni.0` (DPMAC17 → `eth1`) and `dpni.1` (→ `eth0`) exist in Linux:
  NXP's `dpl-eth.19` only creates two. dpmac.2–6 and .18 need DPNIs, either
  via a custom DPL or restool.
- Harmless boot messages: OP-TEE probe -22 (not built in), `regulatory.db`
  (no Wi-Fi), RTC "failed to configure interrupt pins".
- `mmdebstrap` under `sudo` in a terminal got stopped (state T) when apt
  started dpkg. `mk-rootfs.sh` therefore runs it with `setsid` and stdin from
  `/dev/null`. Exact cause not proven.

## Next steps

1. Clean boot of the rebuilt image with patch 0004 and sairedis 0001 (no hand fixes).
2. LLDP and DPMAC18 (test host B) tests; `platform.json` for the platform.
3. A real installer (U-Boot environment entry) instead of typed boot commands.
4. Compare the laptop (qemu) and board builds.
5. Later: switch to the Marvell or Broadcom platform build once the ASIC
   hardware exists.
