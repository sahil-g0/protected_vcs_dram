// =============================================================================
// Bank State Tracker Module
// =============================================================================
// Tracks which row is currently open in each bank (or if precharged).
// Used during schedule emission to determine if PRE/ACT commands are needed.
// =============================================================================
`timescale 1ns/1ps //
`include "dram_scheduler_types.vh"

module bank_state_tracker (
    input  wire clk,
    input  wire rst_n,
    
    // Control
    input  wire clear,
    
    // Query interface
    input  wire [`BANK_GROUP_WIDTH-1:0]  query_bank_group,
    input  wire [`BANK_WIDTH-1:0]        query_bank,
    output reg                           is_precharged,
    output reg                           is_row_open,
    output reg  [`ROW_WIDTH-1:0]         open_row,
    
    // Update interface
    input  wire                          upd_activate,
    input  wire                          upd_precharge,
    input  wire [`BANK_GROUP_WIDTH-1:0]  upd_bank_group,
    input  wire [`BANK_WIDTH-1:0]        upd_bank,
    input  wire [`ROW_WIDTH-1:0]         upd_row
);

    // =============================================================================
    // Internal Storage - One entry per bank
    // =============================================================================
    localparam NUM_BANKS = `NUM_BANK_GROUPS * `NUM_BANKS_PER_GROUP;
    
    reg [`ROW_WIDTH-1:0] row_buffer [0:NUM_BANKS-1];
    reg                  row_valid  [0:NUM_BANKS-1];  // 1 = row open, 0 = precharged
    
    // =============================================================================
    // Address calculation
    // =============================================================================
    wire [$clog2(NUM_BANKS)-1:0] query_addr = 
        {query_bank_group, query_bank};
    wire [$clog2(NUM_BANKS)-1:0] upd_addr = 
        {upd_bank_group, upd_bank};
    
    // =============================================================================
    // Query Logic (Combinational)
    // =============================================================================
    always @(*) begin
        is_precharged = ~row_valid[query_addr];
        is_row_open = row_valid[query_addr];
        open_row = row_buffer[query_addr];
    end
    
    // =============================================================================
    // Update Logic
    // =============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integer i;
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                row_valid[i] <= 1'b0;
            end
        end
        else if (clear) begin
            integer j;
            for (j = 0; j < NUM_BANKS; j = j + 1) begin
                row_valid[j] <= 1'b0;
            end
        end
        else begin
            if (upd_activate) begin
                row_buffer[upd_addr] <= upd_row;
                row_valid[upd_addr] <= 1'b1;
            end
            else if (upd_precharge) begin
                row_valid[upd_addr] <= 1'b0;
            end
        end
    end

endmodule