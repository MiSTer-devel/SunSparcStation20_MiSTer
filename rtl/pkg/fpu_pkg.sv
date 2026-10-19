// SPDX-License-Identifier: GPL-2.0-or-later
//
// fpu_pkg: the types of the SPARC V8 floating-point unit.
//
// From: The SPARC Architecture Manual V8 §4.4 (the FSR: RD, TEM, NS, ver,
//   ftt, qne, fcc, aexc, cexc), §B.* FPop definitions (Table F-5 opf
//   encodings), IEEE 754-1985 (formats, rounding, exceptions).

package fpu_pkg;

  // FSR fields (V8 §4.4)
  typedef struct packed {
    logic [1:0] rd;      // 31:30 rounding direction: 0 nearest, 1 zero, 2 +inf, 3 -inf
    logic [1:0] rsvd1;   // 29:28
    logic [4:0] tem;     // 27:23 trap enable mask: NV OF UF DZ NX
    logic       ns;      // 22 non-standard mode (reads 0 here)
    logic [1:0] rsvd2;   // 21:20
    logic [2:0] ver;     // 19:17 (0 on SuperSPARC)
    logic [2:0] ftt;     // 16:14 trap type
    logic       qne;     // 13 queue not empty
    logic       rsvd3;   // 12
    logic [1:0] fcc;     // 11:10 condition code: 0 =, 1 <, 2 >, 3 unordered
    logic [4:0] aexc;    // 9:5 accrued exceptions
    logic [4:0] cexc;    // 4:0 current exceptions
  } fsr_t;

  // Exception flags, the bit order of cexc/aexc/TEM: NV OF UF DZ NX
  localparam int FX_NV = 4, FX_OF = 3, FX_UF = 2, FX_DZ = 1, FX_NX = 0;

  // ftt codes
  localparam logic [2:0] FTT_NONE          = 3'd0;
  localparam logic [2:0] FTT_IEEE          = 3'd1;
  localparam logic [2:0] FTT_UNFINISHED    = 3'd2;
  localparam logic [2:0] FTT_UNIMPLEMENTED = 3'd3;
  localparam logic [2:0] FTT_SEQUENCE      = 3'd4;

  // Rounding modes
  localparam logic [1:0] RD_NEAREST = 2'd0;
  localparam logic [1:0] RD_ZERO    = 2'd1;
  localparam logic [1:0] RD_PINF    = 2'd2;
  localparam logic [1:0] RD_MINF    = 2'd3;

  // opf codes (Table F-5)
  localparam logic [8:0] OPF_FMOVS  = 9'h001;
  localparam logic [8:0] OPF_FNEGS  = 9'h005;
  localparam logic [8:0] OPF_FABSS  = 9'h009;
  localparam logic [8:0] OPF_FSQRTS = 9'h029;
  localparam logic [8:0] OPF_FSQRTD = 9'h02A;
  localparam logic [8:0] OPF_FSQRTQ = 9'h02B;
  localparam logic [8:0] OPF_FADDS  = 9'h041;
  localparam logic [8:0] OPF_FADDD  = 9'h042;
  localparam logic [8:0] OPF_FADDQ  = 9'h043;
  localparam logic [8:0] OPF_FSUBS  = 9'h045;
  localparam logic [8:0] OPF_FSUBD  = 9'h046;
  localparam logic [8:0] OPF_FSUBQ  = 9'h047;
  localparam logic [8:0] OPF_FMULS  = 9'h049;
  localparam logic [8:0] OPF_FMULD  = 9'h04A;
  localparam logic [8:0] OPF_FMULQ  = 9'h04B;
  localparam logic [8:0] OPF_FDIVS  = 9'h04D;
  localparam logic [8:0] OPF_FDIVD  = 9'h04E;
  localparam logic [8:0] OPF_FDIVQ  = 9'h04F;
  localparam logic [8:0] OPF_FSMULD = 9'h069;
  localparam logic [8:0] OPF_FDMULQ = 9'h06E;
  localparam logic [8:0] OPF_FITOS  = 9'h0C4;
  localparam logic [8:0] OPF_FDTOS  = 9'h0C6;
  localparam logic [8:0] OPF_FQTOS  = 9'h0C7;
  localparam logic [8:0] OPF_FITOD  = 9'h0C8;
  localparam logic [8:0] OPF_FSTOD  = 9'h0C9;
  localparam logic [8:0] OPF_FQTOD  = 9'h0CB;
  localparam logic [8:0] OPF_FITOQ  = 9'h0CC;
  localparam logic [8:0] OPF_FSTOQ  = 9'h0CD;
  localparam logic [8:0] OPF_FDTOQ  = 9'h0CE;
  localparam logic [8:0] OPF_FSTOI  = 9'h0D1;
  localparam logic [8:0] OPF_FDTOI  = 9'h0D2;
  localparam logic [8:0] OPF_FQTOI  = 9'h0D3;
  // FPop2
  localparam logic [8:0] OPF_FCMPS  = 9'h051;
  localparam logic [8:0] OPF_FCMPD  = 9'h052;
  localparam logic [8:0] OPF_FCMPQ  = 9'h053;
  localparam logic [8:0] OPF_FCMPES = 9'h055;
  localparam logic [8:0] OPF_FCMPED = 9'h056;
  localparam logic [8:0] OPF_FCMPEQ = 9'h057;

  // The unpacked operand: value = (-1)^sign * man * 2^(exp - 52), man
  // normalised with its leading one at bit 52 (zero for a zero).
  typedef struct packed {
    logic        sign;
    logic signed [13:0] exp;    // unbiased
    logic [52:0] man;
    logic        zero, inf, nan, snan;
  } fp_t;

  // The result before rounding: value = (-1)^sign * {man, sticky} * 2^(exp - 55),
  // man a 58-bit integer (leading one anywhere; the rounder normalises).
  typedef struct packed {
    logic        sign;
    logic signed [13:0] exp;
    logic [57:0] man;
    logic        sticky;
  } fp_wide_t;

  // The IU-FPU interface (docs/arch/cpu.md §1.7): the IU dispatches an
  // FPop when it commits, moves data for FP loads/stores, and reports an
  // fp_exception trap taken; the FPU reports busy and its exception state.
  typedef struct packed {
    logic        fpop_valid;     // an FPop commits: execute it
    logic [31:0] fpop_inst;
    logic [31:0] fpop_pc;
    logic        trap_taken;     // the IU took fp_exception on an FP instruction
    logic [4:0]  rd_addr;        // register read for an FP store
    logic        wr_valid;       // register write from an FP load
    logic [4:0]  wr_addr;
    logic        wr_dbl;
    logic [63:0] wr_data;        // {even, odd}; a single in [31:0]
    logic        fsr_wr;         // ldfsr
    logic [31:0] fsr_wdata;
    logic        fq_pop;         // stdfq committed
  } fpu_req_t;

  typedef struct packed {
    logic        busy;           // an FPop executes (or its result lands): hold FP instructions
    logic        exc_pending;    // fp_exception_pending: the next FP instruction traps
    logic        exc_state;      // fp_exception: only FP stores may run
    logic [63:0] rd_data;        // the pair at rd_addr[4:1]
    logic [31:0] fsr;
    logic [63:0] fq;             // the front entry: {address, instruction}
  } fpu_rsp_t;

endpackage
