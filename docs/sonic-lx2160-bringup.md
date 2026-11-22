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
| DPAA2 layout (5 DPNIs) | `scripts/mk-dpl.py`, in NOR at 0xd00000 |
| Install without ONIE | `scripts/sonic-lx2160-install.sh` |

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

## Install and boot (no ONIE, nothing saved in U-Boot)

On the board under Debian:

    sudo ./sonic-lx2160-install.sh target/sonic-nxp-lx2160-arm64.bin /srv/build

This unpacks the image into `/srv/build/image-<version>/` on the SSD and
prints the U-Boot commands. To boot it, interrupt autoboot and enter:

    sf probe 0:0; sf read 0xb0000000 0xd00000 0x100000; fsl_mc lazyapply dpl 0xb0000000
    scsi scan
    setenv bootargs 'root=UUID=<ssd uuid> rw rootwait panic=1 console=ttyAMA0,115200 earlycon net.ifnames=0 loopfstype=squashfs loop=image-<version>/fs.squashfs varlog_size=512'
    ext4load scsi 0:1 0xa0000000 /image-<version>/boot/sonic_arm64.fit
    bootm 0xa0000000

A plain reset boots Debian again.

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

## Test results (2026-11-22, fixes 2 and 3 applied by hand)

From the test host A (`scripts/test-host-a-testbed.sh`: namespaces ns-v10 and ns-v20 on VLAN
subinterfaces of its wired port, cabled to DPMAC17). SONiC has Vlan10
(192.168.10.1/24) and Vlan20 (192.168.20.1/24), with Ethernet0 tagged in both.

| Test | Result |
|---|---|
| syncd (SAI-VS) + swss | running, stable |
| Ethernet0/4/8/12 | created, bound to dpmac17/18/3/4; Ethernet0 oper up |
| ns-v10 → 192.168.10.1, ns-v20 → 192.168.20.1 | 0% loss, ~0.65 ms |
| ns-v10 → ns-v20, routed by SONiC | 0% loss, TTL 63 |
| iperf3 ns-v10 → ns-v20 through SONiC | 267 Mbit/s (both directions on one 1G cable, software dataplane) |
| SONiC ARP / FRR / ASIC_DB | test host A MAC learned in VLAN 10 and 20; connected routes; 4 neighbor entries |

Not tested yet: a clean boot of a rebuilt image (no hand fixes), LLDP, BGP,
and DPMAC18 (test host B).
