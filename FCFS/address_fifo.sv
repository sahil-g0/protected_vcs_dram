`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// DRAM Request FIFO
// Stores address, write data, and read/write flag
// Data format: {r_w (1 bit), write_data (32 bits), address (32 bits)} = 65 bits
//////////////////////////////////////////////////////////////////////////////////

module instruction_fifo(
    input CLK,
    input PUSH,
    input [31:0] ADDRESS,
    input [31:0] WRITE_DATA,
    input R_W,              // 0 = read, 1 = write
    input RESET,
    input POP,
    
    output [31:0] ADDRESS_OUT,
    output [31:0] WRITE_DATA_OUT,
    output R_W_OUT,
    output EMPTY,
    output FULL,
    output ALMOST_FULL
    );
    
    // Store packed data: {r_w, write_data, address}
    reg [64:0] queue [0:63];
    reg [6:0] write_ptr;    // Extra bit for empty/full checking 
    reg [6:0] read_ptr;
    
    wire [6:0] next_write_ptr = write_ptr + 1;
    
    // Status signals
    assign EMPTY = (write_ptr == read_ptr);
    assign FULL = (write_ptr[5:0] == read_ptr[5:0]) && (write_ptr[6] != read_ptr[6]);
    assign ALMOST_FULL = (next_write_ptr[5:0] == read_ptr[5:0]) && (next_write_ptr[6] != read_ptr[6]);
    
    // Control signals
    wire write_en = PUSH && !FULL;
    wire pop_en = POP && !EMPTY;
    
    // Combinational outputs (current head of queue)
    // When EMPTY, output all zeros to prevent X propagation
    wire [64:0] current_entry = EMPTY ? 65'b0 : queue[read_ptr[5:0]];
    assign ADDRESS_OUT    = current_entry[31:0];
    assign WRITE_DATA_OUT = current_entry[63:32];
    assign R_W_OUT        = current_entry[64];
    
    always @(posedge CLK) begin
        if (RESET) begin  
            write_ptr <= 0;
            read_ptr <= 0;
            // Initialize queue to prevent X propagation
            for (int i = 0; i < 64; i = i + 1) begin
                queue[i] <= 65'b0;
            end
        end
        else begin
            if (write_en) begin
                queue[write_ptr[5:0]] <= {R_W, WRITE_DATA, ADDRESS};
                write_ptr <= write_ptr + 1;
            end
            if (pop_en) begin
                read_ptr <= read_ptr + 1;
            end
        end
    end
endmodule
