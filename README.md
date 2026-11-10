# Async FIFO Formal Verification (Cadence JasperGold)

Formal verification of a dual-clock FIFO (gray-code pointers, 2-flop
synchronizers) using JasperGold FPV.

## Structure

    async_fifo_formal_repo/
    ├── rtl/async_fifo.sv                 # DUT
    ├── formal/async_fifo_checker.sv      # SVA checker + two-domain model
    ├── formal/async_fifo_bind.sv         # binds checker into the DUT
    ├── scripts/async_fifo_formal.tcl     # JasperGold flow
    └── README.md

## Approach

- Checker is bound into `async_fifo`; RTL is not modified.
- `wclk` and `rclk` are declared as two independent clocks in TCL.
- A free, constant `tracked_idx` (stable by assume) selects which
  accepted write to track. The write domain stores that write's data;
  the read domain counts accepted reads. When the read with the same
  index is accepted, `rd_data` (registered) must equal the stored
  data on the next `rclk` edge. Using counters per domain avoids
  comparing state across clocks.
- Also checked: no read of an unwritten item, no overflow/underflow
  (occupancy never exceeds DEPTH).
- Async-specific checks (use DUT internals, connected by name via bind):
  - Gray pointers match their binary copies and change at most one bit
    per clock (the property that makes the crossing safe).
  - Pointers move only on an accepted transfer, by exactly one.
  - Synchronized pointers are never ahead of the real pointer and lag
    by at most DEPTH.
  - Flags are pessimistic but safe: `!full` implies real space,
    `!empty` implies real data.
  - Covers show the pessimism is real (full/empty asserted while the
    other side has already moved) and that pointers wrap.
- Environment assumptions: wrst_n and rrst_n are tied together and
  reset is only asserted at the start (once released it stays
  released). Reset values are handled by JasperGold reset analysis,
  so there is no separate reset-value assertion (it would be vacuous).
- Covers confirm the tracked item can be written and read, the FIFO
  can fill, and writes and reads can occur on the same edge.

## Run

    jg -no_gui -tcl scripts/async_fifo_formal.tcl

Older installs: `jaspergold -no_gui -tcl scripts/async_fifo_formal.tcl`.

## Notes

- DEPTH must be a power of two and >= 4 (gray full-compare logic).
- Expect an undriven-signal warning for `tracked_idx`; it is intentional.
- Check all covers are reachable before trusting assertion passes.
- FPV treats synchronizer flops as ordinary registers: it does not
  model metastability. Use JasperGold CDC for structural/convergence
  checks.
- Not a signoff-complete proof.
