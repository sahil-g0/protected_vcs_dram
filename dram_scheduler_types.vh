// =============================================================================
// DRAM Scheduler Types and Parameters
// =============================================================================

`ifndef DRAM_SCHEDULER_TYPES_VH
`define DRAM_SCHEDULER_TYPES_VH

// -----------------------------------------------------------------------------
// Dimensions and Sizes
// -----------------------------------------------------------------------------
`define BANK_GROUP_WIDTH    2
`define BANK_WIDTH          2
`define ROW_WIDTH           18
`define COLUMN_WIDTH        10
`define REQUEST_ID_WIDTH    6   // Up to 64 requests
`define CYCLE_WIDTH         32  // Timestamp width

`define NUM_BANK_GROUPS     (1 << `BANK_GROUP_WIDTH)
`define NUM_BANKS_PER_GROUP (1 << `BANK_WIDTH)
`define TOTAL_BANKS         (`NUM_BANK_GROUPS * `NUM_BANKS_PER_GROUP)

`define MAX_REQUESTS        64
`define MAX_SRR_ENTRIES     32
`define MAX_SBR_ENTRIES     16
`define MAX_SCHEDULE_CYCLES 2048

// Derived ID widths
`define SRR_ID_WIDTH        $clog2(`MAX_SRR_ENTRIES)
`define SBR_ID_WIDTH        $clog2(`MAX_SBR_ENTRIES)

// Tag Widths
`define HIT_TAG_WIDTH       (`BANK_GROUP_WIDTH + `BANK_WIDTH + `ROW_WIDTH)
`define MISS_TAG_WIDTH      (`BANK_GROUP_WIDTH + `BANK_WIDTH)

// -----------------------------------------------------------------------------
// Command Encoding
// -----------------------------------------------------------------------------
`define CMD_DESELECT        3'b000
`define CMD_ACT             3'b001
`define CMD_RD              3'b010
`define CMD_WR              3'b011
`define CMD_PRE             3'b100
`define CMD_REF             3'b101

// -----------------------------------------------------------------------------
// DRAM Timing Parameters (in clock cycles)
// Standard DDR4-2400-ish values for demonstration
// -----------------------------------------------------------------------------
`define T_RCD               14  // ACT to READ/WRITE
`define T_CL                14  // CAS Latency
`define T_RP                14  // Precharge time
`define T_RAS               32  // Active to Precharge
`define T_RC                46  // Active to Active (same bank) = T_RAS + T_RP
`define T_RRD_L             4   // Active to Active (same BG)
`define T_RRD_S             4   // Active to Active (diff BG)
`define T_CCD_L             7   // CAS to CAS (same BG)
`define T_CCD_S             4   // CAS to CAS (diff BG)
`define T_RTP               8   // Read to Precharge
`define T_BURST             4   // Data burst duration

// -----------------------------------------------------------------------------
// State Machine States
// -----------------------------------------------------------------------------
`define BATCH_IDLE           3'd0
`define BATCH_PROCESS_REQS   3'd1
`define BATCH_BUILD_SBR      3'd2
`define BATCH_FIND_CRITICAL  3'd3
`define BATCH_DONE           3'd4

`define SCHED_IDLE           4'd0
`define SCHED_LOAD_SBR       4'd1
`define SCHED_LOAD_SRR       4'd2
`define SCHED_CHECK_STATE    4'd3
`define SCHED_EMIT_PRE       4'd4
`define SCHED_EMIT_ACT       4'd5
`define SCHED_REQ_LOOP_RD    4'd6
`define SCHED_WAIT_REQ_DATA  4'd7
`define SCHED_EMIT_RD        4'd8
`define SCHED_NEXT_SRR       4'd9
`define SCHED_NEXT_SBR       4'd10
`define SCHED_DONE           4'd11

`endif // DRAM_SCHEDULER_TYPES_VH