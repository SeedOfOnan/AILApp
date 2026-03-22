-- AILApp.src.App
-- PIC18 application: UART receive into line buffer.
--
-- Static RAM declarations (addresses assigned by allocateStatics — AIL#19):
--   rx_head       1 byte   ring buffer head index
--   rx_tail       1 byte   ring buffer tail index
--   rx_temp       1 byte   ring buffer push scratch byte
--   rx_data      32 bytes  ring buffer body
--   rx_overrun    1 byte   overrun flag
--   getch_result  1 byte   most recently received byte
--   line_len      1 byte   current line accumulation length
--   line_buf     64 bytes  line accumulation buffer
--   (total: 102 bytes, allocated from 0x20)
--
-- IVT:
--   vec 0 = main (reset entry, ProcBody.forever)
--   vec 1 = uart_rx_isr (high-priority interrupt handler)
--
-- Language features used:
--   StaticAlloc        — compiler-assigned RAM addresses (AIL#19)
--   StoreM             — implicit hash management (AIL#18)
--   ProcBody.forever   — main event loop
--   ProcBody.whileLoop — getch spin-wait (AIL#12)
--   ProcBody.cond      — OERR/FERR/full guards in ISR
--   makeINTCON         — INTCON/GIE nodes for critical section (AIL#14)
--
-- Known design gaps (see LANGDEF.md and open GitHub issues):
--   AIL#13  FSR resource annotations — pop/push use FSR0; the critical section
--           (AIL#14) prevents ISR corruption but a typed annotation would allow
--           the compiler to verify the non-conflict with FSR1 in append_line.

import AIL
import AIL.Targets.PIC18.Emitter

open AIL AIL.PIC18

-- ---------------------------------------------------------------------------
-- Static RAM allocation (AIL#19: compiler-assigned addresses).
-- The agent declares name + type; the allocator assigns addresses.
-- PIC18F56Q71 — allocating from 0x20 within bank 0 GPR.
-- ---------------------------------------------------------------------------

private def appStatics : Array StaticDecl := #[
  { name := "rx_head",      width := .w8, count := 1  },
  { name := "rx_tail",      width := .w8, count := 1  },
  { name := "rx_temp",      width := .w8, count := 1  },
  { name := "rx_data",      width := .w8, count := 32 },
  { name := "rx_overrun",   width := .w8, count := 1  },
  { name := "getch_result", width := .w8, count := 1  },
  { name := "line_len",     width := .w8, count := 1  },
  { name := "line_buf",     width := .w8, count := 64 },
]

-- Allocate from 0x20; 0xE0 bytes available (Access Bank + Bank 0, through 0xFF).
private def appRamMap : RamMap :=
  match allocateStatics appStatics 0x20 0xE0 with
  | .ok (m, _) => m
  | .error e   => panic! e

-- ---------------------------------------------------------------------------
-- Full program as a single StoreM build (AIL#18: implicit hash management).
-- Addresses come from appRamMap (AIL#19); no manual address literals.
-- All nodes are hashed and stored by the monad; no manual Store.insert calls.
-- Returns (h_main, h_uart_rx_isr) for the IVT.
-- ---------------------------------------------------------------------------

private def buildApp (rm : RamMap) : StoreM (Hash × Hash) := do

  -- -------------------------------------------------------------------------
  -- UART SFRs (PIC18F56Q71, DS40002329F)
  -- -------------------------------------------------------------------------
  let h_RCSTA ← StoreM.node (.peripheral .sfr 0xFAB
    { readable := true, writable := true,
      sideEffectOnRead := false, sideEffectOnWrite := false, accessWidth := .w8 }
    "RCSTA")
  let h_RCREG ← StoreM.node (.peripheral .sfr 0xFAE
    { readable := true, writable := false,
      sideEffectOnRead := true, sideEffectOnWrite := false, accessWidth := .w8 }
    "RCREG")
  let h_OERR ← StoreM.node (.bitField h_RCSTA 1 "OERR")
  let h_FERR ← StoreM.node (.bitField h_RCSTA 2 "FERR")

  -- STATUS register (Z flag needed for character comparison)
  let h_STATUS ← StoreM.node (.peripheral .sfr 0xFD8
    { readable := true, writable := true,
      sideEffectOnRead := false, sideEffectOnWrite := false, accessWidth := .w8 }
    "STATUS")
  let h_Z ← StoreM.node (.bitField h_STATUS 2 "Z")

  -- -------------------------------------------------------------------------
  -- Ring buffer (addresses from RAM allocator — AIL#19)
  -- -------------------------------------------------------------------------
  let rb ← makeRingBuf
    (rm.addr! "rx_head") (rm.addr! "rx_tail")
    (rm.addr! "rx_data") (rm.addr! "rx_temp")
    32 1000 "rx"

  -- -------------------------------------------------------------------------
  -- INTCON — critical section primitives (AIL#14)
  -- Classic PIC18 / Q71: INTCON at SFR 0xFF2, GIE = bit 7.
  -- -------------------------------------------------------------------------
  let ic ← makeINTCON 0xFF2

  -- -------------------------------------------------------------------------
  -- Application state (addresses from RAM allocator — AIL#19)
  -- -------------------------------------------------------------------------
  let h_rx_overrun   ← StoreM.node (.data .data .w8 (rm.addr! "rx_overrun")   "rx_overrun")
  let h_getch_result ← StoreM.node (.data .data .w8 (rm.addr! "getch_result") "getch_result")
  let h_line_len     ← StoreM.node (.data .data .w8 (rm.addr! "line_len")     "line_len")
  let h_line_buf     ← StoreM.node (.staticArray .data .w8 (rm.addr! "line_buf") 64 "line_buf")

  -- -------------------------------------------------------------------------
  -- Bool formals
  -- -------------------------------------------------------------------------
  let h_bool_oerr  ← StoreM.node (.formal 1001 .bool)
  let h_bool_ferr  ← StoreM.node (.formal 1002 .bool)
  let h_bool_empty ← StoreM.node (.formal 1004 .bool)
  let h_bool_nl    ← StoreM.node (.formal 1005 .bool)

  -- -------------------------------------------------------------------------
  -- Shared utility
  -- -------------------------------------------------------------------------
  let h_nop ← StoreM.node (.proc #[] #[] (.seq #[]) "nop")

  -- -------------------------------------------------------------------------
  -- ISR: uart_rx_isr
  --
  -- Sequence:
  --   1. if OERR → panic
  --   2. if FERR → discard byte + retfie
  --   3. read RCREG → WREG
  --   4. if rx_buf full → set rx_overrun + retfie
  --   5. push WREG to rx_buf
  -- -------------------------------------------------------------------------
  let h_panic ← StoreM.node (.proc #[] #[]
    (.intrinsic #["_L_panic:", "    goto    _L_panic"] #[] #[]
                #["halt: never returns"])
    "panic")

  let h_early_retfie ← StoreM.node (nodeRetfie false "early_retfie")

  let h_discard_rcreg ← StoreM.node (.proc #[] #[]
    (.atomic (.abstract .loadDiscard) #[h_RCREG] #[]) "discard_rcreg")
  let h_read_rcreg ← StoreM.node (.proc #[] #[]
    (.atomic (.abstract .load) #[h_RCREG] #[]) "read_rcreg")

  -- if OERR → panic
  let h_test_oerr ← StoreM.node (.proc #[] #[h_bool_oerr]
    (.atomic (.abstract .testBit) #[h_OERR] #[]) "test_oerr")
  let h_if_oerr ← StoreM.node (.proc #[] #[]
    (.cond h_test_oerr h_panic h_nop) "if_oerr")

  -- if FERR → discard + retfie
  let h_test_ferr ← StoreM.node (.proc #[] #[h_bool_ferr]
    (.atomic (.abstract .testBit) #[h_FERR] #[]) "test_ferr")
  let h_discard_and_retfie ← StoreM.node (.proc #[] #[]
    (.seq #[h_discard_rcreg, h_early_retfie]) "discard_and_retfie")
  let h_if_ferr ← StoreM.node (.proc #[] #[]
    (.cond h_test_ferr h_discard_and_retfie h_nop) "if_ferr")

  -- if full → set overrun + retfie
  -- set_overrun_and_retfie: SETF rx_overrun; RETFIE 0
  -- Expressed as ProcBody.seq of two ISA nodes (AIL issue #9).
  let h_sor_setf   ← StoreM.node (nodeSetf h_rx_overrun "setf_rx_overrun")
  let h_sor_retfie ← StoreM.node (nodeRetfie false "retfie_sor")
  let h_set_overrun_and_retfie ← StoreM.node (.proc #[] #[]
    (.seq #[h_sor_setf, h_sor_retfie]) "set_overrun_and_retfie")

  let h_if_full ← StoreM.node (.proc #[] #[]
    (.cond rb.h_is_full h_set_overrun_and_retfie rb.h_push) "if_full")

  -- Top-level ISR: check errors, read byte, push to ring buffer
  let h_uart_rx_isr ← StoreM.node (.proc #[] #[]
    (.seq #[h_if_oerr, h_if_ferr, h_read_rcreg, h_if_full]) "uart_rx_isr")

  -- -------------------------------------------------------------------------
  -- Main loop: getch → line buffer until '\n', then process_line
  --
  -- getch = whileLoop(is_empty, nop) then pop
  --         whileLoop replaces the raw assembly spin-wait (AIL#12 resolved)
  -- -------------------------------------------------------------------------

  -- is_empty: head == tail (buffer empty)
  -- MOVF tail, W  then  CPFSEQ head — skip-when-TRUE: equal = buffer empty.
  -- Expressed as ProcBody.seq of two ISA nodes (AIL issue #9).
  -- Outer proc has rets = #[h_bool_empty] → type Ty.proc [] [Ty.bool] 0
  -- which satisfies whileLoop_ok's cond constraint.
  let h_ie_movf   ← StoreM.node (nodeMovf_w rb.h_tail "is_empty_movf_tail")
  let h_ie_cpfseq ← StoreM.node (nodeCpfseq rb.h_head "is_empty_cpfseq_head")
  let h_is_empty  ← StoreM.node (.proc #[] #[h_bool_empty]
    (.seq #[h_ie_movf, h_ie_cpfseq]) "rx_is_empty")

  -- getch: spin until non-empty, then pop
  -- whileLoop(is_empty, nop): loops while empty; exits when byte is available
  let h_getch_nop  ← StoreM.node (.proc #[] #[] (.seq #[]) "getch_nop")
  let h_getch_spin ← StoreM.node (.proc #[] #[]
    (.whileLoop h_is_empty h_getch_nop) "getch_spin")

  -- pop: FSR0-indirect read of buf[head] → getch_result; advance head mod 32
  -- Expressed as ProcBody.seq of single-instruction ISA nodes (AIL issue #9).
  -- Uses FSR0; caller (critical_pop) wraps in BCF/BSF INTCON.GIE (AIL#14).
  -- TODO AIL#13: FSR annotation would make FSR0 usage statically checkable.
  let h_pop_s1 ← StoreM.node (nodeLfsr0        rb.h_data      "pop_s1_lfsr0_data")
  let h_pop_s2 ← StoreM.node (nodeMovf_w        rb.h_head      "pop_s2_movf_head")
  let h_pop_s3 ← StoreM.node (nodeAddwf_FSR0L                  "pop_s3_addwf_fsr0l")
  let h_pop_s4 ← StoreM.node (nodeMovf_INDF0_w                 "pop_s4_movf_indf0")
  let h_pop_s5 ← StoreM.node (nodeMovwf         h_getch_result "pop_s5_movwf_result")
  let h_pop_s6 ← StoreM.node (nodeIncf_f        rb.h_head      "pop_s6_incf_head")
  let h_pop_s7 ← StoreM.node (nodeMovlw         31             "pop_s7_movlw_31")
  let h_pop_s8 ← StoreM.node (nodeAndwf_f       rb.h_head      "pop_s8_andwf_head")
  let h_pop    ← StoreM.node (.proc #[] #[h_getch_result]
    (.seq #[h_pop_s1, h_pop_s2, h_pop_s3, h_pop_s4,
            h_pop_s5, h_pop_s6, h_pop_s7, h_pop_s8]) "rx_pop")

  -- critical section: disable_ints; pop; enable_ints
  -- Protects FSR0 use in pop from being clobbered by the UART ISR (which also
  -- uses FSR0 for ring buffer push). BCF/BSF INTCON.GIE (makeINTCON, AIL#14).
  let h_critical_pop ← StoreM.node (.proc #[] #[h_getch_result]
    (.seq #[ic.h_disable_ints, h_pop, ic.h_enable_ints]) "critical_pop")
  let h_getch ← StoreM.node (.proc #[] #[h_getch_result]
    (.seq #[h_getch_spin, h_critical_pop]) "getch")

  -- newline detection: load getch_result; xorlw '\n'; btfss STATUS,Z
  let h_load_gc ← StoreM.node (.proc #[h_getch_result] #[]
    (.atomic (.abstract .load) #[h_getch_result] #[]) "load_getch_result")
  let h_xor_nl  ← StoreM.node (.proc #[] #[]
    (.atomic (.abstract (.xorImm 0x0a)) #[] #[]) "xor_newline")
  let h_test_z  ← StoreM.node (.proc #[] #[h_bool_nl]
    (.atomic (.abstract .testBit) #[h_Z] #[]) "test_Z_flag")
  let h_test_nl ← StoreM.node (.proc #[] #[h_bool_nl]
    (.seq #[h_load_gc, h_xor_nl, h_test_z]) "test_is_newline")

  -- append_line: line_buf[line_len] = getch_result; line_len++
  -- Expressed as ProcBody.seq of single-instruction ISA nodes (AIL issue #9).
  -- Uses FSR1 (distinct from FSR0 used by getch pop — no FSR conflict).
  let h_al_s1 ← StoreM.node (nodeLfsr1      h_line_buf     "al_s1_lfsr1_linebuf")
  let h_al_s2 ← StoreM.node (nodeMovf_w     h_line_len     "al_s2_movf_linelen")
  let h_al_s3 ← StoreM.node (nodeAddwf_FSR1L               "al_s3_addwf_fsr1l")
  let h_al_s4 ← StoreM.node (nodeMovf_w     h_getch_result "al_s4_movf_result")
  let h_al_s5 ← StoreM.node (nodeMovwf_INDF1               "al_s5_movwf_indf1")
  let h_al_s6 ← StoreM.node (nodeIncf_f     h_line_len     "al_s6_incf_linelen")
  let h_append_line ← StoreM.node (.proc #[] #[]
    (.seq #[h_al_s1, h_al_s2, h_al_s3, h_al_s4, h_al_s5, h_al_s6]) "append_line")

  -- process_line: consume accumulated line (stub)
  -- CLRF line_len — clear line length counter.
  -- TODO: implement command dispatch / echo
  let h_process_line ← StoreM.node (nodeClrf h_line_len "process_line")

  -- if newline → process_line else → append_line
  let h_if_nl ← StoreM.node (.proc #[] #[]
    (.cond h_test_nl h_process_line h_append_line) "if_newline")

  -- main_body: one iteration — fetch byte, dispatch on newline
  let h_main_body ← StoreM.node (.proc #[] #[]
    (.seq #[h_getch, h_if_nl]) "main_body")

  -- main: reset entry — run forever
  let h_main ← StoreM.node (.proc #[] #[]
    (.forever h_main_body) "main")

  return (h_main, h_uart_rx_isr)

-- ---------------------------------------------------------------------------
-- Program store and IVT (derived from the monadic build)
-- ---------------------------------------------------------------------------

private def appBuild := StoreM.run (buildApp appRamMap)

def appStore : Store := appBuild.2

def appIVT : Array IVTEntry :=
  let (h_main, h_uart_rx_isr) := appBuild.1
  #[(0, h_main), (1, h_uart_rx_isr)]

def main : IO Unit := do
  IO.println "=== AILApp: UART line buffer ==="
  -- Print RAM map (AIL#19)
  IO.println "  --- RAM map (compiler-assigned addresses) ---"
  for line in appRamMap.renderMapFile do IO.println s!"  {line}"
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
