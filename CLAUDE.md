# CLAUDE.md — AIL Application Project

**Read this before touching anything in this repository.**

---

## What this project is

This is an embedded application written in **AIL**, targeting the **PIC18**
microcontroller family. The application name is TBD.

This project is the *consumer* of AIL. It does not contain the compiler or
language toolchain — those live in the sibling `AIL/` project.

---

## Essential references

- **Language spec:** `../AIL/docs/LANGDEF.md`
  Read this to understand AIL syntax, semantics, and what constructs are available.
  Every AIL construct you write must have an entry in LANGDEF.md. If it doesn't,
  stop and add it there first, then return here.

- **Tier rules:** `../AIL/docs/TIERS.md`
  This application is Tier 1 (PIC18). Do not introduce Tier 2 or Tier 3 constructs.

- **Compiler/emitter:** `../AIL/AIL/Targets/PIC18/Emitter.lean`
  The current state of what the compiler can actually emit. If a construct is in
  LANGDEF.md but not yet implemented in the emitter, note it as `-- TODO: unimplemented`
  in the source and continue designing.

---

## How AIL programs are written (current form)

AIL is currently **AST-direct**: programs are Lean 4 expressions that construct
a `Store` (content-addressed graph of `Node`s) plus an IVT (interrupt vector table).
There is no parser or surface syntax yet.

See `../AIL/TestRunner.lean` for working examples of this form.

---

## Current state

Stub. The application has been partially designed but not yet implemented.

### What is designed (in LANGDEF.md, not yet in code)
- UART receive interrupt handler (`uart_rx_isr`)
  - Hardware overrun (OERR): panic
  - Framing error (FERR): discard byte, continue
  - Ring buffer full: drop byte, set `rx_buffer_overrun` flag

### What is not yet designed
- Application purpose (what does this device do?)
- Main loop / `entry(reset)` startup
- Any other peripherals

---

## Repository layout

```
AILApp/
  CLAUDE.md     -- THIS FILE
  src/          -- AIL source (Store-construction Lean 4 files, or .ail when syntax exists)
```

---

## Rules

- Do not design for human developer ergonomics — the primary author is an AI agent
- All RAM is statically allocated — no heap
- No Tier 2 or Tier 3 constructs
- If you use a construct not in LANGDEF.md, add it there first
- Mark unimplemented constructs with `-- TODO: unimplemented`
