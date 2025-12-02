`ifndef DRAM_TIMINGS_VH
`define DRAM_TIMINGS_VH

//////////////////////////////////////////////////////////////////////////////////
// DRAM Timing Parameters and Constants
// DDR4-2133 (1066 MHz, 0.938ns cycle time)
//////////////////////////////////////////////////////////////////////////////////

// ================================================================
// DRAM Geometry Parameters
// ================================================================
parameter NUM_BG     = 4;              // Bank groups
parameter NUM_BANKS  = 4 * NUM_BG;     // Total banks (16)
parameter ROW_WIDTH  = 14;
parameter COL_WIDTH  = 8;

// Width of extracted fields
parameter BG_W       = 2;              // Bank group width
parameter BANK_W     = 2;              // Bank width (4 banks per group)
parameter ROW_W      = 14;
parameter COL_W      = 8;

// ================================================================
// DRAM Address Bit Layout
// ----------------------------------------------------------------
// [31:30]  unused
// [29:16]  row       (14 bits)
// [15:14]  bank group (2 bits)
// [13:12]  bank       (2 bits)
// [11:4]   column     (8 bits)
// [3:2]    word offset
// [1:0]    byte offset
// ================================================================

// Byte offset (2 bits)
parameter BYTE_LSB = 0;
parameter BYTE_MSB = BYTE_LSB + 1;

// Word offset (2 bits)
parameter WORD_LSB = 2;
parameter WORD_MSB = WORD_LSB + 1;

// Column field
parameter COL_LSB  = 4;
parameter COL_MSB  = COL_LSB + COL_W - 1;

// Bank field
parameter BANK_LSB = COL_MSB + 1;              
parameter BANK_MSB = BANK_LSB + BANK_W - 1;

// Bank group field
parameter BG_LSB   = BANK_MSB + 1;
parameter BG_MSB   = BG_LSB + BG_W - 1;

// Row field
parameter ROW_LSB  = BG_MSB + 1;
parameter ROW_MSB  = ROW_LSB + ROW_W - 1;

// ================================================================
// Core Timing Parameters (in clock cycles)
// ================================================================

// === Read Latency ===
parameter tCL       = 14;   // CAS Latency: READ command to data out
parameter tCWL      = 10;   // CAS Write Latency: WRITE command to data in

// === Row Access ===
parameter tRCD      = 14;   // RAS to CAS Delay: ACT to READ/WRITE
parameter tRP       = 14;   // Row Precharge time: PRE to ACT
parameter tRAS      = 28;   // Row Active time: ACT to PRE (minimum)
parameter tRC       = 42;   // Row Cycle time: ACT to ACT (same bank) = tRAS + tRP

// === Precharge and Write Recovery ===
parameter tRTP      = 8;    // Read to Precharge: READ to PRE
parameter tWR       = 15;   // Write Recovery: WRITE to PRE
parameter tWTR_S    = 3;    // Write to Read (same bank group)
parameter tWTR_L    = 8;    // Write to Read (different bank group)

// === Bank-to-Bank (Activate) ===
parameter tRRD_S    = 4;    // ACT to ACT (same bank group, different bank)
parameter tRRD_L    = 4;    // ACT to ACT (different bank group)
parameter tFAW      = 16;   // Four Activate Window (max 4 ACT in window)

// === Bank-to-Bank (Read/Write) ===
parameter tCCD_S    = 7;    // CAS to CAS (same bank group) - READ to READ same group
parameter tCCD_L    = 4;    // CAS to CAS (different bank group) - READ to READ different group

// === Read-to-Read (alternative naming) ===
parameter tRDRD_sg  = tCCD_S;  // READ to READ (same bank group)
parameter tRDRD_dg  = tCCD_L;  // READ to READ (different bank group)

// === Write-to-Write ===
parameter tWRWR_sg  = tCCD_S;  // WRITE to WRITE (same bank group)
parameter tWRWR_dg  = tCCD_L;  // WRITE to WRITE (different bank group)

// === Read-to-Write ===
parameter tRTW      = (tCL + tCCD_S + 2 - tCWL);  // READ to WRITE

// === Refresh ===
parameter tRFC      = 160;  // Refresh Cycle time
parameter tREFI     = 3120; // Refresh Interval (7.8us @ 1066MHz)

// === Other ===
parameter CR        = 1;    // Command Rate (minimum cycles between commands)
parameter tXS       = 170;  // Exit Self-Refresh to non-read command

// ================================================================
// DRAM Command Enum
// ================================================================
typedef enum logic [2:0] {
    CMD_NOP = 3'd0,
    CMD_PRE = 3'd1,
    CMD_ACT = 3'd2,
    CMD_RD  = 3'd3,
    CMD_WR  = 3'd4,
    CMD_REF = 3'd5    // Refresh command
} cmd_t;

// ================================================================
// DRAM Request Struct (decoded address + rw)
// ================================================================
typedef struct packed {
    logic [BG_W-1:0]   bg;          // bank group
    logic [BANK_W-1:0] bank;        // bank #
    logic [ROW_W-1:0]  row;         // row
    logic [COL_W-1:0]  col;         // column
    logic              rw;          // 0 = read, 1 = write
} dram_req_t;

// ================================================================
// Per-Bank State Struct
// ================================================================
typedef struct packed {
    logic              is_open;     // 1 if row is active
    logic [ROW_W-1:0]  open_row;    // which row is open

    // Timing counters (decrement each cycle, 0 = ready)
    logic [7:0] t_can_pre;          // PRE allowed
    logic [7:0] t_can_act;          // ACT allowed
    logic [7:0] t_can_rd;           // READ allowed
    logic [7:0] t_can_wr;           // WRITE allowed
} bank_state_t;

`endif // DRAM_TIMINGS_VH
