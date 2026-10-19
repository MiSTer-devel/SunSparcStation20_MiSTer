# Building OS disk images in QEMU

How the test images were made (2026-09-28), so they can be rebuilt. Both are
built under QEMU 11.1.1 (`~/.local/qemu-11.1.1`, built from source) on the
`SS-5` machine. Ubuntu's QEMU 8.2.2 cannot install Solaris: it panics
("Non-parity synchronous error" in `fetch_user_instr` / `simulate_unimp`) at
the first instruction Solaris emulates. It also has known V8 bugs
(`tests/cpu/README.md`).

The ISOs are on the NAS (`smb://daninas.local/software/Sun-Solaris/Sparc32`).
The images live in `scratch/images/` (gitignored), and on the MiSTer in
`games/SunSparcStation/`. A fixed VHD is the raw image plus a 512-byte
`conectix` footer:

```bash
qemu-img convert -O vpc -o subformat=fixed,force_size=on in.img out.vhd
```

MiSTer and the core treat `.vhd`, `.img`, `.hda` and `.raw` alike (the OSD
HD slots accept all four).

| Image | Size | SCSI target | Contents |
|---|---|---|---|
| `netbsd11.vhd` | 2 GB | any (installed at 0) | NetBSD 11.0 GENERIC; `sd0a` / 1.7 GB FFSv1, `sd0b` 256 MB swap; sets base etc kern-GENERIC modules rescue text misc man games comp; root password empty |
| `sol8-t3.vhd` | 2.9 GB | **3** (`c0t3d0`) | Solaris 8 2/04, Entire Group, 32-bit, C locale, GMT; `s0` / 1.39 GB, `s1` swap 512 MB, `s7` /export/home; host `sunsparc8`; root password empty |
| `sol8-ss20.img` | 2.9 GB | **3** (`c1t3d0`) | the same installation made bootable on an SS20 (below): device links for the SS20's ESP path, `vfstab` and `dumpadm.conf` on `c1t3d0` |

NetBSD finds its disk as `sd0` whatever the target. Solaris names it by
target (`c0t3d0`) in `/etc/vfstab`, so `sol8-t3` boots only where the disk
is at target 3. Real Suns put it there, and so will the core after the SCSI
rework. The core still puts HD0 at target 0 today.

## NetBSD 11.0

1. **Boot the install CD with the real SS5 PROM.** QEMU's OpenBIOS cannot:
   the CD's Sun label addresses 512-byte blocks, and OpenBIOS reads the
   2048-byte CD without switching the block size.
   ```bash
   qemu-img create -f raw netbsd11.img 2G
   ```
   ```bash
   qemu-system-sparc -M SS-5 -m 256 -bios scratch/SparcStation/ss5.bin -nographic -drive file=netbsd11.img,format=raw,if=scsi,bus=0,unit=0 -drive file=NetBSD-11.0-sparc32.iso,format=raw,if=scsi,bus=0,unit=6,media=cdrom
   ```
   - Use `-nographic`. With a display, OBP moves its console to the
     invisible screen.
   - At `ok`, after the diag-mode memory test, type `boot cdrom`.
2. **Load the installer from the CD.** In the microroot, answer `1`
   (cdrom), then `/dev/cd1a` (the CD at target 6; QEMU adds an empty CD at
   target 2 as `cd0`), then accept the path. At
   `(I)nstall/Upgrade, (H)alt or (S)hell?` choose `S`.
3. **Install by hand.** The ramdisk has no `head`, `tr` or `grep`, and no
   `cd1` device nodes.
   ```sh
   mknod /dev/cd1a b 18 8; mknod /dev/rcd1a c 58 8
   mkdir /cd; mount -t cd9660 -o ro /dev/cd1a /cd
   ```
   ```sh
   # disklabel -R -r sd0 /tmp/proto, where /tmp/proto is:
   #   geometry 63 sect x 16 heads x 4161 cyl (total 4194304)
   #   a: 3670128 0 4.2BSD 2048 16384 0
   #   b: 524160 3670128 swap
   #   c: 4194288 0 unused 0 0
   ```
   ```sh
   newfs -O 1 /dev/rsd0a            # FFSv1 for the OBP-era boot blocks
   mount /dev/sd0a /mnt
   mount -u -o async /dev/sd0a /mnt  # names the device: there is no fstab
   for s in base etc kern-GENERIC modules rescue text misc man games comp; do
     tar -xzpf /cd/sparc/binary/sets/$s.tgz -C /mnt; done
   cd /mnt/dev && sh ./MAKEDEV all; cd /
   cp /mnt/usr/mdec/boot /mnt/boot
   chroot /mnt /usr/sbin/installboot -v /dev/rsd0c /usr/mdec/bootxx /boot
   mkdir -p /mnt/kern /mnt/proc
   ```
   Then write `/mnt/etc/fstab`:
   - `/dev/sd0a / ffs rw,log 1 1`
   - `/dev/sd0b none swap sw 0 0`
   - kernfs, ptyfs and procfs lines.

   Append `rc_configured=YES`, `hostname=sunsparc`, `sshd=NO` and
   `postfix=NO` to `/mnt/etc/rc.conf`, then `umount /mnt; halt`.

   The ramdisk's `printf` cannot print `%`, so keep tmpfs options out of
   `fstab`.
4. **Test boot under QEMU's OpenBIOS.** Drop the `-bios` option and use
   `boot disk`. Under the real PROM in QEMU, GENERIC panics attaching
   `SUNW,bpp` (the PROM lists the parallel port, and QEMU does not emulate
   it).

## Solaris 8 2/04

1. **Label the disk before installing.** `SOL_8_204_SPARC.iso` is the
   single all-in-one install disc. Boot it with QEMU's own OpenBIOS:
   ```bash
   qemu-img create -f raw sol8.img 2900M
   ```
   ```bash
   qemu-system-sparc -M SS-5 -m 256 -nographic -prom-env 'auto-boot?=false' -drive file=sol8.img,format=raw,if=scsi,bus=0,unit=3 -drive file=SOL_8_204_SPARC.iso,format=raw,if=scsi,bus=0,unit=6,media=cdrom
   ```
   ```
   0 > boot /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@6,0:d
   ```
   (OpenBIOS's `cdrom` alias points at QEMU's empty target-2 drive.)
2. **Language, locale, terminal:** answer 0, 0 and 3 (VT100). It runs "Web
   Start" in command-line mode.
3. **Label the disk.** On a disk with no label the installer fails with
   `InvocationTargetException … ProfileServerObject.initProfile` and drops
   to a shell. Label it there with `format`:
   - `format`, then pick disk 0, `c0t3d0` (`<drive type unknown>`);
   - `type` → `18` (other). Auto configure fails on QEMU's drive;
   - enter 5890 data cylinders, 2 alternates, 16 heads and 63
     sectors/track, and take the defaults for the rest;
   - name it `"QEMU 2900MB"`, then `label`, `y`, `quit`;
   - `reboot` and boot the CD again.
4. **Answers.**
   - Networked `n`, host `sunsparc8`, Kerberos `n`, time zone `2` (offset)
     `0`, date `y`.
   - Root password: empty. The installer asks twice, then asks again after
     the "optional password" note; give empty answers until the summary.
   - Then `y`, Enter, Reboot automatically `y`, Eject `n`, `y`, Media `1`,
     Default Install `1`, `y`.
   - The install (software group, additional software, documentation)
     took about 1 h 45 min under QEMU 11.1.1 on this box.
5. **First boot.**
   ```
   0 > boot /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@3,0:a
   ```
   You get `sunsparc8 console login:`. Log in as `root` with no password.

### The SS20 copy (`sol8-ss20.img`, 2026-10-01)

The installation above was made on an SS5, so its `/dev/dsk/c0t3d0*`
links point at the SS5's ESP
(`/iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000`). On
an SS20 the ESP is at `/iommu@f,e0000000/sbus@f,e0001000/espdma@f,400000/
esp@f,800000`: the kernel mounts `/` from the boot path, but `rcS` cannot
remount it through `vfstab` ("Can't open /dev/rdsk/c0t3d0s0", maintenance
mode), and `boot -r` does not help, since the links would be made after
that remount. Fixed once in QEMU's SS-20 (OpenBIOS; the real SS20 PROM
stops with "Data Access Error" under QEMU, and OpenBIOS cannot boot the
Solaris CD there):

1. `cp --sparse=always sol8.img sol8-ss20.img`; boot it on `-M SS-20
   -nographic -prom-env 'auto-boot?=false'` with the disk at target 3:
   `boot /iommu/sbus/espdma/esp/sd@3,0:a -s`. It stops in maintenance mode;
   Enter (empty root password).
2. Make a device node for `/` and remount it read-write through it:
   `mount -F tmpfs swap /tmp; prtconf -D` gives the `sd` instance of
   target 3 on the new path (10: instances 7-13 for targets 0-6, after the
   SS5's 0-6 in `path_to_inst`); `sd` is major 32 (`/etc/name_to_major`),
   slice 0 minor = instance × 8: `mknod /tmp/r0 b 32 80; mount -F ufs -o
   remount,rw /tmp/r0 /`.
3. `devfsadm`: the SS20 path gets controller `c1` (`c0` keeps the SS5's
   links), so `sed s/c0t3d0/c1t3d0/g` over `/etc/vfstab` and
   `/etc/dumpadm.conf`.
4. `reboot`; it comes up to `sunsparc8 console login:` on QEMU's SS-20.
   On the core it needs the official OBP 2.25 (or OpenBIOS) with the disk
   at target 3.

## NeXTSTEP 3.3 for SPARC (`ns33.img`)

QEMU cannot run NeXTSTEP/SPARC, so it is installed on the core itself
(PLAN N1), under either PROM: OpenBIOS (the release's default) or the
official Sun OBP 2.25. The CD is `NeXTSTEP 3.3 User (SPARC, PARISC).iso`
(369 MB). Both were done end to end on 2026-10-06: under OpenBIOS with
`scripts/board/nextstep-install.sh` (the text phase on ttya, as below),
under the Sun OBP as a user would, everything chosen in the OSD (Boot PROM
`ss20-obp225`, Disk 0, CD-ROM, a copy of `ss20-obp-video.nvr`, Auto boot
Off) and both phases on the screen (`boot cdrom` and the answers typed on
the keyboard): the text phase needs no serial console, steps 1-3 work on
the screen as they are, and then step 3's console change is not needed.
`nextstep-install.sh [--obp FILE]` does the following:

**Phase 1, text (ttya; about 15 minutes).**

1. A blank image: `truncate -s 2097152000 ns33.img` (2000 MB; on the
   MiSTer's exFAT this writes the zeros, ~3 minutes), as Disk 0 (SCSI 3),
   the ISO as the CD-ROM (SCSI 6), Network Off, Auto boot Off. The console
   on ttya makes this phase scriptable: OSD Console Serial (ttya) under
   OpenBIOS, a copy of `ss20-obp.nvr` as the NVRAM under the Sun OBP. The
   screen works the same way.
2. `boot cdrom` at `0 >` (OpenBIOS) or `ok` (Sun OBP). NeXT's loader
   counts down, then `1` (English), `1` (prepare to install); after the
   kernel's probe `1` (install on the 2000 MB disk) and `1` (start). It
   partitions the disk ("Mode Sense: Illegal request" from the disk is
   harmless) and copies for 5 to 9 minutes, then asks for Return to
   restart (under a minute). With Auto boot Off the PROM then stops at its
   prompt: `boot disk`.
3. **Stop NeXTSTEP cleanly before changing the console**: at the
   loader's `boot:` prompt type `-s`, then `halt` at the single-user
   shell ("It's safe to turn off the computer"). A core reload or an OSD
   reset under a running NeXTSTEP is a power cut, and the writes of its
   last ~30 seconds are lost (below).

**Phase 2, the GUI (screen; about 30 minutes).**

4. **The GUI needs the screen console**: with the PROM's console on ttya
   NeXTSTEP attaches no mouse (`consconfig` assigns the mouse only when
   stdin is the keyboard). OSD Console Screen+keyboard under OpenBIOS, a
   copy of `ss20-obp-video.nvr` (`output-device=screen`,
   `input-device=keyboard`) under the Sun OBP; Auto boot On. Keep the CD
   attached until the end: the installer's `/etc/fstab` mounts it on
   `/NEXTSTEP_INSTALL`, and without it fsck stops the boot ("Can't read
   label on /dev/rsd1a").
5. "No response from network configuration server": Ctrl-C starts
   without a network.
6. loginwindow logs in as `me` and runs `/NextAdmin/Configure.app`:
   "Summary of Devices" lists S24 Graphics Subsystem (the TCX), SUN Mouse,
   Sun Lance Ethernet, Sun SCSI, Sun Audio and SUN TYPE5 Keyboard; click
   Save.
7. loginwindow then runs BuildDisk in Install mode, "Install NEXTSTEP":
   NEXTSTEP Essentials (61.8 MB, required) and, all selected, the five
   languages, Demonstrations, Documentation, Digital Webster and the rest
   (399 MB). Install copies them from the CD: about 20 minutes on the
   core (2026-10-06, OpenBIOS: 19:41 to 20:01; Sun OBP: 20:53 to 21:18,
   the L2 TLB stays off under it), slowest at the start, where
   the languages are thousands of small files (CPU-bound: NeXTSTEP uses one
   CPU, and PC samples showed 20 % idle).
8. "NEXTSTEP has been installed successfully ... click Restart": Return.
   BuildDisk has written `/private/adm/BuildDisk.custom` and the receipts
   in `/NextLibrary/Receipts` (14 packages); the network panel again
   (Ctrl-C), then the Welcome panel (English, USA: OK, and OK to confirm),
   and loginwindow logs `me` in to the Workspace.
9. To stop: Log Out (Command-Q; the PC's Windows key is Command) and Power
   Off, until "System shutdown. It's safe to turn off the computer".

How loginwindow and BuildDisk hand over: at each login without
`/private/adm/BuildDisk.custom`, loginwindow writes `BuildDisk Install
Yes` into the user's defaults database (`~me/.NeXT/.NeXTdefaults.D` and
`.L`) and runs BuildDisk; BuildDisk's `main` reads that default and
starts in Install mode. Without it BuildDisk starts as the ordinary disk
builder, which never offers the disk it runs from (`auditDisks` disables a
disk mounted on `/`) and so says "No disks that you can build are attached
to this computer". That is what happened to the first `ns33.img`
(sessions 12-15): an unclean stop had left `/me/.NeXT/.NeXTdefaults.D`
(20 bytes) all zeros, the database unreadable, and loginwindow's write
never stuck. The SCSI side was never at fault: through `/dev/sg0`
BuildDisk's own INQUIRY scan finds the disk at target 3 and the CD at
target 6 (`tools/nextstep/sgprobe.sh` runs that scan from a single-user shell).
`tools/ufscmp.py` compares an installed directory with the CD's
(`/usr/lib/NextStep`: every file identical but the fat binaries, which the
installer thins to SPARC).

The kernel's "preposterous time in Real Time Clock" is the 2026 clock
against the CD's 1995 file dates. `scripts/hwtest.sh 20 nextstep` and
`nextstep-obp` (scripts/board/nextstep.sh) boot the installed image to
loginwindow under each PROM.
