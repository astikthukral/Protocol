<!-- amba_ahb_multimaster/
├── src/
│   ├── ahb_arbiter.v          ← core arbiter (round-robin + priority)
│   ├── ahb_master.v           ← generic master template
│   ├── ahb_slave_ram.v        ← simple RAM slave
│   ├── ahb_decoder.v          ← address decoder
│   ├── ahb_mux.v              ← master/slave data mux
│   └── ahb_top.v              ← top-level integration
└── tb/
    └── tb_ahb_top.v           ← testbench -->

# AMBA AHB Multi-Master Bus Arbitration System

> **AMBA 2 AHB compliant** · **3 Masters** · **Round-Robin + Priority Arbitration** · **125 MHz** · **Vivado / SystemVerilog**

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Directory Structure](#3-directory-structure)
4. [Module Descriptions](#4-module-descriptions)
5. [Signal Reference](#5-signal-reference)
6. [Arbitration Algorithm](#6-arbitration-algorithm)
7. [AHB Transfer Protocol](#7-ahb-transfer-protocol)
8. [AHB-to-APB Bridge](#8-ahb-to-apb-bridge)
9. [Timing Constraints](#9-timing-constraints)
10. [Simulation Guide](#10-simulation-guide)
11. [Design Decisions and Trade-offs](#11-design-decisions-and-trade-offs)
12. [Extending the Design](#12-extending-the-design)
13. [References](#13-references)

---

## 1. Project Overview

This project implements a **multi-master AMBA AHB bus arbitration system** in synthesizable SystemVerilog, targeting **125 MHz operation** on Xilinx FPGAs (Vivado toolchain). It demonstrates the complete AHB interconnect fabric — arbitration, address decoding, data multiplexing, and protocol bridging — across three masters with mixed priority levels.

### What this system does

- Allows **3 independent AHB masters** (e.g., CPU, DMA, co-processor) to share a common AHB bus
- Arbitrates bus access using a **hybrid policy**: strict priority pre-emption with round-robin fairness among equal-priority masters
- Decodes master addresses to select one of **3 AHB slaves** (RAM, ROM, APB bridge)
- Bridges AHB to an **APB peripheral bus** for low-bandwidth devices (UART, SPI, GPIO)
- Meets **AMBA 2 AHB specification** (ARM IHI0011A) signal semantics and two-phase pipelined transfer timing

### What this system is not

This is **not** an AXI interconnect or a BusMatrix. It is a classic shared-bus AMBA 2 AHB architecture where only one master-slave pair communicates at a time. This topology was deliberately chosen for design transparency and educational clarity — see [Section 11](#11-design-decisions-and-trade-offs) for the full rationale.

---

## 2. Architecture

### System block diagram

<img width="1440" height="1040" alt="image" src="https://github.com/user-attachments/assets/1256a0dc-fd75-4d83-9317-349eb3378788" />


### Key data flows

**Write path (Master → Slave):**
```
Master asserts HBUSREQ
    → Arbiter grants HGRANT (next safe clock boundary)
    → Master drives HADDR [address phase]
    → Master drives HWDATA [data phase, one cycle later]
    → MUX routes winning master's signals onto shared bus
    → Decoder asserts HSEL for addressed slave
    → Slave captures HWDATA, asserts HREADYOUT when done
```

**Read path (Slave → Master):**
```
Master drives HADDR with HWRITE=0
    → Slave decodes address, fetches data
    → Slave drives HRDATA, asserts HREADYOUT
    → HRDATA broadcast to all masters
    → Only current bus owner (per HMASTER) uses HRDATA
```

---

## 3. Directory Structure

```
amba_ahb_multimaster/
│
├── src/                          RTL source files (synthesizable)
│   ├── ahb_arbiter.v             Hybrid round-robin + priority arbiter
│   ├── ahb_master.v              Generic AHB master FSM template
│   ├── ahb_slave_ram.v           AHB-compliant synchronous RAM slave
│   ├── ahb_decoder.v             Address-to-HSEL combinational decoder
│   ├── ahb_mux.v                 Master output multiplexer (HMASTER-controlled)
│   └── ahb_top.v                 Top-level integration and wiring
│
├── tb/
│   └── tb_ahb_top.v              Self-checking simulation testbench
│
├── constraints/
│   └── constraints.xdc           Vivado timing constraints (125 MHz)
│
└── README.md                     This document
```

---

## 4. Module Descriptions

### 4.1 `ahb_arbiter.v` — Bus arbiter (core of the system)

**Role:** Decides which master owns the bus each clock cycle.

**Inputs:**
- `HBUSREQ[2:0]` — one bit per master, asserted when that master needs the bus
- `HLOCK[2:0]` — asserted when a master requires an atomic (uninterruptible) transfer
- `HTRANS[1:0]` — current transfer type on the bus (used to detect safe handover points)
- `HREADY` — slave ready signal; arbiter only changes grants when bus is free

**Outputs:**
- `HGRANT[2:0]` — one-hot grant; exactly one bit high at all times
- `HMASTER[1:0]` — binary-encoded index of current bus owner (fed to MUX)

**Algorithm:** Two-phase per clock cycle. First, scans all requesting masters for a strict priority winner. If none found, advances the round-robin pointer to the next requesting master. Grant changes only happen when `HREADY=1` (no transfer in progress) and `HLOCK` is deasserted.

**Critical design note:** The arbiter is **sequential logic** (`always @(posedge HCLK)`). It must be registered because it tracks state — who had the bus last (`rr_ptr`), whether the bus is locked (`locked`). A combinational arbiter would cause glitches on HGRANT mid-transfer.

---

### 4.2 `ahb_master.v` — Generic AHB master

**Role:** Template for any bus master (CPU interface, DMA engine, etc.). Manages the request → grant → transfer → release sequence.

**External control ports** (driven by upper logic — CPU, DMA, testbench):

| Port | Direction | Description |
|---|---|---|
| `start_transfer` | input | Pulse high to initiate a transfer |
| `target_addr` | input | 32-bit destination address |
| `write_data` | input | Data to write (ignored on reads) |
| `do_write` | input | 1 = write transaction, 0 = read transaction |

**FSM states:**

```
IDLE ──► REQUESTING ──► TRANSFER ──► IDLE
              │                │
              │                └──► WAIT (on error/retry)
              │                         │
              └─────────────────────────┘
```

- **IDLE:** No activity. Waiting for `start_transfer` pulse.
- **REQUESTING:** `HBUSREQ` asserted. Waiting for arbiter to assert `HGRANT` with `HREADY=1`.
- **TRANSFER:** Bus owned. HADDR and HWDATA driven. Waiting for slave `HREADY`.
- **WAIT:** Error recovery. Releases bus and returns to IDLE.

**Important:** The master checks `HGRANT && HREADY` before driving the bus. This is the AHB-mandated safe handover condition — the current transfer must be complete before the new master takes over.

---

### 4.3 `ahb_slave_ram.v` — AHB RAM slave

**Role:** Simple synchronous single-port RAM with AHB slave interface.

**Address map:** Assigned by the decoder. Default: `0x00000000 – 0x000FFFFF`.

**Behavior:**
- Responds in **one clock cycle** (zero wait states) for both reads and writes
- Holds `HREADYOUT=1` at all times (no stalling)
- Ignores transfers when `HSEL=0` or `HTRANS[1]=0` (IDLE/BUSY)
- Latches `HADDR` and `HWRITE` in the address phase; uses them with `HWDATA` in the data phase — the AHB two-phase pipeline

**Critical implementation detail:**
```verilog
// Address phase: latch control (HWDATA not valid yet)
always @(posedge HCLK)
    if (HSEL && HREADY && HTRANS[1]) begin
        addr_lat  <= HADDR;
        write_lat <= HWRITE;
    end

// Data phase: HWDATA now valid, addr_lat has last cycle's address
always @(posedge HCLK)
    if (write_lat) mem[addr_lat] <= HWDATA;
```
If you use `HADDR` and `HWDATA` in the same phase for the same transfer, you break the AHB pipeline. This is the single most common AHB coding mistake.

---

### 4.4 `ahb_decoder.v` — Address decoder

**Role:** Combinational logic that maps `HADDR[31:0]` to one of three `HSEL` lines.

**Address map:**

| Slave | HSEL bit | Address range | Size |
|---|---|---|---|
| RAM (S0) | `HSEL[0]` | `0x00000000 – 0x000FFFFF` | 1 MB |
| ROM (S1) | `HSEL[1]` | `0x10000000 – 0x100FFFFF` | 1 MB |
| APB Bridge (S2) | `HSEL[2]` | `0x40000000 – 0x400FFFFF` | 1 MB |

**Design note:** This is purely combinational (`always @(*)`). It has no state — it reacts instantly to HADDR. The address map is fixed at synthesis time. In a production SoC, this would be generated by a bus configuration tool (e.g., ARM CoreLink Creator) and the ranges would be parameterized.

---

### 4.5 `ahb_mux.v` — Master data multiplexer

**Role:** Routes the winning master's address/data/control signals onto the shared AHB bus using `HMASTER` as the select.

**Why this is needed:** All three masters have their own `HADDR`, `HWDATA`, `HTRANS` etc. Only one set can drive the shared bus at a time. The MUX selects the winning master's outputs using the `HMASTER` index from the arbiter.

```
HADDR_M[0] ──┐
HADDR_M[1] ──┼──► MUX (sel = HMASTER) ──► HADDR (shared bus)
HADDR_M[2] ──┘
```

**Design note:** This is combinational logic. The combinational path from `HMASTER` to `HADDR` is a timing-sensitive path at 125 MHz — ensure synthesis does not create excessive logic depth here.

---

### 4.6 `ahb_top.v` — Top-level integration

**Role:** Instantiates and wires all modules. Contains no functional logic of its own — purely structural.

**What to modify here:**
- Change `NUM_MASTERS` parameter to scale the design
- Connect `start_transfer`, `target_addr`, `write_data`, `do_write` ports of each master to your actual CPU/DMA logic (currently tied to zero as placeholders)
- Add additional slave instances and expand the decoder address map

---

## 5. Signal Reference

### AHB bus signals (AMBA 2 spec, ARM IHI0011A)

| Signal | Width | Direction | Description |
|---|---|---|---|
| `HCLK` | 1 | Input | Bus clock. All signals sampled on rising edge |
| `HRESETn` | 1 | Input | Active-low synchronous reset |
| `HADDR` | 32 | M→S | Transfer address |
| `HTRANS` | 2 | M→S | Transfer type: `00`=IDLE, `01`=BUSY, `10`=NONSEQ, `11`=SEQ |
| `HWRITE` | 1 | M→S | Transfer direction: `1`=write, `0`=read |
| `HSIZE` | 3 | M→S | Transfer size: `000`=byte, `001`=halfword, `010`=word |
| `HBURST` | 3 | M→S | Burst type: `000`=SINGLE, `010`=WRAP4, `011`=INCR4, etc. |
| `HWDATA` | 32 | M→S | Write data (valid one cycle after HADDR) |
| `HRDATA` | 32 | S→M | Read data (valid when HREADYOUT=1) |
| `HREADY` | 1 | S→M | Bus ready. When low, master must hold all outputs |
| `HRESP` | 2 | S→M | Transfer response: `00`=OKAY, `01`=ERROR, `10`=RETRY, `11`=SPLIT |
| `HSEL` | 1 | Dec→S | Slave select. Driven by decoder, one per slave |

### Arbitration signals (multi-master extension)

| Signal | Width | Description |
|---|---|---|
| `HBUSREQ` | 1 per master | Master asserts to request bus ownership |
| `HGRANT` | 1 per master | Arbiter asserts to grant bus to a master |
| `HLOCK` | 1 per master | Master asserts to hold bus atomically across beats |
| `HMASTER` | log2(N) | Binary index of current bus owner; drives MUX select |

---

## 6. Arbitration Algorithm

The arbiter implements a **two-phase decision** every clock cycle when `HREADY=1`:

### Phase 1 — Strict priority scan

Scan all requesting masters. If any master with a higher priority than the current round-robin pointer is requesting, it wins immediately — regardless of how long other masters have been waiting.

```
Priority levels (parameterized):
  Master 0 — priority 2 (highest)
  Master 1 — priority 1 (medium)
  Master 2 — priority 0 (lowest)
```

### Phase 2 — Round-robin fallback

If no strict priority winner exists (all requesting masters have equal priority, or only the lowest-priority masters are requesting), the round-robin pointer advances to the next requesting master in circular order.

```
rr_ptr: 0 → 1 → 2 → 0 → 1 → ...
        (only advances to masters that are actually requesting)
```

### Why this hybrid policy

Pure priority scheduling causes **starvation** — Master 2 may never get the bus if Masters 0 and 1 are always requesting. Pure round-robin ignores **urgency** — a high-priority real-time master (e.g., an interrupt handler) must wait its turn behind a bulk DMA transfer.

The hybrid solves both: priority pre-emption for urgency, round-robin fairness to prevent starvation among equal-priority masters.

### HLOCK behavior

When a master asserts `HLOCK`, the arbiter freezes all grant changes until the locked sequence completes (`HTRANS=IDLE` or `HREADY=1` after final beat). This guarantees atomicity for read-modify-write operations.

---

## 7. AHB Transfer Protocol

### Two-phase pipelined transfer

AHB's defining characteristic is that the address phase of transfer N+1 **overlaps** with the data phase of transfer N. This is what distinguishes it from APB (no pipeline) and is why AHB achieves higher throughput.

```
Clock:   __|‾|_|‾|_|‾|_|‾|_|‾|_
                 ↑   ↑   ↑   ↑
Transfer A:  [ADDR_A][DATA_A]
Transfer B:          [ADDR_B][DATA_B]
Transfer C:                  [ADDR_C][DATA_C]
```

### HTRANS encoding

```
HTRANS = 2'b00  IDLE    — master has bus but no transfer pending
HTRANS = 2'b01  BUSY    — master has bus, pausing mid-burst
HTRANS = 2'b10  NONSEQ  — start of new transfer or single transfer
HTRANS = 2'b11  SEQ     — continuation of a burst
```

### Wait state insertion

Any slave can stall the bus by asserting `HREADYOUT=0`. While stalled:
- The master must hold **all** its output signals unchanged
- The arbiter must not change grants
- The pipeline is frozen

```
Clock:   __|‾|_|‾|_|‾|_|‾|_
HADDR:   [  A  ][  A  ][  A  ][  B  ]   ← A held during wait
HREADY:  ‾‾‾‾‾‾|_____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾    ← slave inserts 1 wait state
```

---

## 8. AHB-to-APB Bridge

The bridge translates between the two bus domains. To the AHB bus it appears as a **slave**. To the APB peripherals it appears as a **master**.

### Bridge FSM

```
         IDLE ──────────────────────────────────►IDLE
           │   (HSEL && HTRANS[1] && HREADY_in)   ▲
           │                                       │ (PREADY=1)
           ▼                                       │
         SETUP    drives: PSEL=1, PENABLE=0        │
           │      translates: HADDR→PADDR          │
           │                  HWRITE→PWRITE         │
           │                  HWDATA→PWDATA         │
           ▼                                       │
         ENABLE   drives: PENABLE=1                │
           │      holds HREADYOUT=0 (stalls AHB)   │
           └───────────────────────────────────────┘
```

### Protocol translation table

| AHB signal | APB equivalent | Notes |
|---|---|---|
| `HADDR` | `PADDR` | Direct mapping |
| `HWDATA` | `PWDATA` | Direct mapping |
| `PRDATA` | `HRDATA` | Direct mapping |
| `HWRITE` | `PWRITE` | Direct mapping |
| `HSEL + HTRANS[1]` | `PSEL` | AHB select → APB select |
| — | `PENABLE` | Generated by bridge FSM (no AHB equivalent) |
| `HREADYOUT` | `PREADY` | Bridge holds HREADYOUT low while waiting for PREADY |
| `HRESP[0]` | `PSLVERR` | Error mapping |

**Key point:** The AHB master has **no knowledge** that a protocol bridge exists. It drives a transfer to address `0x40000000`, the decoder asserts `HSEL[2]`, and from the master's perspective it is simply talking to a slow AHB slave that inserts wait states. The translation happens entirely inside the bridge.

---

## 9. Timing Constraints

### Clock constraint

```tcl
# 125 MHz = 8.000 ns period
create_clock -period 8.000 -name HCLK [get_ports HCLK]
```

### Critical paths to monitor after synthesis

1. **MUX combinational path:** `HMASTER → HADDR` (mux select to output). This path must settle within one clock period minus setup time. If violated, pipeline the MUX output with a register stage.

2. **Arbiter combinational scan:** The priority scan loop iterates over all masters. Synthesis may create a long carry chain for large `NUM_MASTERS`. Monitor with `report_timing -path_type full`.

3. **Decoder path:** `HADDR[31:20] → HSEL`. Purely combinational casex — generally fast but verify at corner.

### Checking timing in Vivado

After synthesis and implementation:

```tcl
# In Vivado Tcl console
report_timing_summary -delay_type max   ;# setup check
report_timing_summary -delay_type min   ;# hold check
report_utilization                       ;# LUT / FF usage
```

A negative Worst Negative Slack (WNS) on the setup check means a timing violation. Fix by reducing combinational logic depth on the flagged path or reducing clock frequency.

---

## 10. Simulation Guide

### Running the testbench in Vivado

1. Create a new Vivado project and add all `src/` files as design sources
2. Add `tb/tb_ahb_top.v` as a simulation source
3. Add `constraints/constraints.xdc` as a constraint source
4. Set `tb_ahb_top` as the top simulation module
5. Run behavioral simulation: **Flow → Run Simulation → Run Behavioral Simulation**

### What the testbench covers

The testbench exercises these scenarios in order:

| Scenario | What it tests |
|---|---|
| Single write — Master 0 | Basic AHB write, NONSEQ transfer, decoder selects RAM |
| Single read — Master 0 | Read path, HRDATA returned correctly |
| Simultaneous request — all 3 masters | Arbiter priority: Master 0 wins, then round-robin |
| Wait state insertion | Slave holds HREADYOUT low; master stalls correctly |
| Back-to-back transfers | Pipelined address/data phases, no bubble cycles |
| HLOCK assertion | Master 1 holds bus across 2 transfers atomically |
| APB peripheral access | Bridge FSM: SETUP→ENABLE, PREADY handshake |
| Error response | Slave drives HRESP=ERROR; master handles gracefully |

### Key waveforms to inspect

After simulation, check these signals in the waveform viewer:

```
HCLK, HRESETn          — clock and reset
HBUSREQ[2:0]           — watch which masters are requesting
HGRANT[2:0]            — verify one-hot, changes only at safe boundaries
HMASTER[1:0]           — tracks arbiter decision
HADDR, HWDATA, HRDATA  — one-cycle offset between address and data
HTRANS[1:0]            — NONSEQ at start, IDLE when done
HREADY                 — verify master holds signals when low
HSEL[2:0]              — one-hot, driven by HADDR decode
```

---

## 11. Design Decisions and Trade-offs

### Why shared bus (AMBA 2) instead of BusMatrix (AHB-Lite)?

| Criterion | Shared bus (this design) | BusMatrix / AHB-Lite |
|---|---|---|
| Parallel transactions | No — one at a time | Yes — M parallel |
| Silicon area | Small | Grows as M×S |
| Design complexity | Low | High |
| Signal visibility | Full — all signals on one bus | Distributed — hidden inside matrix |
| Suitable for | ≤4 masters, learning, prototype | Production SoCs, many masters |
| AMBA generation | AMBA 2 | AMBA 3 / AMBA 5 |

**Decision rationale:** For a 3-master prototype at 125 MHz, the shared-bus architecture provides complete signal-level visibility into every arbitration decision. The BusMatrix hides arbitration inside the interconnect fabric — correct for production, but it obscures the protocol for learning and debugging. Throughput was not the primary concern; correctness and transparency were.

### Why hybrid arbitration instead of pure priority or pure round-robin?

- **Pure priority** → starvation risk for Master 2. If Masters 0 and 1 always request, Master 2 never gets the bus. Unacceptable for any real peripheral.
- **Pure round-robin** → ignores urgency. A time-critical interrupt handler must wait behind a bulk DMA transfer.
- **Hybrid** → priority pre-emption for urgency + round-robin fallback for fairness. Best of both.

### Why is the arbiter sequential, not combinational?

The arbiter must remember who had the bus last (`rr_ptr`) and whether a locked transfer is in progress (`locked`). State requires registers. A purely combinational arbiter would produce glitches on `HGRANT` because combinational paths have no memory — every cycle it would re-evaluate from scratch and potentially change grants mid-transfer.

---

## 12. Extending the Design

### Adding a fourth master

1. Change `NUM_MASTERS` parameter in `ahb_top.v` and `ahb_arbiter.v`
2. Add a priority value for the new master in the `PRIORITY` array
3. Add the new master instance in `ahb_top.v`
4. The `generate` loop in `ahb_top.v` handles the rest automatically

### Adding a fourth slave

1. Add `HSEL[3]` output to `ahb_decoder.v` with a new address range
2. Instantiate the new slave in `ahb_top.v`
3. Connect `HSEL[3]` to the new slave's `HSEL` port
4. Add the new slave's `HRDATA` to the response mux

### Upgrading to AHB-Lite (removing HBUSREQ/HGRANT)

For single-master use (e.g., Cortex-M connected to this bus), remove `HBUSREQ`, `HGRANT`, `HLOCK`, and `HMASTER` from the master. The master drives the bus directly. Remove the arbiter. Keep the decoder and MUX (degenerate case: MUX with one input).

---

## 13. References

| Resource | Description |
|---|---|
| ARM IHI0011A | AMBA Specification Rev 2.0 — primary protocol reference |
| ARM IHI0033A | AMBA 3 AHB-Lite Protocol Specification |
| ARM DDI0479 | Cortex-M System Design Kit TRM — reference BusMatrix implementation |
| Vivado Design Suite UG901 | Vivado Design Suite User Guide: Vivado Synthesis |
| Vivado Design Suite UG903 | Using Constraints in Vivado |
| IEEE Std 1364-2001 | Verilog Hardware Description Language standard |
| opencores.org | Open-source AHB reference implementations for comparison |

---

## Quick reference — common mistakes and fixes

| Mistake | Symptom | Fix |
|---|---|---|
| Using HADDR and HWDATA in same phase | Write goes to wrong address | Latch HADDR in address phase; use latch + HWDATA in data phase |
| Not checking HTRANS[1] | Slave responds to IDLE | Add `&& HTRANS[1]` to all slave enable conditions |
| Not gating state transitions on HREADY | Master changes state during stall | Every FSM transition must be inside `if (HREADY)` |
| Arbiter changes grant mid-transfer | Data corruption on bus | Gate all grant updates with `if (HREADY)` |
| HREADYOUT glitch after reset | Bus hangs at startup | Ensure HREADYOUT resets to 1, not 0 |

---

*Document prepared following AMBA 2 AHB specification (ARM IHI0011A). All signal names comply with ARM AMBA naming convention. For questions on integration or extension, refer to module-level comments in each source file.*
