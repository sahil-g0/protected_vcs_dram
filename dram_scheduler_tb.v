// =============================================================================
// DRAM Scheduler Testbench
// =============================================================================
// Tests the full flow with extensive debugging enabled.
// =============================================================================

`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module dram_scheduler_tb;

    reg clk;
    reg rst_n;
    
    // Clock Gen
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 10ns period (100 MHz)
    end
    
    // DUT Signals
    reg                             req_valid;
    reg [`BANK_GROUP_WIDTH-1:0]     req_bank_group;
    reg [`BANK_WIDTH-1:0]           req_bank;
    reg [`ROW_WIDTH-1:0]            req_row;
    reg [`COLUMN_WIDTH-1:0]         req_column;
    wire                            req_ready;
    
    reg                             schedule_start;
    wire                            schedule_done;
    wire                            schedule_busy;
    
    reg                             sched_rd_en;
    reg [`CYCLE_WIDTH-1:0]          sched_rd_cycle;
    wire [2:0]                      sched_cmd_type;
    wire [`BANK_GROUP_WIDTH-1:0]    sched_bank_group;
    wire [`BANK_WIDTH-1:0]          sched_bank;
    wire [`ROW_WIDTH-1:0]           sched_row;
    wire [`COLUMN_WIDTH-1:0]        sched_column;
    wire [`REQUEST_ID_WIDTH-1:0]    sched_request_id;
    wire [`CYCLE_WIDTH-1:0]         sched_max_cycle;
    
    wire [`REQUEST_ID_WIDTH-1:0]    num_requests;
    wire [`SRR_ID_WIDTH-1:0]        num_srr_entries;
    wire [`SBR_ID_WIDTH-1:0]        num_sbr_entries;
    wire [`SBR_ID_WIDTH-1:0]        critical_path_bank;
    
    // Counters for assertions
    integer total_reads_issued;
    integer total_acts_issued;
    
    // DUT Instantiation
    dram_scheduler_top u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_bank_group(req_bank_group),
        .req_bank(req_bank),
        .req_row(req_row),
        .req_column(req_column),
        .req_ready(req_ready),
        .schedule_start(schedule_start),
        .schedule_done(schedule_done),
        .schedule_busy(schedule_busy),
        .sched_rd_en(sched_rd_en),
        .sched_rd_cycle(sched_rd_cycle),
        .sched_cmd_type(sched_cmd_type),
        .sched_bank_group(sched_bank_group),
        .sched_bank(sched_bank),
        .sched_row(sched_row),
        .sched_column(sched_column),
        .sched_request_id(sched_request_id),
        .sched_max_cycle(sched_max_cycle),
        .num_requests(num_requests),
        .num_srr_entries(num_srr_entries),
        .num_sbr_entries(num_sbr_entries),
        .critical_path_bank(critical_path_bank)
    );
    
    // =============================================================================
    // Debug Monitor
    // =============================================================================
    
    reg [3:0] prev_gen_state;
    reg [2:0] prev_batch_state;
    
    always @(posedge clk) begin
        if (rst_n) begin
            // 1. Monitor Batch Scheduler FSM Transitions
            if (u_dut.u_batch_scheduler.state != prev_batch_state) begin
                $display("[DEBUG %0t] Batch FSM: %0d -> %0d", $time, prev_batch_state, u_dut.u_batch_scheduler.state);
                prev_batch_state <= u_dut.u_batch_scheduler.state;
            end
            
            // 2. Monitor Generator FSM Transitions
            if (u_dut.u_schedule_generator.state != prev_gen_state) begin
                $display("[DEBUG %0t] Gen FSM:   %0d -> %0d", $time, prev_gen_state, u_dut.u_schedule_generator.state);
                prev_gen_state <= u_dut.u_schedule_generator.state;
                
                // When entering LOAD_SRR, check the pointer
                if (u_dut.u_schedule_generator.state == `SCHED_LOAD_SRR) begin
                    $display("[DEBUG %0t] Gen Loading SRR Ptr: %0d", $time, u_dut.u_schedule_generator.curr_srr_ptr);
                end
                
                // When entering REQ_LOOP_RD, check the request pointer
                if (u_dut.u_schedule_generator.state == `SCHED_REQ_LOOP_RD) begin
                    $display("[DEBUG %0t] Gen Processing Req Ptr: %0d", $time, u_dut.u_schedule_generator.curr_req_ptr);
                    if ($isunknown(u_dut.u_schedule_generator.curr_req_ptr)) begin
                        $display("[ERROR %0t] Generator Current Request Pointer is X!", $time);
                    end
                end
            end
            
            // 3. Spy on Request Buffer Chaining
            if (u_dut.u_schedule_generator.state == `SCHED_EMIT_RD) begin
               $display("[DEBUG %0t] EMIT_RD: ReqID=%0d, NextValid=%b, NextReq=%0d", 
                        $time, 
                        u_dut.u_schedule_generator.curr_req_ptr,
                        u_dut.u_schedule_generator.req_rd_chain_valid,
                        u_dut.u_schedule_generator.req_rd_chain_next);
            end
        end else begin
            prev_gen_state <= 0;
            prev_batch_state <= 0;
        end
    end

    // =============================================================================
    // Helpers
    // =============================================================================
    task reset_dut;
    begin
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[TB] Reset Complete");
    end
    endtask

    task send_request;
        input [`BANK_GROUP_WIDTH-1:0] bg;
        input [`BANK_WIDTH-1:0]       bank;
        input [`ROW_WIDTH-1:0]        row;
        input [`COLUMN_WIDTH-1:0]     col;
    begin
        @(posedge clk);
        req_valid <= 1'b1;
        req_bank_group <= bg;
        req_bank <= bank;
        req_row <= row;
        req_column <= col;
        
        $display("[%0t] Sent Request: BG=%0d B=%0d Row=0x%h Col=0x%h", $time, bg, bank, row, col);
        
        @(posedge clk);
        while (!req_ready) @(posedge clk);
        req_valid <= 1'b0;
    end
    endtask
    
    task dump_stats;
    begin
        $display("\n--- BATCH STATS ---");
        $display("Total Requests:      %0d", num_requests);
        $display("Unique Rows (SRR):   %0d", num_srr_entries);
        $display("Unique Banks (SBR):  %0d", num_sbr_entries);
        $display("Critical Path Bank:  %0d", critical_path_bank);
        $display("-------------------");
    end
    endtask
    
    task dump_schedule;
        integer i;
        reg [31:0] max;
        reg [`ROW_WIDTH-1:0] open_rows [0:15];
        reg                  row_valid [0:15];
        integer bank_idx;
        
        begin
            @(posedge clk);
            max = sched_max_cycle;
            total_reads_issued = 0;
            
            for(i=0; i<16; i=i+1) row_valid[i] = 0;

            $display("\n--- FINAL SCHEDULE (Max Cycle: %0d) ---", max);
            for (i=0; i <= max + 10; i=i+1) begin
                sched_rd_cycle <= i;
                @(posedge clk); 
                @(negedge clk); 
                if (sched_cmd_type != 0) begin
                    $write("T=%04d: ", i);
                    bank_idx = {sched_bank_group, sched_bank};
                    
                    case(sched_cmd_type)
                        `CMD_ACT: begin
                            $write("ACT BG%0d B%0d Row 0x%h", sched_bank_group, sched_bank, sched_row);
                            if (row_valid[bank_idx]) 
                                $display(" [ERROR] ACT to open bank! (Expect PRE first)");
                            
                            open_rows[bank_idx] = sched_row;
                            row_valid[bank_idx] = 1;
                        end
                        
                        `CMD_PRE: begin
                            $write("PRE BG%0d B%0d", sched_bank_group, sched_bank);
                            row_valid[bank_idx] = 0;
                        end
                        
                        `CMD_RD: begin
                            $write("RD  BG%0d B%0d Col 0x%h (ReqID: %0d)", sched_bank_group, sched_bank, sched_column, sched_request_id);
                            total_reads_issued = total_reads_issued + 1;
                            
                            if ($isunknown(sched_request_id)) 
                                $display(" [ERROR] ReqID is X!");
                                
                            if (!row_valid[bank_idx])
                                $display(" [ERROR] Read to closed bank!");
                        end
                        
                        default:  $write("UNK");
                    endcase
                    $display("");
                end
            end
            $display("---------------------------------------");
            
            if (total_reads_issued != num_requests) begin
                $display("[FAILURE] Issued %0d reads, expected %0d!", total_reads_issued, num_requests);
            end else begin
                $display("[SUCCESS] Issued all %0d reads.", total_reads_issued);
            end
        end
    endtask
    
    // =============================================================================
    // Main Test Sequence
    // =============================================================================
    initial begin
        req_valid = 0; req_bank_group = 0; req_bank = 0; req_row = 0; req_column = 0;
        schedule_start = 0; sched_rd_en = 0; sched_rd_cycle = 0;
        
        reset_dut();
        
        // -------------------------------------------------------------------------
        // Test 1
        // -------------------------------------------------------------------------
        $display("\n=== TEST 1: Row Hits (Single Bank) ===");
        send_request(0, 0, 512, 0);
        send_request(0, 0, 512, 8);
        send_request(0, 0, 512, 16);
        
        repeat(5) @(posedge clk);
        $display("[%0t] Starting scheduler...", $time);
        schedule_start <= 1'b1;
        @(posedge clk);
        schedule_start <= 1'b0;
        
        fork : wait_or_timeout
            begin
                @(posedge schedule_done);
                $display("[%0t] Scheduling complete!", $time);
                disable wait_or_timeout;
            end
            begin
                repeat(10000) @(posedge clk); 
                $display("[ERROR] Timed out waiting for schedule_done!");
                $finish;
            end
        join
        
        dump_stats();
        dump_schedule();
        
        // -------------------------------------------------------------------------
        // Test 2
        // -------------------------------------------------------------------------
        reset_dut(); 
        $display("\n=== TEST 2: Row Conflict ===");
        send_request(0, 0, 10, 0); 
        send_request(0, 0, 11, 0); 
        
        repeat(5) @(posedge clk);
        schedule_start <= 1'b1;
        @(posedge clk);
        schedule_start <= 1'b0;
        @(posedge schedule_done);
        
        dump_stats();
        dump_schedule();
        
        // -------------------------------------------------------------------------
        // Test 3
        // -------------------------------------------------------------------------
        reset_dut();
        $display("\n=== TEST 3: Multi-Bank Interleaving ===");
        send_request(0, 0, 100, 0);
        send_request(0, 1, 200, 0);
        send_request(0, 0, 100, 8);
        send_request(1, 0, 300, 0);
        
        repeat(5) @(posedge clk);
        schedule_start <= 1'b1;
        @(posedge clk);
        schedule_start <= 1'b0;
        @(posedge schedule_done);
        
        dump_stats();
        dump_schedule();
        
        $finish;
    end

endmodule