// =============================================================================
// Schedule Generator Module
// =============================================================================
// Implements Phases 2 & 3 of the scheduling algorithm.
// Fixed Logic: 
// 1. Starts at Cycle 0.
// 2. Improved Interleaving.
// 3. Increased Memory Read Latency (2-cycle wait) to fix data races.
// =============================================================================

`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module schedule_generator (
    input  wire clk,
    input  wire rst_n,

    // Control
    input  wire start,
    output reg  done,
    output reg  busy,

    // Input: Critical Path Info
    input  wire [`SBR_ID_WIDTH-1:0]      critical_path_sbr,
    input  wire [`SBR_ID_WIDTH-1:0]      num_sbr_entries,

    // Interface: SBR Table (Read Only)
    output reg  [`SBR_ID_WIDTH-1:0]      sbr_rd_addr,
    input  wire [`BANK_GROUP_WIDTH-1:0]  sbr_rd_bank_group,
    input  wire [`BANK_WIDTH-1:0]        sbr_rd_bank,
    input  wire [`SRR_ID_WIDTH-1:0]      sbr_rd_head_srr,
    
    // Interface: SRR Table (Read Only)
    output reg  [`SRR_ID_WIDTH-1:0]      srr_rd_addr,
    input  wire [`HIT_TAG_WIDTH-1:0]     srr_rd_hit_tag,
    input  wire [`REQUEST_ID_WIDTH-1:0]  srr_rd_head_req,
    input  wire [`SRR_ID_WIDTH-1:0]      srr_rd_chain_next,
    input  wire                          srr_rd_chain_valid,

    // Interface: Request Buffer (Read Only - for chaining)
    output reg  [`REQUEST_ID_WIDTH-1:0]  req_rd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]  req_rd_chain_next,
    input  wire                          req_rd_chain_valid,

    // Interface: Bank State Tracker (Query & Update)
    output reg  [`BANK_GROUP_WIDTH-1:0]  bst_query_bank_group,
    output reg  [`BANK_WIDTH-1:0]        bst_query_bank,
    input  wire                          bst_is_precharged,
    input  wire                          bst_is_row_open,
    input  wire [`ROW_WIDTH-1:0]         bst_open_row,
    
    output reg                           bst_upd_activate,
    output reg                           bst_upd_precharge,
    output reg  [`BANK_GROUP_WIDTH-1:0]  bst_upd_bank_group,
    output reg  [`BANK_WIDTH-1:0]        bst_upd_bank,
    output reg  [`ROW_WIDTH-1:0]         bst_upd_row,

    // Interface: Schedule Memory (Write Only)
    output reg                           sched_wr_en,
    output reg  [`CYCLE_WIDTH-1:0]       sched_wr_cycle,
    output reg  [2:0]                    sched_wr_cmd_type,
    output reg  [`BANK_GROUP_WIDTH-1:0]  sched_wr_bank_group,
    output reg  [`BANK_WIDTH-1:0]        sched_wr_bank,
    output reg  [`ROW_WIDTH-1:0]         sched_wr_row,
    output reg  [`COLUMN_WIDTH-1:0]      sched_wr_column,
    output reg  [`REQUEST_ID_WIDTH-1:0]  sched_wr_request_id
);

    // =============================================================================
    // Internal State
    // =============================================================================
    reg [3:0] state;
    reg [2:0] delay_cnt;

    // Iterators
    reg [`SBR_ID_WIDTH-1:0]     sbr_iter;
    reg [`SRR_ID_WIDTH-1:0]     curr_srr_ptr;
    reg [`REQUEST_ID_WIDTH-1:0] curr_req_ptr;
    reg                         processing_critical; 
    reg [`SBR_ID_WIDTH-1:0]     processed_count;

    // Current Context
    reg [`BANK_GROUP_WIDTH-1:0] curr_bg;
    reg [`BANK_WIDTH-1:0]       curr_bank;
    reg [`ROW_WIDTH-1:0]        curr_target_row;
    
    // Timing State
    reg [`CYCLE_WIDTH-1:0] global_cmd_ptr;
    reg [`CYCLE_WIDTH-1:0] last_act_time;
    reg [`CYCLE_WIDTH-1:0] last_rd_time; 
    reg [`CYCLE_WIDTH-1:0] bank_busy_until [0:`TOTAL_BANKS-1];
    
    wire [$clog2(`TOTAL_BANKS)-1:0] curr_bank_idx = {curr_bg, curr_bank};

    function [`CYCLE_WIDTH-1:0] max;
        input [`CYCLE_WIDTH-1:0] a, b;
        begin
            max = (a > b) ? a : b;
        end
    endfunction

    // Reset bank busy times
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<`TOTAL_BANKS; i=i+1) bank_busy_until[i] <= 0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= `SCHED_IDLE;
            delay_cnt <= 0;
            sbr_iter <= 0;
            processed_count <= 0;
            processing_critical <= 0;
            
            done <= 0;
            busy <= 0;
            sched_wr_en <= 0;
            bst_upd_activate <= 0;
            bst_upd_precharge <= 0;
            
            global_cmd_ptr <= 0; 
            last_act_time <= 0;
            last_rd_time <= 0;
            
            // Output Init
            curr_bg <= 0; curr_bank <= 0; curr_target_row <= 0;
            curr_srr_ptr <= 0; curr_req_ptr <= 0;
            sbr_rd_addr <= 0; srr_rd_addr <= 0; req_rd_addr <= 0;
            bst_query_bank_group <= 0; bst_query_bank <= 0;
            bst_upd_bank_group <= 0; bst_upd_bank <= 0; bst_upd_row <= 0;
            sched_wr_cycle <= 0; sched_wr_cmd_type <= 0;
            sched_wr_bank_group <= 0; sched_wr_bank <= 0;
            sched_wr_row <= 0; sched_wr_column <= 0;
            sched_wr_request_id <= 0;
            
        end else begin
            sched_wr_en <= 0;
            bst_upd_activate <= 0;
            bst_upd_precharge <= 0;

            case (state)
                `SCHED_IDLE: begin
                    done <= 0;
                    if (start) begin
                        busy <= 1;
                        state <= `SCHED_LOAD_SBR;
                        sbr_rd_addr <= critical_path_sbr;
                        processing_critical <= 1;
                        sbr_iter <= 0;
                        processed_count <= 0;
                        delay_cnt <= 0;
                        global_cmd_ptr <= 0;
                        last_act_time <= 0;
                        last_rd_time <= 0;
                    end
                end

                `SCHED_LOAD_SBR: begin
                    // Wait 2 cycles for Registered Memory Output to stabilize
                    if (delay_cnt < 2) begin
                        delay_cnt <= delay_cnt + 1;
                    end else begin
                        curr_bg <= sbr_rd_bank_group;
                        curr_bank <= sbr_rd_bank;
                        curr_srr_ptr <= sbr_rd_head_srr;
                        
                        bst_query_bank_group <= sbr_rd_bank_group;
                        bst_query_bank <= sbr_rd_bank;
                        
                        state <= `SCHED_LOAD_SRR;
                        delay_cnt <= 0;
                    end
                end

                `SCHED_LOAD_SRR: begin
                    srr_rd_addr <= curr_srr_ptr;
                    // Wait 2 cycles for Registered Memory Output
                    if (delay_cnt < 2) begin
                        delay_cnt <= delay_cnt + 1;
                    end else begin
                        curr_target_row <= srr_rd_hit_tag[`ROW_WIDTH-1:0]; 
                        curr_req_ptr <= srr_rd_head_req;
                        
                        state <= `SCHED_CHECK_STATE;
                        delay_cnt <= 0;
                    end
                end

                `SCHED_CHECK_STATE: begin
                    // BST logic assumed combinational or fast enough
                    if (bst_is_row_open) begin
                        if (bst_open_row == curr_target_row)
                            state <= `SCHED_REQ_LOOP_RD;
                        else
                            state <= `SCHED_EMIT_PRE;
                    end else begin
                        state <= `SCHED_EMIT_ACT;
                    end
                end

                `SCHED_EMIT_PRE: begin
                    reg [`CYCLE_WIDTH-1:0] sched_time;
                    sched_time = max(global_cmd_ptr, bank_busy_until[curr_bank_idx]);
                    
                    sched_wr_en <= 1;
                    sched_wr_cycle <= sched_time;
                    sched_wr_cmd_type <= `CMD_PRE;
                    sched_wr_bank_group <= curr_bg;
                    sched_wr_bank <= curr_bank;
                    sched_wr_request_id <= 0; 

                    bst_upd_precharge <= 1;
                    bst_upd_bank_group <= curr_bg;
                    bst_upd_bank <= curr_bank;
                    
                    global_cmd_ptr <= sched_time + 1;
                    bank_busy_until[curr_bank_idx] <= sched_time + `T_RP;
                    state <= `SCHED_EMIT_ACT;
                end

                `SCHED_EMIT_ACT: begin
                    reg [`CYCLE_WIDTH-1:0] sched_time;
                    sched_time = max(global_cmd_ptr, bank_busy_until[curr_bank_idx]);
                    if (last_act_time > 0 || global_cmd_ptr > 0)
                        sched_time = max(sched_time, last_act_time + `T_RRD_S);

                    sched_wr_en <= 1;
                    sched_wr_cycle <= sched_time;
                    sched_wr_cmd_type <= `CMD_ACT;
                    sched_wr_bank_group <= curr_bg;
                    sched_wr_bank <= curr_bank;
                    sched_wr_row <= curr_target_row;
                    sched_wr_request_id <= 0;

                    bst_upd_activate <= 1;
                    bst_upd_bank_group <= curr_bg;
                    bst_upd_bank <= curr_bank;
                    bst_upd_row <= curr_target_row;

                    global_cmd_ptr <= sched_time + 1;
                    bank_busy_until[curr_bank_idx] <= sched_time + `T_RCD;
                    last_act_time <= sched_time;
                    state <= `SCHED_REQ_LOOP_RD;
                end

                `SCHED_REQ_LOOP_RD: begin
                    req_rd_addr <= curr_req_ptr;
                    // Reset delay for next state
                    delay_cnt <= 0; 
                    state <= `SCHED_WAIT_REQ_DATA;
                end

                `SCHED_WAIT_REQ_DATA: begin
                    // Wait 2 cycles for Registered Memory Output
                    if (delay_cnt < 2) begin
                        delay_cnt <= delay_cnt + 1;
                    end else begin
                        state <= `SCHED_EMIT_RD;
                    end
                end

                `SCHED_EMIT_RD: begin
                    reg [`CYCLE_WIDTH-1:0] sched_time;
                    sched_time = max(global_cmd_ptr, bank_busy_until[curr_bank_idx]);
                    if (last_rd_time > 0 || global_cmd_ptr > 0)
                        sched_time = max(sched_time, last_rd_time + `T_CCD_S);
                    
                    sched_wr_en <= 1;
                    sched_wr_cycle <= sched_time;
                    sched_wr_cmd_type <= `CMD_RD;
                    sched_wr_bank_group <= curr_bg;
                    sched_wr_bank <= curr_bank;
                    sched_wr_column <= 0; 
                    sched_wr_request_id <= curr_req_ptr;

                    global_cmd_ptr <= sched_time + 1;
                    last_rd_time <= sched_time;
                    bank_busy_until[curr_bank_idx] <= sched_time + `T_RTP; 

                    if (req_rd_chain_valid) begin
                        curr_req_ptr <= req_rd_chain_next;
                        state <= `SCHED_REQ_LOOP_RD;
                    end else begin
                        state <= `SCHED_NEXT_SRR;
                    end
                end

                `SCHED_NEXT_SRR: begin
                    if (srr_rd_chain_valid) begin
                        curr_srr_ptr <= srr_rd_chain_next;
                        state <= `SCHED_LOAD_SRR;
                        delay_cnt <= 0; // Reset for load state
                    end else begin
                        state <= `SCHED_NEXT_SBR;
                    end
                end

                `SCHED_NEXT_SBR: begin
                    processed_count <= processed_count + 1;
                    delay_cnt <= 0; // Reset for load state
                    
                    if (processed_count + 1 >= num_sbr_entries) begin
                        state <= `SCHED_DONE;
                    end 
                    else if (processing_critical) begin
                        processing_critical <= 0;
                        sbr_iter <= 0;
                        if (critical_path_sbr == 0) begin
                            sbr_rd_addr <= 1;
                            sbr_iter <= 1;
                        end else begin
                            sbr_rd_addr <= 0;
                            sbr_iter <= 0;
                        end
                        state <= `SCHED_LOAD_SBR;
                    end 
                    else begin
                        reg [`SBR_ID_WIDTH-1:0] next_iter;
                        next_iter = sbr_iter + 1;
                        if (next_iter == critical_path_sbr) begin
                            next_iter = next_iter + 1; 
                        end
                        sbr_rd_addr <= next_iter;
                        sbr_iter <= next_iter;
                        state <= `SCHED_LOAD_SBR;
                    end
                end
                
                `SCHED_DONE: begin
                    done <= 1;
                    busy <= 0;
                    state <= `SCHED_IDLE;
                end
            endcase
        end
    end

endmodule