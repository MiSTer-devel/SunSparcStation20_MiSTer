# OpenBoot 2.x Forth: the dictionary format in the SS5 and SS20 PROMs

This is the format that `tools/romdis/obpforth.py` decodes. It was worked out
from the two images, read against their machine code, and checked against the
ROMs themselves running under QEMU (`words`, `see`, `ls`, `.attributes`; see
[Validation](#11-validation)). It applies to:

| | `ss5.bin` | SS20 `525-1377-08` |
|---|---|---|
| Firmware | OBP 2.15, built 95/03/29 | OBP 2.25, built 95/09/15 |
| Forth origin (file / listing / VA) | `0x15a00` / `0x70015a00` / `0xffd15a00` | `0x3e600` / `0x0003e600` / `0xffd3e600` |
| Token scale S | **4** | **16** |
| Dictionary (first header .. user image) | `0x15af4..0x3bd60` (153 KiB) | `0x3e728..0x6f4c0` (195 KiB) |
| User area image (copied to `0xffef0000`) | `0x3bd60`, 0x980 bytes | `0x6f4c0`, 0xa00 bytes |
| Words decoded | 4565 (2142 with headers) | 4849 (2230 with headers) |
| Undecoded bytes in the dictionary | 459 (0.29 %, 8 spans) | 434 (0.22 %, 11 spans) |

`ss5-170.bin` (TurboSPARC SS5, 97/01) has the SS20's layout (S = 16, NEXT at
`0x455e0`); it was not decoded.

The per-ROM outputs are `forth-dictionary.txt` (every word, decompiled),
`forth-nodes.txt` (the device tree built into the image), `forth.json` (what
`romdis.py` needs to print the dictionary as data and disassemble the machine
code inside it) and `fcode-*.txt` (the FCode images, from `tools/romdis/detok.py`).

## 1. Model

OBP 2.x is Bradley Forthware's *Forthmacs*, metacompiled into an image that
**runs in place from the PROM**: the PROM is mapped at VA `0xffd00000`, so the
dictionary's VA is `0xffd00000 + file offset` on both machines. New words
(FCode drivers, `nvramrc`, user definitions) go into RAM mapped right above the
ROM image in the same token space (`here` at the `ok` prompt: SS5
`0xffd42c68`, SS20 `0xffd704b8`). Per-CPU variable state lives in the *user
area* at `up = 0xffef0000` (64 KiB of RAM mapped there by the boot code), which
the cold start fills from the user area image at the end of the ROM
dictionary.

It is **token threaded with 16-bit tokens**. A token is the scaled offset of a
code field address (cfa) from the origin:

```
cfa = origin + token * S          (S = 4 on ss5.bin, 16 on the SS20)
```

With 16 bits this reaches 256 KiB (S = 4) or 1 MiB (S = 16) above the origin,
which is why the later, bigger 512 KiB images went to S = 16: every cfa is then
16-byte aligned and the dictionary pays for it in padding.

## 2. Registers and the inner interpreter

| Register | Use |
|---|---|
| `%g2` | origin (VA of the kernel start) |
| `%g3` | `up`, the user pointer (`0xffef0000`); the user area begins with a copy of NEXT, so **`jmp %g3` is NEXT** |
| `%g4` | top of the data stack |
| `%g5` | IP (points at the next token) |
| `%g6` | return stack pointer (grows down, 4-byte cells) |
| `%g7` | data stack pointer (grows down; `[%g7]` is the second item) |
| `%l1` | W: the cfa of the word being executed (set by NEXT) |
| `%l0` | scratch |

NEXT (user area offset 0, ROM copies at `0x7003bd60` / `0x0006f4c0`):

```
lduh [%g5], %l1          ! token
sll  %l1, log2(S), %l1
add  %l1, %g2, %l1       ! W = cfa
lduh [%l1], %l0          ! the code field is a 16-bit token as well
sll  %l0, log2(S), %l0
jmp  %l0 + %g2           ! run origin + cf*S
add  %g5, 2, %g5         ! IP += 2 (delay slot)
```

A code word ends with `jmp %g3` plus a delay-slot instruction. There are other
copies of NEXT inside code words (e.g. `0x7001ed58`, used by the debugger).

## 3. The kernel prologue: code-field handlers

The origin holds `ba,a cold` followed by the machine code every code field
points at. The tool finds the handlers by signature, so the tokens differ per
ROM:

| Handler | Runtime | SS5 token (addr) | SS20 token (addr) |
|---|---|---|---|
| docode | `jmp %l1+4` (S = 16 only: a code word's cf is 1) | - | `0x01` (`0x3e610`) |
| docolon | push IP on the return stack, IP = W+2 | `0x04` (`0x15a10`) | `0x02` (`0x3e620`) |
| docreate | push W+2 | `0x08` (`0x15a20`) | `0x03` (`0x3e630`) |
| dovariable | push W+2 aligned to 4 | `0x0c` (`0x15a30`) | `0x04` (`0x3e640`) |
| douser | push up + u16[W+2] | `0x12` (`0x15a48`) | `0x06` (`0x3e660`) |
| dovalue | push cell at up + u16[W+2] | `0x17` (`0x15a5c`) | `0x08` (`0x3e680`) |
| dodefer | execute the token at up + u16[W+2] | `0x1c` (`0x15a70`) | `0x0a` (`0x3e6a0`) |
| doconstant | push the cell in the two halfwords at W+2 | `0x24` (`0x15a90`) | `0x0c` (`0x3e6c0`) |
| do2constant | push the two cells at W+2 | `0x2b` (`0x15aac`) | `0x0e` (`0x3e6e0`) |
| dodoes | reached by `call dodoes` (see 5.1): push W+2, push IP, IP = `%o7`+8 | (`0x15adc`) | (`0x3e710`) |

`dovariable` is used by one word only, the metacompiler's label around the
machine-code cold start (`0x7001bb90` / `0x00045b10`).

## 4. Headers

```
 ... 0 pad | name bytes | count | link:16 | cf:16 | parameter field ...
                                           ^ cfa, S-aligned
count = 0x80 | 0x40 (immediate) | 0x20 (alias) | length (1..31)
link  = token of the previous word of the same vocabulary, 0 = end of list
```

* The count byte is at cfa-3, the name ends there; the bytes between the end
  of the previous word and the name are zero padding.
* Names are 7-bit and may contain any non-blank (`^<DEL>` in `keys-forth`).
* **Headerless words** are just `[cf][parameter field]` at an S-aligned
  address. More than half the words are headerless (the metacompiler strips
  internal names); `see` prints them as `(ffdxxxxx)`, and so do the outputs.
* **Aliases** (count bit 0x20, made by `alias new old`): the "cf" halfword is
  the *token of the aliased word* and there is no parameter field. A few alias
  RAM tokens (e.g. `save-forth` -> `0xcc67`).
* **Vocabularies are plain linked lists** (no hashing): each vocabulary has one
  16-bit thread head in the user area, and every header links to the previous
  word of the same vocabulary. The chains the tool walks from the user image
  reproduce the ROM's own `words` output exactly (1779 words in SS5 `forth`,
  1784 in the SS20's, and every other vocabulary).

## 5. Word types

| Kind (outputs) | Code field | Parameter field | SS5 / SS20 count |
|---|---|---|---|
| `colon` | docolon | 16-bit tokens up to `unnest` | 2637 / 2803 |
| `code` | S=4: own token + 1; S=16: docode (1) | 2 bytes padding, machine code at cfa+4 (4-aligned) | 268 / 286 |
| `constant` | doconstant | 32-bit value as two halfwords (2-aligned) | 341 / 388 |
| `2constant` | do2constant | two such cells | 1 / 2 |
| `user` | douser | u16 user-area offset | 165 / 166 |
| `value` | dovalue | u16 user-area offset (the cell lives in the user area) | 154 / 169 |
| `defer` | dodefer | u16 user-area offset (the token lives in the user area) | 149 / 151 |
| `create` | docreate | data up to the next word | 27 / 27 |
| `variable` | dovariable | data aligned to 4 (only the cold label) | 1 / 1 |
| `does` | token of a `call dodoes` | defining-word specific | 571 / 603 |
| `;code` | token of machine code that uses W | defining-word specific | 158 / 163 |
| `alias` | token of the target | none | 41 / 37 |

The initial contents of values, user variables and defers are in the user
area image; the dictionary listing prints them (`initial ...`,
`initially -> word`).

### 5.1 `does>`

`does>` compiles `(does>)`, pads to the next S-aligned address and lays down
two instructions: `call dodoes ; sub %g7,4,%g7`. The tokens of the does> clause
follow them and end with `unnest`. A child's cf is the token of that `call`;
dodoes then pushes the child's pfa (W+2) and runs the clause with
IP = `%o7`+8. The listing shows these as `[addr: call dodoes] does-body: ...`
in the defining word, and each child as `does> of <definer>`.

Common definers: `vocabulary`, `(buffer:)`, `label`, `acf-label`, `field`,
`difield`, `do-external` (32-bit absolute constants such as the VA of an FCode
image, `0000 ffd1 1f00`), `string-array`, the NVRAM option definers
(`/options` properties), the property word definer (5.4), `current-device`
fields of device-node records.

**`actions` tables** (Forthmacs "multiple code field" words, e.g. property
words, `%pc`-style register words, value-like `to` targets) are laid down by
the metacompiler without a colon definer:

```
[action n-1 token] ... [action 1 token]  [count n : 32]  call dodoes ; sub %g7,4,%g7  [does> tokens ... unnest]
```

Children point at the `call`; action *k* is found by counting back from it.
The action words themselves are `;code` children of a handler that takes an
inline token from its *caller's* stream (so `to foo` compiles `(action) foo`).

### 5.2 `;code`, `label`, `acf-label` and code fragments

`;code` compiles `(;code)`, pads to 4 and to S and continues with machine code;
children point at it. The metacompiler also emits such handlers without any
header or code field ("code fragments", e.g. the `file` fields at
`0x7001ab9c`, the ASI accessors `mcr@ sfsr@ ...` at `0x70027510`). `label` and
`acf-label` children hold machine code in their body (trap handlers, the
C-to-Forth entry `0x7002212c`, `prom-cold-code`); an `acf-label`'s code is used
as the cf of further words. `forth.json` gives all of these to `romdis.py` as
code entries (`fw_...`).

### 5.3 C-callable stubs

C code (the client interface, `romvec`) calls Forth through 16-byte stubs:
`save %sp,-N,%sp ; call enter-forth ; nop` followed by one or two tokens, the
last being a code word that restores the C registers and returns (`c-entry` in
the listing; 26 in each ROM, e.g. `0x70024c60`).

### 5.4 Device nodes and properties in the dictionary

A device node built at metacompile time is a vocabulary (its methods) followed
at the next S-aligned cfa at or after cfa+8 by a second vocabulary (its
properties). The node's record in the user area, at the methods vocabulary's
offset M:

| Offset | Content |
|---|---|
| M+0 | methods list head (token) |
| M+2 | first child node (token) |
| M+4 | next peer node (token) |
| M+6 | properties vocabulary (token) |
| M+8, M+0xc | two cells (instance data size / offsets, not decoded) |
| M+0x10 | a token |
| M+0x12 | properties list head (token) |

A static property is a child of the property `actions` word
(`0x700233dc` / `0x0004ecb0`, does> `dup dup @ - swap na1+ w@`): its body is
`[offset:32][length:16]` and the value lies at pfa - offset, compiled before
the header. Properties with computed values (`stdin-path`, the NVRAM options,
the aliases, `available`) are words of other definers. `forth-nodes.txt` walks
this structure from `root-node`; see `device-tree.md` for the result.

## 6. Colon bodies

Tokens run until `unnest` (`;`). `exit` is a separate word, so the first
`unnest` beyond every forward branch ends the definition. Inline operands:

| Word | SS5 token | SS20 token | Operand |
|---|---|---|---|
| `(lit)` | `0x003f` | `0x0013` | 32 bits (two halfwords, 2-aligned) |
| `(wlit)` | `0x004b` | `0x0016` | 16 bits; pushes value **- 1** (`literal` uses it for -1..0xfffe) |
| `(dlit)` | `0x0822` | `0x025a` | 64 bits |
| `branch` / `?branch` | `0x005f` / `0x0066` | `0x001c` / `0x001e` | signed 16-bit offset from the offset's own address |
| `(do)` / `(?do)` | `0x0087` / `0x0099` | `0x0027` / `0x002c` | offset to the loop exit (`leave` target) |
| `(loop)` / `(+loop)` | `0x0070` / `0x007b` | `0x0021` / `0x0024` | offset back to the loop body |
| `(of)` / `(endof)` | `0x00c8` / `0x00db` | `0x003a` / `0x003f` | offset to the next case / past `endcase` |
| `(')` | `0x04fb` | `0x0178` | a token (`['] word`) |
| `(is)` / `compile` | `0x13ce` / `0x0d45` | `0x05ea` / `0x03eb` | a token |
| `(")` `(.")` `(abort")` `("s)` | `0x0514` `0x0cdc` `0x0ce1` `0x0ce9` | `0x017f` `0x03ca` `0x03cc` `0x03ce` | count byte, the bytes, at least one NUL, padded to even |
| `(does>)` / `(;code)` | `0x0e5b` / `0x1050` | `0x0444` / `0x04e1` | machine code at the next S-aligned address |

No operand: `(leave)`, `(?leave)` (they take the exit address the `(do)` frame
saved), `(endcase)`. Beyond this table the tool finds operand-taking code by
analysing machine code: a routine that advances `%g5` by *n* before NEXT takes
*n* inline bytes (a token if it scales and adds `%g2`); that covers the action
handlers.

**RAM tokens**: one ROM word in each image uses a token above the ROM image
(SS5 `0xc058` = `0xffd45b60`), a word the ROM expects to find at a fixed place
in RAM (the a.out loader's buffer word).

## 7. The user area image

Copied to `0xffef0000` by the cold start (the machine-code side; see the ROM
READMEs, section "Kernel start"). Offset 0 holds NEXT (32 bytes); after it:
user variables, the cells of values, the tokens of defers, the vocabulary list
heads, the device-node records (5.4), and (SS5) at `+0x4a0..+0x4bc` the POST results
and memory layout the boot code stores for Forth.

## 8. Cold start

The machine code (SS5 `0x7002a86c` `prom-cold-code`, SS20 `0x00055d54`)
maps the ROM at `0xffd00000`, derives `%g2` from the PC, copies the user image
to `0xffef0000`, sets `%g5` and jumps to NEXT at `%g3`. The first token run is
the body of **`cold`** (SS5 `0x7001b338`, SS20 `0x00045130`):

```
: cold  decimal init-io do-init ['] init-environment guarded ['] cold-hook guarded quit ;
```

with the defers `init-io` -> `stand-init-io`, `do-init` -> `init` (a chain of
`init`s, one per module), `init-environment` -> `stand-init` (the machine setup:
CPU node, clocks, model, banner, SBus probing) and `cold-hook` -> `(cold-hook`
-> `startup` (banner, POST result, memory test, `test-`/`boot-` drop-ins,
auto-boot). On the SS20 the slave CPUs start at `>idle-cpu-loop`
(`0x000549f0`). `stand-init` and friends are redefined several times, each
calling the previous definition.

## 9. FCode

The byte-code interpreter keeps its token tables in the dictionary (SS5
`0x70035de4`, SS20 `0x000682c0`): per FCode page (high byte) 256 16-bit tokens
followed by a 32-byte bitmap of the FCodes executed while compiling (0x220
bytes per page, three pages, 0x000-0x2ff). The table words are OBP 2.x names
(`attribute`, `xdrint`, `xdrphys`, `get-my-attribute` ...), which
`detok.py` uses. FCode images: `startN`/`version1` byte, format, checksum
(sum of bytes 8..length), 32-bit length; 1- or 2-byte FCode numbers, 16-bit
branch offsets (8-bit in `version1` images before `offset16`) counted from the
offset's first byte. `probe`/`byte-load` map a slot's FCode PROM and
interpret it; the SBus node's `map-in` substitutes the images built into the
PROM for the on-board slots (see `device-tree.md`).

## 10. How the tool decompiles

1. Detect origin, S and the handlers by machine-code signature; find `(lit)`
   (the first header) and the user image (NEXT followed by zeros).
2. Scan every S-aligned position for a header (count byte with bit 7, 7-bit
   name, link below its own token). Trust a candidate only on a link chain
   whose head is stored somewhere: a vocabulary or node head in the user
   image, or a token that a decoded word uses. A header has at most one
   successor, so a candidate that links to an already-claimed header is a
   coincidence in data (79 rejected in SS5, 8 in the SS20).
3. Parse from every header, following every token used (bodies, defer
   defaults, alias targets, FCode tables, device-node records) until closure.
4. Walk the dictionary in address order and decode the gaps between known
   words: header candidates, headerless words at S-aligned positions,
   `actions` tables, C stubs, code fragments; resolve overlaps in favour of
   referenced words; give data words the space up to the next word; clip
   machine code at the next word and extend it over machine code that
   follows (branch targets past a routine's last exit).
5. Any address known to execute (the cold entry, the QEMU trace in
   `qemu-trace.json`) that is still inside a data word becomes code: either the
   unreferenced code word it belongs to or a code island in that body.
6. Emit the dictionary listing, the node tree, and `forth.json`: `regions` of
   type `forth` (`format: w16`, printed as halfwords) for everything that is
   not machine code, `entries` + `labels` (`fw_<name>`, `fw_<VA>` for
   headerless ones) for every piece of machine code, a label (`f_<name>`) and a
   comment block with the decompilation at every word, NEXT comments on
   `jmp %g3`. Regions that overlap one already in `romdis.json` are clipped.

## 11. Validation

Under QEMU (`qemu-system-sparc -M SS-5 -bios ss5.bin`, `-M SS-20` for the
other; see the ROM READMEs) both PROMs reach `ok`:

* `words` in every vocabulary: the chains from the ROM image match exactly,
  word for word and in order (`forth`, `hidden`, `root`, `options`,
  `aliases`, `keyboards`, `keys-forth`, `disassembler`,
  `magic-device-types`; `command-completion` and `re-heads` are empty in ROM).
* `see` on 400 random SS5 and 300 SS20 colon words, compared token by token
  (control words and string contents normalised): all agree. The
  differences left are formatting and places where the ROM's `see` itself
  guesses a wrong name for a headerless word (it shows `(ffd25b34)` as
  `[compile] @`).
* `ls` / `.attributes`: the static nodes and their properties match the
  running tree (the runtime additions are listed in `device-tree.md`).

## 12. Differences between the two ROMs

* Token scale 4 vs 16; the docode handler (cf = 1) exists only with S = 16,
  and all handler tokens differ.
* The SS20 dictionary is bigger (multi-CPU, MXCC/Viking/Ross support,
  `eccmemctl`, SX, DBRI, cgfourteen) but uses the same header, body, node and
  property formats.
* The SS20's onboard-device FCode keeps its names (`named-token`), the SS5's is
  mostly headerless.

## 13. Open items

* The two cells at M+8 / M+0xc and the token at M+0x10 of a node record.
* The descriptor the cold code reads (`[%i0+4]`, `[%i0+8]`) is set up by the
  machine code; its fields are documented on that side.
* The remaining undecoded spans (under 0.3 %) are data tables after
  `termemu close`, tables in the SBus/ethernet code and a few zero-padded
  literals; they are printed as data, flagged `UNDECODED` in the listing.
* FCode image checksums differ from the plain byte sum by small amounts
  (SS5 `0xc4cb`/`0xc4ca`, `0x9fc7`/`0x9fb5`); OBP only checks them when
  `fcode-checksum?` is set.
