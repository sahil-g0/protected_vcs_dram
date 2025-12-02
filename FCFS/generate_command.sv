`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// DRAM Controller - Command Generation Module
//////////////////////////////////////////////////////////////////////////////////

`include "dram_timings.vh"
`include "timing_abstraction.vh"

module generate_instruction(
    input clk,
    input reset,
    input [31:0] address,
    input r_w,              // 0 = read, 1 = write
    input [31:0] write_data,
    input fifo_empty,       // FIFO is empty (no data available)
    // Note: If your FIFO has 'valid' output, you can use !valid instead of fifo_empty
    
    output reg pop,         // Pop from FIFO when READ/WRITE completes
    output reg [2:0] command
);
    bank_state_t bank_info [NUM_BANKS];
    
    // Decode address fields
    wire [BG_W-1:0]   bg   = address[BG_MSB : BG_LSB];
    wire [BANK_W-1:0] bank = address[BANK_MSB : BANK_LSB];
    wire [ROW_W-1:0]  row  = address[ROW_MSB  : ROW_LSB];
    wire [COL_W-1:0]  col  = address[COL_MSB  : COL_LSB];
    
    // Calculate flat bank index: bank_group has 4 banks, so index = bg*4 + bank
    wire [3:0] bank_idx = {bg, bank};  // Concatenate for flat index
    
    // Combinational signals
    reg [2:0] next_command;
    reg       can_issue;
    
    // ================================================================
    // COMBINATIONAL LOGIC: Determine next command
    // ================================================================
    // NOTE: Check if counter is 0 (command can issue)
    always @(*) begin
        next_command = CMD_NOP;
        can_issue = 1'b0;
        
        // Only process if FIFO has data available
        if (!fifo_empty) begin
            // Check the target bank's state
            if (!bank_info[bank_idx].is_open) begin
                // Row is closed → need ACTIVATE
                if (bank_info[bank_idx].t_can_act == 0) begin
                    next_command = CMD_ACT;
                    can_issue = 1'b1;
                end
            end
            else begin
                // Row is open
                if (bank_info[bank_idx].open_row == row) begin
                    // Same row → issue READ or WRITE
                    if (r_w == 1'b0) begin
                        // READ
                        if (bank_info[bank_idx].t_can_rd == 0) begin
                            next_command = CMD_RD;
                            can_issue = 1'b1;
                        end
                    end
                    else begin
                        // WRITE
                        if (bank_info[bank_idx].t_can_wr == 0) begin
                            next_command = CMD_WR;
                            can_issue = 1'b1;
                        end
                    end
                end
                else begin
                    // Different row → need PRECHARGE first
                    if (bank_info[bank_idx].t_can_pre == 0) begin
                        next_command = CMD_PRE;
                        can_issue = 1'b1;
                    end
                end
            end
        end
    end
    
    // ================================================================
    // SEQUENTIAL LOGIC: Issue commands and update bank states
    // ================================================================
    integer i;
    
    // Helper task to apply timing rules based on command
    task automatic apply_timing_rules(
        input [2:0] cmd,
        input [3:0] issuing_bank_idx,
        input [BG_W-1:0] issuing_bg
    );
        timing_rule_t rules [MAX_RULES_PER_CMD];
        integer j, rule_idx;
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
                for (j = 0; j < NUM_BANKS; j = j + 1) begin
                    target_bg = j[3:2];  // Extract bank group from bank index
                    should_apply = 0;
                    
                    case (current_rule.scope)
                        SCOPE_SELF:    should_apply = (j == issuing_bank_idx);
                        SCOPE_SAME_BG: should_apply = (j != issuing_bank_idx) && (target_bg == issuing_bg);
                        SCOPE_DIFF_BG: should_apply = (target_bg != issuing_bg);
                        SCOPE_OTHER:   should_apply = (j != issuing_bank_idx);
                        SCOPE_ALL:     should_apply = 1;
                    endcase
                    
                    // Apply timing update: take max (worst case constraint)
                    // Set to value-1 since counters decrement in the same cycle
                    if (should_apply) begin
                        case (current_rule.counter)
                            CTR_PRE: begin
                                if (bank_info[j].t_can_pre < current_rule.value - 1)
                                    bank_info[j].t_can_pre <= current_rule.value - 1;
                            end
                            CTR_ACT: begin
                                if (bank_info[j].t_can_act < current_rule.value - 1)
                                    bank_info[j].t_can_act <= current_rule.value - 1;
                            end
                            CTR_RD: begin
                                if (bank_info[j].t_can_rd < current_rule.value - 1)
                                    bank_info[j].t_can_rd <= current_rule.value - 1;
                            end
                            CTR_WR: begin
                                if (bank_info[j].t_can_wr < current_rule.value - 1)
                                    bank_info[j].t_can_wr <= current_rule.value - 1;
                            end
                        endcase
                    end
                end
            end
        end
    endtask
    
    always @(posedge clk) begin
        if (reset) begin  
            command <= CMD_NOP;
            pop <= 1'b0;
            
            for (i = 0; i < NUM_BANKS; i = i + 1) begin 
                bank_info[i].is_open   <= 1'b0;
                bank_info[i].open_row  <= '0;
                bank_info[i].t_can_pre <= 8'd0;
                bank_info[i].t_can_act <= 8'd0;
                bank_info[i].t_can_rd  <= 8'd0;
                bank_info[i].t_can_wr  <= 8'd0;
            end
        end
        else begin
            // Decrement all timing counters FIRST, before command issue
            // This ensures that apply_timing_rules can overwrite decremented values
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                if (bank_info[i].t_can_pre > 0) 
                    bank_info[i].t_can_pre <= bank_info[i].t_can_pre - 1;
                if (bank_info[i].t_can_act > 0) 
                    bank_info[i].t_can_act <= bank_info[i].t_can_act - 1;
                if (bank_info[i].t_can_rd > 0) 
                    bank_info[i].t_can_rd  <= bank_info[i].t_can_rd - 1;
                if (bank_info[i].t_can_wr > 0) 
                    bank_info[i].t_can_wr  <= bank_info[i].t_can_wr - 1;
            end
            
            // Issue command if ready (AFTER decrementing counters)
            command <= next_command;
            pop <= can_issue && (next_command == CMD_RD || next_command == CMD_WR);
            
            // Update bank state based on issued command
            if (can_issue) begin
                case (next_command)
                    CMD_PRE: begin
                        // Precharge: close the row
                        bank_info[bank_idx].is_open   <= 1'b0;
                        bank_info[bank_idx].open_row  <= '0;
                        
                        // Apply timing rules
                        apply_timing_rules(CMD_PRE, bank_idx, bg);
                    end
                    
                    CMD_ACT: begin
                        // Activate: open the row
                        bank_info[bank_idx].is_open   <= 1'b1;
                        bank_info[bank_idx].open_row  <= row;
                        
                        // Apply timing rules
                        apply_timing_rules(CMD_ACT, bank_idx, bg);
                    end
                    
                    CMD_RD: begin
                        // Apply timing rules
                        apply_timing_rules(CMD_RD, bank_idx, bg);
                    end
                    
                    CMD_WR: begin
                        // Apply timing rules
                        apply_timing_rules(CMD_WR, bank_idx, bg);
                    end
                endcase
            end
        end
    end
endmodule

