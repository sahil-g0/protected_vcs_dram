// =============================================================================
// Request Buffer Module
// =============================================================================
// Fixed: Consolidated write logic + Debug Prints.
// =============================================================================
`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module request_buffer #(
    parameter MAX_REQUESTS = `MAX_REQUESTS
) (
    input  wire clk,
    input  wire rst_n,
    
    input  wire                          req_valid,
    input  wire [`BANK_GROUP_WIDTH-1:0]  req_bank_group,
    input  wire [`BANK_WIDTH-1:0]        req_bank,
    input  wire [`ROW_WIDTH-1:0]         req_row,
    input  wire [`COLUMN_WIDTH-1:0]      req_column,
    output wire                          req_ready,
    
    input  wire                          batch_start,
    input  wire                          batch_clear,
    output reg  [`REQUEST_ID_WIDTH-1:0]  num_requests,
    
    input  wire [`REQUEST_ID_WIDTH-1:0]  rd_addr,
    output reg  [`BANK_GROUP_WIDTH-1:0]  rd_bank_group,
    output reg  [`BANK_WIDTH-1:0]        rd_bank,
    output reg  [`ROW_WIDTH-1:0]         rd_row,
    output reg  [`COLUMN_WIDTH-1:0]      rd_column,
    output reg  [`HIT_TAG_WIDTH-1:0]     rd_hit_tag,
    output reg  [`MISS_TAG_WIDTH-1:0]    rd_miss_tag,
    output reg  [`REQUEST_ID_WIDTH-1:0]  rd_chain_next,
    output reg                           rd_chain_valid,
    
    input  wire                          chain_wr_en,
    input  wire [`REQUEST_ID_WIDTH-1:0]  chain_wr_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]  chain_wr_data,
    
    input  wire                          cam_lookup_en,
    input  wire [`HIT_TAG_WIDTH-1:0]     cam_lookup_tag,
    output reg                           cam_hit,
    output reg  [`REQUEST_ID_WIDTH-1:0]  cam_hit_addr
);

    // Storage
    reg [`BANK_GROUP_WIDTH-1:0]  bank_group_mem [0:MAX_REQUESTS-1];
    reg [`BANK_WIDTH-1:0]        bank_mem       [0:MAX_REQUESTS-1];
    reg [`ROW_WIDTH-1:0]         row_mem        [0:MAX_REQUESTS-1];
    reg [`COLUMN_WIDTH-1:0]      column_mem     [0:MAX_REQUESTS-1];
    reg [`HIT_TAG_WIDTH-1:0]     hit_tag_mem    [0:MAX_REQUESTS-1];
    reg [`MISS_TAG_WIDTH-1:0]    miss_tag_mem   [0:MAX_REQUESTS-1];
    reg [`REQUEST_ID_WIDTH-1:0]  chain_next_mem [0:MAX_REQUESTS-1];
    reg                          chain_valid_mem[0:MAX_REQUESTS-1];
    reg                          valid_mem      [0:MAX_REQUESTS-1];
    
    reg [`REQUEST_ID_WIDTH-1:0] wr_ptr;
    
    // Tags
    wire [`HIT_TAG_WIDTH-1:0]  new_hit_tag  = {req_bank_group, req_bank, req_row};
    wire [`MISS_TAG_WIDTH-1:0] new_miss_tag = {req_bank_group, req_bank};

    assign req_ready = (num_requests < MAX_REQUESTS) && !batch_start;
    
    integer j;
    
    // =============================================================================
    // Consolidated Write Logic
    // =============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            num_requests <= 0;
            for (j = 0; j < MAX_REQUESTS; j = j + 1) begin
                valid_mem[j] <= 0;
                chain_valid_mem[j] <= 0;
                chain_next_mem[j] <= 0;
                bank_group_mem[j] <= 0; bank_mem[j] <= 0; row_mem[j] <= 0; column_mem[j] <= 0;
                hit_tag_mem[j] <= 0; miss_tag_mem[j] <= 0;
            end
        end
        else if (batch_clear) begin
            wr_ptr <= 0;
            num_requests <= 0;
            for (j = 0; j < MAX_REQUESTS; j = j + 1) begin
                valid_mem[j] <= 0;
                chain_valid_mem[j] <= 0;
            end
        end
        else begin
            if (req_valid && req_ready) begin
                bank_group_mem[wr_ptr] <= req_bank_group;
                bank_mem[wr_ptr]       <= req_bank;
                row_mem[wr_ptr]        <= req_row;
                column_mem[wr_ptr]     <= req_column;
                hit_tag_mem[wr_ptr]    <= new_hit_tag;
                miss_tag_mem[wr_ptr]   <= new_miss_tag;
                
                chain_valid_mem[wr_ptr] <= 1'b0;
                valid_mem[wr_ptr]       <= 1'b1;
                
                $display("[REQBUF] Written Req %0d: BG=%0d B=%0d MissTag=0x%h", wr_ptr, req_bank_group, req_bank, new_miss_tag);
                
                wr_ptr <= wr_ptr + 1;
                num_requests <= num_requests + 1;
            end
            
            if (chain_wr_en) begin
                chain_next_mem[chain_wr_addr]  <= chain_wr_data;
                chain_valid_mem[chain_wr_addr] <= 1'b1;
            end
        end
    end
    
    always @(posedge clk) begin
        rd_bank_group  <= bank_group_mem[rd_addr];
        rd_bank        <= bank_mem[rd_addr];
        rd_row         <= row_mem[rd_addr];
        rd_column      <= column_mem[rd_addr];
        rd_hit_tag     <= hit_tag_mem[rd_addr];
        rd_miss_tag    <= miss_tag_mem[rd_addr];
        rd_chain_next  <= chain_next_mem[rd_addr];
        rd_chain_valid <= chain_valid_mem[rd_addr];
    end
    
    reg temp_hit;
    reg [`REQUEST_ID_WIDTH-1:0] temp_addr;
    integer i;
    
    always @(*) begin
        temp_hit = 1'b0;
        temp_addr = 0;
        if (cam_lookup_en) begin
            for (i = 0; i < MAX_REQUESTS; i = i + 1) begin
                if (valid_mem[i] && (hit_tag_mem[i] == cam_lookup_tag)) begin
                    if (temp_hit == 1'b0) begin
                        temp_hit = 1'b1;
                        temp_addr = i[`REQUEST_ID_WIDTH-1:0];
                    end
                end
            end
        end
        cam_hit = temp_hit;
        cam_hit_addr = temp_addr;
    end

endmodule