# sim/ — whole-machine simulation

Verilator runs the same SystemVerilog that Quartus builds: `sim_top.sv` wraps
`rtl/machine/ss20_machine.sv` (the machine below the MiSTer glue), and
`sim_main.cpp` plays the MiSTer side.

| file | what |
|---|---|
| `sim_top.sv` | `ss20_machine` + the OSD decoder (`ss20_osd`), with the MiSTer side as plain ports |
| `sim_main.cpp` | the harness: DDR3, ROM download, SD blocks, RTC, ttya, video frame, the Ethernet mailbox's host side |
| `build.sh [20] [--trace]` | verilate and compile → `obj_ss20/Vsim_top` (`obj_ss20_trace/` with VCD support). The RTL list comes from `files.qip`, so the model and the Quartus build cannot drift apart |
| `run-obp.sh ROM [--diag]` | Sun's OBP 2.25 (your own PROM image) on ttya to `ok`; makes a Sun-format NVRAM image once (`tools/obp_nvram.py`) |
| `run-cputest.sh`, `run-nvram.sh`, `run-eth.sh`, `run-scsi.sh` | the CPU suite, NVRAM, Ethernet and SCSI runs against their expected logs. They need the CPU, the memory controller and the ported HPS blocks: phases 4-8 of the plan bring them back |
| `cpu/`, `iu/` | the CPU module's and the IU's own harnesses (phases 1-3), independent of this one |
| `vcd.py` | query a trace: `vcd.py F.vcd list REGEX`, `vcd.py F.vcd show REGEX… --from C --to C` |

## State (phase 0)

The machine is empty: it drives the DDR3, SD, download and UART ports idle
and shows a test pattern at 1024x768 (eight colour bars, a grey ramp, a
white frame on the outermost pixels).

```bash
sim/build.sh
sim/obj_ss20/Vsim_top --cycles 5M --frame sim/out/frame.ppm
# [sim] cycle limit after 5000000 cycles ..., frames 4
```

`--rom` is optional now: without it there is no download.

## Running

`Vsim_top --help` lists the options. The ones used most:

- `--rom FILE`: the boot PROM, downloaded as index 0.
- `--hd0/--hd1/--cd FILE`: disk images, served the way `hps_io` serves them.
- `--nvram FILE`: the NVRAM image (8192 bytes, slot 3), mounted before the
  ROM download as Main does; it is read at the start and written back when
  the machine changes the NVRAM (the summary counts the sectors).
- `--stop STR`, `--fail STR`: end the run when the console prints STR.
- `--send 'PAT=>TEXT'`: type TEXT on ttya once PAT has appeared.
- `--video`, `--noautoboot`, `--cg3`, `--l2tlb`, `--eth`: OSD options. The
  harness builds the OSD status word bit for bit as `scripts/setopt.sh` does
  and `sim_top` decodes it with the board's decoder. The simulation's
  defaults are the board's except the console (ttya), the L2 TLB (Off) and
  the network (Off).
- `--frame F.ppm`: save the last complete video frame.
- `--ram MB`: the OSD memory option (464, 256, 128, 64). Sun's OBP clears
  all of memory at every start: 64 saves minutes.
- `+iolog`: print every I/O access (system space and SBus) as it completes.
- `+promlog`: every 10M cycles, the memory requests each CPU started, its
  boot-PROM reads (and how many waited), and how busy ss20_memctl was.
- `+prom_wait=N`: replaces ss20_memctl's PROM_WAIT (36 at 55 MHz, ~0.65 us),
  the wait before every boot-PROM read a CPU makes in boot mode
  (MCNTL.BM), the real machine's byte-wide EPROM pace. OBP 2.25's POST
  (`diag-switch?` true) runs in boot mode and times its "PROCn
  Counter/Timer Test" with instruction loops; `+prom_wait=0` makes boot
  mode fast again (the POST then reports "No interrupt received").
- `--trace F.vcd --trace-from N`: a waveform, from a model built with
  `build.sh --trace`. Keep the window short.
- `--ddr-log N`: print the first N DDR commands; `--ddr-stress`,
  `--ddr-gaps`: random waitrequest, random bubbles inside read bursts, as
  the board's port shows under load.

The exit status is 0 for a stop string, 1 for a fail string, 2 for the cycle
limit, and 3 for a usage error. One cycle is one `clk_sys` period; the UART
bit time comes from `SIM_SYSFREQ` (55 MHz, the board's `clk_sys`).

The ROM is preloaded into DDR and only its last word goes through `ioctl`
(`--full-download` sends it all); the loader starts the machine after at
least 128 KB.

## Differences from the board

- **One clock.** The pixel clock (65 MHz on the board) is `clk_sys` here;
  a frame is 1344 x 806 cycles.
- **Memory.** DDR latency is a fixed 8 cycles to the first beat, with up
  to 8 reads outstanding, and the beats of a burst come back to back; the
  board's do not (`--ddr-stress`, `--ddr-gaps`).
- **Disks.** SD requests are answered after 40 cycles (`--sd-latency`). On
  the board, Main takes far longer.
- **Assertions.** They are not checked.
- **Not covered:** `SunSparcStation.sv` itself (the PLL, `hps_io`, the
  video scaler), which only the board runs.
