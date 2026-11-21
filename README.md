# SONiC on the NXP LX2160ARDB

Bring-up of an NXP LX2160ARDB as the control-plane CPU for SONiC, and the
scripts to rebuild everything from source.

The LX2160A is the switch's control-plane CPU only. DPAA2 terminates Ethernet
for management and control traffic. Forwarding will be done by a Marvell or
Broadcom ASIC through its vendor SAI. Until that hardware exists, SONiC's
virtual switch (SAI-VS) is used for testing.

## Status (2026-11-21)

| Area | State |
|---|---|
| Board | LX2160ACE Rev2.0, RDB board version B, FPGA v8.0 |
| Memory | DDR4 UDIMMs, run at 2400 MT/s (DDR-2400 RCW) |
| Firmware | NXP `lf-6.18.37-2.1.0`: TF-A v2.14.1, U-Boot 2026.04, MC 10.40.0, in FlexSPI NOR chip 0 |
| Boot switches | Normal: SW1 = `1111 1000` (FlexSPI NOR) |
| OS | Debian 13.8 + NXP kernel 6.18.37, root filesystem on the SD card (partition 1) |
| Network | `eth1` = DPMAC17 (1G RGMII), iperf3 ~940 Mbit/s both ways, 0 errors |
| SONiC | First arm64 build of upstream `202605` in progress |

### Why the board was dead

With DDR4-2400 DIMMs, NXP's firmware RCW
ran memory at DDR4-3200. BL2 stopped with "DDR Clk is faster than DIMM can
support". The fix is RCW `rcw_2000_700_2400_19_5_2` (lx2160ardb_rev2): cores
2000 MHz, platform 700 MHz, DDR 2400 MT/s, SerDes 19/5/2. Only the PLL ratios
differ from NXP's 3200 RCW.

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

If a qemu restart dies at "Starting docker build service..." with
`/tmp/dockerfs.log` showing "Device or resource busy", a killed helper dockerd
left a mount behind:
`sudo umount ~/lx2160-workspace/sonic-buildimage/dockerfs/var/lib/docker`.
Progress: `tail -f logs/sonic-build-latest.log`. The script blocks sleep
with `systemd-inhibit`; keep the laptop on mains power.

## Test setup

```
                 ┌────────── LX2160ARDB (SONiC, SAI-VS) ──────────┐
  test host A ──────────┤ DPMAC17  Ethernet0  data + in-band SSH         │
  test host B ──────────┤ DPMAC18  Ethernet4  data                       │
  test host A UART ─────┤ console  out-of-band management and recovery   │
                 │ eth0     DPMAC2 (40G QSFP), present, uncabled  │
                 │ DPMAC3/4 10GBASE-T, spare (3rd laptop / mgmt)  │
                 └────────────────────────────────────────────────┘
```

Management is the UART console (out-of-band, survives any test) plus in-band
SSH to a front-panel or loopback IP. Tooling, simple first: FRR (BGP), lldpd,
iperf3 and scapy on the laptops; later a cut-down sonic-mgmt/PTF testbed with
the test host A as test server.

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
- **Network:** cable from DPMAC17 to the laptop, then
  `nmcli con add type ethernet ifname <port> con-name shared-connection ipv4.method shared ipv6.method disabled`
  and `nmcli con up shared-connection`. The board gets a DHCP address in
  192.0.2.0/24 and internet through the laptop. SSH in as the user created by
  `mk-rootfs.sh`.
- **NOR flash:** two 64 MB chips, `mtd0` (boot) and `mtd1`. U-Boot has no
  altbank support on this board. Update from Linux:
  `sudo flashcp -v out/lx2160ardb-nor-fw.img /dev/mtd0`.
  If it fails to boot, set SW1 to SD and reflash from there.
  The original LSDK-21.08 contents of both chips are backed up on the board's
  SD card in `/root/nor-backup/`.
- **Other storage on the board:** the eMMC (118 GB) and a SATA SSD
  (238 GB) hold old LSDK-21.08 installs. Ask before wiping them.

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

1. Finish and time the first upstream SONiC `202605` arm64 build.
2. Add an LX2160ARDB platform: SONiC kernel config fragment + device tree,
   U-Boot based installer, device/HWSKU definition with SAI-VS.
3. Custom DPL so every DPMAC gets a Linux interface.
4. Move the root filesystem off the SD card (eMMC or SSD).
5. Later: switch to the Marvell or Broadcom platform build once the ASIC
   hardware exists.
