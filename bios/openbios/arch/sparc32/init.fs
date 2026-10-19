:noname
  ."   Type 'help' for detailed information" cr
  \ ."   boot secondary slave cdrom: " cr
  \ ."    0 >  boot hd:2,\boot\vmlinuz root=/dev/hda2" cr
  ; DIAG-initializer

: make-openable ( path )
  find-dev if
    begin ?dup while
      \ install trivial open and close methods
      dup active-package! is-open
      parent
    repeat
  then
;

: preopen ( chosen-str node-path )
  2dup make-openable

  " /chosen" find-device
  open-dev ?dup if
    encode-int 2swap property
  else
    2drop
  then
;

:noname
  (set-defaults)
; PREPOST-initializer

\ preopen device nodes (and store the ihandles under /chosen)
:noname
  " memory" " /memory" preopen
  " mmu" " /virtual-memory" preopen
; SYSTEM-initializer

device-end

: rmap@    ( virt -- rmentry )
  drop 0
  ;

\ The Sun OBP's initsyms takes a client's symbol table (the address of its
\ a.out header and its size) for the PROM's debugger. NeXTSTEP's boot
\ loader hands its kernel's over through pv_fortheval
\ ("<addr> <size> initsyms"); OpenBIOS has no symbolic debugger.
: initsyms ( addr size -- )
  2drop
  ;

\ D5.3 SBus specific on-board memory address space
: obmem ( -- space )
  0
  ;

\ (peek) and (poke) implementation
defer sfsr@
defer ignore-dfault

:noname
  \ ( addr xt -- false | value true )
  sfsr@ drop            \ Clear any existing MMU fault status

  -1 ignore-dfault !    \ Disable data fault trap
  execute
  0 ignore-dfault !     \ Enable data fault trap

  sfsr@ 0= if
    true
  else
    drop false          \ Failed, drop the read value
  then
; to (peek)

:noname
  \ ( value addr xt -- okay? )
  sfsr@ drop            \ Clear any existing MMU fault status

  -1 ignore-dfault !    \ Disable data fault trap
  execute
  0 ignore-dfault !     \ Enable data fault trap

  sfsr@ 0=              \ true if no fault
; to (poke)

[IFDEF] CONFIG_TACUS
 -1 constant openbios-tacus
[THEN]

\ Load TCX FCode driver blob
[IFDEF] CONFIG_DRIVER_SBUS
  -1 value tcx-driver-fcode
  " QEMU,tcx.bin" $encode-file to tcx-driver-fcode
  [IFDEF] CONFIG_TACUS
    -1 value cgthree-driver-fcode
    " QEMU,cgthree.bin" $encode-file to cgthree-driver-fcode
  [THEN]
[THEN]
