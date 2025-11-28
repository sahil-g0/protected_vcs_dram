// =============================================================================
// DRAM Scheduler - Top Level Module
// =============================================================================
// Integrates all components: request buffer, batch scheduler, and tables.
// Implements the complete critical path scheduling algorithm.
// =============================================================================
`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module dram_scheduler_top (
    input  wire clk,
    input  wire rst_n,
    
    // Request input interface
    input  wire                          req_valid,
    input  wire [`BANK_GROUP_WIDTH-1:0]  req_bank_group,
    input  wire [`BANK_WIDTH-1:0]        req_bank,
    input  wire [`ROW_WIDTH-1:0]         req_row,
    input  wire [`COLUMN_WIDTH-1:0]      req_column,
    output wire                          req_ready,
    
    // Control interface
    input  wire                          schedule_start,  // Start scheduling current batch
    output wire                          schedule_done,   // Scheduling complete
    output wire                          schedule_busy,   // Scheduler is working
    
    // Schedule output interface (Read from Schedule Memory)
    input  wire                          sched_rd_en,
    input  wire [`CYCLE_WIDTH-1:0]       sched_rd_cycle,
    output wire [2:0]                    sched_cmd_type,
    output wire [`BANK_GROUP_WIDTH-1:0]  sched_bank_group,
    output wire [`BANK_WIDTH-1:0]        sched_bank,
    output wire [`ROW_WIDTH-1:0]         sched_row,
    output wire [`COLUMN_WIDTH-1:0]      sched_column,
    output wire [`REQUEST_ID_WIDTH-1:0]  sched_request_id,
    output wire [`CYCLE_WIDTH-1:0]       sched_max_cycle,
    
    // Status outputs
    output wire [`REQUEST_ID_WIDTH-1:0]  num_requests,
    output wire [`SRR_ID_WIDTH-1:0]      num_srr_entries,
    output wire [`SBR_ID_WIDTH-1:0]      num_sbr_entries,
    output wire [`SBR_ID_WIDTH-1:0]      critical_path_bank
);

    // =========================================================================
    // Internal Control Signals
    // =========================================================================
    wire batch_start = schedule_start;
    wire batch_done_sig;
    wire batch_busy_sig;
    
    wire gen_start;
    wire gen_done_sig;
    wire gen_busy_sig;
    
    // FSM to coordinate Phase 1 (Batch) and Phase 2 (Gen)
    reg [1:0] top_state;
    assign schedule_busy = (top_state != 0);
    assign schedule_done = (top_state == 3); // Done state
    
    assign gen_start = (top_state == 2 && !gen_busy_sig && !batch_busy_sig);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) top_state <= 0;
        else begin
            case(top_state)
                0: if (schedule_start) top_state <= 1; // Start Batch
                1: if (batch_done_sig) top_state <= 2; // Batch Done, Start Gen
                2: if (gen_done_sig)   top_state <= 3; // Gen Done
                3: top_state <= 0; // Handshake/Idle (Wait for external read)
            endcase
        end
    end
    
    // FIX: Separated Clears
    // scratchpad_clear: Resets intermediate tables/schedule memory when a NEW batch starts.
    wire scratchpad_clear = schedule_start; 
    
    // req_buf_clear: Should NOT trigger on schedule_start, or we wipe the input!
    // Tied to 0, relying on rst_n for initialization/reset between tests.
    wire req_buf_clear = 1'b0;

    // =========================================================================
    // Interconnect Signals
    // =========================================================================
    // Request Buffer
    wire [`REQUEST_ID_WIDTH-1:0]  req_buf_num_requests;
    wire [`REQUEST_ID_WIDTH-1:0]  req_buf_rd_addr;
    wire [`BANK_GROUP_WIDTH-1:0]  req_buf_rd_bank_group;
    wire [`BANK_WIDTH-1:0]        req_buf_rd_bank;
    wire [`ROW_WIDTH-1:0]         req_buf_rd_row;
    wire [`COLUMN_WIDTH-1:0]      req_buf_rd_column;
    wire [`HIT_TAG_WIDTH-1:0]     req_buf_rd_hit_tag;
    wire [`MISS_TAG_WIDTH-1:0]    req_buf_rd_miss_tag;
    wire [`REQUEST_ID_WIDTH-1:0]  req_buf_rd_chain_next;
    wire                          req_buf_rd_chain_valid;
    
    // MUX for Request Buffer Read Address (Batch Sched vs Generator)
    wire [`REQUEST_ID_WIDTH-1:0]  bs_req_rd_addr;
    wire [`REQUEST_ID_WIDTH-1:0]  gen_req_rd_addr;
    assign req_buf_rd_addr = (top_state == 1) ? bs_req_rd_addr : gen_req_rd_addr;

    // SRR Table
    wire [`SRR_ID_WIDTH-1:0]      srr_num_entries;
    wire [`SRR_ID_WIDTH-1:0]      srr_rd_addr;
    wire [`HIT_TAG_WIDTH-1:0]     srr_rd_hit_tag;
    wire [`REQUEST_ID_WIDTH-1:0]  srr_rd_count;
    wire [`REQUEST_ID_WIDTH-1:0]  srr_rd_head_req;
    wire [`REQUEST_ID_WIDTH-1:0]  srr_rd_tail_req;
    wire [`SRR_ID_WIDTH-1:0]      srr_rd_chain_next;
    wire                          srr_rd_chain_valid;
    
    // MUX for SRR Read Address
    wire [`SRR_ID_WIDTH-1:0]      bs_srr_rd_addr;
    wire [`SRR_ID_WIDTH-1:0]      gen_srr_rd_addr;
    assign srr_rd_addr = (top_state == 1) ? bs_srr_rd_addr : gen_srr_rd_addr;

    // SBR Table
    wire [`SBR_ID_WIDTH-1:0]      sbr_num_entries;
    wire [`SBR_ID_WIDTH-1:0]      sbr_rd_addr;
    wire [`BANK_GROUP_WIDTH-1:0]  sbr_rd_bank_group;
    wire [`BANK_WIDTH-1:0]        sbr_rd_bank;
    wire [`SRR_ID_WIDTH-1:0]      sbr_rd_head_srr;
    wire [`SBR_ID_WIDTH-1:0]      sbr_rd_tail_srr;
    wire [`SBR_ID_WIDTH-1:0]      critical_path_sbr;
    wire [`MISS_TAG_WIDTH-1:0]    sbr_rd_miss_tag; 
    
    // MUX for SBR Read Address
    wire [`SBR_ID_WIDTH-1:0]      bs_sbr_rd_addr;
    wire [`SBR_ID_WIDTH-1:0]      gen_sbr_rd_addr;
    assign sbr_rd_addr = (top_state == 1) ? bs_sbr_rd_addr : gen_sbr_rd_addr;

    // Bank State Tracker
    wire [`BANK_GROUP_WIDTH-1:0]  bst_query_bank_group;
    wire [`BANK_WIDTH-1:0]        bst_query_bank;
    wire                          bst_is_precharged;
    wire                          bst_is_row_open;
    wire [`ROW_WIDTH-1:0]         bst_open_row;
    wire                          bst_upd_activate;
    wire                          bst_upd_precharge;
    wire [`BANK_GROUP_WIDTH-1:0]  bst_upd_bank_group;
    wire [`BANK_WIDTH-1:0]        bst_upd_bank;
    wire [`ROW_WIDTH-1:0]         bst_upd_row;

    // Schedule Memory Write Interface
    wire                          sched_wr_en;
    wire [`CYCLE_WIDTH-1:0]       sched_wr_cycle;
    wire [2:0]                    sched_wr_cmd_type;
    wire [`BANK_GROUP_WIDTH-1:0]  sched_wr_bank_group;
    wire [`BANK_WIDTH-1:0]        sched_wr_bank;
    wire [`ROW_WIDTH-1:0]         sched_wr_row;
    wire [`COLUMN_WIDTH-1:0]      sched_wr_column;
    wire [`REQUEST_ID_WIDTH-1:0]  sched_wr_request_id;

    // Status Assignments
    assign num_requests = req_buf_num_requests;
    assign num_srr_entries = srr_num_entries;
    assign num_sbr_entries = sbr_num_entries;
    assign critical_path_bank = critical_path_sbr;

    // =========================================================================
    // Module Instantiations
    // =========================================================================
    
    // 1. Request Buffer
    // -------------------------------------------------------------------------
    wire        bs_req_chain_wr_en;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_req_chain_wr_addr;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_req_chain_wr_data;
    
    wire        bs_req_cam_en = 1'b0;
    wire [`HIT_TAG_WIDTH-1:0] bs_req_cam_tag = 0;
    wire        bs_req_cam_hit;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_req_cam_addr;

    request_buffer #(
        .MAX_REQUESTS(`MAX_REQUESTS)
    ) u_request_buffer (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_bank_group(req_bank_group), .req_bank(req_bank),
        .req_row(req_row), .req_column(req_column), .req_ready(req_ready),
        .batch_start(batch_start), .batch_clear(req_buf_clear), // FIX: Connected to req_buf_clear
        .num_requests(req_buf_num_requests),
        .rd_addr(req_buf_rd_addr),
        .rd_bank_group(req_buf_rd_bank_group), .rd_bank(req_buf_rd_bank),
        .rd_row(req_buf_rd_row), .rd_column(req_buf_rd_column),
        .rd_hit_tag(req_buf_rd_hit_tag), .rd_miss_tag(req_buf_rd_miss_tag),
        .rd_chain_next(req_buf_rd_chain_next), .rd_chain_valid(req_buf_rd_chain_valid),
        .chain_wr_en(bs_req_chain_wr_en), .chain_wr_addr(bs_req_chain_wr_addr), .chain_wr_data(bs_req_chain_wr_data),
        .cam_lookup_en(bs_req_cam_en), .cam_lookup_tag(bs_req_cam_tag),
        .cam_hit(bs_req_cam_hit), .cam_hit_addr(bs_req_cam_hit_addr)
    );
    
    // 2. SRR Table
    // -------------------------------------------------------------------------
    wire        bs_srr_wr_en;
    wire [`HIT_TAG_WIDTH-1:0] bs_srr_wr_tag;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_srr_wr_head;
    wire        bs_srr_full;
    wire [`SRR_ID_WIDTH-1:0]  bs_srr_wr_addr;
    wire        bs_srr_upd_en;
    wire [`SRR_ID_WIDTH-1:0]  bs_srr_upd_addr;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_srr_upd_count;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_srr_upd_tail;
    wire        bs_srr_chain_wr_en;
    wire [`SRR_ID_WIDTH-1:0]  bs_srr_chain_wr_addr;
    wire [`SRR_ID_WIDTH-1:0]  bs_srr_chain_wr_data;
    wire        bs_srr_cam_en;
    wire [`HIT_TAG_WIDTH-1:0] bs_srr_cam_tag;
    wire        bs_srr_cam_hit;
    wire [`SRR_ID_WIDTH-1:0]  bs_srr_cam_addr;

    srr_table #(
        .MAX_ENTRIES(`MAX_SRR_ENTRIES)
    ) u_srr_table (
        .clk(clk), .rst_n(rst_n), .clear(scratchpad_clear), // FIX: Use scratchpad_clear
        .num_entries(srr_num_entries),
        .wr_en(bs_srr_wr_en), .wr_hit_tag(bs_srr_wr_tag), .wr_head_req(bs_srr_wr_head),
        .wr_full(bs_srr_full), .wr_addr(bs_srr_wr_addr),
        .upd_en(bs_srr_upd_en), .upd_addr(bs_srr_upd_addr), .upd_count(bs_srr_upd_count), .upd_tail_req(bs_srr_upd_tail),
        .chain_wr_en(bs_srr_chain_wr_en), .chain_wr_addr(bs_srr_chain_wr_addr), .chain_wr_data(bs_srr_chain_wr_data),
        .rd_addr(srr_rd_addr),
        .rd_hit_tag(srr_rd_hit_tag), .rd_count(srr_rd_count), .rd_head_req(srr_rd_head_req), .rd_tail_req(srr_rd_tail_req),
        .rd_chain_next(srr_rd_chain_next), .rd_chain_valid(srr_rd_chain_valid),
        .cam_lookup_en(bs_srr_cam_en), .cam_lookup_tag(bs_srr_cam_tag),
        .cam_hit(bs_srr_cam_hit), .cam_hit_addr(bs_srr_cam_addr)
    );
    
    // 3. SBR Table
    // -------------------------------------------------------------------------
    wire        bs_sbr_wr_en;
    wire [`MISS_TAG_WIDTH-1:0]  bs_sbr_wr_tag;
    wire [`BANK_GROUP_WIDTH-1:0]  bs_sbr_wr_bg;
    wire [`BANK_WIDTH-1:0]  bs_sbr_wr_b;
    wire [`SRR_ID_WIDTH-1:0]  bs_sbr_wr_head;
    wire        bs_sbr_full;
    wire [`SBR_ID_WIDTH-1:0]  bs_sbr_wr_addr;
    wire        bs_sbr_upd_en;
    wire [`SBR_ID_WIDTH-1:0]  bs_sbr_upd_addr;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_sbr_upd_reqs;
    wire [`SRR_ID_WIDTH-1:0]  bs_sbr_upd_rows;
    wire [`SRR_ID_WIDTH-1:0]  bs_sbr_upd_tail;
    wire        bs_sbr_cam_en;
    wire [`MISS_TAG_WIDTH-1:0]  bs_sbr_cam_tag;
    wire        bs_sbr_cam_hit;
    wire [`SBR_ID_WIDTH-1:0]  bs_sbr_cam_addr;
    wire        bs_sbr_find_max;
    wire [`SBR_ID_WIDTH-1:0]  bs_sbr_max_addr;
    wire [`REQUEST_ID_WIDTH-1:0]  bs_sbr_max_reqs;
    wire [`REQUEST_ID_WIDTH-1:0]  sbr_rd_total_reqs; 
    wire [`SRR_ID_WIDTH-1:0]  sbr_rd_row_cnt;

    sbr_table #(
        .MAX_ENTRIES(`MAX_SBR_ENTRIES)
    ) u_sbr_table (
        .clk(clk), .rst_n(rst_n), .clear(scratchpad_clear), // FIX: Use scratchpad_clear
        .num_entries(sbr_num_entries),
        .wr_en(bs_sbr_wr_en), .wr_miss_tag(bs_sbr_wr_tag), .wr_bank_group(bs_sbr_wr_bg), .wr_bank(bs_sbr_wr_b), .wr_head_srr(bs_sbr_wr_head),
        .wr_full(bs_sbr_full), .wr_addr(bs_sbr_wr_addr),
        .upd_en(bs_sbr_upd_en), .upd_addr(bs_sbr_upd_addr), .upd_total_requests(bs_sbr_upd_reqs), .upd_row_count(bs_sbr_upd_rows), .upd_tail_srr(bs_sbr_upd_tail),
        .rd_addr(sbr_rd_addr),
        .rd_miss_tag(sbr_rd_miss_tag),
        .rd_bank_group(sbr_rd_bank_group), .rd_bank(sbr_rd_bank),
        .rd_total_requests(sbr_rd_total_reqs), .rd_row_count(sbr_rd_row_cnt), .rd_head_srr(sbr_rd_head_srr), .rd_tail_srr(sbr_rd_tail_srr),
        .cam_lookup_en(bs_sbr_cam_en), .cam_lookup_tag(bs_sbr_cam_tag),
        .cam_hit(bs_sbr_cam_hit), .cam_hit_addr(bs_sbr_cam_addr),
        .find_max_en(bs_sbr_find_max), .max_addr(bs_sbr_max_addr), .max_requests(bs_sbr_max_reqs)
    );
    
    // 4. Batch Scheduler
    batch_scheduler u_batch_scheduler (
        .clk(clk), .rst_n(rst_n),
        .start(batch_start), .done(batch_done_sig), .busy(batch_busy_sig),
        .num_requests(req_buf_num_requests),
        .req_rd_addr(bs_req_rd_addr), .req_rd_hit_tag(req_buf_rd_hit_tag), .req_rd_miss_tag(req_buf_rd_miss_tag),
        .req_rd_bank_group(req_buf_rd_bank_group), .req_rd_bank(req_buf_rd_bank), .req_rd_row(req_buf_rd_row),
        .req_chain_wr_en(bs_req_chain_wr_en), .req_chain_wr_addr(bs_req_chain_wr_addr), .req_chain_wr_data(bs_req_chain_wr_data),
        .srr_wr_en(bs_srr_wr_en), .srr_wr_hit_tag(bs_srr_wr_tag), .srr_wr_head_req(bs_srr_wr_head), .srr_wr_addr(bs_srr_wr_addr), .srr_wr_full(bs_srr_wr_full),
        .srr_upd_en(bs_srr_upd_en), .srr_upd_addr(bs_srr_upd_addr), .srr_upd_count(bs_srr_upd_count), .srr_upd_tail_req(bs_srr_upd_tail),
        .srr_cam_lookup_en(bs_srr_cam_en), .srr_cam_lookup_tag(bs_srr_cam_tag), .srr_cam_hit(bs_srr_cam_hit), .srr_cam_hit_addr(bs_srr_cam_addr),
        .srr_rd_addr(bs_srr_rd_addr), .srr_rd_count(srr_rd_count), .srr_rd_head_req(srr_rd_head_req), .srr_rd_tail_req(srr_rd_tail_req), .srr_rd_miss_tag(req_buf_rd_miss_tag),
        .srr_chain_wr_en(bs_srr_chain_wr_en), .srr_chain_wr_addr(bs_srr_chain_wr_addr), .srr_chain_wr_data(bs_srr_chain_wr_data), .srr_num_entries(srr_num_entries),
        .sbr_wr_en(bs_sbr_wr_en), .sbr_wr_miss_tag(bs_sbr_wr_tag), .sbr_wr_bank_group(bs_sbr_wr_bg), .sbr_wr_bank(bs_sbr_wr_b), .sbr_wr_head_srr(bs_sbr_wr_head), .sbr_wr_addr(bs_sbr_wr_addr), .sbr_wr_full(bs_sbr_full),
        .sbr_upd_en(bs_sbr_upd_en), .sbr_upd_addr(bs_sbr_upd_addr), .sbr_upd_total_requests(bs_sbr_upd_reqs), .sbr_upd_row_count(bs_sbr_upd_rows), .sbr_upd_tail_srr(bs_sbr_upd_tail),
        .sbr_cam_lookup_en(bs_sbr_cam_en), .sbr_cam_lookup_tag(bs_sbr_cam_tag), .sbr_cam_hit(bs_sbr_cam_hit), .sbr_cam_hit_addr(bs_sbr_cam_addr),
        .sbr_rd_addr(bs_sbr_rd_addr), .sbr_rd_total_requests(sbr_rd_total_reqs), .sbr_rd_row_count(sbr_rd_row_cnt), .sbr_rd_tail_srr(sbr_rd_tail_srr),
        .sbr_find_max_en(bs_sbr_find_max), .sbr_max_addr(bs_sbr_max_addr), .sbr_max_requests(bs_sbr_max_reqs),
        .critical_path_sbr(critical_path_sbr)
    );

    // 5. Bank State Tracker
    bank_state_tracker u_bank_state_tracker (
        .clk(clk), .rst_n(rst_n), .clear(scratchpad_clear), // FIX: Use scratchpad_clear
        .query_bank_group(bst_query_bank_group), .query_bank(bst_query_bank),
        .is_precharged(bst_is_precharged), .is_row_open(bst_is_row_open), .open_row(bst_open_row),
        .upd_activate(bst_upd_activate), .upd_precharge(bst_upd_precharge),
        .upd_bank_group(bst_upd_bank_group), .upd_bank(bst_upd_bank), .upd_row(bst_upd_row)
    );

    // 6. Schedule Generator
    schedule_generator u_schedule_generator (
        .clk(clk), .rst_n(rst_n),
        .start(gen_start), .done(gen_done_sig), .busy(gen_busy_sig),
        .critical_path_sbr(critical_path_sbr), .num_sbr_entries(sbr_num_entries),
        .sbr_rd_addr(gen_sbr_rd_addr), .sbr_rd_bank_group(sbr_rd_bank_group), .sbr_rd_bank(sbr_rd_bank), .sbr_rd_head_srr(sbr_rd_head_srr),
        .srr_rd_addr(gen_srr_rd_addr), .srr_rd_hit_tag(srr_rd_hit_tag), .srr_rd_head_req(srr_rd_head_req), .srr_rd_chain_next(srr_rd_chain_next), .srr_rd_chain_valid(srr_rd_chain_valid),
        .req_rd_addr(gen_req_rd_addr), .req_rd_chain_next(req_buf_rd_chain_next), .req_rd_chain_valid(req_buf_rd_chain_valid),
        .bst_query_bank_group(bst_query_bank_group), .bst_query_bank(bst_query_bank),
        .bst_is_precharged(bst_is_precharged), .bst_is_row_open(bst_is_row_open), .bst_open_row(bst_open_row),
        .bst_upd_activate(bst_upd_activate), .bst_upd_precharge(bst_upd_precharge), .bst_upd_bank_group(bst_upd_bank_group), .bst_upd_bank(bst_upd_bank), .bst_upd_row(bst_upd_row),
        .sched_wr_en(sched_wr_en), .sched_wr_cycle(sched_wr_cycle), .sched_wr_cmd_type(sched_wr_cmd_type), .sched_wr_bank_group(sched_wr_bank_group), .sched_wr_bank(sched_wr_bank),
        .sched_wr_row(sched_wr_row), .sched_wr_column(sched_wr_column), .sched_wr_request_id(sched_wr_request_id)
    );

    // 7. Schedule Memory
    schedule_memory #(
        .MAX_CYCLES(`MAX_SCHEDULE_CYCLES)
    ) u_schedule_memory (
        .clk(clk), .rst_n(rst_n), .clear(scratchpad_clear), // FIX: Use scratchpad_clear
        .wr_en(sched_wr_en), .wr_cycle(sched_wr_cycle),
        .wr_cmd_type(sched_wr_cmd_type), .wr_bank_group(sched_wr_bank_group), .wr_bank(sched_wr_bank),
        .wr_row(sched_wr_row), .wr_column(sched_wr_column), .wr_request_id(sched_wr_request_id),
        .rd_cycle(sched_rd_cycle), .rd_cmd_type(sched_cmd_type),
        .rd_bank_group(sched_bank_group), .rd_bank(sched_bank), .rd_row(sched_row), .rd_column(sched_column), .rd_request_id(sched_request_id),
        .max_cycle(sched_max_cycle)
    );

endmodule