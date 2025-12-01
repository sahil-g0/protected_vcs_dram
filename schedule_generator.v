// =============================================================================
// Schedule Generator Module
// =============================================================================
// Implements Phases 2 & 3 of the scheduling algorithm.
// Fixed: Context Save logic in EMIT_RD to properly update ctx_srr_ptr when
//        marking an SRR as done. This fixes linked-list traversal in Test 6.
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

    // Interface: Request Buffer (Read Only)
    output reg  [`REQUEST_ID_WIDTH-1:0]  req_rd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]  req_rd_chain_next,
    input  wire                          req_rd_chain_valid,
    input  wire [`COLUMN_WIDTH-1:0]      req_rd_column,

    // Interface: Bank State Tracker
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

    // Interface: Schedule Memory
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
    // States
    // =============================================================================
    localparam IDLE             = 4'd0;
    localparam SELECT_NEXT_SBR  = 4'd1;
    localparam WAIT_SBR_DATA    = 4'd2;
    localparam CHECK_SBR_BG     = 4'd3;
    localparam LOAD_SBR         = 4'd4;
    localparam RESOLVE_NEXT_SRR = 4'd5; 
    localparam LOAD_SRR         = 4'd6;
    localparam CHECK_STATE      = 4'd7;
    localparam EMIT_PRE         = 4'd8;
    localparam EMIT_ACT         = 4'd9;
    localparam REQ_LOOP_RD      = 4'd10;
    localparam WAIT_REQ_DATA    = 4'd11;
    localparam EMIT_RD          = 4'd12;
    localparam DONE             = 4'd13;

    reg [3:0] state;
    reg [2:0] delay_cnt;

    reg [`SBR_ID_WIDTH-1:0]     sbr_scan_idx;
    reg [`SBR_ID_WIDTH-1:0]     curr_sbr_idx;
    reg [`SBR_ID_WIDTH-1:0]     backup_sbr_idx;
    reg                         backup_valid;
    
    reg [`SRR_ID_WIDTH-1:0]     ctx_srr_ptr     [0:15];
    reg [`REQUEST_ID_WIDTH-1:0] ctx_req_ptr     [0:15];
    reg                         ctx_valid       [0:15]; 
    reg                         ctx_srr_done    [0:15]; 
    reg                         sbr_finished    [0:15]; 
    
    reg [`SRR_ID_WIDTH-1:0]     curr_srr_ptr;
    reg [`REQUEST_ID_WIDTH-1:0] curr_req_ptr;
    reg [`SBR_ID_WIDTH-1:0]     finished_sbr_count;
    reg [`BANK_GROUP_WIDTH-1:0] curr_bg;
    reg [`BANK_WIDTH-1:0]       curr_bank;
    reg [`ROW_WIDTH-1:0]        curr_target_row;
    reg [`BANK_GROUP_WIDTH-1:0] last_op_bg;
    
    reg [`CYCLE_WIDTH-1:0] last_act_time;
    reg [`CYCLE_WIDTH-1:0] last_rd_time; 
    reg [`BANK_GROUP_WIDTH-1:0] last_rd_bg; 
    reg [`CYCLE_WIDTH-1:0] bank_cmd_ready [0:`TOTAL_BANKS-1];
    reg [`CYCLE_WIDTH-1:0] bank_pre_min   [0:`TOTAL_BANKS-1];
    reg cmd_board [0:`MAX_SCHEDULE_CYCLES-1];
    reg [`CYCLE_WIDTH-1:0] candidate_time;
    reg [`CYCLE_WIDTH-1:0] final_time;
    
    wire [$clog2(`TOTAL_BANKS)-1:0] curr_bank_idx = {curr_bg, curr_bank};

    function [`CYCLE_WIDTH-1:0] max;
        input [`CYCLE_WIDTH-1:0] a, b;
        begin max = (a > b) ? a : b; end
    endfunction

    integer i, k;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<`TOTAL_BANKS; i=i+1) begin bank_cmd_ready[i] <= 0; bank_pre_min[i] <= 0; end
            for (k=0; k<`MAX_SCHEDULE_CYCLES; k=k+1) cmd_board[k] <= 0;
            for (i=0; i<16; i=i+1) begin ctx_valid[i] <= 0; sbr_finished[i] <= 0; ctx_srr_done[i] <= 0; end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; delay_cnt <= 0; sbr_scan_idx <= 0; curr_sbr_idx <= 0; finished_sbr_count <= 0;
            done <= 0; busy <= 0; sched_wr_en <= 0; bst_upd_activate <= 0; bst_upd_precharge <= 0;
            last_act_time <= 0; last_rd_time <= 0; last_rd_bg <= 0; last_op_bg <= 0;
            curr_bg <= 0; curr_bank <= 0; curr_target_row <= 0; curr_srr_ptr <= 0; curr_req_ptr <= 0;
            sbr_rd_addr <= 0; srr_rd_addr <= 0; req_rd_addr <= 0;
            bst_query_bank_group <= 0; bst_query_bank <= 0; bst_upd_bank_group <= 0; bst_upd_bank <= 0; bst_upd_row <= 0;
            sched_wr_cycle <= 0; sched_wr_cmd_type <= 0; sched_wr_bank_group <= 0; sched_wr_bank <= 0; sched_wr_row <= 0; sched_wr_column <= 0; sched_wr_request_id <= 0;
        end else begin
            sched_wr_en <= 0; bst_upd_activate <= 0; bst_upd_precharge <= 0;

            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        busy <= 1; finished_sbr_count <= 0; curr_sbr_idx <= critical_path_sbr;
                        last_act_time <= 0; last_rd_time <= 0; last_rd_bg <= 0; last_op_bg <= ~0; 
                        for (k=0; k<`MAX_SCHEDULE_CYCLES; k=k+1) cmd_board[k] <= 0;
                        for (i=0; i<16; i=i+1) begin ctx_valid[i] <= 0; sbr_finished[i] <= 0; ctx_srr_done[i] <= 0; end
                        state <= LOAD_SBR;
                        $display("[GEN] Started. Critical SBR: %0d", critical_path_sbr);
                    end
                end

                SELECT_NEXT_SBR: begin
                    if (finished_sbr_count >= num_sbr_entries) state <= DONE;
                    else begin sbr_scan_idx <= 0; backup_valid <= 0; state <= WAIT_SBR_DATA; end
                end
                
                WAIT_SBR_DATA: begin
                    if (sbr_scan_idx >= num_sbr_entries) begin
                        if (backup_valid) begin curr_sbr_idx <= backup_sbr_idx; state <= LOAD_SBR; end
                        else state <= DONE;
                    end else if (sbr_finished[sbr_scan_idx]) sbr_scan_idx <= sbr_scan_idx + 1;
                    else begin sbr_rd_addr <= sbr_scan_idx; delay_cnt <= 0; state <= CHECK_SBR_BG; end
                end
                
                CHECK_SBR_BG: begin
                    if (delay_cnt < 2) delay_cnt <= delay_cnt + 1;
                    else begin
                        if (sbr_rd_bank_group != last_op_bg) begin
                            curr_sbr_idx <= sbr_scan_idx;
                            curr_bg <= sbr_rd_bank_group; curr_bank <= sbr_rd_bank;
                            bst_query_bank_group <= sbr_rd_bank_group; bst_query_bank <= sbr_rd_bank;
                            if (ctx_valid[sbr_scan_idx]) begin
                                curr_srr_ptr <= ctx_srr_ptr[sbr_scan_idx]; curr_req_ptr <= ctx_req_ptr[sbr_scan_idx];
                                if (ctx_srr_done[sbr_scan_idx]) state <= RESOLVE_NEXT_SRR;
                                else state <= LOAD_SRR;
                            end else begin curr_srr_ptr <= sbr_rd_head_srr; state <= LOAD_SRR; end
                            delay_cnt <= 0;
                        end else begin
                            if (!backup_valid) begin backup_sbr_idx <= sbr_scan_idx; backup_valid <= 1; end
                            sbr_scan_idx <= sbr_scan_idx + 1; state <= WAIT_SBR_DATA;
                        end
                    end
                end

                LOAD_SBR: begin
                    sbr_rd_addr <= curr_sbr_idx;
                    if (delay_cnt < 2) delay_cnt <= delay_cnt + 1;
                    else begin
                        curr_bg <= sbr_rd_bank_group; curr_bank <= sbr_rd_bank;
                        bst_query_bank_group <= sbr_rd_bank_group; bst_query_bank <= sbr_rd_bank;
                        if (ctx_valid[curr_sbr_idx]) begin
                            curr_srr_ptr <= ctx_srr_ptr[curr_sbr_idx]; curr_req_ptr <= ctx_req_ptr[curr_sbr_idx];
                            if (ctx_srr_done[curr_sbr_idx]) state <= RESOLVE_NEXT_SRR;
                            else state <= LOAD_SRR;
                        end else begin curr_srr_ptr <= sbr_rd_head_srr; state <= LOAD_SRR; end
                        delay_cnt <= 0;
                    end
                end

                RESOLVE_NEXT_SRR: begin
                    srr_rd_addr <= curr_srr_ptr;
                    if (delay_cnt < 2) delay_cnt <= delay_cnt + 1;
                    else begin
                        if (srr_rd_chain_valid) begin
                            curr_srr_ptr <= srr_rd_chain_next;
                            ctx_srr_ptr[curr_sbr_idx] <= srr_rd_chain_next;
                            ctx_srr_done[curr_sbr_idx] <= 0; ctx_valid[curr_sbr_idx] <= 0; 
                            state <= LOAD_SRR; delay_cnt <= 0;
                        end else begin
                            sbr_finished[curr_sbr_idx] <= 1;
                            finished_sbr_count <= finished_sbr_count + 1;
                            state <= SELECT_NEXT_SBR;
                        end
                    end
                end

                LOAD_SRR: begin
                    srr_rd_addr <= curr_srr_ptr;
                    if (delay_cnt < 2) delay_cnt <= delay_cnt + 1;
                    else begin
                        curr_target_row <= srr_rd_hit_tag[`ROW_WIDTH-1:0]; 
                        if (!ctx_valid[curr_sbr_idx]) begin
                            curr_req_ptr <= srr_rd_head_req; ctx_valid[curr_sbr_idx] <= 1; 
                        end
                        state <= CHECK_STATE; delay_cnt <= 0;
                    end
                end

                CHECK_STATE: begin
                    if (bst_is_row_open) begin
                        if (bst_open_row == curr_target_row) state <= REQ_LOOP_RD;
                        else state <= EMIT_PRE;
                    end else state <= EMIT_ACT;
                end

                EMIT_PRE: begin
                    candidate_time = max(bank_cmd_ready[curr_bank_idx], bank_pre_min[curr_bank_idx]);
                    final_time = candidate_time;
                    while (cmd_board[final_time] == 1'b1) final_time = final_time + 1;
                    
                    sched_wr_en <= 1; sched_wr_cycle <= final_time; sched_wr_cmd_type <= `CMD_PRE;
                    sched_wr_bank_group <= curr_bg; sched_wr_bank <= curr_bank; sched_wr_request_id <= 0; 

                    bst_upd_precharge <= 1; bst_upd_bank_group <= curr_bg; bst_upd_bank <= curr_bank;
                    cmd_board[final_time] <= 1'b1; bank_cmd_ready[curr_bank_idx] <= final_time + `T_RP; 
                    state <= EMIT_ACT;
                    $display("[GEN] Emit PRE at %0d", final_time);
                end

                EMIT_ACT: begin
                    candidate_time = bank_cmd_ready[curr_bank_idx];
                    if (last_act_time > 0 || cmd_board[0]) candidate_time = max(candidate_time, last_act_time + `T_RRD_S);
                    final_time = candidate_time;
                    while (cmd_board[final_time] == 1'b1) final_time = final_time + 1;

                    sched_wr_en <= 1; sched_wr_cycle <= final_time; sched_wr_cmd_type <= `CMD_ACT;
                    sched_wr_bank_group <= curr_bg; sched_wr_bank <= curr_bank; sched_wr_row <= curr_target_row;
                    sched_wr_request_id <= 0;

                    bst_upd_activate <= 1; bst_upd_bank_group <= curr_bg; bst_upd_bank <= curr_bank; bst_upd_row <= curr_target_row;
                    cmd_board[final_time] <= 1'b1; bank_cmd_ready[curr_bank_idx] <= final_time + `T_RCD;
                    if (final_time > last_act_time) last_act_time <= final_time;
                    
                    state <= REQ_LOOP_RD;
                    $display("[GEN] Emit ACT at %0d", final_time);
                end

                REQ_LOOP_RD: begin
                    req_rd_addr <= curr_req_ptr; delay_cnt <= 0; state <= WAIT_REQ_DATA;
                end

                WAIT_REQ_DATA: begin
                    if (delay_cnt < 2) delay_cnt <= delay_cnt + 1;
                    else state <= EMIT_RD;
                end

                EMIT_RD: begin
                    reg [`CYCLE_WIDTH-1:0] t_ccd;
                    if ((last_rd_time > 0 || cmd_board[0]) && (curr_bg == last_rd_bg)) t_ccd = `T_CCD_L;
                    else t_ccd = `T_CCD_S;

                    candidate_time = bank_cmd_ready[curr_bank_idx];
                    if (last_rd_time > 0 || cmd_board[0]) candidate_time = max(candidate_time, last_rd_time + t_ccd);
                    
                    final_time = candidate_time;
                    while (cmd_board[final_time] == 1'b1) final_time = final_time + 1;
                    
                    sched_wr_en <= 1; sched_wr_cycle <= final_time; sched_wr_cmd_type <= `CMD_RD;
                    sched_wr_bank_group <= curr_bg; sched_wr_bank <= curr_bank;
                    sched_wr_column <= req_rd_column; sched_wr_request_id <= curr_req_ptr;

                    cmd_board[final_time] <= 1'b1;
                    if (final_time > last_rd_time) begin last_rd_time <= final_time; last_rd_bg <= curr_bg; end
                    
                    bank_pre_min[curr_bank_idx] <= final_time + `T_RTP; 
                    $display("[GEN] Emit RD at %0d. Req=%0d. T_CCD=%0d", final_time, curr_req_ptr, t_ccd);

                    if (req_rd_chain_valid) begin
                        ctx_req_ptr[curr_sbr_idx] <= req_rd_chain_next; ctx_srr_ptr[curr_sbr_idx] <= curr_srr_ptr;
                        ctx_srr_done[curr_sbr_idx] <= 0;
                    end else begin 
                        // FIX: Save current SRR so we can resolve chain next time
                        ctx_srr_ptr[curr_sbr_idx] <= curr_srr_ptr;
                        ctx_srr_done[curr_sbr_idx] <= 1; 
                    end
                    
                    last_op_bg <= curr_bg;
                    state <= SELECT_NEXT_SBR;
                end
                
                DONE: begin done <= 1; busy <= 0; state <= IDLE; $display("[GEN] Done."); end
            endcase
        end
    end

endmodule