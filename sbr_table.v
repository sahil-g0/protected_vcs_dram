// =============================================================================
// Same Bank Requests (SBR) Table Module
// =============================================================================
// CAM structure that stores chains of SRR entries for the same bank.
// Each entry represents a unique (bank_group, bank) combination.
// Used to identify the critical path (bank with most requests).
// =============================================================================
`timescale 1ns/1ps //
`include "dram_scheduler_types.vh"

module sbr_table #(
    parameter MAX_ENTRIES = `MAX_SBR_ENTRIES
) (
    input wire clk,
    input wire rst_n,
    
    // Control
    input wire              clear,
    output reg [`SBR_ID_WIDTH-1:0]     num_entries,
    
    // Write interface - add new SBR entry
    input wire              wr_en,
    input wire [`MISS_TAG_WIDTH-1:0]   wr_miss_tag,
    input wire [`BANK_GROUP_WIDTH-1:0]  wr_bank_group,
    input wire [`BANK_WIDTH-1:0]     wr_bank,
    input wire [`SRR_ID_WIDTH-1:0]    wr_head_srr,
    output wire              wr_full,
    output reg [`SBR_ID_WIDTH-1:0]    wr_addr,
    
    // Update interface - update counts and tail
    input wire              upd_en,
    input wire [`SBR_ID_WIDTH-1:0]    upd_addr,
    input wire [`REQUEST_ID_WIDTH-1:0]  upd_total_requests,
    input wire [`SRR_ID_WIDTH-1:0]    upd_row_count,
    input wire [`SRR_ID_WIDTH-1:0]    upd_tail_srr,
    
    // Read interface (indexed)
    input wire [`SBR_ID_WIDTH-1:0]    rd_addr,
    output reg [`MISS_TAG_WIDTH-1:0]   rd_miss_tag,
    output reg [`BANK_GROUP_WIDTH-1:0]  rd_bank_group,
    output reg [`BANK_WIDTH-1:0]     rd_bank,
    output reg [`REQUEST_ID_WIDTH-1:0]  rd_total_requests,
    output reg [`SRR_ID_WIDTH-1:0]    rd_row_count,
    output reg [`SRR_ID_WIDTH-1:0]    rd_head_srr,
    output reg [`SRR_ID_WIDTH-1:0]    rd_tail_srr,
    
    // CAM lookup interface
    input wire              cam_lookup_en,
    input wire [`MISS_TAG_WIDTH-1:0]   cam_lookup_tag,
    output reg               cam_hit,
    output reg [`SBR_ID_WIDTH-1:0]    cam_hit_addr,
    
    // Critical path finding - find entry with max requests
    input wire              find_max_en,
    output reg [`SBR_ID_WIDTH-1:0]    max_addr,
    output reg [`REQUEST_ID_WIDTH-1:0]  max_requests
);

    // =============================================================================
    // Internal Storage
    // =============================================================================
    reg [`MISS_TAG_WIDTH-1:0]   miss_tag_mem    [0:MAX_ENTRIES-1];
    reg [`BANK_GROUP_WIDTH-1:0]  bank_group_mem   [0:MAX_ENTRIES-1];
    reg [`BANK_WIDTH-1:0]     bank_mem      [0:MAX_ENTRIES-1];
    reg [`REQUEST_ID_WIDTH-1:0]  total_requests_mem [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]    row_count_mem   [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]    head_srr_mem    [0:MAX_ENTRIES-1];
    reg [`SRR_ID_WIDTH-1:0]    tail_srr_mem    [0:MAX_ENTRIES-1];
    reg              valid_mem     [0:MAX_ENTRIES-1];
    
    reg [`SBR_ID_WIDTH-1:0] wr_ptr;
    
    assign wr_full = (num_entries >= MAX_ENTRIES);
    
    // =============================================================================
    // Write Logic - Add New SBR Entry
    // =============================================================================
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) begin
                valid_mem[k] <= 0;
                head_srr_mem[k] <= 0; // Initialize
                total_requests_mem[k] <= 0;
            end
        end
        else if (clear) begin
            wr_ptr <= 0;
            num_entries <= 0;
            wr_addr <= 0;
            for (k=0; k<MAX_ENTRIES; k=k+1) begin
                valid_mem[k] <= 0;
            end
        end
        else if (wr_en && !wr_full) begin
            miss_tag_mem[wr_ptr]    <= wr_miss_tag;
            bank_group_mem[wr_ptr]   <= wr_bank_group;
            bank_mem[wr_ptr]      <= wr_bank;
            total_requests_mem[wr_ptr] <= 0; // Will be updated
            row_count_mem[wr_ptr]   <= 0; // Will be updated
            head_srr_mem[wr_ptr]    <= wr_head_srr;
            tail_srr_mem[wr_ptr]    <= wr_head_srr;
            valid_mem[wr_ptr]     <= 1'b1;
            
            wr_addr <= wr_ptr;
            wr_ptr <= wr_ptr + 1;
            num_entries <= num_entries + 1;
        end
    end
    
    // =============================================================================
    // Update Logic
    // =============================================================================
    always @(posedge clk) begin
        if (upd_en) begin
            total_requests_mem[upd_addr] <= upd_total_requests;
            row_count_mem[upd_addr]   <= upd_row_count;
            tail_srr_mem[upd_addr]    <= upd_tail_srr;
        end
    end
    
    // =============================================================================
    // Read Logic
    // =============================================================================
    always @(posedge clk) begin
        rd_miss_tag    <= miss_tag_mem[rd_addr];
        rd_bank_group   <= bank_group_mem[rd_addr];
        rd_bank      <= bank_mem[rd_addr];
        rd_total_requests <= total_requests_mem[rd_addr];
        rd_row_count    <= row_count_mem[rd_addr];
        rd_head_srr    <= head_srr_mem[rd_addr];
        rd_tail_srr    <= tail_srr_mem[rd_addr];
    end
    
    // =============================================================================
    // CAM Lookup Logic (FIXED: Added priority encoding)
    // =============================================================================
    integer i;
    // Temporary registers for priority encoding
    reg temp_hit;
    reg [`SBR_ID_WIDTH-1:0] temp_addr;
    
    always @(*) begin
        // Initialize temporary registers
        temp_hit = 1'b0;
        temp_addr = 0;
        
        if (cam_lookup_en) begin
            // Iterate from the lowest address (oldest/first available entry)
            for (i = 0; i < MAX_ENTRIES; i = i + 1) begin
                if (valid_mem[i] && (miss_tag_mem[i] == cam_lookup_tag)) begin
                    // Priority encoding: Only register the hit if no hit was found previously.
                    // This ensures the match at the lowest address wins.
                    if (temp_hit == 1'b0) begin
                        temp_hit = 1'b1;
                        temp_addr = i[`SBR_ID_WIDTH-1:0];
                    end
                end
            end
        end
        
        // Assign prioritized result to output ports
        cam_hit = temp_hit;
        cam_hit_addr = temp_addr;
    end
    
    // =============================================================================
    // Find Maximum (Critical Path)
    // =============================================================================
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