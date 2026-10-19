// SPDX-License-Identifier: GPL-2.0-or-later
//
// mmu_pkg: the types of the SRMMU and the caches (docs/arch/mmu.md).
//
// From: The SPARC Architecture Manual V8 Appendix H (PTE/PTD formats,
//   the SFSR fields, fault types, access types), the Viking (TMS390Z50)
//   user documentation §4.11 (the TLB image of ASI 6, MCNTL), Sun-4M
//   System Architecture §4; docs/arch/mmu-notes.md for the digest.

package mmu_pkg;

  // Access type, the SFSR's AT field: {store, instruction, supervisor}
  typedef logic [2:0] at_t;
  localparam at_t AT_LD_UD = 3'd0, AT_LD_SD = 3'd1, AT_LD_UI = 3'd2, AT_LD_SI = 3'd3,
                  AT_ST_UD = 3'd4, AT_ST_SD = 3'd5, AT_ST_UI = 3'd6, AT_ST_SI = 3'd7;

  // Fault types
  localparam logic [2:0] FT_NONE = 3'd0, FT_INVALID = 3'd1, FT_PROT = 3'd2, FT_PRIV = 3'd3,
                         FT_TRANS = 3'd4, FT_BUS = 3'd5, FT_INTERNAL = 3'd6;

  // MCNTL bits (Viking §4.11.11.1)
  localparam int MC_PF = 18, MC_TC = 16, MC_AC = 15, MC_SE = 14, MC_BM = 13, MC_PE = 12,
                 MC_MB = 11, MC_SB = 10, MC_IE = 9, MC_DE = 8, MC_PSO = 7, MC_L2 = 6,
                 MC_NF = 1, MC_EN = 0;
  localparam logic [31:0] MCNTL_RESET = 32'h0100_2800;   // IMPL 0 VER 1, BM, MB
  localparam logic [31:0] MCNTL_WMASK = 32'h0005_F7C3;   // PF TC AC SE BM PE SB IE DE PSO bit6 NF EN

  // A TLB entry as the ASI 6 image keeps it (Viking §4.11.12)
  typedef struct packed {
    logic [19:0] vtag;       // VA[31:12]
    logic [15:0] ctx;
    logic [23:0] ppn;        // PA[35:12]
    logic        c, m, v;    // the image's bits 7, 6, 5
    logic [2:0]  acc;
    logic [1:0]  lvl;        // 0 = 4 GB, 1 = 16 MB, 2 = 256 KB, 3 = 4 KB
    logic        lock;
  } tlb_entry_t;

  /* verilator lint_off UNUSEDSIGNAL */   // the functions use the fields they need
  function automatic logic [31:0] tlb_pte_image(input tlb_entry_t e);
    return {e.ppn, e.c, e.m, e.v, e.acc, e.lvl};
  endfunction

  // A translation request from a side: the VA, the access type, and
  // whether a fault is reported (NF rule)
  typedef struct packed {
    logic        valid;
    logic [31:0] va;
    at_t         at;
    logic        no_fault;    // NF applies to this ASI (not ASI 9, not a fetch)
  } xlat_req_t;

  typedef struct packed {
    logic        hit;         // pa valid this cycle (TLB hit, MMU off, boot mode)
    logic        miss;        // walk needed
    logic        fault;       // permission fault on a hit (SFSR written this cycle)
    logic        busy;        // no answer: the one lookup port served the data side; retry
    logic [35:0] pa;
    logic        pte_c;       // the PTE's C bit (informational; E3 caches RAM anyway)
    logic [2:0]  acc;         // the entry's ACC (for a side's own translation cache)
    logic        m;           // the entry's M bit (likewise: a store may use the copy only with M set)
  } xlat_rsp_t;

  // The physical address space rule for the caches (docs/arch/mmu.md §3)
  function automatic logic cacheable_pa(input logic [35:0] pa);
    return (pa[35:29] == 7'd0) ||                 // RAM, the first 512 MB of space 0
           (pa[35:24] == 12'hFF0);                // the boot PROM
  endfunction

  // The V8 §H.5 fault for an access type and ACC on a valid entry:
  // 0 none, FT_PROT, FT_PRIV
  function automatic logic [2:0] acc_fault(input at_t at, input logic [2:0] acc);
    case (at)
      AT_LD_UD: case (acc) 3'd4: return FT_PROT; 3'd6, 3'd7: return FT_PRIV; default: return FT_NONE; endcase
      AT_LD_SD: case (acc) 3'd4: return FT_PROT; default: return FT_NONE; endcase
      AT_LD_UI: case (acc) 3'd0, 3'd1, 3'd5: return FT_PROT; 3'd6, 3'd7: return FT_PRIV; default: return FT_NONE; endcase
      AT_LD_SI: case (acc) 3'd0, 3'd1, 3'd5: return FT_PROT; default: return FT_NONE; endcase
      AT_ST_UD: case (acc) 3'd0, 3'd2, 3'd4, 3'd5: return FT_PROT; 3'd6, 3'd7: return FT_PRIV; default: return FT_NONE; endcase
      AT_ST_SD: case (acc) 3'd0, 3'd2, 3'd4, 3'd6: return FT_PROT; default: return FT_NONE; endcase
      AT_ST_UI: case (acc) 3'd0, 3'd1, 3'd2, 3'd4, 3'd5: return FT_PROT; 3'd6, 3'd7: return FT_PRIV; default: return FT_NONE; endcase
      default:  case (acc) 3'd0, 3'd1, 3'd2, 3'd4, 3'd5, 3'd6: return FT_PROT; default: return FT_NONE; endcase
    endcase
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

endpackage
