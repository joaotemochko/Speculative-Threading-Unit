# STU: Speculative Threading Unit

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](...)
[![License](https://img.shields.io/badge/license-MIT-blue)](...)
[![Language](https://img.shields.io/badge/language-SystemVerilog-purple)](...)

The **STU (Speculative Threading Unit)** is a SystemVerilog hardware architecture designed to extract Thread-Level Parallelism (TLP) from *single-threaded* code.

Its primary goal is to **minimize performance loss** from failed speculation while still capturing both modest (safe) and aggressive (high-risk) performance gains. It achieves this by acting as an **Adaptive Flow Director** that dynamically selects one of three execution strategies for any given block of code.

---

## 🏛️ The 3-Level Adaptive Architecture

The STU is built on a 3-level execution hierarchy. The `stu_safety_filter` analyzes each instruction block and classifies it, allowing the `stu_fork_controller` to select the optimal strategy.

### Level 0: Safety Bypass (Minimal Loss)
This mode handles code that must be serialized to ensure correctness, such as explicit software-level multi-threading.

* **Trigger:** The `stu_safety_filter` detects instructions with global side-effects (e.g., `FENCE`, `AMO`, `SYSTEM`).
* **Action:** The `stu_fork_controller` idles and does nothing. The code is forwarded to the Master core (Core 0) for standard serial execution.
* **Result:** **Minimal Performance Loss.** The only cost is the single-cycle lookup in the filter. This prevents speculation from breaking software-level synchronization.

### Level 1: Conservative Parallelism (Modest, Safe Gain)
This mode provides a "safe" performance boost for "embarrassingly parallel" code.

* **Trigger:** The `stu_safety_filter` identifies a block containing *only* safe instructions (e.g., `LOAD`s, `ADD`s, `MUL`s) and no `STORE`s or `BRANCH`es.
* **Action:** The `stu_fork_controller` enters "Block Expander" mode. It finds idle worker cores and dispatches the block, split among them (e.g., 2 instructions each). The expensive `stu_memory_tracker` remains clock-gated, saving power.
* **Result:** **Modest Performance Gain.** This mode provides a risk-free performance boost with minimal power overhead, as a `SQUASH` is impossible.

### Level 2: Optimistic Speculation (High-Gain, Controlled-Risk)
This is the "high-stakes" mode for complex code (like loops containing `STORE`s) that cannot be handled by Level 1.

* **Trigger:** The `stu_safety_filter` detects a "difficult" block (containing `STORE`s or `BRANCH`es).
* **Action:** The `stu_fork_controller` attempts a "thread fork", but **only if the HPT predicts success**.
* **Result (COMMIT):** **Massive Performance Gain.** A complex loop is successfully parallelized.
* **Result (SQUASH):** **High Performance Loss.** The `stu_memory_tracker` detected a data violation or the `stu_validator` received an exception. The work is discarded.

---

## 🛡️ Minimizing the Achilles' Heel: The HPT

The greatest risk of Level 2 is the `SQUASH`. The STU mitigates this "Achilles' heel" by using a **History Predictor Table (HPT)** inside the `stu_fork_controller`.

1.  **Prediction:** Before attempting a Level 2 "fork", the controller consults the HPT to check the "confidence score" for that loop (based on its PC).
2.  **Risk Aversion:** If the HPT predicts a failure (e.g., the loop failed last time), the `stu_fork_controller` **cancels the bet**. It overrides the Level 2 classification and treats the block as Level 0 (Bypass).
3.  **Learning:** After a `SQUASH` or `COMMIT`, the `stu_validator` sends feedback to the `stu_fork_controller`, which updates the HPT entry for that loop.

This HPT mechanism ensures that the STU "learns" to avoid loops that cause frequent failures, converting a **High Performance Loss** scenario into a **Minimal Loss** (Bypass) scenario.

---

## 🐧 OS & MMU Support

The STU is designed to be compatible with OS-capable cores (like Nebula and Supernova) that use virtual memory (MMU).

1.  **Physical Address (PA) Tracking:** The `stu_memory_tracker` is designed to snoop **Physical Addresses** (`core_mem_pa_in`) *after* the core's MMU/TLB. This correctly detects memory *aliasing*, where different Virtual Addresses point to the same Physical Address.
2.  **Context Management:** The `stu_fork_controller` implements a "Context Copy" state. It uses a new module, `stu_context_manager`, to copy the full register file (`regfile`) from the Master core to the Speculative core before starting a Level 2 fork.
3.  **Exception Handling:** The `stu_validator` accepts an `l2_spec_exception_in` signal. Any exception on a speculative core (e.g., a Page Fault) is immediately treated as a `SQUASH`.

---

## 📦 Architecture Modules

| Module | Function |
| :--- | :--- |
| **`stu_pkg.sv`** | Defines global types (`addr_t`, `instr_t`) and the `spec_level_t` enum. |
| **`stu_safety_filter.sv`** | **The Director.** Combinational logic that classifies an instruction block as L0, L1, or L2. |
| **`stu_fork_controller.sv`** | **The Brain.** The main FSM. Manages L1 dispatches, L2 forks, and the HPT to decide when to "bet". |
| **`stu_memory_tracker.sv`** | **The Spy.** Power-gated module (L2 only). Uses CAMs to track Read-Sets (PAs) and detect data violations (RAW hazards). |
| **`stu_validator.sv`** | **The Judge.** Power-gated FSM (L2 only). Manages the `COMMIT`/`SQUASH` lifecycle and handles exceptions. |
| **`stu_context_manager.sv`** | **The Copier.** FSM that manages the high-latency register file copy from Master to Speculative core before an L2 fork. |
| **`stu_top.sv`** | **The Top-Level.** Instantiates all components and connects them to the SoC and core interfaces. |

---

## 🚧 Project Status

**Work in Progress (WIP)** - The core logic for the 3-Level Adaptive STU is defined. The next step is the implementation of the `Nebula` (In-Order) and `Supernova` (OoO) cores, which must adhere to the STU interfaces (PA snoop, context copy, exception reporting, etc.).
