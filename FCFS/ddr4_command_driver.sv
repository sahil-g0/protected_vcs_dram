`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// DDR4 Command Driver
// 
// Purpose: Translates controller commands (CMD_ACT, CMD_PRE, CMD_RD, CMD_WR)
//          into DDR4 physical interface signals for Micron model
//
// Note: This module drives the DDR4 interface signals directly, matching
//       the timing and protocol expected by the Micron DDR4 model
//////////////////////////////////////////////////////////////////////////////////

`include "dram_timings.vh"

module ddr4_command_driver #(
    parameter DQ_WIDTH = 8,      // Match your DDR4 configuration (4, 8, or 16)
    parameter DQS_WIDTH = 1      // DQS width (1 for x8, 2 for x16)
)(
    input              clk,
    input              reset,
    
    // From controller
    input [2:0]        command,       // CMD_NOP, CMD_ACT, CMD_PRE, CMD_RD, CMD_WR
    input [31:0]       address,       // Encoded address from controller
    input [31:0]       write_data,    // Write data from controller
    input              r_w,           // Read/Write flag
    
    // To DDR4 Model (Micron interface signals)
    output reg         CKE,
    output reg         CS_n,
    output reg         ACT_n,
    output reg         RAS_n_A16,
    output reg         CAS_n_A15,
    output reg         WE_n_A14,
    output reg [1:0]   BG,            // Bank group
    output reg [1:0]   BA,            // Bank address
    output reg [13:0]  ADDR,          // Address/Row/Column
    
    // Data interface (simplified - full implementation needs proper timing)
    output reg                    dq_en,
    output reg                    dqs_en,
    output reg [DQ_WIDTH-1:0]     dq_out,
    output reg [DQS_WIDTH-1:0]    dqs_out
);

    // Decode address fields from controller
    wire [1:0]  addr_bg   = address[BG_MSB:BG_LSB];
    wire [1:0]  addr_ba   = address[BANK_MSB:BANK_LSB];
    wire [13:0] addr_row  = address[ROW_MSB:ROW_LSB];
    wire [7:0]  addr_col  = address[COL_MSB:COL_LSB];
    
    // Write data pipeline for WL timing (simplified)
    reg [31:0] write_data_pipe [tCWL-1:0];
    integer i;
    
    //=========================================================================
    // DDR4 Command Encoding
    //=========================================================================
    // Command truth table:
    // ACT_n | RAS_n | CAS_n | WE_n  | Command
    //   0   |   X   |   X   |   X   | ACTIVATE
    //   1   |   0   |   1   |   0   | PRECHARGE
    //   1   |   1   |   0   |   1   | READ
    //   1   |   1   |   0   |   0   | WRITE
    //   1   |   1   |   1   |   1   | NOP/DESELECT
    //=========================================================================
    
    always @(posedge clk) begin
        if (reset) begin
            // Reset state
            CKE <= 1'b1;              // Clock enable active
            CS_n <= 1'b1;             // Chip select inactive (NOP)
            ACT_n <= 1'b1;
            RAS_n_A16 <= 1'b1;
            CAS_n_A15 <= 1'b1;
            WE_n_A14 <= 1'b1;
            BG <= 2'b0;
            BA <= 2'b0;
            ADDR <= 14'b0;
            dq_en <= 1'b0;
            dqs_en <= 1'b0;
            dq_out <= '0;
            dqs_out <= '0;
            
            for (i = 0; i < tCWL; i = i + 1) begin
                write_data_pipe[i] <= 32'b0;
            end
        end
        else begin
            // Default: NOP command
            CKE <= 1'b1;
            CS_n <= 1'b0;             // Chip select active
            ACT_n <= 1'b1;
            RAS_n_A16 <= 1'b1;
            CAS_n_A15 <= 1'b1;
            WE_n_A14 <= 1'b1;
            
            // Decode controller command
            case (command)
                CMD_ACT: begin
                    // ACTIVATE command
                    ACT_n <= 1'b0;           // ACT_n = 0 for activate
                    RAS_n_A16 <= addr_row[13];  // Row address bit 13
                    CAS_n_A15 <= addr_row[12];  // Row address bit 12
                    WE_n_A14 <= addr_row[11];   // Row address bit 11
                    BG <= addr_bg;
                    BA <= addr_ba;
                    ADDR <= addr_row[13:0];     // Full row address
                    
                    $display("[%0t] DDR4 Driver: ACT - BG=%0d BA=%0d ROW=0x%h", 
                             $time, addr_bg, addr_ba, addr_row);
                end
                
                CMD_PRE: begin
                    // PRECHARGE command
                    ACT_n <= 1'b1;
                    RAS_n_A16 <= 1'b0;       // RAS=0
                    CAS_n_A15 <= 1'b1;       // CAS=1
                    WE_n_A14 <= 1'b0;        // WE=0
                    BG <= addr_bg;
                    BA <= addr_ba;
                    ADDR <= 14'b0;           // A10=0 for single bank precharge
                    
                    $display("[%0t] DDR4 Driver: PRE - BG=%0d BA=%0d", 
                             $time, addr_bg, addr_ba);
                end
                
                CMD_RD: begin
                    // READ command
                    ACT_n <= 1'b1;
                    RAS_n_A16 <= 1'b1;       // RAS=1
                    CAS_n_A15 <= 1'b0;       // CAS=0
                    WE_n_A14 <= 1'b1;        // WE=1
                    BG <= addr_bg;
                    BA <= addr_ba;
                    ADDR <= {6'b0, addr_col}; // Column address in lower bits
                    
                    $display("[%0t] DDR4 Driver: RD - BG=%0d BA=%0d COL=0x%h", 
                             $time, addr_bg, addr_ba, addr_col);
                end
                
                CMD_WR: begin
                    // WRITE command
                    ACT_n <= 1'b1;
                    RAS_n_A16 <= 1'b1;       // RAS=1
                    CAS_n_A15 <= 1'b0;       // CAS=0
                    WE_n_A14 <= 1'b0;        // WE=0
                    BG <= addr_bg;
                    BA <= addr_ba;
                    ADDR <= {6'b0, addr_col}; // Column address
                    
                    // Pipeline write data for WL timing
                    write_data_pipe[0] <= write_data;
                    
                    $display("[%0t] DDR4 Driver: WR - BG=%0d BA=%0d COL=0x%h DATA=0x%h", 
                             $time, addr_bg, addr_ba, addr_col, write_data);
                end
                
                default: begin
                    // NOP/DESELECT (already set above)
                end
            endcase
            
            // Pipeline write data through WL stages
            for (i = 1; i < tCWL; i = i + 1) begin
                write_data_pipe[i] <= write_data_pipe[i-1];
            end
            
            // Drive DQ/DQS for writes (simplified - real implementation needs
            // proper burst handling with tCK/2 timing)
            if (write_data_pipe[tCWL-1] != 32'b0) begin
                dq_en <= 1'b1;
                dqs_en <= 1'b1;
                dq_out <= write_data_pipe[tCWL-1][DQ_WIDTH-1:0];
                dqs_out <= {DQS_WIDTH{1'b1}};
            end
            else begin
                dq_en <= 1'b0;
                dqs_en <= 1'b0;
            end
        end
    end

endmodule
