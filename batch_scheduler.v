// =============================================================================
// Batch Scheduler Controller
// =============================================================================
// Implements the critical path algorithm.
// Fixed: Added wait states in SBR Build loop to fix Read-After-Write hazards.
// =============================================================================
`timescale 1ns/1ps
`include "dram_scheduler_types.vh"

module batch_scheduler (
    input  wire clk,
    input  wire rst_n,
    
    input  wire                            start,
    output reg                             done,
    output reg                             busy,
    
    // Request Buffer
    input  wire [`REQUEST_ID_WIDTH-1:0]    num_requests,
    output reg  [`REQUEST_ID_WIDTH-1:0]    req_rd_addr,
    input  wire [`HIT_TAG_WIDTH-1:0]       req_rd_hit_tag,
    input  wire [`MISS_TAG_WIDTH-1:0]      req_rd_miss_tag,
    input  wire [`BANK_GROUP_WIDTH-1:0]    req_rd_bank_group,
    input  wire [`BANK_WIDTH-1:0]          req_rd_bank,
    input  wire [`ROW_WIDTH-1:0]           req_rd_row,
    output reg                             req_chain_wr_en,
    output reg  [`REQUEST_ID_WIDTH-1:0]    req_chain_wr_addr,
    output reg  [`REQUEST_ID_WIDTH-1:0]    req_chain_wr_data,
    
    // SRR Table
    output reg                             srr_wr_en,
    output reg  [`HIT_TAG_WIDTH-1:0]       srr_wr_hit_tag,
    output reg  [`REQUEST_ID_WIDTH-1:0]    srr_wr_head_req,
    input  wire [`SRR_ID_WIDTH-1:0]        srr_wr_addr,
    input  wire                            srr_wr_full,
    output reg                             srr_upd_en,
    output reg  [`SRR_ID_WIDTH-1:0]        srr_upd_addr,
    output reg  [`REQUEST_ID_WIDTH-1:0]    srr_upd_count,
    output reg  [`REQUEST_ID_WIDTH-1:0]    srr_upd_tail_req,
    output reg                             srr_cam_lookup_en,
    output reg  [`HIT_TAG_WIDTH-1:0]       srr_cam_lookup_tag,
    input  wire                            srr_cam_hit,
    input  wire [`SRR_ID_WIDTH-1:0]        srr_cam_hit_addr,
    output reg  [`SRR_ID_WIDTH-1:0]        srr_rd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]    srr_rd_count,
    input  wire [`REQUEST_ID_WIDTH-1:0]    srr_rd_head_req,
    input  wire [`REQUEST_ID_WIDTH-1:0]    srr_rd_tail_req,
    input  wire [`MISS_TAG_WIDTH-1:0]      srr_rd_miss_tag,
    output reg                             srr_chain_wr_en,
    output reg  [`SRR_ID_WIDTH-1:0]        srr_chain_wr_addr,
    output reg  [`SRR_ID_WIDTH-1:0]        srr_chain_wr_data,
    input  wire [`SRR_ID_WIDTH-1:0]        srr_num_entries,
    
    // SBR Table
    output reg                             sbr_wr_en,
    output reg  [`MISS_TAG_WIDTH-1:0]      sbr_wr_miss_tag,
    output reg  [`BANK_GROUP_WIDTH-1:0]    sbr_wr_bank_group,
    output reg  [`BANK_WIDTH-1:0]          sbr_wr_bank,
    output reg  [`SRR_ID_WIDTH-1:0]        sbr_wr_head_srr,
    input  wire [`SBR_ID_WIDTH-1:0]        sbr_wr_addr,
    input  wire                            sbr_wr_full,
    output reg                             sbr_upd_en,
    output reg  [`SBR_ID_WIDTH-1:0]        sbr_upd_addr,
    output reg  [`REQUEST_ID_WIDTH-1:0]    sbr_upd_total_requests,
    output reg  [`SRR_ID_WIDTH-1:0]        sbr_upd_row_count,
    output reg  [`SRR_ID_WIDTH-1:0]        sbr_upd_tail_srr,
    output reg                             sbr_cam_lookup_en,
    output reg  [`MISS_TAG_WIDTH-1:0]      sbr_cam_lookup_tag,
    input  wire                            sbr_cam_hit,
    input  wire [`SBR_ID_WIDTH-1:0]        sbr_cam_hit_addr,
    output reg  [`SBR_ID_WIDTH-1:0]        sbr_rd_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]    sbr_rd_total_requests,
    input  wire [`SRR_ID_WIDTH-1:0]        sbr_rd_row_count,
    input  wire [`SRR_ID_WIDTH-1:0]        sbr_rd_tail_srr,
    output reg                             sbr_find_max_en,
    input  wire [`SBR_ID_WIDTH-1:0]        sbr_max_addr,
    input  wire [`REQUEST_ID_WIDTH-1:0]    sbr_max_requests,
    
    output reg  [`SBR_ID_WIDTH-1:0]        critical_path_sbr
);

    reg [2:0] state;
    reg [2:0] next_state;
    
    reg [`REQUEST_ID_WIDTH-1:0] req_idx;
    reg [`SRR_ID_WIDTH-1:0]     srr_alloc_ptr; 
    reg [`SRR_ID_WIDTH-1:0]     srr_iter;
    reg [`SBR_ID_WIDTH-1:0]     sbr_alloc_ptr; 
    
    reg [`HIT_TAG_WIDTH-1:0]    current_hit_tag;
    reg [`MISS_TAG_WIDTH-1:0]   current_miss_tag;
    reg [`SRR_ID_WIDTH-1:0]     current_srr_addr;
    reg [`SBR_ID_WIDTH-1:0]     current_sbr_addr;
    reg                         is_new_sbr;
    reg [3:0]                   delay_counter; 
    
    always @(*) begin
        next_state = state;
        case (state)
            `BATCH_IDLE:          if (start) next_state = `BATCH_PROCESS_REQS;
            `BATCH_PROCESS_REQS:  if (req_idx >= num_requests) next_state = `BATCH_BUILD_SBR;
            `BATCH_BUILD_SBR:     if (srr_iter >= srr_num_entries) next_state = `BATCH_FIND_CRITICAL;
            `BATCH_FIND_CRITICAL: if (delay_counter == 2) next_state = `BATCH_DONE;
            `BATCH_DONE:          next_state = `BATCH_IDLE;
            default:              next_state = `BATCH_IDLE;
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= `BATCH_IDLE;
        else state <= next_state;
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0; done <= 0;
        end else begin
            busy <= (state != `BATCH_IDLE);
            done <= (state == `BATCH_DONE);
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_idx <= 0; srr_alloc_ptr <= 0; srr_iter <= 0; sbr_alloc_ptr <= 0; delay_counter <= 0; is_new_sbr <= 0;
            req_rd_addr <= 0; req_chain_wr_en <= 0; req_chain_wr_addr <= 0; req_chain_wr_data <= 0;
            srr_wr_en <= 0; srr_wr_hit_tag <= 0; srr_wr_head_req <= 0;
            srr_upd_en <= 0; srr_upd_addr <= 0; srr_upd_count <= 0; srr_upd_tail_req <= 0;
            srr_cam_lookup_en <= 0; srr_cam_lookup_tag <= 0; srr_rd_addr <= 0;
            srr_chain_wr_en <= 0; srr_chain_wr_addr <= 0; srr_chain_wr_data <= 0;
            sbr_wr_en <= 0; sbr_wr_miss_tag <= 0; sbr_wr_bank_group <= 0; sbr_wr_bank <= 0; sbr_wr_head_srr <= 0;
            sbr_upd_en <= 0; sbr_upd_addr <= 0; sbr_upd_total_requests <= 0; sbr_upd_row_count <= 0; sbr_upd_tail_srr <= 0;
            sbr_cam_lookup_en <= 0; sbr_cam_lookup_tag <= 0; sbr_rd_addr <= 0; sbr_find_max_en <= 0;
            critical_path_sbr <= 0;
            current_hit_tag <= 0; current_miss_tag <= 0; current_srr_addr <= 0; current_sbr_addr <= 0;
        end
        else begin
            req_chain_wr_en <= 0; srr_wr_en <= 0; srr_upd_en <= 0; srr_chain_wr_en <= 0; sbr_wr_en <= 0; sbr_upd_en <= 0;
            
            case (state)
                `BATCH_IDLE: begin
                    if (start) begin
                        req_idx <= 0; srr_alloc_ptr <= 0; srr_iter <= 0; sbr_alloc_ptr <= 0; delay_counter <= 0;
                    end
                end
                
                `BATCH_PROCESS_REQS: begin
                    if (delay_counter == 0) begin
                        req_rd_addr <= req_idx;
                        delay_counter <= 1;
                    end else if (delay_counter == 1) delay_counter <= 2;
                    else if (delay_counter == 2) begin
                        srr_cam_lookup_en <= 1'b1;
                        srr_cam_lookup_tag <= req_rd_hit_tag;
                        current_hit_tag <= req_rd_hit_tag;
                        current_miss_tag <= req_rd_miss_tag;
                        delay_counter <= 3;
                    end else if (delay_counter == 3) begin
                        srr_cam_lookup_en <= 1'b0;
                        if (srr_cam_hit) begin
                            current_srr_addr <= srr_cam_hit_addr;
                            srr_rd_addr <= srr_cam_hit_addr;
                            delay_counter <= 4;
                        end else begin
                            $display("[BATCH] New SRR %0d for Req %0d. HitTag=0x%h", srr_alloc_ptr, req_idx, current_hit_tag);
                            srr_wr_en <= 1'b1;
                            srr_wr_hit_tag <= current_hit_tag;
                            srr_wr_head_req <= req_idx;
                            srr_alloc_ptr <= srr_alloc_ptr + 1;
                            req_idx <= req_idx + 1;
                            delay_counter <= 0;
                        end
                    end else if (delay_counter == 4) delay_counter <= 5;
                    else if (delay_counter == 5) begin
                        $display("[BATCH] Chaining Req %0d to Prev Req %0d in SRR %0d", req_idx, srr_rd_tail_req, current_srr_addr);
                        req_chain_wr_en <= 1'b1;
                        req_chain_wr_addr <= srr_rd_tail_req;
                        req_chain_wr_data <= req_idx;
                        srr_upd_en <= 1'b1;
                        srr_upd_addr <= current_srr_addr;
                        srr_upd_count <= srr_rd_count + 1;
                        srr_upd_tail_req <= req_idx;
                        req_idx <= req_idx + 1;
                        delay_counter <= 0;
                    end
                end
                
                `BATCH_BUILD_SBR: begin
                    if (delay_counter == 0) begin
                        srr_rd_addr <= srr_iter;
                        delay_counter <= 1;
                    end else if (delay_counter == 1) delay_counter <= 2;
                    else if (delay_counter == 2) begin
                        req_rd_addr <= srr_rd_head_req;
                        $display("[BATCH] Processing SRR %0d. Head Req: %0d", srr_iter, srr_rd_head_req);
                        delay_counter <= 3;
                    end else if (delay_counter == 3) delay_counter <= 4;
                    else if (delay_counter == 4) begin
                        sbr_cam_lookup_en <= 1'b1;
                        sbr_cam_lookup_tag <= req_rd_miss_tag;
                        current_miss_tag <= req_rd_miss_tag;
                        $display("[BATCH] Req %0d MissTag=0x%h", req_rd_addr, req_rd_miss_tag);
                        delay_counter <= 5;
                    end else if (delay_counter == 5) begin
                        sbr_cam_lookup_en <= 1'b0;
                        if (sbr_cam_hit) begin
                            current_sbr_addr <= sbr_cam_hit_addr;
                            sbr_rd_addr <= sbr_cam_hit_addr;
                            is_new_sbr <= 0;
                            delay_counter <= 6; 
                        end else begin
                            $display("[BATCH] New SBR %0d for SRR %0d. MissTag=0x%h", sbr_alloc_ptr, srr_iter, current_miss_tag);
                            sbr_wr_en <= 1'b1;
                            sbr_wr_miss_tag <= current_miss_tag;
                            sbr_wr_bank_group <= req_rd_bank_group;
                            sbr_wr_bank <= req_rd_bank;
                            sbr_wr_head_srr <= srr_iter;
                            current_sbr_addr <= sbr_alloc_ptr;
                            sbr_alloc_ptr <= sbr_alloc_ptr + 1;
                            is_new_sbr <= 1;
                            delay_counter <= 8; 
                        end
                    end else if (delay_counter == 6) delay_counter <= 7;
                    else if (delay_counter == 7) begin
                        $display("[BATCH] Chaining SRR %0d to Prev SRR %0d in SBR %0d", srr_iter, sbr_rd_tail_srr, current_sbr_addr);
                        srr_chain_wr_en <= 1'b1;
                        srr_chain_wr_addr <= sbr_rd_tail_srr;
                        srr_chain_wr_data <= srr_iter;
                        srr_rd_addr <= srr_iter;
                        delay_counter <= 8;
                    end else if (delay_counter == 8) begin
                        sbr_upd_en <= 1'b1;
                        sbr_upd_addr <= current_sbr_addr;
                        sbr_upd_tail_srr <= srr_iter;
                        if (is_new_sbr) begin
                            sbr_upd_total_requests <= srr_rd_count;
                            sbr_upd_row_count <= 1;
                        end else begin
                            sbr_upd_total_requests <= sbr_rd_total_requests + srr_rd_count;
                            sbr_upd_row_count <= sbr_rd_row_count + 1;
                        end
                        srr_iter <= srr_iter + 1;
                        delay_counter <= 0;
                    end
                end
                
                `BATCH_FIND_CRITICAL: begin
                    if (delay_counter == 0) begin
                        sbr_find_max_en <= 1'b1;
                        delay_counter <= 1;
                    end else if (delay_counter == 1) begin
                        critical_path_sbr <= sbr_max_addr;
                        sbr_find_max_en <= 1'b0;
                        delay_counter <= 2;
                    end
                end
                
                `BATCH_DONE: begin end
            endcase
        end
    end
endmodule