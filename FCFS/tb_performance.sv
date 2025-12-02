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
    
    // Direct controller inputs (no FIFO)
    reg [31:0] address;
    reg [31:0] write_data;
    reg r_w;
    reg fifo_empty;
    
    // Controller outputs
    wire pop;
    wire [2:0] command;
    
    // Performance tracking
    integer test_start_cycle;
    integer test_end_cycle;
    integer total_requests;
    integer completed_requests;
    
    // Instantiate controller (no FIFO)
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
    
    // Monitor controller commands
    integer cycle_count;
    integer relative_cycle;
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count = cycle_count + 1;
            relative_cycle = cycle_count - test_start_cycle;
            
            // DEBUG: Print bank counters for TEST 3 - track Banks 0 and 1
            if (cycle_count >= test_start_cycle && cycle_count <= test_start_cycle + 80) begin
                $display("DEBUG CYCLE %0d: Bank[0] rd=%0d wr=%0d pre=%0d | Bank[1] rd=%0d wr=%0d pre=%0d",
                         relative_cycle,
                         controller.bank_info[0].t_can_rd,
                         controller.bank_info[0].t_can_wr,
                         controller.bank_info[0].t_can_pre,
                         controller.bank_info[1].t_can_rd,
                         controller.bank_info[1].t_can_wr,
                         controller.bank_info[1].t_can_pre);
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
    
    // Task to set address for controller (no FIFO)
    task set_address(input [31:0] addr, input [31:0] wdata, input rw);
        begin
            address = addr;
            write_data = wdata;
            r_w = rw;
            fifo_empty = 0;
        end
    endtask
    
    // Task to wait for all requests to complete
    task wait_for_completion();
        begin
            // Wait for pop signal indicating request complete
            while (!pop) begin
                @(posedge clk);
            end
            @(posedge clk);  // One more cycle after pop
            // Mark FIFO as empty so controller doesn't process same address again
            fifo_empty = 1;
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
        address = 0;
        write_data = 0;
        r_w = 0;
        fifo_empty = 1;  // Start with empty
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
        
        // First request: BG0 B0 Row=0x200 Col=0x00
        set_address(make_addr(14'h00200, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Second request: BG0 B0 Row=0x200 Col=0x08 (row hit)
        set_address(make_addr(14'h00200, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
        // Third request: BG0 B0 Row=0x200 Col=0x10 (row hit)
        set_address(make_addr(14'h00200, 2'b00, 2'b00, 8'h10), 32'h0, 0);
        wait_for_completion();
        
        test_end_cycle = cycle_count;
        print_results("TEST 1: Row Hits (Single Bank)");
        
        repeat(20) @(posedge clk);
        
        // Reset address between tests to prevent contamination
        fifo_empty = 1;
        address = 0;
        
        repeat(10) @(posedge clk);
        
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
        
        // First request: BG0 B0 Row=0xa Col=0x00
        set_address(make_addr(14'h0000a, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Second request: BG0 B0 Row=0xb Col=0x00 (row conflict)
        set_address(make_addr(14'h0000b, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
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
        
        // Request 1: BG0 B0 Row=0x64 Col=0x00
        set_address(make_addr(14'h00064, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 2: BG0 B1 Row=0xc8 Col=0x00
        set_address(make_addr(14'h000c8, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 3: BG0 B0 Row=0x64 Col=0x08 (row hit)
        set_address(make_addr(14'h00064, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
        // Request 4: BG1 B0 Row=0x12c Col=0x00
        set_address(make_addr(14'h0012c, 2'b01, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
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
        
        // Request 1: BG0 B0 Row=0xa Col=0x00
        set_address(make_addr(14'h0000a, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 2: BG0 B0 Row=0xb Col=0x00 (conflict)
        set_address(make_addr(14'h0000b, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 3: BG0 B0 Row=0xa Col=0x08 (conflict)
        set_address(make_addr(14'h0000a, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
        // Request 4: BG0 B0 Row=0xb Col=0x08 (conflict)
        set_address(make_addr(14'h0000b, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
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
        
        // Request 1: BG0 B0 Row=0x64 Col=0x00
        set_address(make_addr(14'h00064, 2'b00, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 2: BG1 B0 Row=0xc8 Col=0x00
        set_address(make_addr(14'h000c8, 2'b01, 2'b00, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 3: BG0 B1 Row=0x12c Col=0x00
        set_address(make_addr(14'h0012c, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 4: BG0 B0 Row=0x64 Col=0x08 (row hit)
        set_address(make_addr(14'h00064, 2'b00, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
        // Request 5: BG0 B1 Row=0x12d Col=0x00 (conflict)
        set_address(make_addr(14'h0012d, 2'b00, 2'b01, 8'h00), 32'h0, 0);
        wait_for_completion();
        
        // Request 6: BG1 B0 Row=0xc8 Col=0x08 (row hit)
        set_address(make_addr(14'h000c8, 2'b01, 2'b00, 8'h08), 32'h0, 0);
        wait_for_completion();
        
        // Request 7: BG0 B0 Row=0x64 Col=0x10 (row hit)
        set_address(make_addr(14'h00064, 2'b00, 2'b00, 8'h10), 32'h0, 0);
        wait_for_completion();
        
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
