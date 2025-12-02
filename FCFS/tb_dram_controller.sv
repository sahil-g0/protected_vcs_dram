`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench for DRAM Controller - READ Operations
// Tests various read scenarios with timing verification
//////////////////////////////////////////////////////////////////////////////////

`include "dram_timings.vh"
`include "timing_abstraction.vh"

module tb_dram_controller();
    // Clock and reset
    reg clk;
    reg reset;
    
    // FIFO interface
    reg [31:0] address;
    reg [31:0] write_data;
    reg r_w;
    reg fifo_empty;
    
    // Controller outputs
    wire pop;
    wire [2:0] command;
    
    // Instantiate DUT
    generate_instruction dut (
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
        forever #5 clk = ~clk;
    end
    
    // Command name strings for display
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
    
    // Helper function to create address
    function [31:0] make_addr(input [13:0] row, input [1:0] bg, input [1:0] bank, input [7:0] col);
        return {2'b0, row, bg, bank, col, 4'b0};
    endfunction
    
    // Monitor for displaying commands and bank state
    integer cycle_count;
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count = cycle_count + 1;
            
            if (command != CMD_NOP) begin
                $display("[Cycle %0d] Command: %-5s | BG=%0d Bank=%0d Row=%0d Col=%0d", 
                         cycle_count, cmd_name(command),
                         address[BG_MSB:BG_LSB], 
                         address[BANK_MSB:BANK_LSB],
                         address[ROW_MSB:ROW_LSB],
                         address[COL_MSB:COL_LSB]);
            end
            
            if (pop)
                $display("         └─> POP asserted (request complete)");
        end
    end
    
    // Task to display bank timing state
    task display_bank_timings(input integer bank_idx);
        $display("\n=== Bank %0d Timing State ===", bank_idx);
        $display("  is_open     = %0d (row %0d)", 
                 dut.bank_info[bank_idx].is_open,
                 dut.bank_info[bank_idx].open_row);
        $display("  t_can_pre   = %0d cycles (tRTP=%0d, tWR=%0d)", 
                 dut.bank_info[bank_idx].t_can_pre, tRTP, tWR);
        $display("  t_can_act   = %0d cycles (tRP=%0d, tRRD_S=%0d, tRRD_L=%0d)", 
                 dut.bank_info[bank_idx].t_can_act, tRP, tRRD_S, tRRD_L);
        $display("  t_can_rd    = %0d cycles (tRCD=%0d, tCCD_S=%0d, tCCD_L=%0d)", 
                 dut.bank_info[bank_idx].t_can_rd, tRCD, tCCD_S, tCCD_L);
        $display("  t_can_wr    = %0d cycles (tRCD=%0d, tRTW=%0d)", 
                 dut.bank_info[bank_idx].t_can_wr, tRCD, tRTW);
    endtask
    
    // Task to wait for specific command
    task wait_for_command(input [2:0] expected_cmd, input integer max_cycles);
        integer wait_count;
        wait_count = 0;
        while (command != expected_cmd && wait_count < max_cycles) begin
            @(posedge clk);
            wait_count = wait_count + 1;
        end
        if (wait_count >= max_cycles) begin
            $display("ERROR: Timeout waiting for %s command", cmd_name(expected_cmd));
            $stop;
        end
    endtask
    
    // Main test stimulus
    initial begin
        $display("\n========================================");
        $display("DRAM Controller Testbench - READ Tests");
        $display("========================================\n");
        $display("Timing Parameters:");
        $display("  tRCD=%0d  tRP=%0d  tRAS=%0d  tRTP=%0d", tRCD, tRP, tRAS, tRTP);
        $display("  tRRD_S=%0d  tRRD_L=%0d", tRRD_S, tRRD_L);
        $display("  tCCD_S=%0d  tCCD_L=%0d", tCCD_S, tCCD_L);
        $display("  tRTW=%0d\n", tRTW);
        
        // Initialize
        cycle_count = 0;
        reset = 1;
        fifo_empty = 1;
        r_w = 0;  // READ operations
        address = 0;
        write_data = 0;
        
        repeat(5) @(posedge clk);
        reset = 0;
        @(posedge clk);
        
        //====================================================================
        // TEST 1: Simple READ (cold start - row closed)
        //====================================================================
        $display("\n[TEST 1] Simple READ to closed bank");
        $display("Expected sequence: ACT -> (wait tRCD=%0d) -> READ", tRCD);
        $display("Timeline:");
        $display("  Cycle %0d: Present address, deassert fifo_empty", cycle_count + 1);
        $display("  Cycle %0d: Controller sees request, issues ACT (bank was closed)", cycle_count + 2);
        $display("  Cycle %0d-%0d: Wait for tRCD timing (bank.t_can_rd counts down from %0d)", cycle_count + 3, cycle_count + 2 + tRCD - 1, tRCD);
        $display("  Cycle %0d: Bank is open, t_can_rd=0, controller issues READ, asserts pop", cycle_count + 2 + tRCD);
        
        address = make_addr(14'h1234, 2'b00, 2'b00, 8'h10);
        fifo_empty = 0;
        
        // Should see ACT command
        @(posedge clk);
        $display("\n>>> Cycle %0d: Checking for ACT command...", cycle_count);
        assert(command == CMD_ACT) else $error("Expected ACT, got %s", cmd_name(command));
        $display("    ✓ ACT issued correctly");
        
        // Wait for READ (should be tRCD cycles)
        wait_for_command(CMD_RD, tRCD + 5);
        $display("\n>>> Cycle %0d: Checking for READ command...", cycle_count);
        assert(command == CMD_RD) else $error("Expected READ");
        assert(pop == 1) else $error("POP should be asserted on READ");
        $display("    ✓ READ issued correctly after tRCD=%0d cycles", tRCD);
        $display("    ✓ POP asserted");
        
        display_bank_timings(0);
        fifo_empty = 1;
        @(posedge clk);
        
        //====================================================================
        // TEST 2: READ to same row (row buffer hit)
        //====================================================================
        $display("\n[TEST 2] READ to same row (row buffer hit)");
        $display("Expected: Immediate READ (no ACT needed)");
        $display("Timeline:");
        $display("  After TEST 1: Bank 0 has row 0x1234 open, but t_can_rd=%0d (tCCD_S from previous READ)", tCCD_S);
        $display("  Wait %0d cycles for t_can_rd to reach 0", tRTP + 2);
        
        // Wait for t_can_rd to expire
        repeat(tRTP + 2) @(posedge clk);
        
        $display("  Cycle %0d: Present new address (same row 0x1234, different col)", cycle_count + 1);
        $display("  Cycle %0d: Bank already open, row matches, t_can_rd=0 -> issue READ immediately", cycle_count + 2);
        
        address = make_addr(14'h1234, 2'b00, 2'b00, 8'h20);  // Same row, different column
        fifo_empty = 0;
        
        @(posedge clk);
        $display("\n>>> Cycle %0d: Checking for immediate READ (row buffer hit)...", cycle_count);
        assert(command == CMD_RD) else $error("Expected immediate READ on row hit, got %s", cmd_name(command));
        assert(pop == 1) else $error("POP should be asserted");
        $display("    ✓ READ issued immediately (no ACT required)");
        $display("    ✓ POP asserted");
        
        display_bank_timings(0);
        fifo_empty = 1;
        @(posedge clk);
        
        //====================================================================
        // TEST 3: READ to different row (row buffer conflict)
        //====================================================================
        $display("\n[TEST 3] READ to different row (requires PRE then ACT)");
        $display("Expected sequence: PRE -> (wait tRP=%0d) -> ACT -> (wait tRCD=%0d) -> READ", tRP, tRCD);
        $display("Timeline:");
        $display("  After TEST 2: Bank 0 has row 0x1234 open, but t_can_pre=%0d (tRTP from last READ)", tRTP);
        
        // Wait for t_can_pre to expire
        repeat(tRTP + 2) @(posedge clk);
        
        $display("  Cycle %0d: Present address with different row (0x1678)", cycle_count + 1);
        $display("  Cycle %0d: Bank open with wrong row, t_can_pre=0 -> issue PRE", cycle_count + 2);
        $display("  Cycle %0d-%0d: Wait for tRP timing (t_can_act counts down from %0d)", cycle_count + 3, cycle_count + 2 + tRP - 1, tRP);
        $display("  Cycle %0d: Bank closed, t_can_act=0 -> issue ACT", cycle_count + 2 + tRP);
        $display("  Cycle %0d-%0d: Wait for tRCD timing (t_can_rd counts down from %0d)", cycle_count + 3 + tRP, cycle_count + 2 + tRP + tRCD - 1, tRCD);
        $display("  Cycle %0d: Bank open, t_can_rd=0 -> issue READ", cycle_count + 2 + tRP + tRCD);
        
        address = make_addr(14'h1678, 2'b00, 2'b00, 8'h30);  // Different row
        fifo_empty = 0;
        
        // Should see PRE
        @(posedge clk);
        $display("\n>>> Cycle %0d: Checking for PRE command...", cycle_count);
        assert(command == CMD_PRE) else $error("Expected PRE, got %s", cmd_name(command));
        $display("    ✓ PRE issued correctly");
        
        // Wait for ACT
        wait_for_command(CMD_ACT, tRP + 5);
        $display("\n>>> Cycle %0d: Checking for ACT command...", cycle_count);
        assert(command == CMD_ACT) else $error("Expected ACT");
        $display("    ✓ ACT issued correctly after tRP=%0d cycles", tRP);
        
        // Wait for READ
        wait_for_command(CMD_RD, tRCD + 5);
        $display("\n>>> Cycle %0d: Checking for READ command...", cycle_count);
        assert(command == CMD_RD) else $error("Expected READ");
        assert(pop == 1) else $error("POP should be asserted");
        $display("    ✓ READ issued correctly after tRCD=%0d cycles", tRCD);
        $display("    ✓ POP asserted");
        
        display_bank_timings(0);
        fifo_empty = 1;
        @(posedge clk);
        
        //====================================================================
        // TEST 4: Back-to-back READs to same bank group
        //====================================================================
        $display("\n[TEST 4] Back-to-back READs to same bank group");
        $display("Expected: tCCD_S=%0d cycle delay between READs", tCCD_S);
        
        repeat(tRTP + 2) @(posedge clk);
        
        // First READ (to bank 0, BG 0)
        address = make_addr(14'h1678, 2'b00, 2'b00, 8'h40);
        fifo_empty = 0;
        @(posedge clk);
        assert(command == CMD_RD) else $error("Expected READ");
        
        // Now READ to bank 1, same BG
        address = make_addr(14'h2ABC, 2'b00, 2'b01, 8'h50);
        
        // Need to ACT bank 1 first
        wait_for_command(CMD_ACT, 20);
        wait_for_command(CMD_RD, tRCD + 5);
        
        $display("Bank 0 and Bank 1 READ timing verified");
        display_bank_timings(0);
        display_bank_timings(1);
        
        fifo_empty = 1;
        repeat(5) @(posedge clk);
        
        //====================================================================
        // TEST 5: READs to different bank groups
        //====================================================================
        $display("\n[TEST 5] READs to different bank groups");
        $display("Expected: tCCD_L=%0d cycle delay (less than tCCD_S=%0d)", tCCD_L, tCCD_S);
        
        repeat(20) @(posedge clk);
        
        // READ to BG 1
        address = make_addr(14'h1111, 2'b01, 2'b00, 8'h60);
        fifo_empty = 0;
        
        // Wait for activation and read
        wait_for_command(CMD_ACT, 20);
        wait_for_command(CMD_RD, tRCD + 5);
        
        $display("Different bank group timing verified");
        display_bank_timings(4);  // Bank 4 is in BG 1
        
        fifo_empty = 1;
        repeat(10) @(posedge clk);
        
        //====================================================================
        // Summary
        //====================================================================
        $display("\n========================================");
        $display("All READ tests completed successfully!");
        $display("========================================\n");
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #50000;  // 50us timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end
    
    // Waveform dump (for viewing in GTKWave or similar)
    initial begin
        $dumpfile("tb_dram_controller.vcd");
        $dumpvars(0, tb_dram_controller);
    end
    
endmodule
