# DRAM Timing Abstraction System

## Overview

This DRAM controller uses a **data-driven timing abstraction** that separates timing constraints from command execution logic. This makes it easy to add, modify, or verify timing constraints without touching the core command logic.

## Architecture

### File Structure

```
dram_timings.vh          - All timing parameters and data structures
timing_abstraction.vh    - Timing rule definitions and command tables
generate_command.v       - Main controller logic (uses timing tables)
```

### Key Concepts

1. **Timing Rules** - Declarative constraints that specify:
   - Which counter to update (`t_can_pre`, `t_can_act`, `t_can_rd`, `t_can_wr`)
   - What value to set (in clock cycles)
   - Which banks are affected (scope)

2. **Scope** - Defines the relationship between the bank issuing a command and banks affected:
   - `SCOPE_SELF` - Only the issuing bank
   - `SCOPE_SAME_BG` - Other banks in the same bank group
   - `SCOPE_DIFF_BG` - Banks in different bank groups
   - `SCOPE_OTHER` - All banks except self
   - `SCOPE_ALL` - All banks including self

3. **Command Tables** - Each DRAM command (PRE, ACT, RD, WR) has a table of timing rules

## How It Works

When a command is issued:

1. The `apply_timing_rules()` task is called with the command type and issuing bank
2. It looks up the appropriate rule table (e.g., `ACT_RULES` for ACTIVATE)
3. For each rule in the table:
   - Determines which banks match the scope
   - Updates the specified counter if the new value is larger (max operation)
4. The main logic doesn't need to know about specific timings!

## Adding New Timing Constraints

### Example: Add tFAW (Four Activate Window) constraint

**Step 1:** Add timing parameter to `dram_timings.vh` (already exists)
```systemverilog
parameter int tFAW = 16;  // Four Activate Window
```

**Step 2:** Add rule to `ACT_RULES` in `timing_abstraction.vh`
```systemverilog
parameter timing_rule_t ACT_RULES [MAX_RULES_PER_CMD] = '{
    // ... existing rules ...
    
    // NEW: All banks must respect tFAW
    '{counter: CTR_ACT, value: tFAW, scope: SCOPE_ALL},
    
    // ... remaining slots ...
};
```

**Step 3:** Done! No changes needed to `generate_command.v`

### Example: Add tRFC (Refresh Timing)

**Step 1:** Add to `dram_timings.vh`
```systemverilog
parameter int tRFC = 160;  // Refresh cycle time
```

**Step 2:** Create `REF_RULES` in `timing_abstraction.vh`
```systemverilog
parameter timing_rule_t REF_RULES [MAX_RULES_PER_CMD] = '{
    // All banks blocked from all operations during refresh
    '{counter: CTR_ACT, value: tRFC, scope: SCOPE_ALL},
    '{counter: CTR_RD,  value: tRFC, scope: SCOPE_ALL},
    '{counter: CTR_WR,  value: tRFC, scope: SCOPE_ALL},
    '{counter: CTR_PRE, value: tRFC, scope: SCOPE_ALL},
    // ... remaining slots ...
};
```

**Step 3:** Add `CMD_REF` case to `apply_timing_rules()` task
```systemverilog
case (cmd)
    CMD_PRE: rules = PRE_RULES;
    CMD_ACT: rules = ACT_RULES;
    CMD_RD:  rules = RD_RULES;
    CMD_WR:  rules = WR_RULES;
    CMD_REF: rules = REF_RULES;  // NEW
    default: rules = PRE_RULES;
endcase
```

## Current Timing Rules

### PRECHARGE (PRE_RULES)
- Self bank: Can ACT after `tRP`

### ACTIVATE (ACT_RULES)
- Self bank: Can RD/WR after `tRCD`
- Self bank: Can PRE after `tRAS`
- Same BG: Other banks can ACT after `tRRD_S`
- Diff BG: Other banks can ACT after `tRRD_L`

### READ (RD_RULES)
- Self bank: Can PRE after `tRTP`
- Self bank: Can WR after `tRTW`
- Same BG: Other banks can RD after `tCCD_S`
- Diff BG: Other banks can RD after `tCCD_L`

### WRITE (WR_RULES)
- Self bank: Can PRE after `tWR`
- Same BG: Other banks can WR after `tCCD_S`
- Diff BG: Other banks can WR after `tCCD_L`
- Same BG: Other banks can RD after `tWTR_S`
- Diff BG: Other banks can RD after `tWTR_L`

## Benefits

✅ **Scalable** - Add new timings without touching command logic  
✅ **Maintainable** - All timing constraints in one place  
✅ **Verifiable** - Rules are declarative and easy to audit  
✅ **Self-Documenting** - Rule tables show all timing relationships  
✅ **Flexible** - Easy to experiment with different timing parameters  

## Extending the System

### Need more counters?
Add to `counter_type_t` enum and `bank_state_t` struct, update the case statement in `apply_timing_rules()`

### Need more complex scopes?
Add to `scope_t` enum and update the scope matching logic in `apply_timing_rules()`

### Need conditional rules?
Add conditions to the rule struct (e.g., "only if row buffer hit") and check in `apply_timing_rules()`

## Performance Notes

- Rule application happens once per command issue (not every cycle)
- All counters decrement every cycle regardless of rules
- Loop unrolling in synthesis should make this efficient
- For very large numbers of banks, consider pipelining rule application
