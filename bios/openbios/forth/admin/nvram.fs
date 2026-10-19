\ tag: nvram config handling
\ 
\ this code implements IEEE 1275-1994 
\ 
\ Copyright (C) 2003, 2004 Samuel Rydh
\ 
\ See the file "COPYING" for further information about
\ the copyright and warranty status of this work.
\ 

struct ( config )
  2 cells field >cf.name
  2 cells field >cf.default            \ 0 -1 if no default
  /n field >cf.check-xt
  /n field >cf.exec-xt
  /n field >cf.next
  2 cells field >cf.saved              \ value kept in the NVRAM while >cf.temp?
  /n field >cf.temp?                   \ the value is for this boot only
constant config-info.size

0 value config-root 

\ --------------------------------------------------------
\ config handling
\ --------------------------------------------------------

: find-config ( name-str len -- 0|configptr )
  config-root
  begin ?dup while
    -rot
    2dup 4 pick >cf.name 2@
    strcmp 0= if
      2drop exit
    then
    rot  >cf.next @
  repeat
  2drop 0
;

: is-config-word ( configp -- )
  dup >cf.name 2@ $create ,
  does> @
    dup >cf.name 2@
    s" /options" find-dev if
      get-package-property if 0 -1 then
      ( configp prop-str prop-len )
      \ drop trailing zero
      ?dup if 1- then
    else
      2drop 0 -1
    then
    \ use default value if property is missing
    dup 0< if 2drop dup >cf.default 2@ then
    \ no default value, use empty string
    dup 0< if 2drop 0 0 then
    
    rot >cf.exec-xt @ execute
;

: new-config ( name-str name-len -- configp )
  2dup find-config ?dup if
    nip nip
    0 0 2 pick >cf.default 2!
  else
    dict-strdup
    here config-info.size allot
    dup config-info.size 0 fill
    config-root over >cf.next !
    dup to config-root
    dup >r >cf.name 2! r>
    dup is-config-word
  then
  ( configp )
;

: config-default ( str len configp --  )
  -rot
  dup 0> if dict-strdup then
  rot >cf.default 2!
;

: no-conf-def ( configp --  )
  0 -1
;

\ --------------------------------------------------------
\ config types
\ --------------------------------------------------------

: exec-str-conf ( str len -- str len )
  \ trivial
;
: check-str-conf ( str len -- str len valid? )
  \ nothing
  true
;

: str-config ( def-str len name len -- configp )
  new-config >r
  ['] exec-str-conf r@ >cf.exec-xt !
  ['] check-str-conf r@ >cf.check-xt !
  r> config-default
;

\ ------------------------------------------------------------

: exec-int-conf ( str len -- value )
  \ fixme
  parse-hex
;
: check-int-conf ( str len -- str len valid? )
  true
;

: int-config ( def-str len name len -- configp )
  new-config >r
  ['] exec-int-conf r@ >cf.exec-xt !
  ['] check-int-conf r@ >cf.check-xt !
  r> config-default
;

\ ------------------------------------------------------------

: exec-secmode-conf ( str len -- n )
  2dup s" command" strcmp 0= if 2drop 1 exit then
  2dup s" full" strcmp 0= if 2drop 2 exit then
  2drop 0
;
: check-secmode-conf ( str len -- str len valid? )
  2dup s" none" strcmp 0= if true exit then
  2dup s" command" strcmp 0= if true exit then
  2dup s" full" strcmp 0= if true exit then
  false
;

: secmode-config ( def-str len name len -- configp )
  new-config >r
  ['] exec-secmode-conf r@ >cf.exec-xt !
  ['] check-secmode-conf r@ >cf.check-xt !
  r> config-default
;

\ ------------------------------------------------------------

: exec-bool-conf ( str len -- value )
  2dup s" true" strcmp 0= if 2drop true exit then
  2dup s" false" strcmp 0= if 2drop false exit then
  2dup s" TRUE" strcmp 0= if 2drop false exit then
  2dup s" FALSE" strcmp 0= if 2drop false exit then
  parse-hex 0<>
;

: check-bool-conf ( name len -- str len valid? )
  2dup s" true" strcmp 0= if true exit then
  2dup s" false" strcmp 0= if true exit then
  2dup s" TRUE" strcmp 0= if 2drop s" true" true exit then
  2dup s" FALSE" strcmp 0= if 2drop s" false" true exit then
  false
;

: bool-config ( configp -- configp )
  new-config >r
  ['] exec-bool-conf r@ >cf.exec-xt !
  ['] check-bool-conf r@ >cf.check-xt !
  r> config-default
;


\ --------------------------------------------------------
\ writing the NVRAM
\ --------------------------------------------------------

\ update_nvram(), set by nvconf_init() once the NVRAM has been read: before
\ that, nothing is written.
0 value nvram-commit-func
: nvram-commit-func! ( func -- ) to nvram-commit-func ;

: nvram-commit ( -- )
  nvram-commit-func ?dup if call then
;

\ The value a variable keeps in the NVRAM: the one it had before a value
\ for this boot only ($setenv-temp), else its /options property.
: (config-nvvalue) ( configptr ph -- str len true | false )
  over >cf.temp? @ if
    drop >cf.saved 2@ dup 0< if 2drop false else true then exit
  then
  >r >cf.name 2@ r> get-package-property if
    false
  else
    dup if 1- then true      \ drop the trailing zero
  then
;

: (config-default?) ( str len configptr -- flag )
  >cf.default 2@ dup 0< if 2drop 2drop false exit then
  strcmp 0=
;

\ --------------------------------------------------------
\ 7.4.4    Nonvolatile memory
\ --------------------------------------------------------

\ $setenv sets a variable and saves it in the NVRAM, (setenv) only sets it.
: (setenv)   ( data-addr data-len name-str name-len -- )
  2dup find-config ?dup if
    >r 2swap r>
    ( name len data len configptr )
    >cf.check-xt @ execute
    0= abort" Invalid value."
    2swap
  else
    \ create string config type
    2dup no-conf-def 2swap str-config
  then
  
  2swap encode-string 2swap
  s" /options" find-package drop
  encode-property
;

: $setenv    ( data-addr data-len name-str name-len -- )
  2dup 2>r (setenv) 2r>
  find-config ?dup if 0 swap >cf.temp? ! then
  nvram-commit
;

\ A value for this boot only (on the MiSTer: the OSD's console and autoboot
\ choices, the one-shot reboot command): the NVRAM keeps the value from
\ before, until a $setenv of the variable.
: $setenv-temp ( data-addr data-len name-str name-len -- )
  2dup find-config ?dup 0= if
    2dup no-conf-def 2swap str-config
  then
  ( data len name len configptr )
  dup >cf.temp? @ 0= if
    dup s" /options" find-dev if
      (config-nvvalue) 0= if 0 -1 then
    else
      drop 0 -1
    then
    dup 0> if dict-strdup then
    2 pick >cf.saved 2!
    true over >cf.temp? !
  then
  drop (setenv)
;

: setenv    ( "nv-param< >new-value<eol>" -- )
  parse-word
   \ XXX drop blanks
  dup if linefeed parse else 0 0 then

  dup 0= abort" Invalid value."
  2swap $setenv
;
  
: printenv    ( "{param-name}<eol>" -- )
  \ XXX temporary implementation
  linefeed parse 2drop

  active-package
  s" /options" find-device
  .properties
  active-package!
;

: (set-default) ( configptr -- )
    0 over >cf.temp? !
    dup >cf.default 2@ dup 0>= if
      rot >cf.name 2@ (setenv)
    else
      \ no default value
      3drop
    then
;

: set-default    ( "param-name<eol>" -- )
  linefeed parse
  find-config ?dup if
    (set-default) nvram-commit
  else
    ." No such parameter." -2 throw
  then
;

\ every variable to its default, in RAM only (at boot)
: (set-defaults)    ( -- )
  config-root
  begin ?dup while
    dup (set-default)
    >cf.next @
  repeat
;

: set-defaults    ( -- )
  (set-defaults) nvram-commit
;

( maxlen "new-name< >" -- ) ( E: -- addr len )
: nodefault-bytes
  ;


\ --------------------------------------------------------
\ initialize config from nvram
\ --------------------------------------------------------

\ CHRP format (array of null-terminated strings, "variable=value")
: nvram-load-configs ( data len -- )
  \ XXX: no len checking performed...
  drop
  begin dup c@ while
    ( data )
    dup cstrlen 2dup + 1+ -rot
    ( next str len )
    ascii = left-split ( next val len name str )
    ['] (setenv) catch if
      2drop 2drop
    then
  repeat drop
;

: (nvram-append) ( buf len str slen -- buf+slen len-slen )
  dup >r 3 pick swap move
  swap r@ + swap r> -
;

\ one "name=value" entry, if it fits
: (nvram-store-one) ( buf len name nlen val vlen -- buf' len' )
  2 pick over + 2 +  5 pick > if 2drop 2drop exit then
  2>r (nvram-append) s" =" (nvram-append) 2r> (nvram-append)
  over 0 swap c!  swap 1+ swap 1-
;

\ The variables that differ from their defaults, so a later build's new
\ defaults still apply to the rest.
: nvram-store-configs ( data len -- )
  2 - \ make room for two trailing zeros

  s" /options" find-dev 0= if 2drop exit then
  >r
  config-root
  ( data len configptr R: phandle )
  begin ?dup while
    r@ over >r
    ( data len configptr phandle R: phandle configptr )
    (config-nvvalue) if
      2dup r@ (config-default?) if
        2drop
      else
        r@ >cf.name 2@ 2swap (nvram-store-one)
      then
    then
    r> >cf.next @
  repeat
  \ null terminate
  2 + 0 fill
  r> drop
;


\ --------------------------------------------------------
\ NVRAM variables
\ --------------------------------------------------------
\ fcode-debug? input-device output-device
s" true"     s" auto-boot?"           bool-config   \ 7.4.3.5
s" boot"     s" boot-command"         str-config    \ 7.4.3.5
s" "         s" boot-file"            str-config    \ 7.4.3.5
s" false"    s" diag-switch?"         bool-config   \ 7.4.3.5
no-conf-def  s" diag-device"          str-config    \ 7.4.3.5
no-conf-def  s" diag-file"            str-config    \ 7.4.3.5
s" false"    s" fcode-debug?"         bool-config   \ 7.7
s" "         s" nvramrc"              str-config    \ 7.4.4.2
s" false"    s" oem-banner?"          bool-config
s" "         s" oem-banner"           str-config  
s" false"    s" oem-logo?"            bool-config
no-conf-def  s" oem-logo"             str-config
s" false"    s" use-nvramrc?"         bool-config   \ 7.4.4.2
s" keyboard" s" input-device"         str-config    \ 7.4.5
s" screen"   s" output-device"        str-config    \ 7.4.5
s" 80"       s" screen-#columns"      int-config    \ 7.4.5
s" 24"       s" screen-#rows"         int-config    \ 7.4.5
s" 0"        s" selftest-#megs"       int-config
no-conf-def  s" security-mode"        secmode-config

\ --- devices ---
s" -1"       s" pci-probe-mask"       int-config
s" false"    s" default-mac-address"  bool-config
s" false"    s" skip-netboot?"        bool-config
s" true"     s" scroll-lock"          bool-config

[IFDEF] CONFIG_PPC
\ ---- PPC ----
s" false"    s" little-endian?"       bool-config
s" false"    s" real-mode?"           bool-config
s" -1"       s" real-base"            int-config
s" -1"       s" real-size"            int-config
s" 4000000"  s" load-base"          int-config
s" -1"       s" virt-base"            int-config
s" -1"       s" virt-size"            int-config
[THEN]

[IFDEF] CONFIG_X86
\ ---- X86 ----
s" true"     s" little-endian?"       bool-config
[THEN]

[IFDEF] CONFIG_SPARC32
\ ---- SPARC32 ----
s" 4000"     s" load-base"             int-config
s" true"     s" tpe-link-test?"        bool-config
s" 9600,8,n,1,-" s" ttya-mode"         str-config
s" true"     s" ttya-ignore-cd"        bool-config
s" false"    s" ttya-rts-dtr-off"      bool-config
s" 9600,8,n,1,-" s" ttyb-mode"         str-config
s" true"     s" ttyb-ignore-cd"        bool-config
s" false"    s" ttyb-rts-dtr-off"      bool-config
s" false"    s" keyboard-click?"       bool-config
[THEN]

[IFDEF] CONFIG_SPARC64
\ ---- SPARC64 ----
s" 4000"     s" load-base"          int-config
s" false"    s" little-endian?"       bool-config
[THEN]

\ --- ??? ---
s" "         s" boot-screen"          str-config
s" "         s" boot-script"          str-config
s" false"    s" use-generic?"         bool-config
s" disk"     s" boot-device"          str-config    \ 7.4.3.5
s" "         s" boot-args"            str-config    \ ???

\ defers
['] fcode-debug? to _fcode-debug?
['] diag-switch? to _diag-switch?

\ Hack for load-base: it seems that some Sun bootloaders try
\ and execute "<value> to load-base" which will only work if
\ load-base is value. Hence we redefine load-base here as a
\ value using its normal default.
[IFDEF] CONFIG_SPARC64
load-base value load-base
[THEN]

: release-load-area
    drop
;
