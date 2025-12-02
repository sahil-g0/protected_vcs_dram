`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Performance Testbench: DRAM Controller with FIFO
//
// Purpose: Measure latency and throughput for various access patterns
//          Tests 5 scenarios with cycle-count performance metrics
//////////////////////////////////////////////////////////////////////////////////

`include "dram_timings.vh"
`include "timing_abstraction.vh"

module tb_performance();
    // Clock and reset
    reg clk;
    reg reset;
    
    // FIFO inputs (from testbench)
    reg [31:0] fifo_address_in;
    reg [31:0] fifo_write_data_in;
    reg fifo_r_w_in;
    reg fifo_push;
    
    // FIFO outputs (to controller)
    wire [31:0] address;
    wire [31:0] write_data;
    wire r_w;
    wire fifo_empty;
    wire fifo_full;
    wire fifo_almost_full;
    
    // Controller outputs
    wire pop;
    wire [2:0] command;
    
    // Performance tracking
    integer test_start_cycle;
    integer test_end_cycle;
    integer total_requests;
    integer completed_requests;
    
    // Instantiate FIFO
    instruction_fifo fifo (
        .CLK(clk),
        .RESET(reset),
        .PUSH(fifo_push),
        .ADDRESS(fifo_address_in),
        .WRITE_DATA(fifo_write_data_in),
        .R_W(fifo_r_w_in),
        .POP(pop),
        .ADDRESS_OUT(address),
        .WRITE_DATA_OUT(write_data),
        .R_W_OUT(r_w),
        .EMPTY(fifo_empty),
        .FULL(fifo_full),
        .ALMOST_FULL(fifo_almost_full)
    );
    
    // Instantiate controller (with FIFO)
    generate_instruction controller (
        .clk(clk),
        .reset(reset),
        .address(address),
        .r_w(r_w),
        .write_data(write_data),
        .fifo_empty(fifo_empty),
        .pop(pop),
        .command(command)
    );
    
    // Clock generation (100MHz = 10ns period)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 10ns period
    end
    
    // Helper function to create address
    function [31:0] make_addr(input [13:0] row, input [1:0] bg, input [1:0] bank, input [7:0] col);
        return {2'b0, row, bg, bank, col, 4'b0};
    endfunction
    
    // Command name for display
    function string cmd_name(input [2:0] cmd);
        case(cmd)
            CMD_NOP: return "NOP";
            CMD_PRE: return "PRE";
            CMD_ACT: return "ACT";
            CMD_RD:  return "READ";
            CMD_WR:  return "WRITE";
            default: return "UNKNOWN";
        endcase
    endfunction
    
    // Monitor controller commands and FIFO state
    integer cycle_count;
    integer relative_cycle;
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count = cycle_count + 1;
            relative_cycle = cycle_count - test_start_cycle;
            
            // DEBUG: Print FIFO state every cycle during test
            if (cycle_count >= test_start_cycle && cycle_count <= test_start_cycle + 80) begin
                $display("DEBUG CYCLE %0d: FIFO empty=%0d full=%0d | Bank[0] rd=%0d wr=%0d pre=%0d | Bank[1] rd=%0d wr=%0d pre=%0d | ADDR=0x%h R_W=%0d",
                         relative_cycle,
                         fifo_empty, fifo_full,
                         controller.bank_info[0].t_can_rd,
                         controller.bank_info[0].t_can_wr,
                         controller.bank_info[0].t_can_pre,
                         controller.bank_info[1].t_can_rd,
                         controller.bank_info[1].t_can_wr,
                         controller.bank_info[1].t_can_pre,
                         address, r_w);
            end
            
            // DEBUG: Print FIFO push operations
            if (fifo_push) begin
                $display(">>> CYCLE %0d: FIFO PUSH - addr=0x%h, r_w=%0d, bg=%0d, bank=%0d, row=%0d, col=%0d",
                         cycle_count,
                         fifo_address_in,
                         fifo_r_w_in,
                         fifo_address_in[BG_MSB:BG_LSB],
                         fifo_address_in[BANK_MSB:BANK_LSB],
                         fifo_address_in[ROW_MSB:ROW_LSB],
                         fifo_address_in[COL_MSB:COL_LSB]);
            end
            
            // DEBUG: Print POP operations
            if (pop) begin
                $display("<<< CYCLE %0d: FIFO POP - addr=0x%h, r_w=%0d",
                         cycle_count, address, r_w);
            end
            
            if (command != CMD_NOP && cycle_count >= test_start_cycle) begin
                case(command)
                    CMD_ACT: begin
                        $display("CYCLE %-3d  TIME %0d : ACT  bg=%0d bank=%0d row=%0d",
                                 relative_cycle, $time,
                                 address[BG_MSB:BG_LSB],
                                 address[BANK_MSB:BANK_LSB],
                                 address[ROW_MSB:ROW_LSB]);
                    end
                    CMD_PRE: begin
                        $display("CYCLE %-3d  TIME %0d : PRE  bg=%0d bank=%0d",
                                 relative_cycle, $time,
                                 address[BG_MSB:BG_LSB],
                                 address[BANK_MSB:BANK_LSB]);
                    end
                    CMD_RD: begin
                        $display("CYCLE %-3d  TIME %0d : RD   bg=%0d bank=%0d row=%0d col=%0d",
                                 relative_cycle, $time,
                                 address[BG_MSB:BG_LSB],
                                 address[BANK_MSB:BANK_LSB],
                                 address[ROW_MSB:ROW_LSB],
                                 address[COL_MSB:COL_LSB]);
                    end
                    CMD_WR: begin
                        $display("CYCLE %-3d  TIME %0d : WR   bg=%0d bank=%0d row=%0d col=%0d",
                                 relative_cycle, $time,
                                 address[BG_MSB:BG_LSB],
                                 address[BANK_MSB:BANK_LSB],
                                 address[ROW_MSB:ROW_LSB],
                                 address[COL_MSB:COL_LSB]);
                    end
                endcase
            end
            
            if (pop) begin
                completed_requests = completed_requests + 1;
            end
        end
    end
    
    // Task to push request into FIFO
    task push_request(input [31:0] addr, input [31:0] wdata, input rw);
        begin
            fifo_address_in = addr;
            fifo_write_data_in = wdata;
            fifo_r_w_in = rw;
            fifo_push = 1;
            $display("=== Pushing: BG=%0d B=%0d Row=0x%05h Col=0x%03h (addr=0x%h) at cycle %0d",
                     addr[BG_MSB:BG_LSB],
                     addr[BANK_MSB:BANK_LSB],
                     addr[ROW_MSB:ROW_LSB],
                     addr[COL_MSB:COL_LSB],
                     addr,
                     cycle_count);
            @(posedge clk);
            #1;  // Small delay after clock edge to ensure clean signal setup
            $display("=== Pushed request: BG=%0d B=%0d Row=0x%05h Col=0x%03h R/W=%0d at cycle %0d",
                     addr[BG_MSB:BG_LSB],
                     addr[BANK_MSB:BANK_LSB],
                     addr[ROW_MSB:ROW_LSB],
                     addr[COL_MSB:COL_LSB],
                     rw,
                     cycle_count);
        end
    endtask
    
    // Task to finish pushing all requests
    task finish_push();
        begin
            fifo_push = 0;
            @(posedge clk);
        end
    endtask
    
    // Task to wait for N request completions
    task wait_for_n_completions(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                // Wait for pop signal
                while (!pop) begin
                    @(posedge clk);
                end
                $display("=== Request %0d/%0d completed at cycle %0d", i+1, n, cycle_count);
                @(posedge clk);  // Move to next cycle
            end
        end
    endtask
    
    // Task to print test results
    task print_results(input string test_name);
        integer total_cycles;
        real avg_latency;
        real throughput;
        begin
            total_cycles = test_end_cycle - test_start_cycle;
            avg_latency = real'(total_cycles) / real'(total_requests);
            throughput = real'(total_requests) / real'(total_cycles);
            
            $display("FR-FCFS cycles = %0d\n", total_cycles);
            $display("========================================");
            $display("SUMMARY: %s", test_name);
            $display("========================================");
            $display("Total Cycles:             %0d", total_cycles);
            $display("Total Requests:           %0d", total_requests);
            $display("Avg Latency:              %.2f cycles/request", avg_latency);
            $display("Throughput:               %.4f requests/cycle", throughput);
            $display("========================================\n");
        end
    endtask
    
    // Main test stimulus
    initial begin
        $display("\n========================================");
        $display("DRAM Controller Performance Tests");
        $display("========================================\n");
        
        // Initialize
        cycle_count = 0;
        reset = 1;
        fifo_address_in = 0;
        fifo_write_data_in = 0;
        fifo_r_w_in = 0;
        fifo_push = 0;
        total_requests = 0;
        completed_requests = 0;
        
        repeat(10) @(posedge clk);
        reset = 0;
        repeat(5) @(posedge clk);
        
        //====================================================================
        // TEST 1: Row Hits (Single Bank)
        // Same bank, same row, different columns
        //====================================================================
        $display("\n========================================");
        $display("TEST 1: Row Hits (Single Bank)");
        $display("========================================");
        $display("Expected: ACT -> RD -> RD -> RD (all row hits)\n");
        
        test_start_cycle = cycle_count;
        total_requests = 3;
        completed_requests = 0;
        
        // Wait a few cycles for controller to stabilize
        repeat(3) @(posedge clk);
        
        // Push all requests into FIFO at once
        $display("=== Pushing all 3 requests into FIFO...");
        push_request(make_addr(14'h00200, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h00200, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        push_request(make_addr(14'h00200, 2'b00, 2'b00, 8'h10), 32'h0, 0);
        finish_push();
        $display("=== All requests pushed, controller will process...\n");
        
        // Wait for all requests to complete
        wait_for_n_completions(3);
        
        test_end_cycle = cycle_count;
        print_results("TEST 1: Row Hits (Single Bank)");
        
        repeat(20) @(posedge clk);
        
        //====================================================================
        // TEST 2: Row Conflict
        // Same bank, different rows (requires PRE -> ACT -> RD sequence)
        //====================================================================
        $display("\n========================================");
        $display("TEST 2: Row Conflict");
        $display("========================================");
        $display("Expected: ACT -> RD -> PRE -> ACT -> RD\n");
        
        test_start_cycle = cycle_count;
        total_requests = 2;
        completed_requests = 0;
        
        // Push all requests into FIFO at once
        $display("=== Pushing all 2 requests into FIFO...");
        push_request(make_addr(14'h0000a, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h0000b, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        finish_push();
        $display("=== All requests pushed, controller will process...\n");
        
        // Wait for all requests to complete
        wait_for_n_completions(2);
        
        test_end_cycle = cycle_count;
        print_results("TEST 2: Row Conflict");
        
        repeat(20) @(posedge clk);
        //====================================================================
        // TEST 3: Multi-Bank Interleaving (Different Bank Groups)
        // Access different banks/bank groups for parallelism
        //====================================================================
        $display("\n========================================");
        $display("TEST 3: Multi-Bank Interleaving");
        $display("========================================");
        $display("Expected: Multiple ACTs, then interleaved READs\n");
        
        test_start_cycle = cycle_count;
        total_requests = 4;
        completed_requests = 0;
        
        // Push all requests into FIFO at once
        $display("=== Pushing all 4 requests into FIFO...");
        push_request(make_addr(14'h00064, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h000c8, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h00064, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        push_request(make_addr(14'h0012c, 2'b01, 2'b00, 8'h00), 32'h0, 0);
        finish_push();
        $display("=== All requests pushed, controller will process...\n");
        
        // Wait for all requests to complete
        wait_for_n_completions(4);
        
        test_end_cycle = cycle_count;
        print_results("TEST 3: Multi-Bank Interleaving");
        
        repeat(20) @(posedge clk);
        //====================================================================
        // TEST 4: Row Thrashing (Ping-Pong)
        // Alternating between two rows in same bank (worst case)
        //====================================================================
        $display("\n========================================");
        $display("TEST 4: Row Thrashing (Ping-Pong)");
        $display("========================================");
        $display("Expected: ACT -> RD -> PRE -> ACT -> RD (repeat)\n");
        
        test_start_cycle = cycle_count;
        total_requests = 4;
        completed_requests = 0;
        
        // Push all requests into FIFO at once
        $display("=== Pushing all 4 requests into FIFO...");
        push_request(make_addr(14'h0000a, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h0000b, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h0000a, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        push_request(make_addr(14'h0000b, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        finish_push();
        $display("=== All requests pushed, controller will process...\n");
        
        // Wait for all requests to complete
        wait_for_n_completions(4);
        
        test_end_cycle = cycle_count;
        print_results("TEST 4: Row Thrashing (Ping-Pong)");
        
        repeat(20) @(posedge clk);
        //====================================================================
        // TEST 5: Kitchen Sink Complex Pattern
        // Mix of row hits, conflicts, and multi-bank accesses
        //====================================================================
        $display("\n========================================");
        $display("TEST 5: Kitchen Sink Complex Pattern");
        $display("========================================");
        $display("Expected: Mix of row hits, conflicts, multi-bank\n");
        
        test_start_cycle = cycle_count;
        total_requests = 7;
        completed_requests = 0;
        
        // Push all requests into FIFO at once
        $display("=== Pushing all 7 requests into FIFO...");
        push_request(make_addr(14'h00064, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h000c8, 2'b01, 2'b00, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h0012c, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h00064, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        push_request(make_addr(14'h0012d, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        push_request(make_addr(14'h000c8, 2'b01, 2'b00, 8'h08), 32'h0, 0);
        push_request(make_addr(14'h00064, 2'b00, 2'b00, 8'h10), 32'h0, 0);
        finish_push();
        $display("=== All requests pushed, controller will process...\n");
        
        // Wait for all requests to complete
        wait_for_n_completions(7);
        
        test_end_cycle = cycle_count;
        print_results("TEST 5: Kitchen Sink Complex Pattern");
        
        //====================================================================
        // Summary
        //====================================================================
        repeat(20) @(posedge clk);
        
        $display("\n========================================");
        $display("All Performance Tests Completed!");
        $display("========================================\n");
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #10000000;  // 10ms timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("tb_performance.vcd");
        $dumpvars(0, tb_performance);
    end
    
endmodule
