-- AILApp.src.App
-- PIC18 application: UART receive into line buffer.
--
-- Memory map (manual allocation — see AIL#19 for compiler-managed static RAM):
--   0x20        rx_head
--   0x21        rx_tail
--   0x22        rx_temp   (ring buffer push scratch byte)
--   0x23–0x42   rx_data   (32-byte ring buffer body)
--   0x43        rx_overrun
--   0x44        getch_result
--   0x45        line_len
--   0x46–0x85   line_buf  (64-byte line accumulation buffer)
--
-- IVT:
--   vec 0 = main (reset entry, ProcBody.forever)
--   vec 1 = uart_rx_isr (high-priority interrupt handler)
--
-- Language features used:
--   ProcBody.forever    — main event loop
--   ProcBody.whileLoop  — getch spin-wait (AIL#12)
--   ProcBody.cond       — OERR/FERR/full guards in ISR
--   makeINTCON          — INTCON/GIE nodes for critical section (AIL#14)
--   ProcBody.intrinsic  — ring buffer pop, line append (FSR ops not yet
--                         expressible as abstract typed nodes; AIL#13, #21)
--
-- Known design gaps (see LANGDEF.md and open GitHub issues):
--   AIL#13  FSR resource annotations — pop/push use FSR0; the critical section
--           (AIL#14) prevents ISR corruption but a typed annotation would allow
--           the compiler to verify the non-conflict with FSR1 in append_line.
--   AIL#19  Static RAM allocator — addresses assigned manually here.
--   AIL#20  Implicit Store merging — rb/ic nodes merged manually below.

import AIL
import AIL.Lib.RingBuf
import AIL.Targets.PIC18.Emitter

open AIL AIL.PIC18

-- ---------------------------------------------------------------------------
-- UART SFRs (PIC18F56Q71, DS40002329F)
-- ---------------------------------------------------------------------------

private def n_RCSTA : Node := .peripheral .sfr 0xFAB
  { readable := true, writable := true,
    sideEffectOnRead := false, sideEffectOnWrite := false, accessWidth := .w8 }
  "RCSTA"
private def h_RCSTA := hashNode n_RCSTA

private def n_RCREG : Node := .peripheral .sfr 0xFAE
  { readable := true, writable := false,
    sideEffectOnRead := true, sideEffectOnWrite := false, accessWidth := .w8 }
  "RCREG"
private def h_RCREG := hashNode n_RCREG

private def n_OERR : Node := .bitField h_RCSTA 1 "OERR"
private def h_OERR := hashNode n_OERR

private def n_FERR : Node := .bitField h_RCSTA 2 "FERR"
private def h_FERR := hashNode n_FERR

-- STATUS register (Z flag needed for character comparison)
private def n_STATUS : Node := .peripheral .sfr 0xFD8
  { readable := true, writable := true,
    sideEffectOnRead := false, sideEffectOnWrite := false, accessWidth := .w8 }
  "STATUS"
private def h_STATUS := hashNode n_STATUS

private def n_Z : Node := .bitField h_STATUS 2 "Z"
private def h_Z := hashNode n_Z

-- ---------------------------------------------------------------------------
-- Ring buffer (rx_head=0x20, rx_tail=0x21, rx_data=0x23, rx_temp=0x22, cap=32)
-- ---------------------------------------------------------------------------

private def rb := makeRingBuf 0x20 0x21 0x23 0x22 32 1000 "rx"

-- ---------------------------------------------------------------------------
-- INTCON — critical section primitives (AIL#14)
-- Classic PIC18 / Q71: INTCON at SFR 0xFF2, GIE = bit 7.
-- ---------------------------------------------------------------------------

private def ic := makeINTCON 0xFF2

-- ---------------------------------------------------------------------------
-- Application state
-- ---------------------------------------------------------------------------

private def n_rx_overrun   : Node := .data .data .w8 0x43 "rx_overrun"
private def h_rx_overrun   := hashNode n_rx_overrun
private def n_getch_result : Node := .data .data .w8 0x44 "getch_result"
private def h_getch_result := hashNode n_getch_result
private def n_line_len     : Node := .data .data .w8 0x45 "line_len"
private def h_line_len     := hashNode n_line_len
private def n_line_buf     : Node := .staticArray .data .w8 0x46 64 "line_buf"
private def h_line_buf     := hashNode n_line_buf

-- ---------------------------------------------------------------------------
-- Bool formals
-- ---------------------------------------------------------------------------

private def n_bool_oerr  : Node := .formal 1001 .bool
private def h_bool_oerr  := hashNode n_bool_oerr
private def n_bool_ferr  : Node := .formal 1002 .bool
private def h_bool_ferr  := hashNode n_bool_ferr
private def n_bool_full  : Node := .formal 1003 .bool
private def h_bool_full  := hashNode n_bool_full
private def n_bool_empty : Node := .formal 1004 .bool
private def h_bool_empty := hashNode n_bool_empty
private def n_bool_nl    : Node := .formal 1005 .bool
private def h_bool_nl    := hashNode n_bool_nl

-- ---------------------------------------------------------------------------
-- Shared utility nodes
-- ---------------------------------------------------------------------------

private def n_nop : Node := .proc #[] #[] (.seq #[]) "nop"
private def h_nop := hashNode n_nop

-- ---------------------------------------------------------------------------
-- ISR: uart_rx_isr
--
-- Sequence:
--   1. if OERR → panic
--   2. if FERR → discard byte + retfie
--   3. read RCREG → WREG
--   4. if rx_buf full → set rx_overrun + retfie
--   5. push WREG to rx_buf
-- ---------------------------------------------------------------------------

private def n_panic : Node := .proc #[] #[]
  (.intrinsic #["_L_panic:", "    goto    _L_panic"] #[] #[]
              #["halt: never returns"])
  "panic"
private def h_panic := hashNode n_panic

private def n_early_retfie : Node := .proc #[] #[]
  (.intrinsic #["    retfie  0"] #[] #[] #["early ISR exit"])
  "early_retfie"
private def h_early_retfie := hashNode n_early_retfie

private def n_discard_rcreg : Node := .proc #[] #[]
  (.atomic (.abstract .loadDiscard) #[h_RCREG] #[]) "discard_rcreg"
private def h_discard_rcreg := hashNode n_discard_rcreg

private def n_read_rcreg : Node := .proc #[] #[]
  (.atomic (.abstract .load) #[h_RCREG] #[]) "read_rcreg"
private def h_read_rcreg := hashNode n_read_rcreg

-- if OERR → panic
private def n_test_oerr : Node := .proc #[] #[h_bool_oerr]
  (.atomic (.abstract .testBit) #[h_OERR] #[]) "test_oerr"
private def h_test_oerr := hashNode n_test_oerr
private def n_if_oerr : Node := .proc #[] #[]
  (.cond h_test_oerr h_panic h_nop) "if_oerr"
private def h_if_oerr := hashNode n_if_oerr

-- if FERR → discard + retfie
private def n_test_ferr : Node := .proc #[] #[h_bool_ferr]
  (.atomic (.abstract .testBit) #[h_FERR] #[]) "test_ferr"
private def h_test_ferr := hashNode n_test_ferr
private def n_discard_and_retfie : Node := .proc #[] #[]
  (.seq #[h_discard_rcreg, h_early_retfie]) "discard_and_retfie"
private def h_discard_and_retfie := hashNode n_discard_and_retfie
private def n_if_ferr : Node := .proc #[] #[]
  (.cond h_test_ferr h_discard_and_retfie h_nop) "if_ferr"
private def h_if_ferr := hashNode n_if_ferr

-- if full → set overrun + retfie
private def n_set_overrun_and_retfie : Node := .proc #[] #[]
  (.intrinsic
    #[s!"    setf    {hashLabel h_rx_overrun}, c", "    retfie  0"]
    #[] #[h_rx_overrun]
    #["set rx_overrun flag; drop byte; exit ISR"])
  "set_overrun_and_retfie"
private def h_set_overrun_and_retfie := hashNode n_set_overrun_and_retfie

private def n_if_full : Node := .proc #[] #[]
  (.cond rb.h_is_full h_set_overrun_and_retfie rb.h_push) "if_full"
private def h_if_full := hashNode n_if_full

-- Top-level ISR: check errors, read byte, push to ring buffer
private def n_uart_rx_isr : Node := .proc #[] #[]
  (.seq #[h_if_oerr, h_if_ferr, h_read_rcreg, h_if_full]) "uart_rx_isr"
private def h_uart_rx_isr := hashNode n_uart_rx_isr

-- ---------------------------------------------------------------------------
-- Main loop: getch → line buffer until '\n', then process_line
--
-- getch = whileLoop(is_empty, nop) then pop
--         whileLoop replaces the raw assembly spin-wait (AIL#12 resolved)
-- ---------------------------------------------------------------------------

-- is_empty: head == tail (buffer empty)
-- CPFSEQ skips when TRUE (head == tail = empty) — satisfies proc [] [Bool] 0
private def n_is_empty : Node := .proc #[] #[h_bool_empty]
  (.intrinsic
    #[s!"    movf    {hashLabel rb.h_tail}, w, c",
      s!"    cpfseq  {hashLabel rb.h_head}, c"]
    #[rb.h_head, rb.h_tail] #[]
    #["condition: head == tail (buffer empty)"])
  "rx_is_empty"
private def h_is_empty := hashNode n_is_empty

-- getch: spin until non-empty, then pop
-- whileLoop(is_empty, nop): loops while empty; exits when byte is available
private def n_getch_nop : Node := .proc #[] #[] (.seq #[]) "getch_nop"
private def h_getch_nop := hashNode n_getch_nop

private def n_getch_spin : Node := .proc #[] #[]
  (.whileLoop h_is_empty h_getch_nop) "getch_spin"
private def h_getch_spin := hashNode n_getch_spin

-- pop: FSR0-indirect read of buf[head] → getch_result; advance head mod 32
-- TODO: AIL#13 — uses FSR0, conflicts with ISR push. AIL#14 needed for safety.
private def n_pop : Node := .proc #[] #[h_getch_result]
  (.intrinsic
    #[s!"    lfsr    0, {hashLabel rb.h_data}",
      s!"    movf    {hashLabel rb.h_head}, w, c",
      "    addwf   FSR0L, f, c",
      "    movf    INDF0, w, c",
      s!"    movwf   {hashLabel h_getch_result}, c",
      s!"    incf    {hashLabel rb.h_head}, f, c",
      "    movlw   31",
      s!"    andwf   {hashLabel rb.h_head}, f, c"]
    #[rb.h_data, rb.h_head] #[rb.h_head, h_getch_result]
    #["pop buf[head] → getch_result; advance head mod 32",
      "uses FSR0; caller (critical_pop) wraps in BCF/BSF INTCON.GIE (AIL#14 resolved)",
      "TODO AIL#13: FSR annotation would make the FSR0 usage statically checkable"])
  "rx_pop"
private def h_pop := hashNode n_pop

-- critical section: disable_ints; pop; enable_ints
-- Protects FSR0 use in pop from being clobbered by the UART ISR (which also
-- uses FSR0 for ring buffer push). BCF/BSF INTCON.GIE (makeINTCON, AIL#14).
private def n_critical_pop : Node := .proc #[] #[h_getch_result]
  (.seq #[ic.h_disable_ints, h_pop, ic.h_enable_ints]) "critical_pop"
private def h_critical_pop := hashNode n_critical_pop

private def n_getch : Node := .proc #[] #[h_getch_result]
  (.seq #[h_getch_spin, h_critical_pop]) "getch"
private def h_getch := hashNode n_getch

-- newline detection: load getch_result; xorlw '\n'; btfss STATUS,Z
private def n_load_gc : Node := .proc #[h_getch_result] #[]
  (.atomic (.abstract .load) #[h_getch_result] #[]) "load_getch_result"
private def h_load_gc := hashNode n_load_gc

private def n_xor_nl : Node := .proc #[] #[]
  (.atomic (.abstract (.xorImm 0x0a)) #[] #[]) "xor_newline"
private def h_xor_nl := hashNode n_xor_nl

private def n_test_z : Node := .proc #[] #[h_bool_nl]
  (.atomic (.abstract .testBit) #[h_Z] #[]) "test_Z_flag"
private def h_test_z := hashNode n_test_z

private def n_test_nl : Node := .proc #[] #[h_bool_nl]
  (.seq #[h_load_gc, h_xor_nl, h_test_z]) "test_is_newline"
private def h_test_nl := hashNode n_test_nl

-- append_line: line_buf[line_len] = getch_result; line_len++
-- Uses FSR1 (not FSR0) — no conflict with getch pop (FSR0).
private def n_append_line : Node := .proc #[] #[]
  (.intrinsic
    #[s!"    lfsr    1, {hashLabel h_line_buf}",
      s!"    movf    {hashLabel h_line_len}, w, c",
      "    addwf   FSR1L, f, c",
      s!"    movf    {hashLabel h_getch_result}, w, c",
      "    movwf   INDF1, c",
      s!"    incf    {hashLabel h_line_len}, f, c"]
    #[h_line_buf, h_line_len, h_getch_result] #[h_line_len]
    #["line_buf[line_len] = getch_result; line_len++",
      "uses FSR1 (distinct from FSR0 used by getch pop — no FSR conflict)"])
  "append_line"
private def h_append_line := hashNode n_append_line

-- process_line: consume accumulated line (stub)
-- TODO: implement command dispatch / echo
private def n_process_line : Node := .proc #[] #[]
  (.intrinsic
    #[s!"    clrf    {hashLabel h_line_len}, c"]
    #[] #[h_line_len]
    #["stub: clear line buffer; TODO implement line processing"])
  "process_line"
private def h_process_line := hashNode n_process_line

-- if newline → process_line else → append_line
private def n_if_nl : Node := .proc #[] #[]
  (.cond h_test_nl h_process_line h_append_line) "if_newline"
private def h_if_nl := hashNode n_if_nl

-- main_body: one iteration — fetch byte, dispatch on newline
private def n_main_body : Node := .proc #[] #[]
  (.seq #[h_getch, h_if_nl]) "main_body"
private def h_main_body := hashNode n_main_body

-- main: reset entry — run forever
private def n_main : Node := .proc #[] #[]
  (.forever h_main_body) "main"
private def h_main := hashNode n_main

-- ---------------------------------------------------------------------------
-- Program store (manual merge — see AIL#20 for implicit library integration)
-- ---------------------------------------------------------------------------

def appStore : Store :=
  -- Ring buffer nodes
  let s := rb.nodes.foldl (fun acc (h, n) => Store.insert acc h n) Store.empty
  -- INTCON / critical section nodes (AIL#14)
  let s := ic.nodes.foldl (fun acc (h, n) => Store.insert acc h n) s
  -- SFRs
  let s := Store.insert s h_RCSTA             n_RCSTA
  let s := Store.insert s h_RCREG             n_RCREG
  let s := Store.insert s h_OERR              n_OERR
  let s := Store.insert s h_FERR              n_FERR
  let s := Store.insert s h_STATUS            n_STATUS
  let s := Store.insert s h_Z                 n_Z
  -- Application state
  let s := Store.insert s h_rx_overrun        n_rx_overrun
  let s := Store.insert s h_getch_result      n_getch_result
  let s := Store.insert s h_line_len          n_line_len
  let s := Store.insert s h_line_buf          n_line_buf
  -- Bool formals
  let s := Store.insert s h_bool_oerr         n_bool_oerr
  let s := Store.insert s h_bool_ferr         n_bool_ferr
  let s := Store.insert s h_bool_full         n_bool_full
  let s := Store.insert s h_bool_empty        n_bool_empty
  let s := Store.insert s h_bool_nl           n_bool_nl
  -- Utilities
  let s := Store.insert s h_nop               n_nop
  -- ISR nodes
  let s := Store.insert s h_panic             n_panic
  let s := Store.insert s h_early_retfie      n_early_retfie
  let s := Store.insert s h_discard_rcreg     n_discard_rcreg
  let s := Store.insert s h_read_rcreg        n_read_rcreg
  let s := Store.insert s h_test_oerr         n_test_oerr
  let s := Store.insert s h_if_oerr           n_if_oerr
  let s := Store.insert s h_test_ferr         n_test_ferr
  let s := Store.insert s h_discard_and_retfie n_discard_and_retfie
  let s := Store.insert s h_if_ferr           n_if_ferr
  let s := Store.insert s h_set_overrun_and_retfie n_set_overrun_and_retfie
  let s := Store.insert s h_if_full           n_if_full
  let s := Store.insert s h_uart_rx_isr       n_uart_rx_isr
  -- Main loop nodes
  let s := Store.insert s h_is_empty          n_is_empty
  let s := Store.insert s h_getch_nop         n_getch_nop
  let s := Store.insert s h_getch_spin        n_getch_spin
  let s := Store.insert s h_pop               n_pop
  let s := Store.insert s h_critical_pop      n_critical_pop
  let s := Store.insert s h_getch             n_getch
  let s := Store.insert s h_load_gc           n_load_gc
  let s := Store.insert s h_xor_nl            n_xor_nl
  let s := Store.insert s h_test_z            n_test_z
  let s := Store.insert s h_test_nl           n_test_nl
  let s := Store.insert s h_append_line       n_append_line
  let s := Store.insert s h_process_line      n_process_line
  let s := Store.insert s h_if_nl             n_if_nl
  let s := Store.insert s h_main_body         n_main_body
  let s := Store.insert s h_main              n_main
  s

-- IVT: vec 0 = main (reset), vec 1 = uart_rx_isr (high-priority)
def appIVT : Array IVTEntry := #[(0, h_main), (1, h_uart_rx_isr)]

def main : IO Unit := do
  IO.println "=== AILApp: UART line buffer ==="
  match checkStore targetConfig appStore with
  | .error (_, h) =>
      IO.println s!"  checkStore: FAIL (type error at hash {h})"
  | .ok tyEnv =>
      IO.println   "  checkStore: PASS"
      let warns := readClearsWarnings appStore
      for w in warns do IO.println s!"  {w}"
      match compile appStore tyEnv appIVT with
      | .error msg =>
          IO.println s!"  compile:    FAIL ({msg})"
      | .ok lines =>
          IO.println   "  compile:    PASS"
          for line in lines do IO.println s!"  {line}"
