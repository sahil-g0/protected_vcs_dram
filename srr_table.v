// =============================================================================
// Same Row Requests (SRR) Table Module
// =============================================================================
// Fixed: Consolidated write logic.
// =============================================================================
`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module srr_table #(
    parameter MAX_ENTRIES = `MAX_SRR_ENTRIES
) (
    input  wire clk,
    input  wire rst_n,
    
    input  wire                          clear,
    output reg [`SRR_ID_WIDTH-1:0]       num_entries,
    
    input  wire                          wr_en,
    input  wire [`HIT_TAG_WIDTH-1:0]     wr_hit_tag,
    input  wire [`REQUEST_ID_WIDTH-1:0]  wr_head_req,
    output wire                          wr_full,
    output reg  [`SRR_ID_WIDTH-1:0]      wr_addr,
    
    input  wire                          upd_en,
    input  wire [`SRR_ID_WIDTH-1:0]      upd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]  upd_count,
    input  wire [`REQUEST_ID_WIDTH-1:0]  upd_tail_req,
    
    input  wire                          chain_wr_en,
    input  wire [`SRR_ID_WIDTH-1:0]      chain_wr_addr,
    input  wire [`SRR_ID_WIDTH-1:0]      chain_wr_data,
    
    input  wire [`SRR_ID_WIDTH-1:0]      rd_addr,
    output reg  [`HIT_TAG_WIDTH-1:0]     rd_hit_tag,
    output reg  [`REQUEST_ID_WIDTH-1:0]  rd_count,
    output reg  [`REQUEST_ID_WIDTH-1:0]  rd_head_req,
    output reg  [`REQUEST_ID_WIDTH-1:0]  rd_tail_req,
    output reg  [`SRR_ID_WIDTH-1:0]      rd_chain_next,
    output reg                           rd_chain_valid,
    
    input  wire                          cam_lookup_en,
    input  wire [`HIT_TAG_WIDTH-1:0]     cam_lookup_tag,
    output reg                           cam_hit,
    output reg  [`SRR_ID_WIDTH-1:0]      cam_hit_addr
);

    reg [`HIT_TAG_WIDTH-1:0]    hit_tag_mem    [0:MAX_ENTRIES-1];
    reg [`REQUEST_ID_WIDTH-1:0] count_mem      [0:MAX_ENTRIES-1];
    reg [`REQUEST_ID_WIDTH-1:0] head_req_mem   [0:MAX_ENTRIES-1];
    reg [`REQUEST_ID_WIDTH-1:0] tail_req_mem   [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]     chain_next_mem [0:MAX_ENTRIES-1];
    reg                         chain_valid_mem[0:MAX_ENTRIES-1];
    reg                         valid_mem      [0:MAX_ENTRIES-1];
    
    reg [`SRR_ID_WIDTH-1:0] wr_ptr;
    assign wr_full = (num_entries >= MAX_ENTRIES);
    
    integer k;
    
    // Consolidated Write Block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) begin
                valid_mem[k] <= 0;
                chain_valid_mem[k] <= 0;
                hit_tag_mem[k] <= 0; count_mem[k] <= 0; head_req_mem[k] <= 0; tail_req_mem[k] <= 0; chain_next_mem[k] <= 0;
            end
        end
        else if (clear) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) valid_mem[k] <= 0;
        end
        else begin
            // Case 1: New Entry
            if (wr_en && !wr_full) begin
                hit_tag_mem[wr_ptr]     <= wr_hit_tag;
                count_mem[wr_ptr]       <= 1;
                head_req_mem[wr_ptr]    <= wr_head_req;
                tail_req_mem[wr_ptr]    <= wr_head_req;
                chain_valid_mem[wr_ptr] <= 1'b0; // Init
                valid_mem[wr_ptr]       <= 1'b1;
                
                wr_addr <= wr_ptr;
                wr_ptr <= wr_ptr + 1;
                num_entries <= num_entries + 1;
            end
            
            // Case 2: Update Existing Entry
            if (upd_en) begin
                count_mem[upd_addr]    <= upd_count;
                tail_req_mem[upd_addr] <= upd_tail_req;
            end
            
            // Case 3: Chain Link Update
            if (chain_wr_en) begin
                chain_next_mem[chain_wr_addr]  <= chain_wr_data;
                chain_valid_mem[chain_wr_addr] <= 1'b1;
            end
        end
    end
    
    always @(posedge clk) begin
        rd_hit_tag      <= hit_tag_mem[rd_addr];
        rd_count        <= count_mem[rd_addr];
        rd_head_req     <= head_req_mem[rd_addr];
        rd_tail_req     <= tail_req_mem[rd_addr];
        rd_chain_next   <= chain_next_mem[rd_addr];
        rd_chain_valid  <= chain_valid_mem[rd_addr];
    end
    
    reg temp_hit;
    reg [`SRR_ID_WIDTH-1:0] temp_addr;
    integer i;
    always @(*) begin
        temp_hit = 1'b0;
        temp_addr = 0;
        if (cam_lookup_en) begin
            for (i = 0; i < MAX_ENTRIES; i = i + 1) begin
                if (valid_mem[i] && (hit_tag_mem[i] == cam_lookup_tag)) begin
                    if (temp_hit == 1'b0) begin 
                        temp_hit = 1'b1;
                        temp_addr = i[`SRR_ID_WIDTH-1:0];
                    end
                end
            end
        end
        cam_hit = temp_hit;
        cam_hit_addr = temp_addr;
    end

endmodule