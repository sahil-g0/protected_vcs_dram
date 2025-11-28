// =============================================================================
// Schedule Memory Module
// =============================================================================
// Stores the emitted command schedule as an array indexed by cycle number.
// Each location stores a command (ACT, RD, PRE) or DESELECT (no-op).
// =============================================================================

`timescale 1ns/1ps // Added timescale for consistency across all modules
`include "dram_scheduler_types.vh"

module schedule_memory #(
    parameter MAX_CYCLES = `MAX_SCHEDULE_CYCLES
) (
    input wire clk,
    input wire rst_n,
    
    // Control
    input wire clear,
    
    // Write interface - emit command at specific cycle
    input wire             wr_en,
    input wire [`CYCLE_WIDTH-1:0]    wr_cycle,
    input wire [2:0]          wr_cmd_type,
    input wire [`BANK_GROUP_WIDTH-1:0] wr_bank_group,
    input wire [`BANK_WIDTH-1:0]    wr_bank,
    input wire [`ROW_WIDTH-1:0]     wr_row,
    input wire [`COLUMN_WIDTH-1:0]   wr_column,
    input wire [`REQUEST_ID_WIDTH-1:0] wr_request_id,
    
    // Read interface
    input wire [`CYCLE_WIDTH-1:0]    rd_cycle,
    output reg [2:0]          rd_cmd_type,
    output reg [`BANK_GROUP_WIDTH-1:0] rd_bank_group,
    output reg [`BANK_WIDTH-1:0]    rd_bank,
    output reg [`ROW_WIDTH-1:0]     rd_row,
    output reg [`COLUMN_WIDTH-1:0]   rd_column,
    output reg [`REQUEST_ID_WIDTH-1:0] rd_request_id,
    
    // Max cycle tracker
    output reg [`CYCLE_WIDTH-1:0]    max_cycle
);

    // =============================================================================
    // Internal Storage
    // =============================================================================
    reg [2:0]          cmd_type_mem  [0:MAX_CYCLES-1];
    reg [`BANK_GROUP_WIDTH-1:0] bank_group_mem [0:MAX_CYCLES-1];
    reg [`BANK_WIDTH-1:0]    bank_mem    [0:MAX_CYCLES-1];
    reg [`ROW_WIDTH-1:0]     row_mem    [0:MAX_CYCLES-1];
    reg [`COLUMN_WIDTH-1:0]   column_mem   [0:MAX_CYCLES-1];
    reg [`REQUEST_ID_WIDTH-1:0] request_id_mem [0:MAX_CYCLES-1];
    
    // =============================================================================
    // Write Logic
    // =============================================================================
    
    integer i; 
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous Reset
            max_cycle <= 0;
            // Initialize all to DESELECT on reset
            for (i = 0; i < MAX_CYCLES; i = i + 1) begin
                cmd_type_mem[i] <= `CMD_DESELECT;
                // FIX: Initialize payload memories to 0 to prevent X on read
                bank_group_mem[i] <= 0;
                bank_mem[i] <= 0;
                row_mem[i] <= 0;
                column_mem[i] <= 0;
                request_id_mem[i] <= 0;
            end
        end
        else if (clear) begin
            // Synchronous Clear
            max_cycle <= 0;
            // Initialize all to DESELECT
            for (i = 0; i < MAX_CYCLES; i = i + 1) begin
                cmd_type_mem[i] <= `CMD_DESELECT;
                bank_group_mem[i] <= 0;
                bank_mem[i] <= 0;
                row_mem[i] <= 0;
                column_mem[i] <= 0;
                request_id_mem[i] <= 0;
            end 
        end
        else if (wr_en) begin
            // Synchronous Write
            cmd_type_mem[wr_cycle]  <= wr_cmd_type;
            bank_group_mem[wr_cycle] <= wr_bank_group;
            bank_mem[wr_cycle]    <= wr_bank;
            row_mem[wr_cycle]    <= wr_row;
            column_mem[wr_cycle]   <= wr_column;
            request_id_mem[wr_cycle] <= wr_request_id;
            
            if (wr_cycle > max_cycle)
                max_cycle <= wr_cycle;
        end
    end
    
    // =============================================================================
    // Read Logic
    // =============================================================================
    always @(posedge clk) begin
        // Synchronous Read
        rd_cmd_type  <= cmd_type_mem[rd_cycle];
        rd_bank_group <= bank_group_mem[rd_cycle];
        rd_bank    <= bank_mem[rd_cycle];
        rd_row    <= row_mem[rd_cycle];
        rd_column   <= column_mem[rd_cycle];
        rd_request_id <= request_id_mem[rd_cycle];
    end

endmodule