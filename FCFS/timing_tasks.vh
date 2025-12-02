`ifndef TIMING_TASKS_VH
`define TIMING_TASKS_VH

//////////////////////////////////////////////////////////////////////////////////
// DRAM Timing Rule Application Tasks
// 
// This file contains reusable tasks for applying timing rules to bank state.
// Include this file in any scheduler module that needs to update timing counters
// based on issued DRAM commands.
//
// Usage:
//   1. Include dram_timings.vh and timing_abstraction.vh first
//   2. Include this file
//   3. Declare bank_state_t bank_info [NUM_BANKS] in your module
//   4. Call apply_timing_rules() when a command is issued
//
// The task uses automatic variables (local scope) so no external declarations needed.
//////////////////////////////////////////////////////////////////////////////////

// Helper task to apply timing rules based on command
task automatic apply_timing_rules(
    input [2:0] cmd,
    input [3:0] issuing_bank_idx,
    input [BG_W-1:0] issuing_bg
);
    timing_rule_t rules [MAX_RULES_PER_CMD];
    integer i, rule_idx;
    timing_rule_t current_rule;
    logic [3:0] target_bg;
    logic should_apply;
    
    // Select rule table based on command
    case (cmd)
        CMD_PRE: rules = PRE_RULES;
        CMD_ACT: rules = ACT_RULES;
        CMD_RD:  rules = RD_RULES;
        CMD_WR:  rules = WR_RULES;
        default: rules = PRE_RULES;  // Shouldn't happen
    endcase
    
    // Apply each rule in the table
    for (rule_idx = 0; rule_idx < MAX_RULES_PER_CMD; rule_idx = rule_idx + 1) begin
        current_rule = rules[rule_idx];
        
        // Skip if value is 0 (unused rule)
        if (current_rule.value != 0) begin
            // Iterate through all banks and apply rule based on scope
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                target_bg = i[3:2];  // Extract bank group from bank index
                should_apply = 0;
                
                case (current_rule.scope)
                    SCOPE_SELF:    should_apply = (i == issuing_bank_idx);
                    SCOPE_SAME_BG: should_apply = (i != issuing_bank_idx) && (target_bg == issuing_bg);
                    SCOPE_DIFF_BG: should_apply = (target_bg != issuing_bg);
                    SCOPE_OTHER:   should_apply = (i != issuing_bank_idx);
                    SCOPE_ALL:     should_apply = 1;
                endcase
                
                // Apply timing update: take max (worst case constraint)
                if (should_apply) begin
                    case (current_rule.counter)
                        CTR_PRE: begin
                            if (bank_info[i].t_can_pre < current_rule.value)
                                bank_info[i].t_can_pre <= current_rule.value;
                        end
                        CTR_ACT: begin
                            if (bank_info[i].t_can_act < current_rule.value)
                                bank_info[i].t_can_act <= current_rule.value;
                        end
                        CTR_RD: begin
                            if (bank_info[i].t_can_rd < current_rule.value)
                                bank_info[i].t_can_rd <= current_rule.value;
                        end
                        CTR_WR: begin
                            if (bank_info[i].t_can_wr < current_rule.value)
                                bank_info[i].t_can_wr <= current_rule.value;
                        end
                    endcase
                end
            end
        end
    end
endtask

`endif // TIMING_TASKS_VH
