# Replicating this on another LX2160ARDB

This guide takes an unmodified NXP LX2160ARDB to SONiC installed from ONIE
onto its eMMC, using this repository, in nine steps. Run the commands as
written, in order. Each step says what to expect, so you can tell whether it
worked before moving on.

The result:

```
NOR flash:  RCW/BL2, TF-A + U-Boot (ONIE environment), MC firmware, DPL, ONIE
eMMC:       SONiC (nxp-lx2160 image, SAI-VS on the DPAA2 ports)
SD card:    optional Debian 13 for recovery and as the native SONiC build host
```

## Pinned versions

| Component | Version |
|---|---|
| NXP BSP (TF-A, U-Boot, RCW, MC firmware, MC utils, DDR PHY) | `lf-6.18.37-2.1.0` (git tag, from github.com/nxp-qoriq) |
| Cross toolchain (firmware) | Arm GNU Toolchain 14.3.rel1, aarch64-none-linux-gnu |
| ONIE | opencomputeproject/onie `ac03c31f` + `patches/onie/` |
| SONiC | sonic-net/sonic-buildimage branch `202605`, commit `5ef9e45cc` + `patches/sonic-buildimage/` |

## Prebuilt binaries

The [releases](https://github.com/wrouwet/lx2160-sonic/releases) page has the
binaries that run on the tested board. Check them against `SHA256SUMS`. With
them you can skip the builds in steps 4, 5 and 7:

| File | Use it in | Where it goes |
|---|---|---|
| `lx2160ardb-nor-fw.img` | step 4, instead of building | NOR 0x0–0x1000000: RCW/BL2, TF-A + U-Boot (ONIE environment), DDR PHY firmware, MC firmware 10.40.0, DPL, DPC. Its U-Boot environment area is blank on purpose: U-Boot writes its defaults on first boot |
| `nxp_lx2160ardb-r0.itb` | step 5, instead of building | NOR 0x1000000: ONIE |
| `sonic-nxp-lx2160-arm64.bin` | step 8, instead of building it in steps 6–7 | eMMC, through ONIE |
| `onie-updater-arm64-nxp_lx2160ardb-r0` | later ONIE updates | `onie-self-update` |
| `nxp-firmware-licenses.tar.gz` | | NXP's licences for the MC and DDR PHY firmware inside the NOR image |

Steps 1–3 still apply: you need the SD card for recovery and the NOR backup.

## What you need

- **The board:** an LX2160ARDB with LX2160A rev2 silicon (board rev B tested).
  The firmware runs DDR4 at 2400 MT/s, which works with DDR4-2400 and faster
  DIMMs. See the README, "DDR speed and the RCW".
- **A serial console** on UART1: 115200 8N1, USB-serial adapter.
- **A network cable** from the board's DPMAC17 RGMII port to a host that gives
  it DHCP and internet, for example a NetworkManager "shared" connection.
- **An x86-64 Linux host** (Ubuntu 24.04/26.04) with Docker and about 100 GB
  free: it builds the firmware, ONIE and the SD card.
- **A native arm64 machine** for the SONiC build. The board itself works, with
  a SATA SSD of 128 GB or more and Debian from the SD card (step 6), and takes
  about 7 hours. Any other arm64 Linux host with Docker works too. An x86 host
  can only build it under qemu, which takes 40–60 hours (README, "Overnight
  SONiC build").
- **An SD card** of 8 GB or more, plus a reader.

Boot source switch SW1: change only bits 1–4, and keep bits 5–8 at `1000`.
- `1111 1000`: boot from FlexSPI NOR (normal).
- `1000 1000`: boot from the SD card (recovery).

## 1. Prepare the host

```sh
sudo apt install -y bison flex libgnutls28-dev swig python3-pyelftools device-tree-compiler \
    mmdebstrap qemu-user-binfmt debian-archive-keyring picocom tmux docker.io docker-buildx
sudo usermod -aG docker $USER          # log out and back in
git clone https://github.com/wrouwet/lx2160-sonic.git ~/lx2160-workspace
cd ~/lx2160-workspace
scripts/setup-workspace.sh             # NXP sources at lf-6.18.37-2.1.0 + toolchain (~6.5 GB)
```

Console, in its own terminal:

```sh
sudo setfacl -m u:$USER:rw /dev/ttyUSB0
tmux new -s lx2160 'picocom -b 115200 /dev/ttyUSB0'
```

## 2. Build an SD card (recovery and build host)

```sh
scripts/build-all.sh                   # firmware + kernel; NXP's standard U-Boot
sudo scripts/mk-rootfs.sh              # Debian 13 root filesystem
scripts/mk-sdcard.sh                   # -> out/lx2160ardb-sdcard.img
sudo dd if=out/lx2160ardb-sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

`mk-rootfs.sh` installs your `~/.ssh/id_ed25519.pub` and sets console logins
(see the script). Change them after the first boot.

Put the card in the board, set SW1 to `1000 1000` (SD) and power on. Debian
should reach a login prompt on the console and get a DHCP address on DPMAC17.

## 3. Back up the NOR flash (do not skip)

On Debian on the board:

```sh
sudo dd if=/dev/mtd0 of=~/nor0-backup.bin bs=1M      # boot chip, 64 MiB
sudo dd if=/dev/mtd1 of=~/nor1-backup.bin bs=1M      # second chip
```

Copy both files off the board. A factory board keeps NXP's LSDK recovery
Linux at NOR 0x1000000, and ONIE replaces it. With these files you can always
restore the board: boot from SD, then `sudo flashcp nor0-backup.bin /dev/mtd0`.

## 4. Firmware with the ONIE U-Boot environment

On the host:

```sh
UBOOT_DEFCONFIG=lx2160ardb_tfa_onie_defconfig scripts/build-all.sh uboot atf fwimg
ls -l out/lx2160ardb-nor-fw.img        # 16 MiB: NOR 0x0-0x1000000
```

This also rebuilds `out/lx2160ardb-sd-fw.img` with the ONIE U-Boot. That
build is meant for NOR only, so rerun step 2 if you need a new SD card later.

Copy `out/lx2160ardb-nor-fw.img` to the board. Then, on Debian on the board:

```sh
sudo flashcp -v lx2160ardb-nor-fw.img /dev/mtd0
```

This writes the firmware area only (up to 0x1000000) and leaves ONIE's area
alone. Power off, set SW1 to `1111 1000` (NOR) and power on.

Expected: U-Boot prints `*** Warning - bad CRC, using default environment`,
then `Saving Environment to SPIFlash... done`. It does this once, by design.
No ONIE is installed yet, so the boot stops at the `=>` prompt. From there,
`run debian_boot` still boots Debian from the SD card.

## 5. Build and install ONIE

On the host (or any machine with Docker; aarch64 works too):

```sh
scripts/onie-build.sh                  # about 1 h on the first run (it builds a toolchain)
ls -l onie/build/images/               # nxp_lx2160ardb-r0.itb, onie-updater-arm64-nxp_lx2160ardb-r0
```

Write the ONIE image to NOR 0x1000000. Boot Debian (`run debian_boot` at the
U-Boot prompt), copy `nxp_lx2160ardb-r0.itb` to the board, and run:

```sh
sudo flash_erase /dev/mtd0 0x1000000 127      # 0xfe0000: the ONIE area
sudo dd if=nxp_lx2160ardb-r0.itb of=/dev/mtd0 bs=4096 seek=$((0x1000000)) oflag=seek_bytes
sudo reboot
```

The other way is from U-Boot: TFTP the image to 0xa0000000, then
`sf probe 0:0; sf erase 0x1000000 +$filesize; sf write 0xa0000000 0x1000000 $filesize`.

Expected on the console: `Loading Open Network Install Environment ...`,
`Platform: arm64-nxp_lx2160ardb-r0`, then ONIE's discovery in installer mode.
Press Enter for the `ONIE:/ #` prompt, then program the system EEPROM once,
with your board's first MAC address (U-Boot `printenv ethaddr`):

```sh
onie-stop
onie-syseeprom -s 0x21="LX2160ARDB",0x22="LX2160A-RDB",0x23="<serial>",0x24="<first MAC>",0x2A=8,0x2B="NXP",0x2D="NXP",0x28="arm64-nxp_lx2160ardb-r0"
onie-syseeprom                          # "Checksum is valid."
```

Later ONIE updates go through `onie-self-update <url of onie-updater-arm64-nxp_lx2160ardb-r0>`.
That only runs in rescue or update mode: boot those with `run onie_rescue` or
`run onie_update` at the U-Boot prompt.

## 6. Prepare a SONiC build host (optional: the board itself)

Skip this if you have another arm64 host with Docker. To use the board, boot
Debian from SD (`run debian_boot`) with a SATA SSD attached:

```sh
ls -l /dev/disk/by-id/ | grep ata-                       # find the SSD
sudo SSD=/dev/disk/by-id/ata-<model>_<serial> ~/lx2160-workspace/scripts/board-build-host.sh
```

This **wipes that SSD**. It creates `/srv/build` (ext4, mounted from fstab)
with a 16 GiB swap file, Docker with its data on the SSD, and `j2`.

## 7. Build the SONiC image

On the arm64 build host (on the board: `W=/srv/build/work`):

```sh
W=/srv/build/work                       # or any directory with ~150 GB free
git clone -b 202605 https://github.com/sonic-net/sonic-buildimage.git $W/sonic-buildimage
cd $W/sonic-buildimage && git checkout 5ef9e45cc && make init
cp -r ~/lx2160-workspace/patches $W/
cp ~/lx2160-workspace/scripts/sonic-build.sh ~/lx2160-workspace/scripts/build-manifest.sh $W/
mkdir -p $W/logs && cd $W
W=$W PLATFORM=nxp-lx2160 ./sonic-build.sh     # about 7 h on the board; run it in tmux or with nohup
ls -l $W/sonic-buildimage/target/sonic-nxp-lx2160-arm64.bin
```

`sonic-build.sh` applies `patches/sonic-buildimage/` (the platform, the
installer, the syncd and CLI fixes), configures the platform once, and
builds. It sizes the parallelism by RAM; progress goes to
`$W/logs/sonic-build-latest.log`.

To rebuild after changing a patch: `make` only notices changed inputs that
are listed as dependencies, so first move the affected outputs out of
`target/`. For example, for platform files move
`target/debs/trixie/sonic-platform-nxp-lx2160ardb_1.0_arm64.deb`,
`target/debs/trixie/sonic-device-data_*.deb` and the `.bin`.

## 8. Install SONiC from ONIE

ONIE starts in installer mode by itself while no network OS is installed. To
reinstall later, use `setenv onie_boot_reason install; boot` at the U-Boot
prompt. Pick one of these two ways:

- **Over HTTP:** on a host the board can reach, run
  `python3 -m http.server 8080` in the directory with the `.bin`. Then, at the
  ONIE prompt:

      onie-stop; onie-nos-install http://<host>:8080/sonic-nxp-lx2160-arm64.bin

- **From a USB stick or disk partition:** copy the `.bin` to the root of a
  FAT or ext4 partition as `onie-installer-arm64-nxp_lx2160ardb-r0`. ONIE's
  discovery finds it and installs it unattended.

The installer **wipes the eMMC**, creates one `SONiC-OS` partition, installs
the image and sets U-Boot's `nos_bootcmd`. Then it reboots. Expected on the
console:

```
ONIE: NOS install successful: ...
1: SONiC-OS-202605.0-... (run sonic_image_1)
2:  (run sonic_image_2)
3: ONIE (run onie_rescue)
...
sonic login:
```

Log in as `admin` with the password `YourPaSsWoRd`, SONiC's default; change
it. The first boot takes a few minutes until all containers run.

## 9. Check that it works

```sh
show version                       # Platform: arm64-nxp_lx2160ardb-r0, HwSKU NXP-LX2160ARDB-VS
docker ps --format '{{.Names}}'    # swss syncd bgp pmon lldp teamd snmp gnmi mgmt-framework ...
systemctl --failed                 # nothing
show interfaces status             # Ethernet0/4/8/12; Ethernet0 up with a cable on DPMAC17
show platform syseeprom            # the TlvInfo EEPROM
show platform temperature          # 11 sensors
sudo show system-health summary    # OK (wait ~5 min after boot: monit's start delay)
```

Traffic test with a test host on DPMAC17: SONiC routes between two VLANs on
Ethernet0, and the host injects traffic from two namespaces.

```sh
# on SONiC
sudo config interface ip remove Ethernet0 10.0.0.0/31
sudo config vlan add 10; sudo config vlan add 20
sudo config vlan member add 10 Ethernet0; sudo config vlan member add 20 Ethernet0
sudo config interface ip add Vlan10 192.168.10.1/24
sudo config interface ip add Vlan20 192.168.20.1/24
sudo config save -y
# on the test host (its wired port cabled to DPMAC17)
sudo IFC=<wired port> ~/lx2160-workspace/scripts/test-host-setup.sh
sudo ip netns exec ns-v10 ping -c 3 192.168.10.1        # SONiC's gateway
sudo ip netns exec ns-v10 ping -c 3 192.168.20.2        # routed by SONiC (TTL 63)
```

For more tests (BGP, LLDP, EVPN-VXLAN, warm and fast reboot) and their
results, see [sonic-lx2160-bringup.md](sonic-lx2160-bringup.md).

## Recovery and useful commands

| Situation | What to do |
|---|---|
| The board doesn't boot from NOR | Set SW1 to `1000 1000` (SD), boot Debian, then `sudo flashcp nor0-backup.bin /dev/mtd0` or reflash step 4 |
| Boot Debian with the ONIE U-Boot | Stop autoboot, then `run debian_boot` |
| ONIE rescue shell | `run onie_rescue` |
| Reinstall SONiC | `setenv onie_boot_reason install; boot` (or `run onie_uninstall`, which also wipes SONiC and the U-Boot environment) |
| Pick a SONiC image | the menu at each boot; or `run sonic_image_1` / `run sonic_image_2` |
| Corrupt U-Boot environment | Erase it (`sf probe 0:0; sf erase 0x500000 0x20000`, or ONIE uninstall). U-Boot restores and saves its defaults on the next boot |

## Notes

- The LX2160A is the control-plane CPU, not a switch ASIC. SAI-VS emulates
  the ASIC, so forwarding runs in software on the CPU (about 270–290 Mbit/s
  in our tests). A product pairs the LX2160A with a switch ASIC and its
  vendor SAI.
- The DPAA2 layout (DPL) in NOR at 0xd00000 creates the five interfaces
  SONiC uses: dpni.0–4 on dpmac17, dpmac2, dpmac18, dpmac3 and dpmac4. The
  source is `firmware/dpl/dpl-lx2160ardb-sonic.dts`, generated by
  `scripts/mk-dpl.py` and built by `build-all.sh dpl`.
- Upstream status of these changes: see the README, "Scope".
