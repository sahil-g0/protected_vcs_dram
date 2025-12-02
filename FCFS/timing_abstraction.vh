`ifndef TIMING_ABSTRACTION_VH
`define TIMING_ABSTRACTION_VH

//////////////////////////////////////////////////////////////////////////////////
// DRAM Timing Abstraction Layer
// 
// This file provides a data-driven approach to timing constraint management.
// Instead of hardcoding timing updates in command logic, we define timing
// rules that describe:
//   - Which counter to update (t_can_act, t_can_rd, etc.)
//   - What value to apply
//   - Which banks are affected (same bank, same BG, different BG, all, etc.)
//
// To add a new timing constraint:
//   1. Add the timing parameter to dram_timings.vh
//   2. Add a timing rule to the appropriate command's rule table below
//   3. No changes needed to the command execution logic!
//////////////////////////////////////////////////////////////////////////////////

// ================================================================
// Timing Counter Type Enum
// ================================================================
typedef enum logic [2:0] {
    CTR_PRE = 3'd0,    // t_can_pre counter
    CTR_ACT = 3'd1,    // t_can_act counter
    CTR_RD  = 3'd2,    // t_can_rd counter
    CTR_WR  = 3'd3     // t_can_wr counter
} counter_type_t;

// ================================================================
// Bank Scope Enum (which banks are affected by timing rule)
// ================================================================
typedef enum logic [2:0] {
    SCOPE_SELF       = 3'd0,  // Only the bank issuing the command
    SCOPE_SAME_BG    = 3'd1,  // Banks in same bank group (excluding self)
    SCOPE_DIFF_BG    = 3'd2,  // Banks in different bank groups
    SCOPE_OTHER      = 3'd3,  // All other banks (excluding self)
    SCOPE_ALL        = 3'd4   // All banks (including self)
} scope_t;

// ================================================================
// Timing Rule Structure
// ================================================================
typedef struct packed {
    counter_type_t counter;    // Which counter to update
    logic [7:0]    value;      // Timing value (cycles)
    scope_t        scope;      // Which banks are affected
} timing_rule_t;

// ================================================================
// Command Timing Rule Tables
// 
// Each command has a table of timing rules that are applied when
// the command is issued. The apply_timing_rules function (in the
// main module) iterates through these rules and updates the
// appropriate bank counters.
// ================================================================

// Maximum number of rules per command
parameter MAX_RULES_PER_CMD = 8;

// ----------------------------------------------------------------
// PRECHARGE Timing Rules
// ----------------------------------------------------------------
parameter timing_rule_t PRE_RULES [MAX_RULES_PER_CMD] = '{
    // Self: Can ACT after tRP
    '{counter: CTR_ACT, value: tRP, scope: SCOPE_SELF},
    
    // All other rules unused (set to 0)
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF}
};

// ----------------------------------------------------------------
// ACTIVATE Timing Rules
// ----------------------------------------------------------------
parameter timing_rule_t ACT_RULES [MAX_RULES_PER_CMD] = '{
    // Self: Can READ/WRITE after tRCD
    '{counter: CTR_RD,  value: tRCD,   scope: SCOPE_SELF},
    '{counter: CTR_WR,  value: tRCD,   scope: SCOPE_SELF},
    
    // Self: Can PRECHARGE after tRAS
    '{counter: CTR_PRE, value: tRAS,   scope: SCOPE_SELF},
    
    // Same BG: ACT-to-ACT timing
    '{counter: CTR_ACT, value: tRRD_S, scope: SCOPE_SAME_BG},
    
    // Diff BG: ACT-to-ACT timing
    '{counter: CTR_ACT, value: tRRD_L, scope: SCOPE_DIFF_BG},
    
    // Unused
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF}
};

// ----------------------------------------------------------------
// READ Timing Rules
// ----------------------------------------------------------------
parameter timing_rule_t RD_RULES [MAX_RULES_PER_CMD] = '{
    // Self: Can PRECHARGE after tRTP
    '{counter: CTR_PRE, value: tRTP,   scope: SCOPE_SELF},
    
    // Self: Can WRITE after tRTW (Read-to-Write turnaround)
    '{counter: CTR_WR,  value: tRTW,   scope: SCOPE_SELF},
    
    // Self: READ-to-READ timing (same bank)
    '{counter: CTR_RD,  value: tCCD_S, scope: SCOPE_SELF},
    
    // Same BG: READ-to-READ timing
    '{counter: CTR_RD,  value: tCCD_S, scope: SCOPE_SAME_BG},
    
    // Diff BG: READ-to-READ timing
    '{counter: CTR_RD,  value: tCCD_L, scope: SCOPE_DIFF_BG},
    
    // Unused
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF}
};

// ----------------------------------------------------------------
// WRITE Timing Rules
// ----------------------------------------------------------------
parameter timing_rule_t WR_RULES [MAX_RULES_PER_CMD] = '{
    // Self: Can PRECHARGE after tWR (Write Recovery)
    '{counter: CTR_PRE, value: tWR,    scope: SCOPE_SELF},
    
    // Self: WRITE-to-WRITE timing (same bank)
    '{counter: CTR_WR,  value: tCCD_S, scope: SCOPE_SELF},
    
    // Same BG: WRITE-to-WRITE timing
    '{counter: CTR_WR,  value: tCCD_S, scope: SCOPE_SAME_BG},
    
    // Diff BG: WRITE-to-WRITE timing
    '{counter: CTR_WR,  value: tCCD_L, scope: SCOPE_DIFF_BG},
    
    // Same BG: WRITE-to-READ timing
    '{counter: CTR_RD,  value: tWTR_S, scope: SCOPE_SAME_BG},
    
    // Diff BG: WRITE-to-READ timing
    '{counter: CTR_RD,  value: tWTR_L, scope: SCOPE_DIFF_BG},
    
    // Unused
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF},
    '{counter: CTR_PRE, value: 0, scope: SCOPE_SELF}
};

`endif // TIMING_ABSTRACTION_VH
