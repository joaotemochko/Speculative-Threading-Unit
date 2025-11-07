# STU: Speculative Threading Unit

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](https://github.com/joaotemochko/Instruction-Flow-Expander)
[![License](https://img.shields.io/badge/license-MIT-blue)](https://github.com/joaotemochko/Instruction-Flow-Expander)
[![Language](https://img.shields.io/badge/language-SystemVerilog-purple)](https://github.com/joaotemochko/Instruction-Flow-Expander)

The **STU (Speculative Threading Unit)** is a SystemVerilog hardware architecture designed to extract Thread-Level Parallelism (TLP) from *single-threaded* code via an adaptive speculation system.

## 🎯 The Problem

Many applications (such as games, physics simulators, and media processing) spend most of their time in *loops* that are serialized at the software level, even though they contain vast data parallelism (ILP/TLP).

## 💡 The Solution: The "Adaptive Flow Director"

The STU is not a single architecture, but rather an **Adaptive Flow Director**. It analyzes the instruction stream and dynamically selects, at the hardware level, the best execution strategy to minimize losses and maximize gains.

The STU operates on three levels of speculation:



* **Level 0: Safety Bypass (Objective: "No-Loss")**
    * **Detection:** Explicit synchronization code (`FENCE`, `AMO`) or system calls (`ECALL`).
    * **Action:** Speculation is disabled. The code is serialized.
    * **Result:** Guarantees correctness for *multi-threaded* software with no risk of failure.

* **Level 1: Conservative Speculation (IFE-Mode) (Objective: "Safe Gains")**
    * **Detection:** "Easy" code block (no `STORE`s or `BRANCH`es, only `LOAD`s and `COMPUTE`).
    * **Action:** The STU reconfigures as an "Expander." The `stu_fork_controller` splits the work (the block) among idle cores. The `stu_memory_tracker` is disabled to save power.
    * **Result:** A performance gain (e.g., 2x-4x) with **zero risk** of a `SQUASH`.

* **Level 2: Optimistic Speculation (STU-Mode) (Objective: "The High Bet")**
    * **Detection:** "Hard" code (contains `STORE`s, `BRANCH`es, or is a complex loop).
    * **Action:** The full STU architecture is enabled. The `stu_fork_controller` "forks" the loop, and the `stu_memory_tracker` (with its CAMs) is activated to check for data violations.
    * **Result:** A massive performance gain (`COMMIT`) or a controlled performance loss (`SQUASH`).

---

## 🏛️ Architecture & Modules

The system is composed of a top module (`stu_top`) that coordinates four primary components.

| Module | Function |
| :--- | :--- |
| **`stu_top.sv`** | The top-level module that instantiates and connects all STU components. |
| **`stu_safety_filter.sv`** | **The Flow Director.** Combinational decoder that analyzes the instruction stream and classifies each block into Level 0, 1, or 2. |
| **`stu_fork_controller.sv`** | **The Brain.** FSM that forks tasks. Detects triggers (*loops*) and allocates idle cores, operating in either "Expander" (Level 1) or "Forker" (Level 2) mode. |
| **`stu_memory_tracker.sv`** | **The Spy (Level 2).** The most complex component. Uses CAMs (Content Addressable Memories) to track the "Read-Sets" of speculative cores and compare them against the Master core's `STORE`s. |
| **`stu_validator.sv`** | **The Judge (Level 2).** FSM that coordinates "done" and "violation" signals. Issues the final `SQUASH` (failure) or `COMMIT` (success) pulse for the task. |
| **`stu_pkg.sv`** | SystemVerilog package containing global types and parameters. |

---

## ⚙️ Example Workflow

1.  **Level 1 (Safe Gain):**
    * A block of 4 `fld` (float loads) arrives.
    * The `stu_safety_filter` classifies it as **Level 1** (no `STORE`s).
    * The `stu_fork_controller` is instructed to split the block among 4 idle cores.
    * **Result:** Data fetch time is divided by 4. The `stu_memory_tracker` remains off, saving power.

2.  **Level 2 (The High Bet):**
    * The `stu_safety_filter` detects a backward branch (`BNE`) containing `STORE`s. It classifies it as **Level 2**.
    * The `stu_fork_controller` "forks" the next loop iteration to Core 1.
    * The `stu_memory_tracker` is activated and begins logging Core 1's `LOAD`s into its Read-Set.
    * **If Core 0 (Master) performs a `STORE`** to an address Core 1 has already read, the tracker fires `violation_out`. The `stu_validator` issues a `SQUASH`.
    * **If Core 0 (Master) finishes** with no violations, the `stu_validator` waits for Core 1 to finish and issues a `COMMIT`.

---

## ⚖️ Trade-offs: Power vs. Performance

* **Performance:** The net gain depends on the "hit rate" of Level 2 bets. In ideal workloads (games, physics), the Level 1 code and Level 2 `COMMIT`s will far outweigh the losses from `SQUASH`es.
* **Power:** Power consumption is the greatest challenge. The `stu_memory_tracker` is expensive, as CAMs are power-hungry components. The STU's adaptive architecture mitigates this by activating the tracker ("The Spy") only when absolutely necessary (Level 2), while operating in a low-power mode (Level 1) the rest of the time.

## 🚧 Project Status

**Work in Progress (WIP)** - This architecture is a conceptual prototype for exploring Adaptive Thread-Level Speculation.
