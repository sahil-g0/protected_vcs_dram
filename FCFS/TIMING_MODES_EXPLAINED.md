# DRAM Timing Update Modes: MAX vs ADD

## The Question

When a command issues and updates timing counters, should we:
- **MAX**: Take the larger of (current_value, new_value) 
- **ADD**: Accumulate (current_value + new_value)

## TL;DR Answer

**Most DRAM timings use MAX**, but some rare cases need ADD. The system now supports both via the `additive` flag in timing rules.

---

## MAX Mode (Default) - `additive = 0`

### How it works:
```verilog
if (bank_info[i].t_can_act < current_rule.value)
    bank_info[i].t_can_act <= current_rule.value;
```

### When to use:
**Use MAX when the timing constraint is relative to the MOST RECENT command of a given type.**

### Example: ACT-to-ACT (tRRD_S = 4 cycles)
```
Cycle 0: ACT to Bank0 in BG0
         → Bank1.t_can_act = 4  (can ACT at cycle 4)

Cycle 1: Decrement
         → Bank1.t_can_act = 3

Cycle 2: ACT to Bank2 in BG0 (another ACT in same BG!)
         → Bank1.t_can_act = MAX(3, 4) = 4  ✓ CORRECT
         → Constraint now relative to THIS new ACT (cycle 2)
         → Bank1 can ACT at cycle 6 (4 cycles from cycle 2)
```

**Why MAX is correct**: The tRRD_S constraint means "4 cycles since the **last** ACT in this bank group". When Bank2 activates, it becomes the new reference point. We care about the **most recent** ACT, not all ACTs.

### Other timings that use MAX:
- `tRCD` - Time since last ACT to this bank
- `tRAS` - Time since last ACT to this bank  
- `tRP` - Time since last PRE to this bank
- `tRTP` - Time since last READ to this bank
- `tWR` - Time since last WRITE to this bank
- `tCCD_S/L` - Time since last CAS (RD/WR) in bank group
- `tWTR_S/L` - Time since last WRITE in bank group

---

## ADD Mode (Rare) - `additive = 1`

### How it works:
```verilog
bank_info[i].t_can_act <= bank_info[i].t_can_act + current_rule.value;
```

### When to use:
**Use ADD when timing constraints accumulate or when tracking multiple independent events.**

### Example 1: tFAW (Four Activate Window)
DDR4 rule: "Max 4 ACTs per 16 cycles across all banks"

This requires tracking a **sliding window** of ACT commands. If you implement tFAW as a simple counter:

```
Cycle 0: ACT → faw_counter += tFAW  (additive!)
Cycle 4: ACT → faw_counter += tFAW  (accumulates)
Cycle 8: ACT → faw_counter += tFAW
Cycle 12: ACT → faw_counter += tFAW
Cycle 13: Next ACT would violate tFAW
```

**Note**: Full tFAW implementation is more complex (needs a 4-entry history), but additive counters can be part of the solution.

### Example 2: Write Data Bus Conflicts
If multiple writes target the same data bus and queue up:

```
Cycle 0: WRITE → bus_busy = tWL + tBurst (6 cycles)
Cycle 2: WRITE → bus_busy = 4 + 6 = 10  (ADD, not MAX!)
         → Second write must wait for first to finish
```

### Example 3: Deferred Refresh Accumulation
```
Miss 1 refresh → refresh_debt += tREFI
Miss 2 refresh → refresh_debt += tREFI  (cumulative!)
```

### Other potential ADD use cases:
- Back-to-back writes to same column (data burst extension)
- Pipeline stage occupancy tracking
- Power budget accumulation

---

## Summary Table

| Timing Constraint | Mode | Reason |
|-------------------|------|--------|
| tRCD, tRAS, tRP | MAX | Relative to last command to this bank |
| tRRD_S, tRRD_L | MAX | Relative to last ACT in bank group |
| tCCD_S, tCCD_L | MAX | Relative to last CAS in bank group |
| tRTP, tWR | MAX | Relative to last RD/WR to this bank |
| tWTR_S, tWTR_L | MAX | Relative to last WR in bank group |
| tFAW (simplified) | ADD | Tracks cumulative ACT density |
| Write bus conflicts | ADD | Queued operations accumulate |
| Refresh debt | ADD | Missed refreshes accumulate |

---

## Implementation in Your Code

All current timing rules use `additive: 1'b0` (MAX mode), which is correct for standard DDR4 timings.

To add a cumulative constraint, just set `additive: 1'b1`:

```systemverilog
// Example: If implementing simplified tFAW tracking
'{counter: CTR_ACT, value: tFAW, scope: SCOPE_ALL, additive: 1'b1}
```

The `apply_timing_rules()` task automatically handles both modes.
