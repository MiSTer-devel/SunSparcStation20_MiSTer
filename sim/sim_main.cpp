// sim_main.cpp - Verilator harness for the whole machine (sim_top.sv).
//
// It plays the MiSTer side: the DDR3 behind ddram_arb, hps_io's ROM
// download and SD-block service for the disk images, the RTC, and a
// terminal on ttya. The run ends when the console prints a --stop string
// (exit 0), a --fail string (exit 1), or after --cycles (exit 2).
//
//   Vsim_top --rom tests/cpu/out/ss20/cputest.rom --stop "PASS" --cycles 50M
//   Vsim_top --rom boot.rom --hd0 netbsd.img --send "ok =>boot disk\r"
//
// Cycle accounting: one cycle is one clk_sys period; with the PLL stub every
// clock in the machine is this clock. Rates such as the UART bit time are
// derived from SIM_SYSFREQ, the SYSFREQ the model was generated with.

#include "Vsim_top.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <sys/mman.h>
#include <sys/time.h>
#include <cinttypes>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <string>
#include <vector>

#ifndef SIM_SYSFREQ
#define SIM_SYSFREQ 55000000
#endif

static double now_s() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

static uint64_t parse_count(const char *s) {
    char *end;
    double v = strtod(s, &end);
    if (*end == 'k' || *end == 'K') v *= 1e3;
    else if (*end == 'M') v *= 1e6;
    else if (*end == 'G') v *= 1e9;
    return (uint64_t)v;
}

// "\r", "\n", "\t", "\\", "\xHH" in command-line strings.
static std::string unescape(const std::string &s) {
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] != '\\' || i + 1 == s.size()) { o += s[i]; continue; }
        char c = s[++i];
        if (c == 'r') o += '\r';
        else if (c == 'n') o += '\n';
        else if (c == 't') o += '\t';
        else if (c == 'B') o += '\xff';     // --send: a BREAK (see Uart)
        else if (c == 'x' && i + 2 < s.size() + 1) {
            o += (char)strtol(s.substr(i + 1, 2).c_str(), nullptr, 16);
            i += 2;
        } else o += c;
    }
    return o;
}

// ---------------------------------------------------------------------------
// DDR3: 512 MB of 64-bit words, zeroed (the machine is built with
// SKIP_CLEAR for the simulation). ss20_machine puts its memory in the
// MiSTer's FPGA window, byte addresses 0x2000_0000-0x3FFF_FFFF, with core
// address bits 28:20 inverted (main memory at the top, away from the video
// scaler's buffer at the bottom: rtl/machine/ss20_memctl.sv); each
// doubleword big-endian, byte offset 0 in bits 63:56.
// Reads are pipelined (up to DDR_QUEUE bursts outstanding, first beat after
// DDR_LAT cycles); write bursts take one beat per cycle.
struct Ddr {
    static const uint64_t WORDS = 64ull << 20;   // 512 MB
    static const int DDR_LAT = 8;
    static const size_t DDR_QUEUE = 8;
    uint64_t *mem;
    struct Rd { uint32_t addr; int count; uint64_t start; };
    std::deque<Rd> rq;
    uint32_t wr_addr = 0;
    int wr_left = 0;
    bool stress = false;          // random waitrequest
    bool gaps = false;            // random bubbles inside read bursts
    uint64_t log_left = 0;        // --ddr-log: accesses still to print
    uint64_t log_from = 0;        // --ddr-log-from: first cycle to log
    uint32_t log_lo = 0, log_hi = 0;   // --ddr-log-range: core byte addresses [lo, hi) to log (equal: all)
    // The core's own byte address for a DDR word address, and back.
    static uint32_t core_addr(uint32_t a) { return ((a - BASE) ^ (0x1FFu << 17)) << 3; }
    static uint32_t ddr_word(uint32_t core) { return BASE | (((core >> 3) ^ (0x1FFu << 17)) & (WORDS - 1)); }
    // Store bytes where ss20_loader would put them: file byte k of each 8
    // in bits 63-8k:56-8k (big-endian, as the interconnect carries them).
    void backdoor(uint32_t core, const uint8_t *p, size_t n) {
        for (size_t i = 0; i < n; i += 8) {
            uint64_t w = 0;
            for (int k = 0; k < 8 && i + k < n; k++) w |= (uint64_t)p[i + k] << (8 * (7 - k));
            at(ddr_word(core + i)) = w;
        }
    }
    uint32_t lfsr = 0xACE1u;
    uint64_t oob = 0;

    Ddr() {
        mem = (uint64_t *)mmap(nullptr, WORDS * 8, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (mem == MAP_FAILED) { perror("mmap"); exit(3); }
    }
    static const uint32_t BASE = 0x04000000;     // word address of 0x2000_0000
    // The Ethernet mailbox (eth_hps), ARM physical 0x1FF0_0000, 64 KB
    static const uint32_t MB_BASE = 0x1FF00000u / 8, MB_WORDS = 0x10000 / 8;
    uint64_t mbox[MB_WORDS] = {};
    uint64_t &at(uint32_t a) {
        if (a >= MB_BASE && a < MB_BASE + MB_WORDS) return mbox[a - MB_BASE];
        a -= BASE;
        if (a >= WORDS) {
            if (oob++ < 4) fprintf(stderr, "[sim] DDR word address %08x outside the FPGA window\n", a + BASE);
            static uint64_t dummy;
            dummy = 0;
            return dummy;
        }
        return mem[a];
    }
    bool rnd() { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u); return lfsr & 1; }

    // Called after the rising edge with the outputs the core showed before it
    // and the busy it was given; drives the inputs for the next cycle.
    void step(Vsim_top *t, uint64_t cyc, bool rd, bool we, uint32_t addr, int bc,
              uint64_t din, uint8_t be, bool busy_was) {
        if (!busy_was) {
            if (log_left && cyc >= log_from && (we ? wr_left == 0 : rd) &&
                (log_lo == log_hi || (core_addr(addr) >= log_lo && core_addr(addr) < log_hi))) {
                log_left--;
                if (we)
                    fprintf(stderr, "[ddr] %" PRIu64 " WR %08x x%d be=%02x d=%016" PRIx64 "\n", cyc,
                            core_addr(addr), bc, be, din);
                else
                    fprintf(stderr, "[ddr] %" PRIu64 " RD %08x x%d\n", cyc, core_addr(addr), bc);
            }
            if (we) {
                if (wr_left == 0) { wr_addr = addr; wr_left = bc ? bc : 1; }
                uint64_t &w = at(wr_addr);
                for (int i = 0; i < 8; i++)
                    if (be & (1 << i)) w = (w & ~(0xFFull << (8 * i))) | (din & (0xFFull << (8 * i)));
                wr_addr++;
                wr_left--;
            } else if (rd) {
                rq.push_back({addr, bc ? bc : 1, cyc + DDR_LAT});
            }
        }
        t->ddr_dout_ready = 0;
        // --ddr-gaps: the board's DDR port does not deliver the beats of a
        // burst back to back under load (the HPS shares the SDRAM with
        // the ARM side); a bubble on about half the cycles reproduces it.
        if (!rq.empty() && rq.front().start <= cyc && !(gaps && rnd())) {
            Rd &r = rq.front();
            t->ddr_dout = at(r.addr);
            t->ddr_dout_ready = 1;
            r.addr++;
            if (--r.count == 0) rq.pop_front();
        }
        t->ddr_busy = (rq.size() >= DDR_QUEUE) || (stress && rnd() && rnd());
    }
};

// ---------------------------------------------------------------------------
// Main's side of the Ethernet mailbox (Main: support/sun/sun_enet.cpp;
// layout in rtl/mister/eth_hps.sv). Every POLL cycles: frames the core
// posted in the TX ring are logged and, with --eth-loop, sent back through
// the RX ring (with the FCS and the LADRF index, as Main adds them), so the
// LANCE receives what it sent.
struct EthHost {
    static const uint64_t MAGIC = 0x5353455448303032ull;   // "SSETH002"
    enum { W_MAGIC, W_GEN, W_TXW, W_TXR, W_RXW, W_RXR, W_MAC };
    static const uint32_t W_TX = 0x1000 / 8, W_RX = 0x5000 / 8, TX_RING = 8, RX_RING = 16,
                          POLL = 2000;
    bool loop = false;
    uint64_t gen = ~0ull, tx_rd = 0, tx_frames = 0, rx_frames = 0;
    std::deque<std::vector<uint8_t>> pending;

    static uint32_t crc_le(const uint8_t *p, size_t n) {
        uint32_t c = 0xFFFFFFFFu;
        for (size_t i = 0; i < n; i++) {
            c ^= p[i];
            for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1u));
        }
        return c;
    }
    static void get(const uint64_t *w, uint8_t *p, size_t n) {
        for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(w[i / 8] >> (8 * (i % 8)));
    }
    static void put(uint64_t *w, const uint8_t *p, size_t n) {
        for (size_t i = 0; i < (n + 7) / 8; i++) w[i] = 0;
        for (size_t i = 0; i < n; i++) w[i / 8] |= (uint64_t)p[i] << (8 * (i % 8));
    }
    void step(Ddr &d, uint64_t cyc) {
        if (cyc % POLL) return;
        uint64_t *m = d.mbox;
        if (m[W_MAGIC] != MAGIC) return;
        if (m[W_GEN] != gen) {
            gen = m[W_GEN];
            tx_rd = m[W_TXR];
            pending.clear();
            fprintf(stderr, "[eth] mailbox up, generation %08" PRIx64 "\n", gen);
        }
        while ((uint32_t)m[W_TXW] != (uint32_t)tx_rd) {
            uint64_t *slot = &m[W_TX + 256 * (tx_rd % TX_RING)];
            unsigned len = slot[0] & 0x7FF;
            std::vector<uint8_t> f(len);
            get(slot + 1, f.data(), len);
            tx_frames++;
            fprintf(stderr, "[eth] TX %u bytes, %02x:%02x:%02x:%02x:%02x:%02x <- "
                    "%02x:%02x:%02x:%02x:%02x:%02x type %02x%02x\n", len,
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11],
                    f[12], f[13]);
            // type 0x88b6 (ethtest's t_eth_oversize): sent back 1600 bytes
            // long, past what a guest's buffer holds; eth_hps must drop it
            if (len >= 14 && f[12] == 0x88 && f[13] == 0xb6) f.resize(1600, 0);
            if (loop) pending.push_back(f);
            tx_rd++;
            m[W_TXR] = tx_rd;
        }
        while (!pending.empty() && (uint32_t)(m[W_RXW] - m[W_RXR]) < RX_RING) {
            std::vector<uint8_t> f = pending.front();
            pending.pop_front();
            if (f.size() < 60) f.resize(60, 0);
            uint32_t fcs = ~crc_le(f.data(), f.size());
            for (int k = 0; k < 4; k++) f.push_back((uint8_t)(fcs >> (8 * k)));
            unsigned hash = crc_le(f.data(), 6) >> 26;
            uint64_t *slot = &m[W_RX + 256 * (m[W_RXW] % RX_RING)];
            put(slot + 1, f.data(), f.size());
            slot[0] = f.size() | ((uint64_t)hash << 16);
            m[W_RXW]++;
            rx_frames++;
        }
    }
};

// ---------------------------------------------------------------------------
// hps_io SD-block service for one image. The core raises sd_rd/sd_wr with
// sd_lba (and, for the SCSI slots 0-2, sd_blk_cnt = blocks - 1); we raise
// sd_ack for the length of the transfer (the core drops its request when it
// sees ack) and move 256 16-bit words per block through the buffer port,
// low byte first, at hps_io's pace, sd_buff_addr counting through them all.
struct Disk {
    FILE *f = nullptr;
    std::string path;
    uint64_t size = 0;
    bool ro = false;
    uint64_t reads = 0, writes = 0;
    bool open(const std::string &p, bool readonly) {
        path = p;
        ro = readonly;
        f = fopen(p.c_str(), readonly ? "rb" : "r+b");
        if (!f) { perror(p.c_str()); return false; }
        fseeko(f, 0, SEEK_END);
        size = ftello(f);
        return true;
    }
};

// Main's windows on the CD slot (support/sun/sun_cdrom.h), for a virtual
// disc: the image as track 1 (data), then cd_audio tracks of 150 frames
// (2 s) of audio, frame f's sample k being (f << 4) + k
static int cd_audio = 0;
static uint64_t cd_data_size = 0;

static void cd_toc_entry(uint8_t *e, int ctl, int trk, uint32_t lba)
{
    uint32_t a = lba + 150;
    e[0] = ctl; e[1] = trk; e[2] = a / 4500; e[3] = a / 75 % 60; e[4] = a % 75;
    e[5] = lba >> 16; e[6] = lba >> 8; e[7] = lba;
}

static void cd_window(uint32_t lba, uint8_t *buf, int sz)
{
    memset(buf, 0, sz);
    uint32_t data = (uint32_t)(cd_data_size / 2048);
    if (lba == 0xC0000000u) {
        cd_toc_entry(buf + 8, 0x14, 1, 0);
        for (int i = 0; i < cd_audio; i++)
            cd_toc_entry(buf + 16 + 8 * i, 0x10, 2 + i, data + 150 * i);
        cd_toc_entry(buf + 16 + 8 * cd_audio, 0x10, 0xAA, data + 150 * cd_audio);
        buf[0] = 1; buf[1] = 1 + cd_audio; buf[2] = 2 + cd_audio; buf[3] = 1;
        return;
    }
    if (lba >= 0xC0000000u) return;
    uint64_t off = (uint64_t)(lba - 0x80000000u) * 512;
    for (int pos = 0; pos < sz; pos += 2, off += 2) {
        uint32_t f = off / 2560, fo = off % 2560;
        if (fo >= 2352 || f < data || f >= data + 150u * cd_audio) continue;
        uint16_t v = (uint16_t)((f << 4) + fo / 2);
        buf[pos] = v & 0xFF; buf[pos + 1] = v >> 8;
    }
}

struct SdHost {
    enum { IDLE, DELAY, RD_WORD, WR_WORD, END } st = IDLE;
    int slot = -1, word = 0, sub = 0, wait = 0, nblk = 1;
    int latency = 40;   // request to ack: Main's poll and SD latency, shortened
    bool sd_log = false;   // --sd-log: print every block request
    uint64_t cyc_now = 0;
    bool is_write = false;
    uint32_t lba = 0;
    uint8_t buf[16384];
    Disk *disks[4] = {nullptr, nullptr, nullptr, nullptr};

    void step(Vsim_top *t, uint8_t sd_rd, uint8_t sd_wr, const uint32_t lbas[4],
              uint16_t din[4]) {
        t->sd_buff_wr = 0;
        switch (st) {
        case IDLE:
            for (int n = 0; n < 4; n++) {
                if (!((sd_rd | sd_wr) & (1 << n))) continue;
                slot = n;
                is_write = sd_wr & (1 << n);
                lba = lbas[n];
                nblk = n < 3 ? t->sd_blk_cnt + 1 : 1;
                if (sd_log) fprintf(stderr, "[sd] %" PRIu64 " slot %d %s lba %u x%d\n", cyc_now, n, is_write ? "WR" : "RD", lba, nblk);
                memset(buf, 0, sizeof buf);
                Disk *d = disks[n];
                if (!is_write && n == 2 && cd_audio && lba >= 0x80000000u) {
                    cd_window(lba, buf, 512 * nblk);
                } else if (!is_write && d && d->f && (uint64_t)lba * 512 < d->size) {
                    fseeko(d->f, (off_t)lba * 512, SEEK_SET);
                    if (fread(buf, 1, 512 * nblk, d->f) == 0) {}
                    d->reads++;
                }
                st = DELAY;
                wait = latency;
                break;
            }
            break;
        case DELAY:
            if (--wait > 0) break;
            t->sd_ack = 1 << slot;
            t->sd_buff_addr = 0;
            word = 0;
            sub = 0;
            st = is_write ? WR_WORD : RD_WORD;
            break;
        case RD_WORD:
            // addr and data, then the write strobe, then the next address
            if (sub == 0) {
                t->sd_buff_addr = word;
                t->sd_buff_dout = buf[2 * word] | (buf[2 * word + 1] << 8);
            } else if (sub == 1) {
                t->sd_buff_wr = 1;
            }
            if (++sub == 4) {
                sub = 0;
                if (++word == 256 * nblk) { st = END; wait = 4; }
            }
            break;
        case WR_WORD:
            if (sub == 0) t->sd_buff_addr = word;
            else if (sub == 3) {
                buf[2 * word] = din[slot] & 0xFF;
                buf[2 * word + 1] = din[slot] >> 8;
            }
            if (++sub == 4) {
                sub = 0;
                if (++word == 256 * nblk) {
                    Disk *d = disks[slot];
                    if (d && d->f && !d->ro && (uint64_t)lba * 512 < d->size) {
                        fseeko(d->f, (off_t)lba * 512, SEEK_SET);
                        fwrite(buf, 1, 512 * nblk, d->f);
                        d->writes++;
                    }
                    st = END;
                    wait = 4;
                }
            }
            break;
        case END:
            if (--wait > 0) break;
            t->sd_ack = 0;
            st = IDLE;
            break;
        }
    }
};

// ---------------------------------------------------------------------------
// ttya at 115200 8N1: decode the core's TX line, and type into its RX line.
struct Uart {
    double bit;                    // cycles per bit
    // receiver (core -> us)
    int rx_state = -1;             // -1 idle, else bit index
    double rx_next = 0;
    int rx_byte = 0;
    int last_txd = 0;              // wait for the line to go idle first
    // transmitter (us -> core); BRK in the queue is a BREAK: the line low
    // for 30 bit times
    static const int BRK = -1;
    std::deque<int> tx_q;
    int tx_bit = -1;
    double tx_next = 0;
    int tx_byte = 0;
    int rxd = 1;

    explicit Uart(double cyc_per_bit) : bit(cyc_per_bit) {}

    // Returns a received character, or -1.
    int step_rx(uint64_t cyc, int txd) {
        int out = -1;
        if (rx_state < 0) {
            if (last_txd && !txd) { rx_state = 0; rx_next = cyc + bit * 1.5; rx_byte = 0; }
        } else if (cyc >= rx_next) {
            if (rx_state < 8) {
                rx_byte |= txd << rx_state;
                rx_state++;
                rx_next += bit;
            } else {
                out = rx_byte;       // stop bit position; framing not checked
                rx_state = -1;
            }
        }
        last_txd = txd;
        return out;
    }
    void step_tx(uint64_t cyc) {
        if (tx_bit < 0) {
            if (tx_q.empty() || cyc < tx_next) return;
            tx_byte = tx_q.front();
            tx_q.pop_front();
            tx_bit = 0;
            rxd = 0;                 // start bit
            tx_next = cyc + bit;
            if (tx_byte == BRK) { tx_bit = 9; tx_next = cyc + bit * 30; }
        } else if (cyc >= tx_next) {
            if (tx_bit < 8) { rxd = (tx_byte >> tx_bit) & 1; tx_bit++; }
            else if (tx_bit == 8) { rxd = 1; tx_bit++; }            // stop bit
            else if (tx_byte == BRK && tx_bit == 9) { rxd = 1; tx_bit++; } // BREAK over
            else { tx_bit = -1; tx_next = cyc + bit * 2; return; }  // idle gap
            tx_next += bit;
        }
    }
};

// ---------------------------------------------------------------------------
// The last complete video frame, for --frame.
struct Video {
    std::vector<uint32_t> cur, last;
    int x = 0, y = 0, w = 0, h = 0, lw = 0, lh = 0;
    int last_de = 0, last_vs = 0;
    uint64_t frames = 0;
    void step(int r, int g, int b, int de, int vs) {
        if (vs && !last_vs) {
            if (y > 0 && w > 0) { last = cur; lw = w; lh = y; frames++; }
            y = 0;
            x = 0;
        }
        if (de) {
            if (x == 0 && (int)cur.size() < (y + 1) * 2048) cur.resize((y + 1) * 2048);
            if (x < 2048) cur[y * 2048 + x] = (r << 16) | (g << 8) | b;
            x++;
        } else if (last_de) {
            if (x > w) w = x;
            y++;
            x = 0;
        }
        last_de = de;
        last_vs = vs;
    }
    bool save(const char *path) {
        if (!lw || !lh) return false;
        FILE *f = fopen(path, "wb");
        if (!f) return false;
        fprintf(f, "P6\n%d %d\n255\n", lw, lh);
        for (int yy = 0; yy < lh; yy++)
            for (int xx = 0; xx < lw; xx++) {
                uint32_t p = last[yy * 2048 + xx];
                uint8_t c[3] = {(uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p};
                fwrite(c, 1, 3, f);
            }
        fclose(f);
        return true;
    }
};

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

static void usage() {
    fprintf(stderr,
        "usage: Vsim_top [--rom FILE] [options]\n"
        "  --rom FILE          boot PROM image (downloaded as boot.rom, index 0; without\n"
        "                      one there is no download)\n"
        "  --hd0 FILE, --hd1 FILE, --cd FILE   SCSI images (--hd1 selects HD0+HD1)\n"
        "  --cd-audio N        the CD has N audio tracks of 2 s after the image (track 1):\n"
        "                      Main's track table and audio windows (CD audio)\n"
        "  --nvram FILE        the NVRAM image (8192 bytes; slot 3, read and written)\n"
        "  --ro                open the disk images read-only\n"
        "  --cycles N          stop after N cycles (k/M/G suffixes; default 200M)\n"
        "  --stop STR          end the run, exit 0, at the end of the line that prints STR\n"
        "  --fail STR          end the run, exit 1, at the end of the line that prints STR\n"
        "  --mark STR          print the cycle (stderr) each time the console prints STR\n"
        "  --send PAT=>TEXT    type TEXT on ttya once PAT has been printed (\\r etc.;\n"
        "                      \\B is a BREAK)\n"
        "  --log FILE          copy of the console output\n"
        "  --video             console on the screen (default: ttya)\n"
        "  --noautoboot        OSD AutoBoot OFF\n"
        "  --cg3               CG3 instead of TCX\n"
        "  --ram MB            memory size: 464 (default), 256, 128 or 64 (the OSD option)\n"
        "  --l2tlb             OSD L2 TLB On (the MMU's second-level TLB,\n"
        "                      used when software also sets MCNTL bit 6)\n"
        "  --frame FILE.ppm    save the last complete video frame at the end\n"
        "  --ram-fill BYTE     every RAM byte starts as BYTE (default 0; the board's DDR holds\n"
        "                      leftovers, which OpenBIOS's (undefined-defer) relies on)\n"
        "  --ddr-stress        random DDR waitrequest\n"
        "  --ddr-gaps          random bubbles between the beats of a DDR read burst\n"
        "  --sd-latency N      cycles from a block request to hps_io's ack (default 40;\n"
        "                      Main takes a millisecond or more: 20000 and up)\n"
        "  --eth               OSD Network on: the Ethernet mailbox runs, TX frames logged\n"
        "  --eth-loop          ... and every TX frame comes back as a received frame\n"
        "  --full-download     send the whole ROM through ioctl (slow; default: preload\n"
        "                      it into DDR and send only the last word)\n"
        "  --dl-gap N          cycles between download words (default 32)\n"
        "  --sd-log            print every SD block request (cycle, slot, LBA, count)\n"
        "  --ddr-log N         print the first N DDR commands (core addresses)\n"
        "  --ddr-log-from C    ... starting at cycle C\n"
        "  --ddr-log-range LO HI  ... only core byte addresses in [LO, HI) (hex)\n"
        "  --rtc 'YYYY-MM-DD hh:mm:ss'   RTC value (default 2026-01-01 00:00:00)\n"
        "  --trace FILE.vcd    waveform (model built with sim/build.sh --trace)\n"
        "  --trace-from N      start the waveform at cycle N\n"
        "  --quiet             do not echo the console to stdout\n"
        "  --progress          report speed every 10M cycles on stderr\n");
    exit(3);
}

static uint8_t bcd(int v) { return (uint8_t)(((v / 10) << 4) | (v % 10)); }

int main(int argc, char **argv) {
    std::string rom, hd[4], log_path, frame_path, trace_path;   // hd[3]: NVRAM
    std::vector<std::string> stops, fails, marks;
    struct Send { std::string pat, text; bool done; };
    std::vector<Send> sends;
    uint64_t max_cycles = 200000000ull, trace_from = 0, ddr_log = 0;
    int dl_gap = 32;
    uint64_t ddr_log_from = 0;
    uint32_t ddr_log_lo = 0, ddr_log_hi = 0;
    bool sd_log = false;
    int ram_sel = 0;              // --ram: the OSD memory option (0 = 464 MB)
    int ram_fill = -1;            // --ram-fill: every RAM byte starts as this (the board's DDR holds leftovers; the sim's is zeros)
    bool readonly = false, video = false, noautoboot = false, cg3 = false,
         l2tlb = false, quiet = false, progress = false, stress = false, gaps = false,
         full_download = false, eth = false, eth_loop = false;
    int sd_latency = 40;
    struct tm rtc_tm = {};
    rtc_tm.tm_year = 126; rtc_tm.tm_mon = 0; rtc_tm.tm_mday = 1;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { if (i + 1 >= argc) usage(); return argv[++i]; };
        if (a == "--rom") rom = next();
        else if (a == "--hd0") hd[0] = next();
        else if (a == "--hd1") hd[1] = next();
        else if (a == "--cd") hd[2] = next();
        else if (a == "--cd-audio") cd_audio = atoi(next().c_str());
        else if (a == "--nvram") hd[3] = next();
        else if (a == "--ro") readonly = true;
        else if (a == "--cycles") max_cycles = parse_count(next().c_str());
        else if (a == "--stop") stops.push_back(unescape(next()));
        else if (a == "--fail") fails.push_back(unescape(next()));
        else if (a == "--mark") marks.push_back(unescape(next()));
        else if (a == "--send") {
            std::string s = next();
            size_t p = s.find("=>");
            if (p == std::string::npos) usage();
            sends.push_back({unescape(s.substr(0, p)), unescape(s.substr(p + 2)), false});
        }
        else if (a == "--log") log_path = next();
        else if (a == "--video") video = true;
        else if (a == "--noautoboot") noautoboot = true;
        else if (a == "--cg3") cg3 = true;
        else if (a == "--ram") {
            int mb = (int)strtoul(next().c_str(), nullptr, 0);
            ram_sel = mb == 464 ? 0 : mb == 256 ? 1 : mb == 128 ? 2 : mb == 64 ? 3 : -1;
            if (ram_sel < 0) usage();
        }
        else if (a == "--l2tlb") l2tlb = true;
        else if (a == "--frame") frame_path = next();
        else if (a == "--ram-fill") ram_fill = (int)strtoul(next().c_str(), nullptr, 0) & 0xFF;
        else if (a == "--sd-log") sd_log = true;
        else if (a == "--ddr-stress") stress = true;
        else if (a == "--ddr-gaps") gaps = true;
        else if (a == "--eth") eth = true;
        else if (a == "--sd-latency") sd_latency = (int)parse_count(next().c_str());
        else if (a == "--eth-loop") eth = eth_loop = true;
        else if (a == "--full-download") full_download = true;
        else if (a == "--dl-gap") dl_gap = (int)parse_count(next().c_str());
        else if (a == "--ddr-log") ddr_log = parse_count(next().c_str());
        else if (a == "--ddr-log-from") ddr_log_from = parse_count(next().c_str());
        else if (a == "--ddr-log-range") { ddr_log_lo = strtoul(next().c_str(), nullptr, 16); ddr_log_hi = strtoul(next().c_str(), nullptr, 16); }
        else if (a == "--rtc") {
            if (!strptime(next().c_str(), "%Y-%m-%d %H:%M:%S", &rtc_tm)) usage();
        }
        else if (a == "--trace") trace_path = next();
        else if (a == "--trace-from") trace_from = parse_count(next().c_str());
        else if (a == "--quiet") quiet = true;
        else if (a == "--progress") progress = true;
        else if (a[0] == '+') ;   // a plusarg for the design ($value$plusargs)
        else usage();
    }
    std::vector<uint8_t> romdata;
    if (!rom.empty()) {
        FILE *f = fopen(rom.c_str(), "rb");
        if (!f) { perror(rom.c_str()); return 3; }
        uint8_t b[65536];
        size_t n;
        while ((n = fread(b, 1, sizeof b, f)) > 0) romdata.insert(romdata.end(), b, b + n);
        fclose(f);
        if (romdata.size() & 1) romdata.push_back(0xFF);
        if (romdata.size() < 131072) {
            // The loader only starts the machine after at least 128 KB.
            romdata.resize(131072, 0xFF);
        }
    }

    Disk disks[4];
    SdHost sd;
    sd.latency = sd_latency;
    for (int n = 0; n < 4; n++) {
        if (hd[n].empty()) continue;
        if (!disks[n].open(hd[n], readonly || n == 2)) return 3;
        if (n == 2) cd_data_size = disks[2].size;
        sd.disks[n] = &disks[n];
    }

    FILE *logf = nullptr;
    if (!log_path.empty() && !(logf = fopen(log_path.c_str(), "w"))) { perror(log_path.c_str()); return 3; }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsim_top *t = new Vsim_top{ctx};

#if VM_TRACE
    VerilatedVcdC *tfp = nullptr;
    if (!trace_path.empty()) ctx->traceEverOn(true);
#else
    if (!trace_path.empty()) { fprintf(stderr, "this model was built without --trace\n"); return 3; }
#endif

    // The OSD status word, bit for bit as on the board (rtl/machine/
    // ss20_osd.sv, scripts/setopt.sh); 0 is every option's default.
    {
        uint32_t st0 = 0;
        if (noautoboot) st0 |= 1u << 8;     // Auto boot Off
        if (!video) st0 |= 1u << 9;         // console on ttya
        if (cg3) st0 |= 1u << 10;           // CG3 (not offered: ss20_osd forces TCX)
        if (!l2tlb) st0 |= 1u << 17;        // L2 TLB Off (the board's default is On)
        if (!eth) st0 |= 1u << 24;          // Network Off (value 1)
        st0 |= (uint32_t)ram_sel << 22;     // memory: 464, 256, 128, 64 MB
        t->status[0] = st0;
        t->status[1] = t->status[2] = t->status[3] = 0;
    }
    t->uart_rxd = 1;
    t->ddr_busy = 0;
    t->ddr_dout_ready = 0;
    t->ioctl_download = 0;
    t->ioctl_wr = 0;
    t->ioctl_index = 0;
    t->ioctl_addr = 0;
    t->img_mounted = 0;
    t->sd_ack = 0;
    t->sd_buff_wr = 0;
    {
        // MiSTer RTC: BCD sec, min, hour, date, month, year, weekday; bit 64
        // toggles on each update.
        mktime(&rtc_tm);
        uint64_t v = (uint64_t)bcd(rtc_tm.tm_sec) | ((uint64_t)bcd(rtc_tm.tm_min) << 8) |
                     ((uint64_t)bcd(rtc_tm.tm_hour) << 16) | ((uint64_t)bcd(rtc_tm.tm_mday) << 24) |
                     ((uint64_t)bcd(rtc_tm.tm_mon + 1) << 32) | ((uint64_t)bcd(rtc_tm.tm_year % 100) << 40) |
                     ((uint64_t)bcd(rtc_tm.tm_wday + 1) << 48);
        t->rtc[0] = (uint32_t)v;
        t->rtc[1] = (uint32_t)(v >> 32);
        t->rtc[2] = 1;
    }

    Ddr ddr;
    if (ram_fill >= 0) memset(ddr.mem, ram_fill, Ddr::WORDS * 8);
    EthHost ethh;
    ethh.loop = eth_loop;
    ddr.stress = stress;
    ddr.gaps = gaps;
    ddr.log_left = ddr_log;
    ddr.log_from = ddr_log_from;
    sd.sd_log = sd_log;
    ddr.log_lo = ddr_log_lo; ddr.log_hi = ddr_log_hi;
    Uart uart((double)SIM_SYSFREQ / 115200.0);
    Video vid;
    std::string console;          // everything printed so far (tail kept)
    size_t send_from = 0;         // --send patterns match after this offset
    int result = 2, end_result = -1;
    const char *why = "cycle limit";

    // ROM download. The loader starts the machine when a download ends with
    // ioctl_addr >= 128 KB. Unless --full-download, the image is preloaded at
    // OBRAM (0x1D00_0000) and only its last word goes through ioctl; the
    // whole download, paced at 32 cycles a word, costs millions of cycles.
    const uint32_t OBRAM = 0x1D000000;
    size_t dl_pos = 0;
    if (!full_download && !romdata.empty()) {
        ddr.backdoor(OBRAM, romdata.data(), romdata.size());
        dl_pos = romdata.size() - 2;
    }
    int dl_phase = 0;             // 0 reset, 1 download, 2 mount, 3 run
    int dl_sub = 0;
    uint64_t phase_at = 0;
    int mount_slot = 0;

    double t0 = now_s(), tp = t0;
    uint64_t cyc = 0, pcyc = 0;
    t->reset = 1;
    t->clk = 0;
    t->eval();

    for (; cyc < max_cycles && !g_stop; cyc++) {
        // Sample what the core shows before this rising edge.
        bool rd = t->ddr_rd, we = t->ddr_we, busy = t->ddr_busy;
        uint32_t addr = t->ddr_addr;
        int bc = t->ddr_burstcnt;
        uint64_t din = t->ddr_din;
        uint8_t be = t->ddr_be;
        uint8_t sd_rd = t->sd_rd, sd_wr = t->sd_wr;
        uint32_t lbas[4] = {t->sd_lba0, t->sd_lba1, t->sd_lba2, t->sd_lba3};
        uint16_t sdin[4] = {t->sd_buff_din0, t->sd_buff_din1, t->sd_buff_din2,
                            t->sd_buff_din3};
        int txd = t->uart_txd;
        bool iowait = t->ioctl_wait;

        t->clk = 1;
        t->eval();
#if VM_TRACE
        if (!trace_path.empty() && !tfp && cyc >= trace_from) {
            tfp = new VerilatedVcdC;
            t->trace(tfp, 99);
            tfp->open(trace_path.c_str());
        }
        if (tfp) tfp->dump(cyc * 2 + 1);
#endif

        // Models, driving the inputs for the next cycle.
        ddr.step(t, cyc, rd, we, addr, bc, din, be, busy);
        if (eth) ethh.step(ddr, cyc);
        sd.cyc_now = cyc;
        sd.step(t, sd_rd, sd_wr, lbas, sdin);
        vid.step(t->vga_r, t->vga_g, t->vga_b, t->vga_de, t->vga_vs);

        switch (dl_phase) {
        case 0:                       // reset, then start the download
            // Main may hold the core in reset while it sends the boot
            // PROM (the board's first phase-4 bring-up: a loader that
            // ignored downloads in reset never started): the reset is held
            // through the download here, and released after it
            if (cyc == 16 && romdata.empty()) t->reset = 0;
            // Main mounts the remembered images before it downloads the ROM;
            // the NVRAM's (slot 3) loads meanwhile.
            if (cyc == 32 && sd.disks[3]) {
                t->img_size = disks[3].size;
                t->img_readonly = disks[3].ro;
                t->img_mounted = 1 << 3;
            }
            if (cyc == 48) t->img_mounted = 0;
            // hps_io raises ioctl_download well before the first word; the
            // loader needs a few cycles to enter its download state.
            if (cyc == 64) t->ioctl_download = !romdata.empty();
            if (cyc == 80) { dl_phase = romdata.empty() ? 2 : 1; phase_at = cyc; }
            break;
        case 1:                       // 16-bit words, spaced as hps_io would
            if (dl_sub == 0 && !iowait) {
                if (dl_pos >= romdata.size()) {
                    t->ioctl_download = 0;   // ioctl_addr keeps the last address
                    t->reset = 0;
                    dl_phase = 2;
                    phase_at = cyc;
                    break;
                }
                t->ioctl_addr = dl_pos;
                t->ioctl_dout = romdata[dl_pos] | (romdata[dl_pos + 1] << 8);
                t->ioctl_wr = 1;
                dl_pos += 2;
                dl_sub = 1;
            } else if (dl_sub > 0) {
                t->ioctl_wr = 0;
                // Cycles from one word to the next (--dl-gap). Main does not
                // wait on ioctl_wait inside a block, so this also tests how
                // much DDR stall the loader tolerates.
                if (++dl_sub >= dl_gap) dl_sub = 0;
            }
            break;
        case 2:                       // mount the images, as Main does after the ROM
            t->img_mounted = 0;
            if (cyc < phase_at + 32) break;
            phase_at = cyc;
            while (mount_slot < 3 && !sd.disks[mount_slot]) mount_slot++;
            if (mount_slot == 3) { dl_phase = 3; break; }
            t->img_size = disks[mount_slot].size;
            t->img_readonly = disks[mount_slot].ro;
            t->img_mounted = 1 << mount_slot;
            mount_slot++;
            break;
        }

        int ch = uart.step_rx(cyc, txd);
        uart.step_tx(cyc);
        t->uart_rxd = uart.rxd;
        if (ch >= 0) {
            if (!quiet) { fputc(ch, stdout); fflush(stdout); }
            if (logf) { fputc(ch, logf); fflush(logf); }
            console += (char)ch;
            // A stop or fail string ends the run at the end of its line, so
            // the log keeps the whole line.
            for (auto &s : stops)
                if (end_result < 0 && console.size() >= s.size() &&
                    console.compare(console.size() - s.size(), s.size(), s) == 0) {
                    end_result = 0; why = "stop string";
                }
            for (auto &s : marks)
                if (console.size() >= s.size() &&
                    console.compare(console.size() - s.size(), s.size(), s) == 0)
                    fprintf(stderr, "\n[sim] mark '%s' at cycle %" PRIu64 "\n", s.c_str(), cyc);
            for (auto &s : fails)
                if (end_result < 0 && console.size() >= s.size() &&
                    console.compare(console.size() - s.size(), s.size(), s) == 0) {
                    end_result = 1; why = "fail string";
                }
            if (end_result >= 0 && (ch == '\n' || ch == '\r')) { result = end_result; g_stop = 1; }
            for (auto &s : sends) {
                if (s.done) continue;
                size_t p = console.find(s.pat, send_from);
                if (p != std::string::npos) {
                    for (char c : s.text)
                        uart.tx_q.push_back((uint8_t)c == 0xff ? Uart::BRK : (uint8_t)c);
                    s.done = true;
                    send_from = p + s.pat.size();
                    fprintf(stderr, "\n[sim] send after '%s' at cycle %" PRIu64 "\n", s.pat.c_str(), cyc);
                }
                break;               // in order: one pending send at a time
            }
        }

        t->clk = 0;
        t->eval();
#if VM_TRACE
        if (tfp) tfp->dump(cyc * 2 + 2);
#endif

        if (progress && cyc - pcyc >= 10000000ull) {
            double tn = now_s();
            fprintf(stderr, "[sim] %" PRIu64 "M cycles, %.0f kHz\n", cyc / 1000000,
                    (cyc - pcyc) / (tn - tp) / 1e3);
            tp = tn;
            pcyc = cyc;
        }
    }

    double el = now_s() - t0;
    if (end_result >= 0 && result == 2) result = end_result;   // line never ended
    else if (g_stop && result == 2) why = "interrupted";
    fprintf(stderr, "\n[sim] %s after %" PRIu64 " cycles (%.3f s of machine time), "
            "%.1f s, %.0f kHz; disk reads %" PRIu64 ", writes %" PRIu64 ", frames %" PRIu64 "\n",
            why, cyc, cyc / (double)SIM_SYSFREQ, el, cyc / el / 1e3,
            disks[0].reads + disks[1].reads + disks[2].reads,
            disks[0].writes + disks[1].writes, vid.frames);
    if (disks[3].f)
        fprintf(stderr, "[sim] NVRAM image: %" PRIu64 " sector reads, %" PRIu64 " writes\n",
                disks[3].reads, disks[3].writes);
    if (eth) fprintf(stderr, "[sim] Ethernet: %" PRIu64 " frames sent, %" PRIu64 " looped back\n",
                     ethh.tx_frames, ethh.rx_frames);
    if (ddr.oob) fprintf(stderr, "[sim] %" PRIu64 " DDR accesses outside the FPGA window\n", ddr.oob);
    if (!frame_path.empty() && !vid.save(frame_path.c_str()))
        fprintf(stderr, "[sim] no complete video frame to save\n");

#if VM_TRACE
    if (tfp) tfp->close();
#endif
    if (logf) fclose(logf);
    for (auto &d : disks) if (d.f) fclose(d.f);
    t->final();
    delete t;
    delete ctx;
    return result;
}
