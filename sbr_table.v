// =============================================================================
// Same Bank Requests (SBR) Table Module
// =============================================================================
// Fixed: Consolidated write logic.
// =============================================================================
`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module sbr_table #(
    parameter MAX_ENTRIES = `MAX_SBR_ENTRIES
) (
    input  wire clk,
    input  wire rst_n,
    
    input  wire                          clear,
    output reg [`SBR_ID_WIDTH-1:0]       num_entries,
    
    input  wire                          wr_en,
    input  wire [`MISS_TAG_WIDTH-1:0]    wr_miss_tag,
    input  wire [`BANK_GROUP_WIDTH-1:0]  wr_bank_group,
    input  wire [`BANK_WIDTH-1:0]        wr_bank,
    input  wire [`SRR_ID_WIDTH-1:0]      wr_head_srr,
    output wire                          wr_full,
    output reg  [`SBR_ID_WIDTH-1:0]      wr_addr,
    
    input  wire                          upd_en,
    input  wire [`SBR_ID_WIDTH-1:0]      upd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]  upd_total_requests,
    input  wire [`SRR_ID_WIDTH-1:0]      upd_row_count,
    input  wire [`SRR_ID_WIDTH-1:0]      upd_tail_srr,
    
    input  wire [`SBR_ID_WIDTH-1:0]      rd_addr,
    output reg  [`MISS_TAG_WIDTH-1:0]    rd_miss_tag,
    output reg  [`BANK_GROUP_WIDTH-1:0]  rd_bank_group,
    output reg  [`BANK_WIDTH-1:0]        rd_bank,
    output reg  [`REQUEST_ID_WIDTH-1:0]  rd_total_requests,
    output reg  [`SRR_ID_WIDTH-1:0]      rd_row_count,
    output reg  [`SRR_ID_WIDTH-1:0]      rd_head_srr,
    output reg  [`SRR_ID_WIDTH-1:0]      rd_tail_srr,
    
    input  wire                          cam_lookup_en,
    input  wire [`MISS_TAG_WIDTH-1:0]    cam_lookup_tag,
    output reg                           cam_hit,
    output reg  [`SBR_ID_WIDTH-1:0]      cam_hit_addr,
    
    input  wire                          find_max_en,
    output reg  [`SBR_ID_WIDTH-1:0]      max_addr,
    output reg  [`REQUEST_ID_WIDTH-1:0]  max_requests
);

    reg [`MISS_TAG_WIDTH-1:0]    miss_tag_mem       [0:MAX_ENTRIES-1];
    reg [`BANK_GROUP_WIDTH-1:0]  bank_group_mem     [0:MAX_ENTRIES-1];
    reg [`BANK_WIDTH-1:0]        bank_mem           [0:MAX_ENTRIES-1];
    reg [`REQUEST_ID_WIDTH-1:0]  total_requests_mem [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]      row_count_mem      [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]      head_srr_mem       [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]      tail_srr_mem       [0:MAX_ENTRIES-1];
    reg                          valid_mem          [0:MAX_ENTRIES-1];
    
    reg [`SBR_ID_WIDTH-1:0] wr_ptr;
    assign wr_full = (num_entries >= MAX_ENTRIES);
    
    integer k;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) begin
                valid_mem[k] <= 0;
                // Init data
                miss_tag_mem[k] <= 0; bank_group_mem[k] <= 0; bank_mem[k] <= 0;
                total_requests_mem[k] <= 0; row_count_mem[k] <= 0;
                head_srr_mem[k] <= 0; tail_srr_mem[k] <= 0;
            end
        end
        else if (clear) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) valid_mem[k] <= 0;
        end
        else begin
            // Case 1: New SBR
            if (wr_en && !wr_full) begin
                miss_tag_mem[wr_ptr]       <= wr_miss_tag;
                bank_group_mem[wr_ptr]     <= wr_bank_group;
                bank_mem[wr_ptr]           <= wr_bank;
                total_requests_mem[wr_ptr] <= 0;
                row_count_mem[wr_ptr]      <= 0;
                head_srr_mem[wr_ptr]       <= wr_head_srr;
                tail_srr_mem[wr_ptr]       <= wr_head_srr; // Init tail to head
                valid_mem[wr_ptr]          <= 1'b1;
                
                wr_addr <= wr_ptr;
                wr_ptr <= wr_ptr + 1;
                num_entries <= num_entries + 1;
            end
            
            // Case 2: Update
            if (upd_en) begin
                total_requests_mem[upd_addr] <= upd_total_requests;
                row_count_mem[upd_addr]      <= upd_row_count;
                tail_srr_mem[upd_addr]       <= upd_tail_srr;
            end
        end
    end
    
    always @(posedge clk) begin
        rd_miss_tag       <= miss_tag_mem[rd_addr];
        rd_bank_group     <= bank_group_mem[rd_addr];
        rd_bank           <= bank_mem[rd_addr];
        rd_total_requests <= total_requests_mem[rd_addr];
        rd_row_count      <= row_count_mem[rd_addr];
        rd_head_srr       <= head_srr_mem[rd_addr];
        rd_tail_srr       <= tail_srr_mem[rd_addr];
    end
    
    reg temp_hit;
    reg [`SBR_ID_WIDTH-1:0] temp_addr;
    integer i;
    always @(*) begin
        temp_hit = 1'b0;
        temp_addr = 0;
        if (cam_lookup_en) begin
            for (i = 0; i < MAX_ENTRIES; i = i + 1) begin
                if (valid_mem[i] && (miss_tag_mem[i] == cam_lookup_tag)) begin
                    if (temp_hit == 1'b0) begin
                        temp_hit = 1'b1;
                        temp_addr = i[`SBR_ID_WIDTH-1:0];
                    end
                end
            end
        end
        cam_hit = temp_hit;
        cam_hit_addr = temp_addr;
    end
    
    integer j;
    always @(*) begin
        max_addr = 0;
        max_requests = 0;
        if (find_max_en) begin
            for (j = 0; j < MAX_ENTRIES; j = j + 1) begin
                if (valid_mem[j] && (total_requests_mem[j] > max_requests)) begin
                    max_requests = total_requests_mem[j];
                    max_addr = j[`SBR_ID_WIDTH-1:0];
                end
            end
        end
    end

endmodule