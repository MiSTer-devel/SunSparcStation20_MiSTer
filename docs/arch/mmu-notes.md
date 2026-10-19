# SRMMU, L1 caches and MMU control space: reference digest for the SS20 core

Facts gathered for the design of the phase 3 memory management unit (SRMMU),
the L1 instruction and data caches and the SuperSPARC-compatible ASI control
space of the SS20 CPU ([VERILOG-PLAN.md](../VERILOG-PLAN.md) §2, §3 phase 3).
Each fact names its source. The digest gives no design advice. Where the
sources disagree, it says so and gives each side. It is the companion of
[iu-notes.md](iu-notes.md), whose §4.6, §4.7 and §6 already cover the IU side
of error mode, reset, MCNTL and access errors; this digest repeats only what
the MMU design needs.

## Sources and how they are cited

| Short name | Document | Where |
|---|---|---|
| **V8** | *The SPARC Architecture Manual, Version 8*, Appendix H (SPARC Reference MMU) and Appendix I (Suggested ASI Assignments) | `scratch/reference/cpu/sparcv8.pdf`. Cited by section/table/figure. Line numbers refer to a `pdftotext` extraction (`sparcv8.txt`), which is not in the repository. That extraction prints "−" as `<` |
| **Viking** | *The Viking Microprocessor (TI TMS390Z50) User Documentation*, Sun 800-4510-02, Rev 2.00, Nov 1990, with its errata list (end of the PDF) | `scratch/reference/cpu/800-4510-02_…pdf`. Cited by section/table. PDF page = document page + 18. The PDF is a scan; bit tables quoted here were checked against page images, not only the OCR text |
| **SS-II** | *SuperSPARC II Addendum* (STP1021), Rev 1.3, Dec 1994. It documents SuperSPARC II and, by difference, SuperSPARC | `scratch/reference/text/STP1021UG.txt:line` |
| **Sun-4M** | *Sun-4M System Architecture* | `scratch/reference/text/Sun4M_SystemArchitecture_edited2.txt:line` |
| **QEMU** | QEMU `target/sparc/` | `scratch/reference/emulators/qemu/target/sparc/<file>:line` |
| **Linux** | Linux `arch/sparc` | `scratch/reference/emulators/linux/arch/sparc/<path>:line` |
| **NetBSD** | NetBSD `sys/arch/sparc` | `scratch/reference/emulators/netbsd/sys/arch/sparc/<path>:line` |
| **OBP** | OBP 2.25 disassembly notes | `docs/rom-disassembly/ss20-obp-2.25/<file>.md:line` |
| **tests** | the project's CPU suite | `tests/cpu/…:line` |
| **PLAN** | `docs/VERILOG-PLAN.md` | § and line |

**Which chip.** The 1990 Viking manual describes the TMS390Z50 that the SS20
calls "SuperSPARC" (OBP prints "TMS390Z50(3.x)", iu-notes §6.1). Where the
manual (Rev 2.00) and later material differ, the digest says which is which.
Several registers the task list names (ASI 4 VA 0x1000, the ASI 0x10-0x14
flushes, ASI 5 and 7) are **not in the Viking manual's ASI table** (Viking
Table 4-19 lists 0x10-0x1F, 0x05 and 0x07 as "Reserved"); §2 gives what each
other source says about them.

---

## 1. The SPARC Reference MMU (V8 Appendix H)

### 1.1 Addresses and table formats

- **Translation:** a 32-bit VA plus the context number → a 36-bit PA
  (V8 §H.3, Figure H-2; Viking §4.11.1). PA[11:0] = VA[11:0] always
  (V8 §H.3).
- **VA fields** (V8 Figure H-4; Viking Figure 4-3):

  | Bits | Field | Indexes |
  |---|---|---|
  | 31:24 | Index 1 | level-1 table, 256 entries |
  | 23:18 | Index 2 | level-2 table, 64 entries |
  | 17:12 | Index 3 | level-3 table, 64 entries |
  | 11:0 | page offset | — |

- **Table sizes and alignment:** level 1 = 1024 bytes, level 2 = 256 bytes,
  level 3 = 256 bytes. Each table must be aligned on its own size
  (V8 §H.3 "Page Table Descriptors"; Viking §4.11.1 "Important Note").
- **PTD** (page table descriptor, Viking calls it PTP) (V8 Figure H-7;
  Viking §4.11.1):

  | Bits | Field |
  |---|---|
  | 31:2 | PTP: PA[35:6] of the next-level table |
  | 1:0 | ET = 1 |

  The PTP "appears on bits 35 through 6 of the physical address bus" (V8
  §H.3). So the next table address is `{PTP[31:2], 6'b0}` and the entry
  address within it is that base + index × 4.
- **PTE** (V8 Figure H-8; Viking §4.11.1):

  | Bits | Field | Meaning |
  |---|---|---|
  | 31:8 | PPN | PA[35:12] |
  | 7 | C | cacheable |
  | 6 | M | modified (set by the MMU on a write) |
  | 5 | R | referenced (set by the MMU on any access) |
  | 4:2 | ACC | access permissions (§1.3) |
  | 1:0 | ET | 2 = PTE |

- **ET encoding** (V8 §H.3; Viking §4.11.1): 0 invalid, 1 PTD, 2 PTE,
  3 reserved. SuperSPARC II reuses ET = 3 as "PTE with reversed byte order"
  on the data side; on SuperSPARC (I) it is reserved (SS-II
  `STP1021UG.txt:1160-1185`).
- **Large pages:** a PTE found before level 3 maps a linear region. The
  PPN low bits that the region covers are ignored by Viking ("the lower 6,
  12 or 20 bits respectively of the PPN are ignored", Viking §4.11.1 PPN).
  V8 instead requires them to be 0 ("the low-order 6 bits of PPN must all
  be zeros", V8 §H.3 "Page Table Entry") and forms the PA as the bitwise OR
  of PPN<<12 and the untranslated VA bits.

  | PTE found in | Maps | PA formation (Viking Figures 4-4..4-6) |
  |---|---|---|
  | context table (level 0) | 4 GB | PA[35:32] = PPN[23:20], PA[31:0] = VA[31:0] |
  | level-1 table | 16 MB (region) | PA[35:24] = PPN[23:12], PA[23:0] = VA[23:0] |
  | level-2 table | 256 KB (segment) | PA[35:18] = PPN[23:6], PA[17:0] = VA[17:0] |
  | level-3 table | 4 KB (page) | PA[35:12] = PPN, PA[11:0] = VA[11:0] |

  (V8 Table H-1 gives the four mapping sizes.)

### 1.2 Context table and the walk

- **Context table:** indexed by the context register; each entry is the
  root PTD (or a 4 GB PTE) for that context (V8 §H.3.1 "Contexts",
  Figure H-6). Its size is implementation-defined; it must be aligned on
  its size (V8 Figure H-11 text: 8 context bits → 1024-byte alignment).
- **V8 CTPR** (Figure H-11): bits 31:2 = context table pointer, appearing on
  PA[35:6] for the first fetch of a miss; bits 1:0 reserved.
- **Viking root-pointer address** (Viking §4.11.11.2, Figure 4-7):
  CTPR is "a 24 bit register", CTPR[31:8] (bits 7:0 read 0). The address of
  the root entry is

  `PA[35:18] = CTPR[31:14]`, `PA[17:12] = CTPR[13:8] | CTX[15:10]`,
  `PA[11:2] = CTX[9:0]`, `PA[1:0] = 0`.

  The context table must be aligned to its size: 10 or fewer context bits
  → 4 KB, 11 → 8 KB, 12 → 16 KB, 13 → 32 KB, 14 → 64 KB, 15 → 128 KB,
  16 → 256 KB (Viking §4.11.11.2 table). The CTPR[13:8] and CTX[15:10]
  fields are ORed in the figure ("CTP[13:8] or CTX[15:10]").
- **Context register:** V8 says 32 bits with an implementation-defined
  maximum one less than a power of two (V8 Figure H-12). Viking: 16 bits,
  CTX[15:0], bits 31:16 ignored on a write and read as 0 (Viking
  §4.11.11.2).
- **The walk** (V8 §H.3, §H.7 "Miss Processing"; Viking §4.11.1,
  §4.11.2):
  1. Read the context-table entry (level 0) at the address above.
  2. ET = 2 → 4 GB PTE, stop. ET = 1 → read the level-1 entry at
     `{PTP, 6'b0} + VA[31:24]*4`.
  3. ET = 2 → 16 MB PTE, stop. ET = 1 → level-2 entry at
     `{PTP, 6'b0} + VA[23:18]*4`.
  4. ET = 2 → 256 KB PTE, stop. ET = 1 → level-3 entry at
     `{PTP, 6'b0} + VA[17:12]*4`.
  5. Level 3 must be a PTE. A PTD at level 3 is a translation error (FT 4)
     (V8 §H.5 "translation error … a PTD is found in a level-3 page
     table").
  6. At any level: ET = 0 → invalid address error (FT 1); ET = 3 →
     translation error (FT 4); an external bus error on a table read →
     translation error (FT 4). The SFSR.L field gets the level of the entry
     (0-3) (V8 §H.5 L, FT; Viking §4.11.11.3 FT text).
- **Viking walk bus behaviour in MBus mode:** "All page tables should be
  treated as non cacheable in Viking direct MBUS systems … only level-1
  transactions are used to reference page tables." The walk holds the bus
  (lock bit set in the address phase) unless told to relinquish. Each level
  is a single-word READ (Viking §8.6.3). Table-walk data is never cached
  internally; in MBus mode the walk does not snoop the data cache, so "page
  tables must be accessed through non-cacheable memory space" and MCNTL.TC
  must be 0 (Viking §4.8.2 "Important Note", §4.11.11.1 TC).
- **Linear-mapping CAM:** the Viking TLB matches the four mapping sizes in
  one CAM lookup (Viking §4.11.2).

### 1.3 Access permissions (ACC) and the fault each access gets

- **ACC table** (V8 Figure H-8 text; Viking §4.11.1 ACC). User = ASI 8 or
  0xA; supervisor = ASI 9 or 0xB (V8):

  | ACC | User | Supervisor |
  |---|---|---|
  | 0 | Read only | Read only |
  | 1 | Read/Write | Read/Write |
  | 2 | Read/Execute | Read/Execute |
  | 3 | Read/Write/Execute | Read/Write/Execute |
  | 4 | Execute only | Execute only |
  | 5 | Read only | Read/Write |
  | 6 | No access | Read/Execute |
  | 7 | No access | Read/Write/Execute |

- **Access type (AT)** recorded in the SFSR (V8 §H.5; Viking §4.11.11.3):
  0 load user data, 1 load supervisor data, 2 load/execute user
  instruction, 3 load/execute supervisor instruction, 4 store user data,
  5 store supervisor data, 6 store user instruction, 7 store supervisor
  instruction. AT 6/7 and loads at AT 2/3 come from LDA/STA to ASI 8/9 (V8
  §H.5 AT).
- **FT for each AT × ACC** (V8 §H.5 table; "−" = no fault; V = 0 means the
  entry was invalid):

  | AT | V=0 | ACC 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
  |---|---|---|---|---|---|---|---|---|---|
  | 0 | 1 | − | − | − | − | 2 | − | 3 | 3 |
  | 1 | 1 | − | − | − | − | 2 | − | − | − |
  | 2 | 1 | 2 | 2 | − | − | − | 2 | 3 | 3 |
  | 3 | 1 | 2 | 2 | − | − | − | 2 | − | − |
  | 4 | 1 | 2 | − | 2 | − | 2 | 2 | 3 | 3 |
  | 5 | 1 | 2 | − | 2 | − | 2 | − | 2 | − |
  | 6 | 1 | 2 | 2 | 2 | − | 2 | 2 | 3 | 3 |
  | 7 | 1 | 2 | 2 | 2 | − | 2 | 2 | 2 | − |

  FT 1 = invalid address, 2 = protection, 3 = privilege violation.
  - **Disagreement:** Viking Table 4-12 (page 104) prints a different,
    six-row table (for example AT 0 / ACC 0 = 2). The Viking errata list
    says "Table 4-12 … had errors" and gives a corrected eight-row table
    (errata, "Page 104"); the OCR of the correction is too damaged to
    transcribe. The V8 table above is internally consistent with the ACC
    table.
- **Which trap:** an MMU fault on an instruction fetch →
  instruction_access_exception (tt 0x01); on a data access →
  data_access_exception (tt 0x09) (Viking §4.11.11.3, §4.13.4.3,
  §4.13.4.12).

### 1.4 Referenced and modified bits

- **V8 (§H.7):** any successful translation examines R; if R = 0 the MMU
  sets R in the cached PTE and the PTE in memory. A successful write
  translation examines M; if M = 0 it sets M in both. The updates must be
  atomic with respect to other page-table accesses and **synchronous**
  with the access: "the Modified bit must be set before a store to a
  location in a page becomes visible", for store, LDSTUB(A) and SWAP(A).
  Pass-through ASIs (0x20-0x2F) never set R or M (V8 §H.3 PTE M/R; §I.3
  ASI 0x20-0x2F).
- **Viking (§4.11.3, §4.11.3.1, §8.6.3):**
  - R is set when the page is accessed during miss handling, or by an
    entire probe. "If the referenced bit is already set, it is not set
    again."
  - M: on a store whose TLB entry has M = 0, M is set in the TLB and in
    memory.
  - R+M updates block the pipeline and force a store-buffer copy-out
    first. A copy-out error → data_store_error; the R/M update is not
    done and is restarted with the access.
  - Write method: setting R and M together uses a plain WRITE; setting R
    only uses an atomic SWAP (non-cacheable, locked), so that an R-only
    update cannot overwrite another processor's R+M update. "The only
    combinations that Viking will ever write back to the PTE are (R=1,M=0)
    and (R=1,M=1)."
  - In MBus mode: table reads are single-word READs; "Updates to R and M
    bits, or just M bits will be done with standard WRITE operations.
    Updates the the R bit only will be done with non-cacheable atomic
    swaps" (Viking §8.6.3).
- Viking §4.5.5 gives the software algorithm for safe PTE updates against
  the hardware R/M writes (swap the PTE to 0, flush all MMUs, OR in late
  R/M bits, loop).

### 1.5 Fault status and fault address registers (V8 §H.5, §H.6)

- **V8 SFSR layout** (Figure H-13): bits 31:18 reserved; 17:10 EBE
  (external bus error, implementation-defined bits); 9:8 L; 7:5 AT;
  4:2 FT; 1 FAV; 0 OW.
- **Viking MFSR layout** (Viking §4.11.11.3, checked on the page image):

  | Bit(s) | Name | Meaning |
  |---|---|---|
  | 31:18 | — | reserved, read 0 |
  | 17 | EM | error-mode (watchdog) reset taken |
  | 16 | CS | control space access error |
  | 15 | SB | store buffer error (data_store_error); sticky |
  | 14 | P | parity error (also sets UC) |
  | 13 | UD | undefined error: retry signalled with data ready |
  | 12 | UC | uncorrectable error (parity, ECC; MBus ERROR3) |
  | 11 | TO | time-out (MBus ERROR2) |
  | 10 | BE | bus error (MBus ERROR1) |
  | 9:8 | L | table level of the entry that caused the fault: 0 root (context table), 1, 2, 3 |
  | 7:5 | AT | access type (§1.3) |
  | 4:2 | FT | fault type |
  | 1 | FAV | fault address valid |
  | 0 | OW | overwrite |

  UD/UC/TO/BE are mutually exclusive (Viking §4.11.11.3). On the MBus,
  ERROR1 → BE, ERROR2 → TO, ERROR3 → UC; all RETRY replies are treated as
  ERROR3 (Viking §8.9.1).
- **FT codes** (V8 §H.5; Viking §4.11.11.3): 0 none, 1 invalid address,
  2 protection, 3 privilege violation, 4 translation error, 5 access bus
  error, 6 internal error, 7 reserved.
  - FT 1: invalid PTE or PTD found during a walk or a probe.
  - FT 4: external bus error while fetching a table entry, a reserved
    (ET = 3) entry, or a PTD at level 3. L records the level (V8 §H.5;
    Viking §4.11.11.3).
  - FT 5: an external bus error on a memory access that is not a table
    walk; EBE (Viking: UD/UC/TO/BE) records which.
  - FT 6: the MMU or a cache detected an internal inconsistency (Viking:
    multiple tag matches). Viking enters error mode → watchdog reset;
    after that only EM and FT are meaningful (Viking §4.11.11.3 "Error
    Mode and Internal Errors").
- **Priority when one access has several errors** (V8 Table H-8, highest
  first): 1 internal, 2 translation, 3 invalid address, 4 privilege
  violation, 5 protection, 6 access bus error.
- **Overwrite rules, V8 (§H.5):** three classes: instruction access, data
  access, translation-table access.
  - A second fault of the same class before the SFSR is read overwrites it
    and sets OW.
  - A data fault overwriting an instruction fault clears OW. An instruction
    fault may not overwrite a data fault.
  - A table-access fault overwriting an instruction or data fault clears
    OW. An instruction or data fault may not overwrite a table-access
    fault.
  - Only the data fault the CPU takes may be latched.
- **Overwrite rules, Viking (Table 4-10, Table 4-11):** "translation
  error" here is the high-priority class; Viking priorities are
  translation error 1, data access exception 2, instruction access
  exception 3.

  | Pending | New | OW | Recorded |
  |---|---|---|---|
  | translation | translation | set | translation |
  | translation | data | unchanged | data |
  | translation | instruction | unchanged | instruction |
  | data | translation | clear | translation |
  | data | data | set | data |
  | data | instruction | unchanged | instruction |
  | instruction | translation | clear | translation |
  | instruction | data | clear | data |
  | instruction | instruction | set | instruction |

  - **Disagreement:** V8 says an instruction fault may not overwrite a
    data fault and a data fault may not overwrite a table fault; the
    Viking table records the new instruction or data fault in those rows
    (with OW unchanged). Viking also says "The occurrence of a translation
    error can not be overwritten by any other errors … the MFSR.FT bit will
    continue to indicate the occurrence of a translation error", which
    matches V8 and contradicts its own table rows 2-3 (Viking §4.11.11.3
    "MFSR timing and operation").
- **Read clears:** "Reading the Fault Status Register clears it. Writes to
  the Fault Status Register are ignored" (V8 §H.5). Viking: read-only,
  cleared on a read, writes ignored at VA 0x300; read/write alias at VA
  0x1300 (Viking §4.11.11.3 "MFSR timing and operation"). The SB bit is
  sticky (not overwritten by later faults), cleared by a read or by a
  write to the 0x1300 alias (same section).
- **Viking FSR validity:** the MFSR may record a fault from a non-demand
  instruction prefetch that is never taken; it is guaranteed valid only
  after an instruction, data or store-buffer exception (Viking §4.11.11.3
  "MFSR timing and operation").
- **FAV:** set when the SFAR is valid. V8: the SFAR need not be valid for
  instruction faults, must be valid for data faults and translation
  errors (V8 §H.5 FAV). Viking: "Viking will never place instruction fault
  addresses in the FAR"; FAV is not set for a copy-back fault seen as a
  data_access_exception with the store buffer off (Viking §4.11.11.4 and
  the "Important Note" after it).
- **SFAR** (V8 §H.6, Figure H-14): the faulting VA, 32 bits, overwritten by
  the same priority as the SFSR; writes ignored. An implementation may
  latch only the VPN (low bits 0). For a translation error it is the VA
  whose translation was requested. Viking: read-only at VA 0x400, read/write
  alias at VA 0x1400; word access only (Viking §4.11.11.4).
- **NF (no-fault)** (V8 §H.4 Control Register NF; Viking §4.11.10,
  §4.11.11.1 NF; errata "Page 95"):
  - V8: with NF = 1 a fault on ASI 9 is reported as usual; a fault on any
    other ASI updates FSR and FAR but no trap is raised, and clearing NF
    later does not raise it.
  - Viking: with NF = 1 faults on ASIs 0x08 (alternate accesses only),
    0x0A, 0x0B and 0x20-0x2F are not reported; faults on ASI 0x09, real
    instruction fetches from ASI 0x08, ASI 0x02, Viking internal ASIs
    (control space errors), internal errors and unassigned ASIs (errata)
    are always reported. "Regardless of whether/not the fault is taken,
    the FSR is always updated." A masked load writes an indeterminate
    value to rd; a masked store changes no register, and memory is
    "system dependent".

### 1.6 Probe (ASI 3, load)

- **Address format** (V8 Figure H-9): VA[31:12] = VFPA, VA[11:8] = type,
  VA[7:0] reserved. Viking: VA[31:12] VFPA, VA[11] reserved, VA[10:8]
  type, VA[7:0] reserved (Viking §4.11.7). Viking: "types 0x8-0xF are
  treated as identical to types 0x0-0x7"; types 5-7 → data_access_exception
  (Viking §4.11.7.1 "Important"; SS-II `STP1021UG.txt:1240-1242`). V8: types
  5-0xF return an undefined value (V8 §H.3 probe).
- **What each type returns** (V8 Table H-4, from the page image; ● = the
  entry itself is returned, ⇒ = walk on to the next level, 0 = zero
  returned; a memory error at any level returns 0):

  | Type | Level-0 entry ET 2/3/0/1 | Level-1 | Level-2 | Level-3 |
  |---|---|---|---|---|
  | 0 page | 0 / 0 / 0 / ⇒ | 0 / 0 / 0 / ⇒ | 0 / 0 / 0 / ⇒ | ● / 0 / ● / 0 |
  | 1 segment | 0 / 0 / 0 / ⇒ | 0 / 0 / 0 / ⇒ | ● / 0 / ● / ● | — |
  | 2 region | 0 / 0 / 0 / ⇒ | ● / 0 / ● / ● | — | — |
  | 3 context | ● / 0 / ● / ● | — | — | — |
  | 4 entire | ● / 0 / 0 / ⇒ | ● / 0 / 0 / ⇒ | ● / 0 / 0 / ⇒ | ● / 0 / 0 / 0 |

  So a type 0-3 probe returns the entry at its level even when that entry
  is invalid (ET 0) or a PTD; an entire probe returns only a PTE.
- **V8 rules:** probe types 0-3 are optional (the dagger in the type table after V8 Figure H-9). Page,
  segment and region probes should not set R; an entire probe may. It is
  recommended to check the PDC first and that only an entire probe load
  the PTE into the PDC (V8 §H.3 "Implementation Note"). No trap is raised;
  "the fault registers are updated" on a memory error (V8 §H.3 "Probe
  Operations").
- **Viking rules** (§4.11.7.1):
  - The TLB is checked first. A TLB hit returns the cached PTE "in the
    memory format with R=1 and ET=2". TLB match criteria per type:
    type 0: V & VA[31:12] & context & LVL = 3; type 1: VA[31:18] & LVL = 2;
    type 2: VA[31:24] & LVL = 1; type 3: context & LVL = 0; type 4: context &
    any of the four (Viking §4.11.7.1 table; note these require
    Context_equal, unlike the hit criteria of §4.11.6).
  - On a miss a walk is done. An error in a probe walk raises **no
    exception**, but sets "the AT field of the MMU status register … to 1" (OCR; the meaning is unclear), FT = 1 or 4, and L = the level.
  - Page probe: returns the level-3 entry even if invalid; if the level-3
    entry is ET 1 or 3, an intermediate entry is not a PTD, or a hardware
    error occurs → 0 and FT = 4.
  - Segment/region probe: returns the level-2/level-1 entry (PTE, PTD or
    invalid). Reserved entry, a non-PTD intermediate, or a hardware error →
    0, FT = 4.
  - Context probe: returns the level-0 entry if PTE, PTD or invalid;
    reserved → 0, FT = 4.
  - Entire probe: a normal walk; returns the PTE found. Invalid entry on the
    way → 0, FT = 1; reserved entry, level-3 PTD or hardware error → 0,
    FT = 4. **A successful entire probe loads the TLB and updates R if
    needed**; the other probe types leave the TLB and R unchanged.
  - The cached level-2 PTD (PTP2, §2.6) is used by entire probes (Viking
    §4.11.5).
  - Disagreement in detail: Viking's page probe returns 0 when an
    intermediate entry is invalid with FT = 4; V8 Table H-4 returns 0 too
    but does not name an FT.
- QEMU's probe behaviour and the project expectation (QEMU deviation 5)
  are in §7.3.

### 1.7 Flush / demap (ASI 3, store)

- Same address format as the probe; the store data is ignored. The
  context used is the context register (V8 §H.3 "Flush Operations").
- **What each type removes** (V8 §H.3 table; Viking §4.11.7.2):

  | Type | V8 removes | Viking removes |
  |---|---|---|
  | 0 page | level-3 PTE | level-3 PTE |
  | 1 segment | level-2 & 3 PTE/PTDs | level-2 and 3 PTEs |
  | 2 region | level-1, 2 & 3 PTE/PTDs | level-1, 2 and 3 PTEs |
  | 3 context | level-0..3 PTE/PTDs | level-0..3 PTEs |
  | 4 entire | everything | all PTEs |
  | 5-0xF | ignored | 5-7 reserved |

- **Precise PTE match criteria** (V8 Table H-2; Viking §4.11.7.2 table,
  which adds the LVL condition explicitly):

  | Type | Criterion |
  |---|---|
  | 0 | (ACC ≥ 6 or context equal) and VA[31:12] equal (Viking: and LVL = 3) |
  | 1 | (ACC ≥ 6 or context equal) and VA[31:18] equal (Viking: LVL = 3 or 2) |
  | 2 | (ACC ≥ 6 or context equal) and VA[31:24] equal (Viking: LVL = 3, 2 or 1) |
  | 3 | ACC ≤ 5 and context equal (an imprecise flush may also remove supervisor entries) |
  | 4 | none: all entries |

  A flush may remove more than the precise set (V8 §H.3 footnote 27).
- **PTD match criteria** (V8 Table H-3): page: context and VA[31:12];
  segment: context and VA[31:18]; region: context and VA[31:24]; context:
  context; entire: all.
- **Viking cached pointers** (Viking §4.11.5): the cached root pointer
  (PTP0) is invalidated by a context register write, a CTPR write, a
  demap-all, and a context demap for the current context. The cached
  level-2 PTD (PTP2) is invalidated by the same, plus level-1 and level-2
  demaps that match it, and by any walk that does not use it (which then
  replaces it). SS-II gives the SuperSPARC II version: page → TLB entries
  only; region → PTP2 and TLB entries; entire → PTP0, PTP2 and all TLB
  entries (SS-II `STP1021UG.txt:1226-1240`).
- **Types 5-7 on SuperSPARC:** "Illegal demaps (types 5-7) will be ignored
  internally. However, the demap will be broadcast to the system through
  DEMAP_. This behavior is the same as in SuperSPARC" (SS-II
  `STP1021UG.txt:1237-1240`).
- **MP:** in MBus mode demaps are not broadcast; every processor must be
  interrupted and flush its own TLB. Only one demap may be in progress
  system-wide at a time (Viking §4.11.7.2, §4.5.5.3).
- **Viking TLB hit criteria** (§4.11.6): entry valid, VA bits for the
  entry's size equal, and **(ACC = 6-7 or context equal)**: "context is
  not compared for any page classified as a supervisor page … supervisor
  pages are present in all contexts simultaneously." V8 recommends this
  as an implementation note (V8 §H.3 "Implementation Note" after Table
  H-1).

### 1.8 Control register: the V8 part

- **V8 layout** (Figure H-10): 31:28 IMPL (read-only), 27:24 VER
  (read-only), 23:8 SC (system control, implementation-defined; an
  unimplemented bit reads 0 and ignores writes), 7 PSO, 6:2 reserved
  (must be 0), 1 NF, 0 E.
- **E = 0** (V8 §H.4): VAs pass untranslated, PA[35:32] = 0, every access
  is non-cacheable as far as the MMU is concerned, and E reads as 0.
- **Reset** (V8 §H.7 "Reset"): E ← 0, PSO ← 0; all other MMU state is
  unaffected.
- **Register map** (V8 Table H-5): VA 0x000xx control, 0x001xx CTPR,
  0x002xx context, 0x003xx SFSR, 0x004xx SFAR, 0x005xx-0x00Fxx reserved,
  0x010xx and up unassigned. VA[7:0] unused. App. I: ASI 4 selects the
  register by VA[11:8]; byte, halfword and doubleword accesses "can return
  undefined data (and should be flagged as an error)" (V8 §I.3 ASI 4).
  Viking decodes VA[12:8] (§2.1).
- **V8 diagnostic registers** (Table H-6/H-7, suggested only): VA[31:12]
  virtual address, VA[11:4] PDC entry, VA[3:2] register (0 context +
  tag, 1 PTE, 2 control bits, 3 compare/LRU). Viking does **not** use this
  layout (§2.5).

## 2. SuperSPARC (Viking) specifics in MBus mode

### 2.1 ASI 4 register map

- **Decode** (Viking §4.11.11): "These registers are all 32-bits wide …
  Attempts to access them with byte, Halfword, or Doubleword operations
  will result in data_access_exception. Virtual address bits [12:8] are
  used to select individual registers, all other bits are ignored and
  should be 0. Any access to addresses other than defined in the table
  below causes a data_access_exception" (with MFSR.CS, Viking §4.11.11.3
  "Control Space Errors").
- **Per source:**

  | VA | Viking Table 4-9 | Other sources |
  |---|---|---|
  | 0x0000 | MCNTL | all |
  | 0x0100 | CTPR (MCTP) | all |
  | 0x0200 | context | all |
  | 0x0300 | MFSR, read clears | all |
  | 0x0400 | MFAR | all |
  | 0x0500 | — (not listed → data_access_exception) | Sun-4M generic AFSR (§2.3); "Viking has no AFSR/AFAR" (`Sun4M…txt:5126-5130`). NetBSD AFSR "HS only" (`include/ctlreg.h:241-250`); `docs/arch/cpu.md:227-237` and `memory-map.md:53-65` list AFSR 0x500 for this core; the SS5 test `t_mmu_swift` expects 0x500/0x600 to read 0 on microSPARC-II (MMU-1). The OBP map lists 0x500/0x600 as AFSR/AFAR (`hardware-access.md:263-266`) |
  | 0x0600 | — | Sun-4M generic AFAR; NetBSD AFAR "HS only" / PCFG (Turbo); the core plan's AFAR |
  | 0x0700 | — | Sun-4M generic reset register (WD bit 2, SI bit 1); "There is no Reset Register internal to Viking. The Watchdog Reset status is found in SFSR bit <17>" (`Sun4M…txt:1046-1059`, `:5132-5137`). OBP 2.25 reads 0x700 bit 2 only on Ross modules (MCNTL IMPL = 1) (`listing.s:39136-39150`, `hardware-access.md:263-266`). NetBSD `SRMMU_RST` 0x700, SI 0x2, WD 0x4 (`include/ctlreg.h:428-429`); the core plan's "reset 0x700" (`docs/arch/cpu.md:227-237`). §5 |
  | 0x0800 and up | — | Sun-4M: "implementation dependent" (`Sun4M…txt:547-557`) |
  | 0x1000 | — | NetBSD `SRMMU_TLBCTRL` 0x1000 (TLBC_DISABLE 0x20, RCNTMASK 0x1f) (`include/ctlreg.h:241-250`, `:424-425`); QEMU stores it as `mmuregs[0x10]` with `mmu_trcr_mask` (0xffffffff for TI SuperSparc) (`ldst_helper.c:1027-1029`, `cpu.c:479-490`); microSPARC-II TRCR (MMU-1). **The SS5 OBP** (microSPARC-II) writes 0 to it every boot (`tlb_init_clear` at 0x7000be70). OBP 2.25 touches ASI 4 0x1000-0x1200 only on its Ross/HyperSPARC paths (`listing.s:6609-6634`; `hardware-access.md:263-266`: "0x1000-0x1700 HyperSPARC / emulation registers"); no SS20 Viking path writes it |
  | 0x1300 | read/write MFSR (Viking: "to allow read/write access to the MFSR") | QEMU: read returns the SFSR **without clearing**, write sets it (`ldst_helper.c:674-689`, `:1030-1033`) |
  | 0x1400 | read/write MFAR | QEMU `ldst_helper.c:1034-1036` |
  | 0x1500 | shadow MFSR (emulation mode) | SuperSPARC II: no MSFSR, data_access_exception (SS-II `STP1021UG.txt:1330-1340`) |

- **QEMU decode:** `reg = (addr >> 8) & 0x1f`, so VA bits above 12 are
  dropped (0x2000 aliases 0) and every index is a plain storage register
  except 3, 0x13, 0x14 (`ldst_helper.c:674-689`). It never raises an
  exception for a bad VA or size on ASI 4.
- **Project-private registers** in the reserved space: 0xB00 (SFSR
  without clear), 0xC00 (scratch), 0xD00 (SYSCONF: RAM size in MB in bits
  31:20, CPU count). The suite still reads 0xB00
  (`wdtest.S`) and 0xD00 (`t_cache_diag.S:93-95` skip rule; `t_msi.S:98-107`
  `t_mem_slot7`). On a Viking these VAs are not in Table 4-9 →
  data_access_exception with CS.

### 2.2 MCNTL (ASI 4 VA 0)

The bit table is in iu-notes §6.3 (Viking §4.11.11.1, checked on the page
image; SS-II Table A-28 has the same layout). Facts the MMU and caches
need:

| Bit | Name | Value / behaviour | Sources |
|---|---|---|---|
| 31:24 | IMPL/VER | 0x01 on SuperSPARC 3.x (IMPL 0, VER 1); 4.x VER 2, 5.x VER 3; SS-II VER 8/0xA. Viking 1990 says 0 | SS-II Table A-51; QEMU `cpu.c:479-490` (`mmu_version 0x01000800`); NetBSD `cpu.c:2025-2036` ("SuperSPARC v3") |
| 18 | PF | data prefetcher; CC mode only, ignored in MBus mode. SS-II: "NO SUPPORT FOR SuperSPARC OR SuperSPARC II". Linux `VIKING_DPENABLE 0x40000` | Viking §4.9; SS-II `STP1021UG.txt:1285`; Linux `asm/viking.h:87-99` |
| 16 | TC | table walks cacheable externally; never cached internally; **must be 0 in MBus mode**. Linux and NetBSD clear it without an MXCC | Viking §4.8.2, §4.11.11.1; Linux `mm/srmmu.c:1396-1409`; NetBSD `cpu.c:1845-1860` |
| 15 | AC | cacheability of accesses that have no PTE (MMU off, bypass ASIs 0x20-0x2F); boot-mode fetches are always uncached. Linux clears it (`poke_viking`); NetBSD sets it temporarily with an MXCC to read the PROM's IOPTEs through ASI 0x20 (`iommu.c:354-394`) | Viking §4.3.4, §4.11.11.1, Tables 4-6/4-7; Linux `srmmu.c:1411-1415` |
| 14 | SE | snoop enable; "In MBUS mode, both the instruction and data caches will snoop regardless of whether they are enabled"; flash-clear before enabling snoops; store buffer snooping is always on | Viking §4.11.11.1 SE; Linux `viking.h:40-49` |
| 13 | BT/BM | boot mode, set by every reset (§2.7) | Viking §4.3.4 |
| 12 | PE | parity enable (errata: 1 = even parity generated, 0 = odd) | Viking errata "Page 97" |
| 11 | MB | read-only, CCRDY_ pin; 1 = MBus mode (no MXCC); the D-cache is then copy-back with write allocate | Viking §4.8.1, §4.11.11.1 |
| 10 | SB | store buffer enable (0 at reset) | Viking §4.12.6 |
| 9 / 8 | IE / DE | cache enables (0 at reset) | Viking §4.7, §4.8 |
| 7 | PSO | memory model | Viking §4.5.1.3 |
| 6:2 | — | reserved. In this project: bit 6 is the L2-TLB enable (§6); bits 3:2 read 0; `runtime.S:43-46`, `t_smp.S:23-26`, `memstress.S:143-146` and OpenBIOS read them as a CPU number (MMU-11) | Viking §4.11.11.1; PLAN §3 phase 3 |
| 1 | NF | §1.5 | |
| 0 | EN | MMU enable | |

- **Reset value** (Viking Table 4-1, §4.11.11.1 "On power-on reset, all the
  control bits mentioned above (except BT) are cleared"): IMPL/VER, BT = 1,
  MB = pin, everything else 0. For the SS20 module (VER 1, MB = 1) that is
  **0x01002800**; QEMU's TI-SuperSparc-60 power-on value is the same
  (`cpu.c:869-874`, `:76-77`). QEMU's reset clears only EN and NF and sets
  BM; IE/DE/SB etc. survive a QEMU reset (`cpu.c:76-77`, `cpu.h:484-508`).
- **QEMU write mask:** `mmuregs[0] = (mmuregs[0] & 0xff000000) | (val &
  0x00ffffff)`: bits 23:0 all writable, including reserved ones and MB
  (`ldst_helper.c:1003-1012`).
- **Values software writes:**
  - Linux `poke_viking`, MBus mode: clear TC; set SE|IE|DE|SB (0x4700);
    clear AC; leave PSO/NF/PE as found. On secondaries also clear
    ACTION.MIX (ASI 0x4C) (`srmmu.c:1376-1416`).
  - NetBSD: clears TC without an MXCC (`cpu.c:1845-1860`); never sets SE
    (SMP-3); `viking_cache_enable` sets IE/DE after a
    flash clear (C-2; the body is not in this NetBSD tree).
  - The suite: `MCR_ON = SE|IE|DE|EN = 0x4301`, written as `(MCNTL & ~BM) |
    0x4301` (`mmu_setup.S:61-76`, `:207-223`).
  - OpenBIOS: secondaries 0x001; CPU 0 `| 0x4140` (SE, DE, bit 6)
    (SMP-3). PLAN §3 phase 9 says 0x041 for the secondary start, not
    0x001.

### 2.3 Fault, asynchronous-fault and other ASI 4 registers on the SS20

- **SFSR/SFAR:** §1.5 (layout, FT, overwrite, read-clear, aliases).
- **AFSR/AFAR:** not in Viking Table 4-9.
  - Sun-4M generic module registers (`Sun4M…txt:1004-1043`): AFSR (0x500)
    = bit 12 UC, 11 TO, 10 BE, 7:4 AFA = PA[35:32], 0 AFV; AFAR (0x600) =
    PA[31:0]. Asynchronous faults are reported by a level-15 broadcast when
    AFV is set; "Reading the AFAR clears the AFSR", so the AFSR is read
    first.
  - "Viking has no AFSR/AFAR": on Viking/NE asynchronous errors are the
    store-buffer trap 0x2B plus a level-15 module_error
    (`Sun4M…txt:5126-5130`, `:4941-4978`).
  - NetBSD's AFSR layout (AFO 0x1, AFA 0xf0, BE 0x400, TO 0x800, UC 0x1000,
    SE 0x2000) is marked "HS only" (`include/ctlreg.h:411-418`).
  - On the SS20 the write-error registers of the system are the MSI's
    M-to-S AFSR/AFAR at pa 0xF_E000_1000/1004 (`Sun4M…txt:1157-1178`;
    `docs/arch/memory-map.md:34-36`).
- **Sun-4M generic SFSR** (`Sun4M…txt:905-928`): 12 UC, 11 TO, 10 BE, 9:8
  L, 7:5 AT, 4:2 FT, 1 FAV, 0 OW; "This register is clear-on-read. Reading
  it also unlocks the Synchronous Fault Address Register." Viking adds 13
  VMP (Sun-4M name; the Viking manual calls bit 13 UD), 14 P, 15 SB, 16 CS,
  17 EM (`Sun4M…txt:5103-5118`). OBP's Forth `.sfsr` decoder uses the same
  names: OW 0, FAV 1, FT 4:2, AT 7:5, L 9:8, BE 10, TO 11, UC 12, VMP 13,
  P 14, SB 15, CS 16, EM 17 (`forth-dictionary.txt:9210-9224`).
- **Sun-4M generic MCR** (`Sun4M…txt:826-849`) puts BM at bit 14, C at 13,
  CE at 8; the Viking MCR differs (BT at 13, SE at 14, AC 15, TC 16) and
  Sun-4M says "PSO … always 0 in Sun-4M" and "SRMMU IMPL = 0x4 (Texas
  Instruments)", VER = 0 (`Sun4M…txt:5057-5078`). **Disagreement:** OBP
  2.25 treats MCNTL[31:28] = 0 as Viking and 1 as Ross
  (`listing.s:39106-39110`, `:46296-46299`) and SS-II/QEMU give IMPL 0,
  VER 1 (§2.2).
- **Context register:** 16 bits; t_mmu_ctx_bits writes walking ones over
  bits 0-31 and expects `readback == written & 0xffff`; 0x5a5a5a5a reads
  0x5a5a (`t_mmu.S:15-55`). OBP 2.25 publishes `mmu-nctx` = 0x10000 and
  allocates a 256 KB context table; the POST walks 12 bits (MMU-3).
- **CTPR:** Viking keeps CTPR[31:8] (24 bits). The suite checks bits 31:6
  ("POST mask 0xfffffc00, QEMU 0xffffffc0; bits 5:0 are not checked")
  (`t_mmu.S:12-14`, `:15-55`). QEMU `mmu_ctpr_mask 0xffffffc0`
  (`cpu.c:479-490`). **Disagreement:** Viking says bits 7:0 read 0; QEMU and
  the suite keep bits 7:6. QEMU forms the context-table address as
  `(CTPR << 4) + (CTX << 2)` (an add, `mmu_helper.c:105`); Viking ORs
  CTPR[13:8] with CTX[15:10] (§1.2); NetBSD's comment gives
  `(context << 2) | ((ctpr >> 2) << 6)` (`include/pte.h:98-107`).

### 2.4 TLB geometry and replacement

- **64 entries, fully associative, unified I and D** on SuperSPARC (Viking
  §4.11; SS-II `STP1021UG.txt:1108-1118`: SuperSPARC II splits it into a
  64-entry D-TLB and a 16-entry I-TLB). Each entry tags VA, context and
  level, and caches only PTEs (Viking §4.11.7.1 "only PTEs are cached").
- **Hit criteria** (Viking §4.11.6): V, the VA bits for the size, and
  (ACC 6-7 or context equal).
- **Replacement** (Viking §4.11.4): the first invalid entry from 0 to 63.
  When all are valid, a limited-history LRU: one used bit per entry, set
  on a hit; when all used bits are set, all except the last one set (and
  locked ones) are cleared; the victim is the first entry from 0 whose used
  bit is clear. A demap-all clears all used bits; an invalidated entry's
  used bit is cleared.
- **Lock bit** per entry: a locked entry is never replaced; an invalid
  locked entry can be refilled and stays locked (and survives demaps).
  If all 64 are locked a miss loops in the table walk forever. Lock bits are
  cleared by hardware reset (Viking §4.11.4, §4.11.12; Table 4-1).
- **Cached pointers:** one root pointer (PTP0) and one level-2 PTD (PTP2)
  with a VA[31:18] tag, both implicitly for the current context (Viking
  §4.11.5). PTP2 is used by walks, R/M updates and entire probes; "Other
  operations still go through the three level table-walk mechanism"; it is
  not cached when the level-2 entry is a PTE. Invalidation events: §1.7.
  SS-II: "If the MCTP is changed, the cached page table pointers will be
  invalidated. However, SuperSPARC II, like SuperSPARC, does not
  automatically demap the tlb's on a context table pointer change" (SS-II
  `STP1021UG.txt:1290-1296`).
- **Multiple matches** (two entries mapping the same VA, possible through
  ASI 6 writes or a missing flush after a page-table change): undefined
  result, not reported; the hardware is not damaged (Viking §4.11.12
  "Important Note").

### 2.5 ASI 6: the TLB diagnostic image

- **Address** (Viking §4.11.12, page image; SS-II Table A-29): VA[31:18]
  reserved, **VA[17:12] = entry (0-63)**, VA[11] reserved, **VA[10:8] =
  SEL**, VA[7:0] reserved. 32-bit accesses only; other sizes →
  data_access_exception.
- **SEL** (Viking §4.11.12):

  | SEL | Data | Format |
  |---|---|---|
  | 0 | VA tag | bits 31:12 = VPN (for a 256 KB entry only 31:18 are significant, 16 MB 31:24, 4 GB none); 11:0 reserved |
  | 1 | context tag | bits 15:0; 31:16 reserved |
  | 2 | cached PTE | bits 31:8 PPN, 7 C, 6 M, **5 V** (in the R position), 4:2 ACC, **1:0 LVL** (0 = 4 GB, 1 = 16 MB, 2 = 256 KB, 3 = 4 KB) |
  | 3 | lock | bit 0 = lock. SuperSPARC II adds bit 1 RBO on the D-TLB |
  | 4 | cached root pointer (entry field unused) | bits 31:2 root pointer, bit 0 V (SS-II: only bits 31:6 written) |
  | 5 | cached level-2 PTD (entry field unused) | bits 31:0 (SS-II: bits 31:2 PTP2, 1:0 valid = 01; only bits 31:4 written) |
  | 6 | PTP2 virtual address tag | bits 31:18 VA, 17:0 reserved |

  The SEL = 2 format differs from the memory PTE: R is replaced by V and
  ET by LVL (Viking §4.11.12; SS-II Table A-30).
  - **Disagreement:** Sun-4M B.I.5.1 lists SEL 2 = LOCK and SEL 3 = PTE
    (`Sun4M…txt:5188-5265`). Viking, SS-II, the POST and OBP's watchdog
    code use SEL 2 = PTE, SEL 3 = lock: `reset_watchdog_lock_tlb` writes the
    PTE at ASI 6 `0x200` and the dump reads the lock at `0x300`
    (`listing.s:39806-39809`; `post-tests.md:574-578`).
- **ASI 5 and 7:** reserved in Viking Table 4-19 (→ error). SuperSPARC II
  uses ASI 5 for its 16-entry I-TLB (TLB entry field bits 15:12) (SS-II
  `STP1021UG.txt:1351-1370`). V8 suggests 5 = I-PDC diag, 6 = D or combined,
  7 = I/O PDC (V8 Table I-1). QEMU: ASI 5/6/7 loads return 0, stores are
  ignored (`ldst_helper.c:690-693`, `:1050-1053`). The project requires an
  ASI 5/6/7 write to drop the TLBs (PLAN §6 L2, §3 phase 3; §6 here).
- **What the suite expects** (`t_mmu_diag.S`, MMU off; macros `sta/lda
  [e<<12 | sel<<8] 6`, `:13-14`):
  - **t_mmu_diag_pattern** (`:111-150`): for each pattern set and each
    entry 0..63, write SEL0..SEL3 and read each back at once:

    | Set | SEL0 | SEL1 | SEL2 | SEL3 |
    |---|---|---|---|---|
    | 1 | 0xaaaaa000 | 0xaaaa | 0xaaaaaaaa | 0 |
    | 2 | 0x55555000 | 0x5555 | 0x55555555 | 1 |
    | 3 | 0xfffff000 | 0xffff | 0xffffffff | 1 |
    | 4 | 0 | 0 | 0 | 0 |

    So SEL0 holds bits 31:12, SEL1 16 bits, **SEL2 all 32 bits** (every
    PTE bit including the V and LVL positions), SEL3 bit 0
    (`t_mmu_diag.S:18-21`).
  - **t_mmu_diag_flush** (`:152-212`, `dg_mode :39-109`): fill all 64
    entries (SEL3 = 0), then for j = 0..63 demap at `(j << shift) |
    type << 8`; after step j, entry j must read SEL2 with V (0x20) cleared
    and entry j + 1 unchanged:

    | Mode | SEL0 | SEL1 | SEL2 | Demap |
    |---|---|---|---|---|
    | context | 0 | e | 0x20 (V, LVL 0) | context reg := j, then ASI 3 VA 0x300 |
    | region (ctx 0) | e << 24 | 0 | 0x21 | `j<<24 \| 0x200` |
    | segment | e << 18 | 0 | 0x22 | `j<<18 \| 0x100` |
    | page | e << 12 | 0 | 0x23 | `j<<12 \| 0x000` |
    | entire | e << 12 | e | 0x20 \| (e & 3) | one demap at 0x400; then every entry reads e & 3 |

    So a demap clears **only the V bit** of SEL2 and leaves the other
    bits readable, and it matches the entry's LVL as in Viking §4.11.7.2.
  - Header source: OBP POST "MMU TLB Bit Pattern Tests" and "MMU Flush
    Tests" (`t_mmu_diag.S:1-9`). The POST versions: #6 runs `0xf6dc` four
    times with the same four pattern sets over 64 entries and leaves every
    entry 0; #7 (0x1c5c8) fills through ASI 6 and demaps with the same five
    modes, expecting a flushed entry to read `lvl` (only V cleared) and an
    unflushed one `0x20|lvl` (`post-tests.md:83-84`, `:787-826`).
- **Who uses ASI 6:** the SS20 POST TLB tests; the watchdog path of OBP 2.25
  dumps the D-TLB into NVRAM through ASI 6; no OS uses it in the normal
  path (Linux, NetBSD checked); NeXTSTEP is suspected of invalidating TLB
  entries through it (MMU-2). Acknowledging and ignoring ASI 5/6/7 is not
  enough: "a diagnostic-only shadow array would pass the marches but not
  the flush tests" (MMU-2).
- **QEMU** fails t_mmu_diag_pattern (check 1 expects 0xaaaaa000, observes 0)
  and t_mmu_diag_flush (`tests/cpu/expected/ss20-qemu.log:83-97`); none of
  the numbered deviations covers it.

### 2.6 ASI 0x38 breakpoint registers and ASI 0x4C ACTION

- **ASI 0x38** (Viking §4.14.4.1, Table 4-17): four registers, **double-word
  access only** (other sizes → data_access_exception), selected by
  VA[9:8]:

  | VA[9:8] | Register | Format |
  |---|---|---|
  | 0 (VA 0x000) | MDIAG_BKV, breakpoint value | bits 35:0 = 36-bit address; 63:36 reserved, read 0 |
  | 1 (VA 0x100) | MDIAG_BKM, mask | bits 35:0; a 1 masks that bit out of the compare |
  | 2 (VA 0x200) | MDIAG_BKC, control | bit 6 CSPACE (1 = code), 5 PAMD (1 = physical), 4 CBFEN (code fault → instruction_access_exception, else interrupt), 3 CBKEN, 2 DBFEN (data fault → data_access_exception), 1 DBREN, 0 DBWEN; 63:7 reserved |
  | 3 (VA 0x300) | MDIAG_BKS, status | bit 3 CBKIS, 2 CBKFS, 1 DBKIS, 0 DBKFS; cleared by any reset and **by any load** of BKS |

  - Reset: "All breakpoint enable and status bits are cleared at reset. All
    values and masks are unchanged through reset"; BKC "All bits are
    cleared on both hardware and watchdog reset" (Viking §4.14.4.1). A
    write must be followed by an IFLUSH or BA before the breakpoint is
    guaranteed active (Viking §4.14.3 text after Table 4-16).
  - Errata: use read-modify-write on BKC, ACTION and CTRC (Viking errata
    "Page 123").
  - **OBP 2.25 keeps the module ID in ASI 0x38 VA 0:** "Every CPU copies
    the MSI MID register (pa `0xF_E000_2000`) into ASI 0x38 va 0; with IOMMU
    IMPL = 0 it then reads its MID back from ASI 0x38 va 0 … and ORs in 8"
    (SMP-1).
  - **Suite:** `stda {0xa, 0x12345678},[0] 0x38` and `{0x5, 0x9abcdef0},
    [0x100] 0x38`, `ldda` both back exactly (`t_iu2.S:235-281`,
    t_asi_width checks 2-5; header: "ASI 0x38 va 0 and 0x100 … must hold
    64-bit values"). Value and mask hold at least bits 35:0.
  - **QEMU:** `reg = (addr >> 8) & 3`; writes masked reg0/reg1 `&
    0xfffffffff` (36 bits), reg2 `& 0x7f`, reg3 `& 0xf`; reading reg 3
    clears it (`ldst_helper.c:736-758`, `:1102-1123`). No size check.
- **ASI 0x49-0x4B** counters (Viking §4.14.4.2-4.14.4.4): CTRV (ICNT 31:16,
  CCNT 15:0, unchanged at reset), CTRC (bit 1 ICNTEN, bit 0 CCNTEN, cleared
  by any reset), CTRS (bit 1 ZICIS, bit 0 ZCCIS, cleared by any reset).
  QEMU masks 0xffffffff, 0x3, 0x3 (`ldst_helper.c:1124-1135`).
- **ASI 0x4C ACTION** (Viking §4.14.4.5, page image): single word.

  | Bit(s) | Field |
  |---|---|
  | 31:13 | reserved |
  | 12 | MIX: multiple instructions per cycle (0 at reset) |
  | 11:8 | BCIPL: interrupt level for breakpoint/counter interrupts |
  | 7 | STEN_CBK |
  | 6 | STEN_ZIC |
  | 5 | STEN_DBK |
  | 4 | STEN_ZCC (the STEN bits drive the ESB pin) |
  | 3 | IEN_CBK |
  | 2 | IEN_ZIC |
  | 1 | IEN_DBK |
  | 0 | IEN_ZCC (interrupt enables) |

  All fields are cleared at reset (Viking §4.14.4.5). 13 bits wide; QEMU
  keeps `val & 0x1fff` at any address (`ldst_helper.c:1124-1135`).
  - **Users:** OBP 2.25 `obp_cache_init` writes 0; Linux `poke_viking`
    read-modify-writes it on secondaries (clears MIX); Solaris 8 writes
    0x1000 (MIX) and loops until it reads 0x1000 back (MMU-12;
    iu-notes §6.5).
  - **Suite** (`t_iu2.S:235-281`, t_asi_width): `sta 0x100,[0] 0x0c`, then
    `sta %g0,[0] 0x4c`, the ASI 0x0C tag must be unchanged (check 1: all 8
    ASI bits are decoded, so 0x4C must not alias 0x0C, MMU-12); ACTION
    writes 0x1000 / 0x0aaa / 0 must read back the same (checks 6-8, "13
    bits in QEMU").
  - Viking decodes all 8 ASI bits; "an error occurs on all access to
    reserved values" (Viking §4.16).
- **Other Viking-only ASIs** (Viking Table 4-19): 0x02 control space (to the
  MXCC; in MBus mode see §2.9), 0x30-0x32 store buffer (§4.3), 0x39 BIST,
  0x40/0x41 MTMP1/2, 0x44 MDIN (read-only), 0x46 MDOUT, 0x47/0x48 MPC/MNPC.
  0x00, 0x01, 0x05, 0x07, 0x10-0x1F, 0x33-0x35, 0x3A-0x3F, 0x42, 0x43,
  0x45, 0x4D-0xFF are reserved/unassigned. LDSTUBA/SWAPA to any ASI but
  0x08-0x0B and 0x20-0x2F → data_access_exception (Viking §4.5.2.3, Table
  4-19 notes).

### 2.7 Boot mode, MMU-off and bypass address formation

- **Boot mode** (MCNTL.BT = 1; set by hardware and watchdog reset)
  (Viking §4.3.4, §4.11.9, §4.11.11.1 BT; Linux `viking.h:51-58`):
  - Instruction fetches, and LDA/STA to ASI 0x08/0x09, go to
    `PA[35:28] = 0xFF, PA[27:0] = VA[27:0]` (= 0xF_F000_0000 + VA[27:0]),
    whatever EN says.
  - These accesses are **non-cacheable** whatever IE and AC say.
  - Data accesses are not affected: with EN = 0 they use the MMU-off rule,
    with EN = 1 they are translated.
  - BT is cleared only by software writing MCNTL.
- **QEMU:** a boot-mode fetch goes to `prom_addr | (va & 0x7ffff)` (19 VA
  bits) with prom_addr = 0xF_F000_0000 (`mmu_helper.c:89-93`;
  `hw/sparc/sun4m.c:1226`, `:834`); only while EN = 0, since the
  physical-index path is used only then (`cpu.c:793-802`). Boot mode has
  no effect in QEMU when EN = 1. **Disagreement** with Viking (28 bits, any
  EN).
- **The SS20 PROM** is 512 KB at pa 0xF_F000_0000, mirrored through the
  16 MB, and also at PA 0 in boot mode (`docs/arch/memory-map.md:37`).
  "The SS20 PROM is not readable at its link address with the MMU off, so
  runtime.S first copies the image to RAM at pa 0" (`tests/cpu/README.md:14-17`).
- **MMU off, BT = 0** (EN = 0): PA[35:32] = 0, PA[31:0] = VA (Viking
  §4.11.9; V8 §H.4 E).
- **Bypass ASIs 0x20-0x2F** (Viking §4.11.8; V8 §I.3; SS-II
  `STP1021UG.txt:1474-1479`): `PA[35:32] = ASI[3:0]`, `PA[31:0] = VA[31:0]`,
  for loads and stores of every size; no translation, no R/M updates;
  cacheability from MCNTL.AC. Atomic LDSTUBA/SWAPA are allowed on them
  (Viking §4.5.2.3). They do not force a store-buffer copy-out for STA
  (Viking §4.5.3 and errata "Page 62").
  - QEMU: ASI 0x20 is handled inline as a 32-bit physical access
    (PA[35:32] = 0); 0x21-0x2F use `addr | (asi & 0xf) << 32`
    (`translate.c:1570-1600`; `ldst_helper.c:699-729`).
  - ASIs the suite and PROMs use: 0x20 (RAM), 0x2E (SBus, `t_buserr`), 0x2F
    (control space, pa 0xF_xxxx_xxxx) (`tests/cpu/src/platform.h:33-38`).
- **Translation and cacheability summary** (Viking §4.11.9 and Tables
  4-6/4-7):

  | Mode | Instruction fetch (ASI 8/9) | Data (ASI 0xA/0xB) |
  |---|---|---|
  | BT = 1 | PA = 0xFF<<28 \| VA[27:0], never cached | as BT = 0 |
  | BT = 0, EN = 0 | PA = VA, cached iff IE and AC | PA = VA, cached iff DE and AC |
  | BT = 0, EN = 1 | PTE, cached iff IE and C | PTE, cached iff DE and C |
  | bypass 0x20-0x2F | n/a | PA = ASI[3:0]:VA, cached iff DE and AC |

### 2.8 PTE.C, MCNTL.AC and requirement E3

- **Viking:** the PTE's C bit decides cacheability when the MMU is on and
  the cache is enabled; AC decides for accesses without a PTE; table-walk
  data is never cached internally (Viking §4.7.1, §4.8.2, errata "Page
  75": "the C bit from the PTE"). C = 1 also drives the CCHBL_ pin
  (Viking §4.11.1 C).
- **Project decision (PLAN §2 lines 112-114; §6 E3 line 342):** "main
  memory cached even where a PTE says C = 0". Test `t_cache_force.S:1-12`: "The SS20 MMU sets C in a TLB entry
  whose page is in main memory (pa[35:32] = 0) while snooping is on
  (MCNTL.SE), whatever the PTE's C bit." Reason given: "the Sun OBP 2.25
  maps everything it gives a client program uncacheable on a module
  without an E-cache, so boot loaders ran uncached (NetBSD's install CD
  899 s to its installer)."
- **Consequence the test checks:** the OSes keep page tables uncached on
  this module, so with E3 the PTEs are cached; "the table walker's own R/M
  writes must reach the CPU's cached copy of the PTE (the walk's write
  invalidates the line through the snoop port), or an OS reads M = 0 for a
  page it dirtied" (`t_cache_force.S:1-12`). Expected values in §7.
- **This differs from Viking**, whose MBus-mode walk does not snoop the
  data cache and requires uncached page tables (Viking §4.8.2).

### 2.9 MBus module, port register and the MID

- **MID:** sampled at reset from ADDR[3:0]; any value but 0 (0 is the boot
  space) (Viking §8.3). Sun-4M modules use MIDs 8-11; the MSI MID register
  at pa 0xF_E000_2000 returns the requester's MID (SMP-1;
  `docs/arch/memory-map.md:34-36`).
- **Port register** (Viking §8.6.1.4, §8.10, page image; errata "Page
  199"): MBus port registers are read with non-cacheable accesses "to
  physical addresses in the range 0xff1000000 → 0xfff000000, depending on
  module number being addressed. It is legal for a processor to address
  it's own port register. This is the only case of snooping on
  non-coherent read transactions." Viking returns **0x00000004** on
  MAD[31:0] (device 0, revision 0, SPARC licensee ID 4 = TI); read-only.
- **Sun-4M** (`Sun4M…txt:637-654`, `:662-665`, `:1067-1086`): system space
  PA[35:24] 0xFF8-0xFFF is the control space of MBus master #8-#F; "the
  highest 32-bit location in each slot (PA = 0xFFnFFFFFC, where n = MID) is
  reserved for the MBus Port Address register". Format: bits 31:16
  implementation-specific, 15:8 MDEV, 7:4 MREV, 3:0 MVEND (0 Fujitsu,
  1 Ross/Cypress, 3 LSI, 4 TI; the same codes as MCR IMPL). "Viking/NE:
  MDEV = 0, MREV = 0, MVEND = 4; can only be accessed via module control
  space"; Viking/NE has no software-readable MID (`Sun4M…txt:5147-5160`,
  `:5329-5330`). With an MXCC (ASI 2 0x01C00F00): 27:24 MID, 15:8 MDEV = 1,
  7:4 MREV 0, 3:0 MVEND 4 (`Sun4M…txt:6785-6797`).
- **This project's memory map** places the MBus module control space at
  0xF_F8xx_xxxx-0xF_FFxx_xxxx for MID 8-F with "`+0xFF_FFFC` the MBus Port
  Address register | cpu" (`docs/arch/memory-map.md:48`), i.e. pa
  0xF_FnFF_FFFC; bus.md wants "a module ID per master (MID) for the MBus
  Port Address register" (`docs/arch/bus.md:65-86`). No test reads it.
- **How OBP 2.25 finds the MID** (`reset_find_mid`, `listing.s:39152-39190`;
  `README.md:114-121`): IOMMU control [31:28] ≠ 0 → trust the MSI MID
  register (pa 0xF_E000_2000); else Ross → MCNTL[18:15]; else Viking with
  MCNTL.MB = 1 → `ldda [0] 0x38`; else (MXCC) `ldda [0x01c00f00] 0x02`,
  low word `>> 24 & 0xf`. At a power-on (SFSR.EM = 0) every Viking first
  zeroes ASI 0x38 VA 0/0x100/0x200/0x300 with `stda` and stores the MSI MID
  register value (both halves) at VA 0 (`listing.s:39117-39129`). Sun-4M
  notes that the first MSI MID register implementation was broken and
  suggests per-CPU TBR aliasing (`Sun4M…txt:1343-1370`).
- **With an MXCC**, software reads the MID from the MXCC port register
  `ldda [0x01c00f00] ASI 2`: NetBSD `(v >> 24) & 0xf` (`cpu.c:1863-1871`);
  Linux comment "MID bits 20-18" (`asm/mxcc.h:77-85`); QEMU sets
  `mxccregs[7] = ((cpu + 8) & 0xf) << 24` and answers ASI 2 even on the
  MXCC-less model (`cpu.c:206-211`; `ldst_helper.c:596-658`). **Without an
  MXCC NetBSD's `viking_getmid` returns 0** and the MID comes from the
  PROM "mid" property (`cpu.c:1863-1871`, `:229`, `:476`).
- **ASI 2 in MBus mode:** Viking: control-space accesses go to the external
  cache controller, are non-cacheable, any size, faults →
  data_access_exception with CS (Viking §4.10, MFSR CS "[4] bus errors on
  ASI 0x02"). The project: "SuperSPARC control space / MXCC (not
  implemented: MBus mode, no MXCC)" (`docs/arch/memory-map.md:53-65`).
  Linux (`init_viking`) and NetBSD (`viking_hotfix`) skip every MXCC access
  when MCNTL.MB = 1 (`srmmu.c:1464-1501`; `cpu.c:1802-1842`).

---

## 3. The caches

### 3.1 SuperSPARC geometry

| | I-cache | D-cache |
|---|---|---|
| Size | 20 KB | 16 KB |
| Organisation | 5-way, 64 sets | 4-way, 128 sets |
| Line | 64 bytes, two 32-byte half-lines (sub-blocks), a valid bit per half-line | 32 bytes, no sub-blocking |
| Index (set) | PA[11:6] | PA[11:5] |
| Tag | PA[35:12] | PA[35:12] |
| Addressing | physical (the MMU translates first) | physical |
| Write policy | never written by the CPU | MBus mode: copy-back, write-allocate; CC mode: write-through, no allocate |
| Replacement | limited-history LRU + lock bits (line 0 cannot be locked); fills line 4 first, then 3, 2, 1, 0 | same, 4 ways; fills 3, 2, 1, 0 |

Sources: Viking §4.7, §4.8, §4.8.1, §4.7.2, §4.8.3; SS-II
`STP1021UG.txt:1484-1520` (the same geometry for SuperSPARC II); Sun-4M
B.I.2 (`Sun4M…txt:4673-4884`); NetBSD `cpu.c:1929-1941` (sun4d: I 64 × 64 B ×
5, D 128 × 32 B × 4); Linux `viking.S:38-89` and `viking.h:165-180` (128 sets
× 4 ways × 32 B). The way size of both caches is 4 KB (= page size), so
the set index lies entirely within the page offset.

- **Hit:** PA[35:12] equals the tag and the valid bit of the addressed
  (half-)line is set (Viking §4.7, §4.8).
- **Replacement detail** (Viking §4.7.2, §4.8.3; errata "Page 69/75"): the
  MRU (history) bit of a line is set when an instruction fetch (I) or a
  load (D) hits it; when it is set, if every other MRU bit ORed with its
  lock bit is already 1, all the others are cleared. Victim: no locked line;
  among unlocked lines the one with history 0, the "rightmost available"
  in the figure, i.e. line order from the big end.
- **Instruction prefetch** never starts a table walk or raises an
  exception; only a demand fetch does (Viking §4.7.4).
- **Fill errors** (Viking §4.5.7, §8.9): a miss is a 4-doubleword burst,
  critical doubleword first, the rest modulo 32 bytes. An error on the
  demand doubleword is reported; an error on a prefetched doubleword is not,
  and the whole line is invalidated. "If any errors occur during the
  transfer of a cache line, the internal cache will not be validated."
- **Snooping** (Viking §4.7.5, §4.8.5, Table 4-8, §4.11.11.1 SE): with SE
  set, the I-cache invalidates on any snoop hit by CRI/CI/CWI (and only
  asserts MSH on CR); the D-cache follows the MBus MOESI table (set shared on
  CR, copy out when owned, invalidate on CRI/CI/CWI). In MBus mode both
  caches snoop even when disabled. Instruction-cache invalidations include
  those caused by the processor's own stores.
- **Snoop vs lock** (Viking §4.7.3): a snoop invalidation leaves a locked
  line locked and invalid; it is then never replaced and never hits.
- **FLUSH instruction** (Viking §4.4.4; iu-notes §2.12): flushes no cache;
  it drains the store buffer, waits for pending coherence actions and
  clears the pipeline and instruction queue. Affects only the executing
  processor. Sun-4M: "`flush` only flushes the pipeline"
  (`Sun4M…txt:4915-4924`).
- **Atomics in MBus mode** (Viking §4.5.2.2, §8.6.1.3, §8.6.2.3): cacheable
  LDSTUB/SWAP are a read-for-ownership (CRI) then a local write; non-cacheable
  ones are a locked READ + WRITE pair on the bus.

### 3.2 Cacheability

Tables 4-6 and 4-7 of Viking are summarised in §2.7. Table-walk data is
never cached internally (Viking §4.8.2). Sun-4M: "Main memory is allowed to
be mapped cacheable. No other element may be marked cacheable"
(`Sun4M…txt:2153-2154`). Sun-4M disagrees with itself on page tables: §7.1
recommends cacheable page tables on Viking (`:2156-2160`), B.I.5 says "The
page tables are not cacheable in Viking/NE" (`:5165`). OBP's first PTEs
are `pa >> 4 | 0x1e` (uncacheable, ACC 7) (`README.md:217-229`). The project
caches main memory regardless of C (§2.8).

### 3.3 Diagnostic ASIs 0x0C-0x0F (Viking §4.7.6, §4.8.6; page images)

All four ASIs are **double-word only** (other sizes →
data_access_exception). Tags and data are not changed by a watchdog or
hardware reset; flash clear does not touch data.

- **I-cache tags, ASI 0x0C** — address: VA[31:30] T (1 = set tag/STAG,
  2 = physical tag/PTAG; 0 and 3 → data_access_exception), VA[29]
  reserved, **VA[28:26] line (way) 0-4** (5-7 → data_access_exception),
  VA[25:12] reserved, **VA[11:6] set**, VA[5:3] reserved, VA[2:0] = 0.
  - PTAG (64 bits): 63:58 reserved, **57:56 valid bits** (56 = half-line
    with A[4] = 0, 57 = A[4] = 1), 55:24 reserved, **23:0 PA[35:12]**.
  - STAG: 63:13 reserved, **12:8 MRU** (bit 8 + n = line n), 7:5 reserved,
    **4:0 LCK** (bit 0 fixed 0, bits 1-4 lock lines 1-4).
- **I-cache data, ASI 0x0D** — VA[31:29] reserved, VA[28:26] line, VA[25:12]
  reserved, VA[11:6] set, **VA[5:3] doubleword**, VA[2:0] = 0.
- **D-cache tags, ASI 0x0E** — VA[31:30] T (as above), VA[29:28] reserved,
  **VA[27:26] line 0-3**, VA[25:12] reserved, **VA[11:5] set**, VA[4:3]
  reserved, VA[2:0] = 0.
  - PTAG: 63:57 reserved, **56 V**, 55:49 reserved, **48 dirty (owned)**,
    47:41 reserved, **40 shared**, 39:24 reserved, **23:0 PA[35:12]**.
    Dirty is set only in MBus mode. SuperSPARC II stores only the 24 tag
    bits and V; D and S read 0 (SS-II Table A-34).
  - STAG: 63:12 reserved, **11:8 MRU** (lines 0-3), 7:4 reserved, **3:0 LCK**
    (bit 0 fixed 0).
- **D-cache data, ASI 0x0F** — VA[31:28] reserved, VA[27:26] line, VA[25:12]
  reserved, VA[11:5] set, **VA[4:3] doubleword**.
- In the 32-bit register pair of an `ldda`/`stda`, the even register is
  bits 63:32 ("hi") and the odd one 31:0 ("lo"). So valid/dirty/shared
  appear in hi (D: V = 0x01000000, D = 0x00010000, S = 0x00000100; I:
  0x03000000) and the PA tag in lo. Linux defines `VIKING_PTAG_VALID
  0x01000000`, `_DIRTY 0x00010000`, `_SHARED 0x00000100`
  (`asm/viking.h:109-111`) and reads word 1 as the physical page
  (`:165-180`).
- **Sun-4M** gives the same fields (`Sun4M…txt:4728-4870`).
- **QEMU:** loads of ASI 0x0C-0x0F return 0, stores are ignored
  (`ldst_helper.c:694-698`, `:1054-1063`). `t_cache_diag` therefore skips
  on QEMU ("QEMU hangs on these ASIs") (`t_cache_diag.S:93-95`).

### 3.4 Flash clear ASI 0x36 / 0x37 (Viking §4.7.6.1, §4.8.6.1; page image)

- A **word store** (other sizes → data_access_exception); the data is
  ignored; **VA[31] = type**: 0 → clear every valid bit (PTAGs) and every
  MRU bit (STAGs); 1 → clear every lock bit (STAGs). Other bits reserved
  (0x36 = I-cache, 0x37 = D-cache).
- "Flash clear operations should always be used before enabling" the cache;
  at power-on the valid bits are undefined; after a watchdog reset the
  D-cache contents are unmodified (Viking §4.7, §4.8). Sun-4M: flash clear
  is "required after power-up" (`Sun4M…txt:4722-4726`, `:4808-4810`).
- Sun-4M: "no flush mechanism is supported" by ASI on Viking; software uses
  displacement or flash clear (`Sun4M…txt:4893-4903`).
- **Users:** OBP 2.25 POST start (`sta %g0` to 0x36 [0], 0x36 [0x80000000],
  0x37 [0], 0x37 [0x80000000], `listing.s:6594-6599`), `obp_cache_init`
  (`listing.s:46375-46379`), Forth `clear-vcache` and `vcache-off`
  (`forth-dictionary.txt:9128-9148`); Linux `viking_flush_icache/dcache`
  (`sta %g0,[%g0] 0x36/0x37`) and `viking_unlock_*` (`[0x80000000]`)
  (`asm/viking.h:115-145`); NetBSD `viking_cache_enable` (C-2). QEMU
  ignores stores to 0x36/0x37 and faults on loads (`ldst_helper.c:1094-1101`,
  `:771-774`).

### 3.5 Line flush ASIs 0x10-0x14 and 0x18-0x1C

- **V8** (§I.3, Table I-2): 0x10-0x14 flush one line from both caches by
  page/segment/region/context/user, comparing a virtual tag (S or CTX,
  VA[31:12]/[31:18]/[31:24]; context: U and CTX; user: U); 0x18-0x1C the
  same for the I-cache only. Sun-4M lists 0x10-0x14 as "Flush I/D cache(s)"
  and 0x18-0x1C as "Flush D cache" (`Sun4M…txt:467-513`).
- **Viking:** 0x10-0x1F are "Reserved" (Viking Table 4-19), so an access
  raises data_access_exception (all 8 bits decoded, §4.16); Sun-4M's Viking
  ASI list has no 0x10-0x1F (`Sun4M…txt:5275-5307`). Viking caches are
  physical and coherent; Linux's `viking_flush_cache_*` only flush windows
  (`viking.S:110-127`).
- **Who uses them anyway:**
  - OBP 2.25 `obp_flush_user_ctx` (an ASI 0x13 loop) on the client-start path,
    reached on Viking only with an MXCC (`listing.s:46251-46281`,
    `:40537-40610`); its Ross 605 branch uses 0x13/0x14
    (`listing.s:46301-46371`).
  - **The suite:** `mmu_flush_lines` does `sta %g0,[va] 0x10` every 32
    bytes ("ASI 0x10 (I&D line, page type)") (`mmu_setup.S:228-236`), and
    `t_mmu_tlb_flush`, `t_mmu_l2`, `t_cache2`, `t_cache3` flush lines with it
    after normal stores. In a write-through cache this has no visible
    effect except in t_cache_flush_miss, which flushes a line whose page is
    no longer in the D-TLB (on a D-TLB miss the flush must not use PA = VA;
    C-3).
  - QEMU ignores stores to 0x10-0x14 and faults loads
    (`ldst_helper.c:1054-1063`).
- **Mode dependence:** the task asked how the flushes behave in MBus vs CC
  mode. The Viking manual defines none of them in either mode; with an MXCC
  (CC mode) the external cache is flushed through ASI 2 stream operations
  (Linux `viking_mxcc_flush_page`, `viking.S:91-108`).

### 3.6 Store buffer (Viking §4.12; Sun-4M `:4926-5042`)

- 8 doubleword entries, fully associative, flushing type (a read that
  matches a pending doubleword waits for it). No byte collection.
- **MBus mode:** only non-cacheable stores and copy-back data go through it
  (Viking §4.12.3, §8.7). Cacheable stores wait until non-cacheable stores
  have completed (§8.6.1.2). Copy-back data in the buffer is snooped and
  supplied (Table 8-1).
- Disabled at power-up (SB = 0 → every store synchronous).
- Copy-outs happen before every ASI access (except STA to 0x20-0x2F, LDA/STA
  0x40-0x4C, STA to 0x08-0x0B and cacheable LDA to 0x08-0x0B, errata
  "Page 62"), before non-cacheable loads, atomics, R/M updates, traps and
  context writes (Viking §4.5.2-4.5.6).
- **Errors** → data_store_error (tt 0x2B, priority 2), MFSR.SB (sticky),
  the buffer is disabled, entries kept; in MBus mode AERR_ stays asserted
  until the MFSR is read (errata "Page 110"). Sun-4M: SB frozen, MCR.SB
  cleared, and on NE a level-15 module_error (`Sun4M…txt:4941-4978`).
- Diagnostic ASIs: 0x30 tags (double: 42 SP, 41 burst, 40 V, 39 S, 38 C,
  37:36 size, 35:0 PA; entry VA[5:3]), 0x31 data (double, entry VA[5:3]),
  0x32 control (word: 8 SE (= MCNTL.SB, read-only), 7 EM (empty), 6 ER,
  5:3 drain pointer, 2:0 fill pointer) (Viking §4.12.7-4.12.9).
- OBP 2.25 `obp_cache_init` clears the 8 tags (`stda %g0` to ASI 0x30 at
  0x38..0) and writes 0 to ASI 0x32 (`listing.s:46396-46402`). QEMU returns
  0 for 0x30-0x32 loads and ignores stores (`ldst_helper.c:730-735`,
  `:1094-1101`).

### 3.7 What OBP 2.25 and its POST do to the caches, in order

1. **Reset entry** (`reset_entry`): no MCNTL write on Viking
   (`README.md:126-134`).
2. **POST start** (`post_iu_done`, `listing.s:6566-6606`): SFSR.EM test,
   flush entire TLB (`sta %g0,[0x400] 3`), the four flash clears, CTX = 1,
   CTPR = 0x40000 (table at pa 0x400000). MCNTL is not written: POST runs
   with ME = 0, BM = 1, caches and snooping off.
3. **POST tests** (`post-tests.md:69-102`, `:229-384`):
   - #4 CTPR walking one, mask 0xfffffc00; #5 context, mask 0xfff (12 bits);
     #6/#7 TLB patterns and flushes (§2.5).
   - #8 D-cache: flash 0x37 [0x80000000] then [0]; RAM test through ASI
     0x0F at `way<<26 | set<<5 | dw<<3`, all ones then zeros; PTAG at
     `0x80000000 | way<<26 | set<<5`, after all-ones expects hi 0x01010100
     (0x01000000 on SuperSPARC II) and lo 0x00ffffff; STAG at
     `0x40000000 | set<<5`, writing {0, 0xffffffff} expects lo 0xf0e,
     {0xffffffff, 0} expects lo 0.
   - #9 I-cache: ASI 0x0D `way<<26 | set<<6 | dw<<3`; PTAG hi 0x03000000, lo
     0x00ffffff; STAG lo 0x1f1e.
   - #10 I-cache flush test: init STAG 0x1f1e, PTAG {0x03000000, 0x502};
     0x36 [0x80000000] → STAG & 0x1f = 0; re-init, 0x36 [0] → STAG & 0x1f00
     = 0 and PTAG hi & 0x03000000 = 0.
   - #11 flash-clear test: lock flash → STAG 0xf00 (D) / 0x1f00 (I), PTAG
     unchanged; valid/MRU flash → STAG 0xe / 0x1e, PTAG hi 0.
   - A "D-Cache Write Hit Special Test" (dead code, runs only with MB = 1)
     expects copy-back with MB = 1 and write-through with MB = 0
     (`post-tests.md:406-452`).
4. **`obp_cache_init`** (`listing.s:46374-46449`): the four flash clears;
   I-cache STAG clear `stda %g0,[0x40000000 + 64n] 0x0c`, n = 0..63 (VA
   0x1000 down by 0x40); D-cache STAG clear `0x40000000 + 32n` ASI 0x0E,
   n = 0..127; PTAGs are not walked; store-buffer tags and control cleared;
   MXCC set-up only when MB = 0; then **MCNTL |= 0x4000 (SE)** and `sta
   %g0,[0] 0x4c`. Result on the SS20 module: reset value | SE, caches still
   off.
5. **First MMU-on** (`cold_mmu_on`, `listing.s:69035-69053`): MCNTL |= 1,
   clear BT (0x2000), %tbr = 0xffeff000, continue at the 0xffd00000 mapping
   of the same PROM page.
6. **Caches on, from Forth:** `vcache-on` = `mcr@ 0x4700 or mcr!` (SE | SB
   | IE | DE) (`forth-dictionary.txt:9130-9131`). `vcache-off`
   displacement-reads 64 KB, clears IE/DE and flash-clears.
7. **Watchdog reset path:** `MCNTL &= ~0x4301` (SE, IE, DE, ME), dump the
   TLB, lock two TLB entries, MMU on (§5.3).

### 3.8 The project's geometry and what the diagnostic ASIs must show

- **Disagreement inside the project:** the task statement and
  `docs/arch/cpu.md:227-237` plan "I-cache and D-cache of 16 KB, 4-way,
  32-byte lines"; `t_cache_diag` and the POST expect the real I-cache image
  (5 ways × 64 sets × 64-byte lines, two valid bits), and the PROMs publish
  the real geometry (C-6). bus.md says the
  line transfer is 32 bytes (`docs/arch/bus.md:65-86`); Viking fills each
  32-byte half-line separately on the MBus (only 32-byte bursts, Viking
  §8.1).
- **What the D-cache image must be** (`t_cache_diag.S:1-12`, POST #8):
  ASI 0x0F way VA[27:26], set VA[11:5], doubleword VA[4:3] (4 × 128 × 4);
  PTAG at `0x80000000 | way<<26 | set<<5`, all-ones reads back {0x01010100,
  0x00ffffff}; STAG at `0x40000000 | set<<5`, all-ones lo reads 0x00000f0e
  (MRU 11:8, locks 3:1; bit 0 and the hi word read 0).
- **What the I-cache image must be** (`t_cache_diag.S:1-12`, POST #9):
  ASI 0x0D way VA[28:26], set VA[11:6], doubleword VA[5:3] (5 × 64 × 8);
  PTAG `0x80000000 | way<<26 | set<<6`, all-ones reads {0x03000000,
  0x00ffffff}; STAG `0x40000000 | set<<6`, lo 0x00001f1e.
- **Index-reach rule** (C-6): OS flush loops reach
  every set as long as a tag-ASI write or line flush hits all ways at an
  index and the way size (4 KB) is not larger than the published cache.
  `mmu_off` clears tags through 0x0E/0x0C at a 32-byte stride over VA
  0..0xFFF "as the core decodes them (index VA[11:5])"
  (`mmu_setup.S:25-26`, `:265-272`) — with a 64-byte I-line each I set is
  written twice; OBP walks I STAGs at a 64-byte stride.
- The detailed checks are in §7.

---

## 4. Bus errors as the MMU sees them

### 4.1 What Viking does

- **Instruction and data bus errors are reported as
  instruction_access_exception (tt 0x01) / data_access_exception (tt
  0x09)**: Viking does not implement instruction_access_error (0x21) or
  data_access_error (0x29) (Viking Table 4-15, §4.13.4.3, §4.13.4.12,
  §4.11.11.3). MFSR: FT = 5 (access bus error) with BE/TO/UC from the MBus
  reply (ERROR1/2/3 → BE/TO/UC; RETRY → UC) (Viking §8.9.1); FAV for data,
  never for instruction faults.
- **Table-walk bus error:** FT = 4 (translation error), L = the level being
  fetched, plus the UD/TO/BE/UC bit (V8 §H.5; Viking §4.11.11.3 FT text);
  trapped as an access exception of the access being translated.
- **Probe walk errors** do not trap (§1.6). Bus errors on ASIs 0x08-0x0B,
  0x20-0x2F and probes do not set CS; bus errors on ASI 0x02 do (Viking
  §4.11.11.3).
- **data_store_error (tt 0x2B):** a store-buffer copy-out (non-cacheable
  store or copy-back in MBus mode) that gets an error; deferred; MFSR.SB;
  the buffer is disabled; reported only with PSR.ET = 1 (with ET = 0 the
  store-buffer control ER bit holds it pending until traps are enabled)
  (Viking §4.12.5, §4.12.9, §4.13.4.2). Sun-4M adds the level-15
  module_error (§3.6). OBP's POST has a tt 0x2B handler that reads the SFSR
  (`README.md:419`).
- **NF:** a fault masked by NF still updates the MFSR; masked loads return
  indeterminate data (Viking §4.11.10). ASI 0x09 and real instruction
  fetches are never masked.

### 4.2 What the project requires (`t_buserr`, PLAN §6 A3/B1)

The suite and the project follow V8's error traps instead of Viking's:
`TT_IACC_ERR 0x21`, `TT_DACC_ERR 0x29` (`platform.h:119-120`). Header of
`t_buserr.S:1-21`: "data_access_error (tt 0x29) or instruction_access_error
(tt 0x21) with SFSR FT 5 (Access Bus Error), the TO bit (11), AT, FAV and
the SFAR; a table walk that reads the refused address is a Translation
Error (FT 4, L the level) and faults as one, tt 9." "A store is posted and
never traps here: its error is the chipset's, reported asynchronously
(AFSR/AFAR and a level-15 interrupt, B1)." AT follows the ASI's user bit: a
bypass load through 0x2E/0x20 is AT 0 (the POST's 0x816); a supervisor load
through a mapping AT 1 (0x836); ldstub is a store (AT 4, 0x896).

- **Disagreement:** Viking Table 4-15 says the 0x21/0x29 traps do not exist
  on this chip; the SS20 POST and the suite expect them (iu-notes §6.4).
  `docs/arch/cpu.md:180-182` writes "0x2B (data access error)", which
  conflicts with both (0x2B is data_store_error).
- **POST expectations** (`post-tests.md:1956-1962`, `:2469-2472`): the dead
  EMC timeout test wants `SFSR & ~0x300 == 0x836`, SFAR 0x20000000, the
  second SFSR read 0, and tests `MCNTL == 0x800`; the MBus-to-EBus timeout
  test 0x436 (BE). The SBus time-out test reads pa 0xE_0000_0010 and expects
  SFSR 0x816 (`t_buserr.S:1-21`). SS5 POST: 0x816 (SBus) / 0x416 (EBus).
- **SFSR values in t_buserr** (decode: bit 11 TO, 9:8 L, 7:5 AT, 4:2 FT, 1
  FAV, 0 OW):

  | Access | tt | SFSR | SFAR |
  |---|---|---|---|
  | `lda [0x10] 0x2e` (pa 0xE_0000_0010, empty slot) | 0x29 | 0x816 (TO, AT 0, FT 5, FAV) | 0x10 (the VA) |
  | `ldstuba [0x10] 0x2e` | 0x29 | 0x896 (AT 4) | |
  | two loads, VA 0x10 then 0x14, no SFSR read between | 0x29 twice | 0x817 (OW) | 0x14 |
  | load with MCNTL.NF | none | 0x816 | |
  | `sta` to the slot | none | 0 | |
  | mapped load VA 0x295010 (PTE 0xe000000e) | 0x29 | 0x836 (AT 1) | 0x295010 |
  | `jmpl` to VA 0x295020 | 0x21 | 0x874 (TO, AT 3, FT 5, no FAV) | — |
  | load VA 0x280030 with L2[10] = PTD 0xe0000001 (level-3 table in the slot) | 0x09 | 0xb32 (TO, L 3, AT 1, FT 4, FAV) | 0x280030 |

  In every trapping case the destination register keeps its old value
  (0x5a5a1234) (`t_buserr.S:60-188`).
- Note the L value for the moved level-3 table: the walk faulted while
  fetching the level-3 entry, so L = 3 (V8 "the Level field records the page
  table level of the page table containing the entry").
- **QEMU** (deviation 11, README:134-138): traps an unassigned access only
  with the MMU on, as tt 0x29/0x21 per `sparc_raise_mmu_fault`, with FT 5
  and AT but no TO/BE bit and the physical address in the SFAR; with the
  MMU off (or NF) it records and continues; it sets no L bits and has an
  odd OW rule (`ldst_helper.c:422-481`). The README text says tt 9, the
  code `TT_DATA_ACCESS` 0x29. `t_buserr` skips on QEMU because the probe
  load does not trap.

---

## 5. Reset and the watchdog

### 5.1 State after each reset

| State | Hardware reset (Viking Table 4-1) | Watchdog reset (Viking §4.3.2, §4.13.2) | Sun-4M §12 POR/SWR/RSTSW → watchdog (`Sun4M…txt:3272-3321`) |
|---|---|---|---|
| MCNTL.BT | 1 | 1 (the only MCNTL bit changed) | boot-mode bit 1 → 1 |
| EN, NF, DE, IE, SB, SE, PSO, PE, PF, AC, TC | 0 | unchanged | caches/MMUs "Disabled" → "unchanged"; 'Dual' (snooping) Off → unchanged |
| MFSR.EM | 0 | 1 | watchdog bit 0 → 1 |
| rest of MFSR, MSFSR | uninitialized | unchanged (internal error: only EM and FT meaningful) | |
| TLB entries | unchanged | unchanged | TLBs unaffected |
| TLB lock bits | cleared | unchanged | |
| caches, tags | contents uninitialized / not changed | unchanged | caches, tags unaffected |
| store buffer | tags invalid, pointers 0 | — | write buffers empty → drain normally |
| breakpoints (BKC, BKS, ACTION) | cleared; ACTION.MIX = 0 | cleared | |
| PC / nPC | 0 / 4 | reset trap, tt not written (except from RETT) | |
| PSR | S = 1, ET = 0 | PS unchanged | |

- Sun-4M: "The contents of processor general registers, caches, tags,
  TLB's, and main memory are unaffected by RESET. All I/O devices and state
  machines will be reset" (`Sun4M…txt:3284-3287`). A watchdog reset "resets
  only the one processor, and generates a broadcast level-15 interrupt"
  (`:3272-3276`). Search order for the cause: "local-watchdog, local SI,
  SWR, RSTSW, POR" (`:3281-3282`).
- **Reset register:** Sun-4M generic 0x700: bit 2 WD (read-only), bit 1 SI
  (software internal reset, RW) (`Sun4M…txt:1046-1059`). **Viking/NE has
  none**: "The Watchdog Reset status is found in SFSR bit <17>"; EM asserts
  module_error until the SFSR is read; "Snooping is maintained during either
  an SI or a WD reset" (`:5132-5137`). With an MXCC the module reset
  register is ASI 2 0x01C00C00 (WD bit 2, SI bit 1, write 1 to clear) and
  SFSR bit 17 mirrors its WD (`:6517-6522`, `:6652-6668`, `:6502-6503`).
- **MBus mode signalling:** "Viking asserts AERR_ until MFSR.EM is cleared.
  For example, a read on MFSR clears it. This is then followed by a
  watchdog reset" (Viking errata "Page 54").
- **System control/status register** pa 0xF_F1F0_0000 (`Sun4M…txt:1104-1115`):
  bit 0 SW_RST (write: equivalent of a power-on reset), bit 1 SW_RST_STAT,
  bit 2 DIAG switch, bit 3 RST.SW. `wdtest` expects WD in **bit 4** of this
  register on the SS20 (`wdtest.S:43-101`); Sun-4M marks bits 31:4 reserved.
  The project's requirement RST: "RS/WD status after a software or watchdog
  reset" (PLAN line 359).
- **QEMU** has no watchdog (iu-notes §4.6). Its CPU reset clears only
  MCNTL.EN/NF and sets BM; CTPR, context, SFSR, SFAR and the other MCNTL
  bits survive (`cpu.c:36-84`, `cpu.h:484-508`).

### 5.2 How OBP 2.25 tells the resets apart

1. `reset_entry` reads MCNTL; IMPL = 1 → Ross (reset register 0x700 bit 2).
2. Viking (IMPL 0): `lda [0x300] 4; andcc 0x20000` → set → `reset_watchdog`
   (`listing.s:39111-39116`, `:39327-39329`). This read clears the SFSR.
3. Otherwise ASI 0x38 set-up and MID (§2.9), then pa 0xF_F1F0_0000: bit 3
   (switch) or bit 1 (software reset) → `obp_start` without POST; else
   power-on → POST (`listing.s:39233-39243`).
4. POST start tests SFSR.EM again and reports an unexpected watchdog
   (`listing.s:6586-6591`).
5. POST hands over to OBP through a software reset (master writes 1 to
   0xF_F1F0_0000) and every CPU re-enters `reset_entry`
   (`README.md:180-191`).

### 5.3 The watchdog path (`reset_watchdog` 0x26710)

`listing.s:39506-39831`; `README.md:248-258`: find the MID, clear its
pending soft interrupt (`0xf_f140_n004` ← 0x8000), save CTX; Viking:
`flush`, `MCNTL &= ~0x4301` (BT is left set); dump ASI 6 SEL 4/5/6
(`0x400`, `0x500`, `0x600`) and all 64 entries' SEL 0-3 into NVRAM
0x1cd8-0x1f63; flush entire; write TLB entries 0 and 1 (SEL0 VA
0x26000/0x27000, SEL1 = CTX, SEL2 PTE 0xff00263f/0xff00273f; also through
ASI 5 on SuperSPARC II); `MCNTL = (MCNTL & ~0x2000) | 1`; jump to the Forth
handler, which prints "Watchdog Reset". So the watchdog path relies on
ASI 6 writes creating usable translations (with the PTE's V bit, here
0x3f = C 0, M 0, V 1, ACC 7, LVL 3).

### 5.4 What `wdtest` expects (`tests/cpu/src/wdtest.S`, PLAN §6 IU-1)

- First boot: reads `lda [0xb00] 4` (the project-private **non-clearing
  SFSR alias**); EM clear → store 0x57444f47 at 0x201000,
  print "WD?", clear ET, `ta 0x7f` (error mode).
- Second boot: system status `lda [0xf1f00000] 0x2f & 0x10 == 0x10`
  (check 1); the marker survived (2); `lda [0x300] 4 & 0x20000` set (3);
  `lda [0xb00] 4 & 0x20000 == 0` (4: cleared by the 0x300 read).
- **The Viking equivalent of 0xB00** is the read/write MFSR alias at VA
  0x1300 (Viking §4.11.11.3 "MFSR timing and operation"; QEMU reads it
  without clearing, `ldst_helper.c:674-689`). On a Viking VA 0xB00 is not a
  register (data_access_exception with CS).
- Sun-4M B.I.4.4 is the source the test cites for EM
  (`wdtest.S:1-27`).

---

## 6. The L2 TLB / PTP cache option (MCNTL bit 6)

- **SuperSPARC itself** caches only PTP0 and one PTP2 (§2.4); MCNTL bits
  6:2 are reserved (Viking §4.11.11.1). The L2 TLB is this project's
  option: PLAN §2 lines 115-119 ("Plan for 16-32 fully associative entries
  plus a PTP cache, and keep the SuperSPARC 64-entry diagnostic TLB image
  (ASI 6) for the POST"); §3 phase 3 ("the L2 TLB/PTP cache (MCNTL bit 6;
  an ASI 5/6/7 write drops the TLBs, which NeXTSTEP needs)"); §6 L2 line
  343 ("L2 TLB safe to switch at run time; ASI 5/6/7 writes drop the
  TLBs", `t_mmu_l2`). OpenBIOS CPU 0 sets 0x4140 (SE, DE, bit 6)
  (SMP-3). `tlbbench.S -DTB_L2TLB` sets bit 6 (`tlbbench.S:1-40`).
- **Pitfall** (CFG-1): a 256-entry level-3 PTE block RAM with an 8-bit
  generation in the tag, bumped on each flush and swept 2 entries per
  flush, keeps its contents over reset, so switching the option on at run
  time after 256 flushes can revive stale entries. Remedy: sweep all
  entries after reset and whenever the enable rises.
- **Requirement: invisible** (`t_mmu_l2.S:1-16`): "a correct OS cannot tell
  it from a larger TLB". Three tests (MARK(i) = 0x4c200000 + i; PTE changes
  are normal stores to MT_L3 + 21×4 followed by `sta [VA] 0x10`; bit 6 set
  by read-modify-write of MCNTL):
  - **t_mmu_l2_asi6** (`:27-51`): VA 0x295000 → page 22 (0x4c200016); bit 6
    on; load = ...16 (1); remap L3[21] to page 23 without a TLB flush; load
    still ...16 (2); `sta %g0,[0x200] 6` (ASI 6 entry 0 SEL 2 := 0); load =
    **0x4c200017** (3). So any ASI 6 write must drop every cached
    translation, including the L2 TLB.
  - **t_mmu_l2_enable** (`:57-93`): bit 6 on; load ...16 (1); bit 6 off;
    remap to page 24; load 8 other pages (MT_PAGE(0..7)) so the L1 TLB
    forgets the entry (the comment assumes a 4-entry D-TLB); 256 writes of
    CTPR with its own value; bit 6 on; load must be **0x4c200018** (2). So
    re-enabling must not revive the old entry ("the core sweeps the L2 TLB
    RAM when bit 6 comes on").
  - **t_mmu_l2_probe** (`:95-114`): bit 6 on; load ...16 (1); remap to page
    25 with no flush; `lda [0x295400] 3` (entire probe) must return
    **0x0002998e**, the PTE in memory (2), not a cached one.
  - "Without the option they pass trivially" (README:88).
- **Disagreement:** README:88 says "QEMU passes them"; the expected QEMU log
  shows t_mmu_l2_asi6 (check 3 observes 0x4c200016) and t_mmu_l2_enable
  (check 2 observes 0x4c200016) failing (`expected/ss20-qemu.log:83-97`).
- **Interaction with Viking's probe rule:** Viking's entire probe returns
  the cached PTE on a TLB hit (§1.6). t_mmu_l2_probe expects the memory PTE
  for an entry that should still be in a 64-entry TLB; the test therefore
  requires the probe to bypass (or the walk to refresh) the cached entry.
  A probe that also flushes the matching TLB entry never returns a stale
  TLB entry, which NetBSD needs (MMU-6).
- **ASI 5 and 7:** Viking has neither (§2.5); the project requires that
  writes to them drop the TLBs (PLAN line 343). NeXTSTEP is the suspected
  user.

---

## 7. Acceptance (phase 3)

Phase 3 exit (PLAN §3, lines 172-185): t_mmu, t_mmu_diag, t_mmu_l2,
t_mmu_swift (expected skips on the SS20), t_cache*, t_buserr, memstress,
tlbbench and bmbench pass, and the suite runs from the real boot address.
The suite expects every MMU/cache/buserr test to pass on the board
(`expected/ss20-core-hw.log`, 76 pass / 0 fail / 2 skip); QEMU SS20 55 / 12 / 11 (`expected/ss20-qemu.log:106`).

### 7.1 Shared set-up (`mmu_setup.S`)

- Tables in SCRATCH (0x200000), written through ASI 0x20: MT_L1 0x230000,
  MT_L2 0x230400, MT_L3 0x230800, context table MT_CTX 0x240000 (**CTPR =
  0x24000**, 256 KB aligned), MT_SEG 0x280000 (L2 index 10), alias VA
  0x40000000, context-test VA 0x04000000 (`mmu_setup.S:30-41`).
- Formats: "PTD = (pa >> 4) | 1; PTE = ((pa >> 4) & ~0xff) | C << 7 | ACC << 2
  | 2", R/M set by hardware (`:1-27`).
- Entries: CTX[0] = 0x00023001; L1[0] = 0x00023041; L1[0x40] = 0x0000008e
  (16 MB alias); L2[i] = level-2 PTEs `(i<<18)>>4 | 0x8e` except L2[10] =
  0x00023081; L3[i] = `(0x280000 + i*0x1000)>>4 | 0x8e` except: 16 invalid
  (0), 17 reserved (0x00abcd03), 18 ACC 0 C 0 (0x00029202), 19 ACC 6 C 0
  (0x0002931a), 20 non-cacheable (0x0002940e), 21 → page 22 (0x0002968e).
  Contexts 1, 0x101, 0x8001 at MT_CTX + ctx×4 → private L1s whose entry 4
  maps VA 0x04000000 to pages 32/33/34 (`:43-177`).
- `mmu_on`: CTPR, CTX 0, flush entire (`sta [0x400] 3`), MCNTL = (MCNTL &
  ~BM) | 0x4301 (`:194-223`). `mmu_off`: line-flush VARS, stack and MT_SEG
  via ASI 0x10; MCNTL = (MCNTL & ~(0x4301|NF)) | BM; flash 0x37 then 0x36;
  `sta %g0` to ASI 0x0E and 0x0C for VA 0..0xFFF step 32; CTX 0; flush
  entire (`:240-278`).

### 7.2 Per-test behaviours

- **t_mmu_ctx_bits** (`t_mmu.S:15-55`): context readback = written &
  0xffff for walking ones 0-31, 0x5a5a5a5a → 0x5a5a, 0xa5a5a5a5 → 0xa5a5;
  CTPR readback & 0xffffffc0 = written for bits 6-31.
- **t_mmu_ctx_hi** (`:67-96`): loads of VA 0x04000000 in contexts 1, 0x101,
  0x8001, 1 (context write + entire flush each time) return 0xa0000001,
  0xb0000101, 0xc0008001, 0xa0000001: the full 16-bit context indexes the
  table.
- **t_mmu_tlb_flush** (`:113-160`): VA 0x295000 remapped by stores to
  0x230854; the old translation stays until a flush (check 2); each of page
  (VA), segment (0x280100), region (0x200), context (0x300) and entire
  (0x400) flushes makes the next load see the new page (0x7a000017..1b).
- **t_mmu_probe** (`:168-209`, MMU off; L3[0] = 0x000280ee, L2[4] =
  0x000100ee):

  | Probe address | Expected |
  |---|---|
  | 0x280000 (page) | 0x280ee |
  | 0x280100 (segment) | 0x23081 (the level-2 PTD) |
  | 0x280200 (region) | 0x23041 (the level-1 PTD) |
  | 0x300 (context) | 0x23001 (the root PTD) |
  | 0x280400 (entire) | 0x280ee |
  | 0x100400 (entire, level-2 PTE) | 0x100ee |
  | 0x100100 (segment probe of a level-2 PTE) | 0x100ee |
  | 0x290000 (page 16, invalid level 3) | 0 |
  | 0x80000000 (invalid level 1) | 0 |
  | 0x291000 (page 17, ET 3) | 0 |
  | 0x100000 (page probe, PTE at level 2) | **0** (QEMU 0x100ee, deviation 5) |

  These match V8 Table H-4 (§1.6), except that a page probe of an invalid
  level-3 entry returns the entry itself (0 here because the entry is 0).
- **t_mmu_fault_regs** (`:211-299`, MMU on):

  | Access | tt | SFSR | Other |
  |---|---|---|---|
  | ld page 16 (invalid L3) | 9 | 0x326 (L 3, AT 1, FT 1, FAV) | SFAR page 0x290000; next read 0 |
  | ld 0x80000000 (invalid L1) | 9 | 0x126 (L 1) | SFAR 0x80000000 |
  | ld page 17 (ET 3) | 9 | 0x332 (L 3, FT 4) | |
  | st page 18 (ACC 0) | 9 | 0x3aa (L 3, AT 5, FT 2) | QEMU 0xaa (deviation 6) |
  | user ld page 19 (ACC 6) | 9 | 0x30e (L 3, AT 0, FT 3) | QEMU 0x0e (deviation 6) |
  | two invalid loads, no read between | 9, 9 | 0x327 (OW) | |
  | NF set, invalid load | none | SFSR & ~1 = 0x326 | QEMU sets OW (deviation 9) |

  L is the level of the faulting PTE for protection and privilege faults too
  (MMU-8).
- **t_mmu_ifault** (`:301-332`): `jmpl` to 0x2908b8 (invalid page): tt 1,
  trap PC 0x2908b8, SFSR **0x366** (L 3, AT 3, FT 1, FAV, **no OW**), then
  0. Reason: Solaris 8's `get_fault_type` treats OW as "overwritten",
  re-probes and loops (SFSR 0x347 for a user text fault) (MMU-7/8). Note FAV is set here although Viking never writes the
  SFAR for instruction faults.
- **t_mmu_diag_pattern / t_mmu_diag_flush:** §2.5.
- **t_mmu_l2_asi6 / _enable / _probe:** §6.
- **t_asi_width** (`t_iu2.S:235-281`): §2.6.
- **t_flash_clear** (`t_cache2.S:13-63`): with DE off, a bypass store then
  `sta [0] 0x37`, DE on → the load sees the new value 0x22220000; with DE
  off, a normal store 0x33330000, flash, DE on → 0x33330000; I-side: IE off,
  patch an instruction via ASI 0x20, `sta [0] 0x36`, IE on → the routine
  returns 2. Checks 0x11110000, 0x22220000, 0x33330000, 1, 2.
- **t_cache_wrhit** (`:71-174`): 16 KB at MT_PAGE(0) filled by loads, every
  word overwritten (write hits); cached reads all new; bypass reads classify
  write-through (all new) or write-back (all old); after line flushes all
  0x1000 words in memory are new. The core and QEMU print write-through
  (V_WBMODE 1).
- **t_cache_flush_miss** (`:193-233`): mem 0x285080 = 0x51510000, loaded
  through the alias 0x40285080; then a bypass store 0x52520000 (write-through
  mode); six loads in other segments evict the D-TLB entry; `sta
  [0x40285080] 0x10`; expects 0x51510000, memory 0x52520000, cached reload
  0x52520000: the line flush must translate the VA (walk on a TLB miss),
  not use PA = VA.
- **t_cache_atomic** (`:240-279`): on a cached line 0x289040: `ldstub
  [+4]` returns 0x22, word 1 = 0xff222222, word 0 untouched; `swap [+8]`
  returns 0x33333333 and stores 0x55555555; word 3 untouched; memory word 0
  0x11111111; after the line flush memory shows 0xff222222 and 0x55555555.
- **t_cache_st_atomic** (`:288-344`): 512 iterations mixing `st` with
  ldstub/swap/stb on one line; word 0 must read i after each atomic, the
  lock byte is never found set; afterwards memory word 0 = 512, word 1 =
  512, byte 12 = 0. (Solaris 8 "recursive mutex_enter".)
- **t_cache_wback_burst** (`:355-423`): 32 lines at 0x28c000, word j of line
  i = (i+1)<<24 | (i+1)<<16 | j<<8 | j; per line `ldstub [line+4]` then `sta
  [line+4] 0x10`; after mmu_off every word in memory matches, word 1 with
  top byte 0xff.
- **t_selfmod** (`:428-451`): a normal store of 0x90102002 into a routine,
  `flush`, 5 nops; the routine returns 2: the I-cache must see the store
  (snoop invalidation of the own processor's store).
- **t_cache_fill_words** (`t_cache3.S:58-159`): 64 KB at 0x29c000 (mem =
  a ^ 0x5a5a1234); per line, load word 0 then 7..1 (all match); then load
  word 0 (miss), store words 7..1 during the fill, `lda [line] 0x20`, read
  7..1 back. "A line's tag is written valid when the fill starts … The CPU
  side must therefore stay blocked until the last beat has been written,
  even when the beats come with gaps" (`:1-14`; run with `Vsim_top
  --ddr-gaps`).
- **t_icache_fill_words** (`:190-259`): ten code lines at 0x2ac100 +
  k×0x1000 (one I set); lines 4-9 contain 7× `add %o0,k,%o0` + `retl`; 64
  rounds must each return 7k. The comment says "six lines, four ways"; with
  5 ways six lines still miss each call.
- **t_cdiag_data** (`t_cache_diag.S:97-112`; skipped unless ASI 4 VA 0xD00
  ≠ 0): flash both caches; write {addr, ~addr} at every way/set/doubleword
  (sampling every 7th D set, 5th I set) through 0x0F and 0x0D and read back;
  the I pass must not disturb the D image.
- **t_cdiag_tags** (`:114-173`): PTAG all-ones → D {0x01010100, 0x00ffffff},
  I {0x03000000, 0x00ffffff}; STAG (way 0) {0, 0xffffffff} → D lo 0x00000f0e,
  I 0x00001f1e, hi 0; no aliasing: each PTAG written {0x01000000 /
  0x03000000, base | way<<8 | set} (base 0x00500000 D, 0x00600000 I) reads
  back, STAGs still 0xf0e/0x1f1e; zeros read back as zeros.
- **t_cdiag_flash** (`:175-236`): from STAG 0xf0e/0x1f1e and PTAG
  {0x01000000/0x03000000, 0x502}:

  | Flash | D STAG | D PTAG hi | I STAG | I PTAG hi |
  |---|---|---|---|---|
  | `sta [0x80000000] 0x37` | 0xf00 | 0x01000000 | 0x1f1e | 0x03000000 |
  | `sta [0] 0x37` | 0xe | 0 | 0x1f1e | 0x03000000 |
  | `sta [0x80000000] 0x36` | 0xf0e | 0x01000000 | 0x1f00 | 0x03000000 |
  | `sta [0] 0x36` | 0xf0e | 0x01000000 | 0x1e | 0 |
  | all four | 0 | 0 | 0 | 0 |

  PTAG lo (0x502) is never changed by a flash.
- **t_cache_force** (`t_cache_force.S:16-50`): mem 0x294040 (page 20, PTE C =
  0) = 0x11110000; mmu_on; read the PTE at 0x230850 (l3 = 0x2940e); load the
  page (l1 = 0x11110000); PTE now 0x2942e (R); bypass store 0x22220000; the
  load still returns **0x11110000** (cached although C = 0); `st 0x33330000`;
  PTE now 0x2946e (R + M) as seen through the cache; `lda [0x294040] 0x20` =
  0x33330000. QEMU fails check 2 (deviation 12).
- **t_buserr_load / t_buserr_mapped:** §4.2.
- **wdtest:** §5.4 (separate ROM image).
- **t_smp_coherent / t_smp_nosnoop** (phase 9, listed for SE): with SE on CPU
  0 sees CPU 1's store to a line it caches; with SE off on CPU 0 it keeps the
  stale 0x71710000 until SE is set again and the line flushed
  (`t_smp.S:127-164`, `:241-284`).

### 7.3 QEMU deviations the core must not copy (`tests/cpu/README.md:97-145`)

- **5:** "A probe returns a PTE found above the level asked for." QEMU's
  `mmu_probe` returns a level-2 PTE to a page probe; V8 Table H-4 gives 0
  (`t_mmu_probe` check 11). Also: QEMU's probe never sets the SFSR, never
  sets R and never loads the TLB; types 0 and 4 behave alike; a
  context-level PTE returns 0 (`mmu_helper.c:268-355`).
- **6:** "SFSR.L is 0 for protection and privilege faults"
  (`t_mmu_fault_regs` checks 11 and 13; `mmu_helper.c:181-185`).
- **9:** "NF: the suppressed fault is recorded twice … so OW is set."
- **10:** "A page flush inside a large page's range flushes the whole TLB"
  (QEMU maps large PTEs as 4 KB pages; flush types 1-4 flush everything and
  ignore the context, `ldst_helper.c:970-994`).
- **11:** bus errors (§4.2).
- **12:** "No cache" (`t_cache_force` check 2).
- **Not numbered** but visible in the expected log or the code:
  - ASI 6 is not modelled (loads 0): t_mmu_diag_pattern/flush fail; ASI 6
    writes do not drop translations: t_mmu_l2_asi6/enable fail
    (`expected/ss20-qemu.log:83-97`).
  - QEMU's fault OW rule: any pending SFSR is replaced by 1 before the new
    status is ORed in (`mmu_helper.c:244-246`); FAR is the page-aligned VA,
    written for instruction faults too.
  - MMU faults are not trapped while PSR.ET = 0 (`mmu_helper.c:250-257`).
  - Boot mode: 19 VA bits and only with EN = 0 (§2.7).
  - ASI 4: no size or VA checks, VA[12:8] wrap; ASI 0x18/0x19/0x1C act as
    LEON MMU flush/regs/bypass on every CPU; ASI 2 MXCC registers answer on
    the MXCC-less model; cache and flush ASIs are silent no-ops
    (`ldst_helper.c:583-1155`, `asi.h:120-122`).
  - R/M write-back is a plain store, not atomic (`mmu_helper.c:188-197`).
  - A 4 GB (context-level) PTE is a translation error
    (`mmu_helper.c:117-119`).
  - CPU reset keeps CTPR/CTX/SFSR/SFAR and the cache enables
    (`cpu.c:76-77`).
- README:144-145: "The core has to follow the manual, not QEMU."

### 7.4 Facts the sources do not settle

- The exact SuperSPARC (3.x) behaviour of ASI 4 VA 0x1000, 0x500-0x700 and of
  ASIs 0x10-0x14 and 5/7: the Viking manual (1990) lists none of them, and
  no SS20 Viking code path in OBP 2.25 uses them.
- Whether a real SuperSPARC sets FAV for instruction faults: Viking says the
  SFAR is never written for them, the suite expects FAV in 0x366 and not in
  0x874.
- The corrected Viking Table 4-12 (errata page 104) is unreadable in the
  OCR; §1.3 uses V8's table.
- Viking's MFSR overwrite table (Table 4-10) contradicts both V8 and its own
  text for instruction/data faults arriving over a pending translation
  error (§1.5).
- Sun-4M's TLB SEL numbering (SEL 2 lock) contradicts Viking, SS-II and the
  ROM (§2.5).
- MCNTL IMPL/VER: Viking 0/0, Sun-4M 4/0, SS-II/QEMU/OBP 0/1 (§2.2, §2.3).
