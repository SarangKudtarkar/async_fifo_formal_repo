module async_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 8,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    // Write domain
    input  logic                  wclk,
    input  logic                  wrst_n,
    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,
    output logic                  full,

    // Read domain
    input  logic                  rclk,
    input  logic                  rrst_n,
    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  empty
);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers have one extra bit to distinguish full from empty.
    logic [ADDR_WIDTH:0] wbin, wgray;
    logic [ADDR_WIDTH:0] rbin, rgray;

    // Synchronizers
    logic [ADDR_WIDTH:0] rgray_wsync1, rgray_wsync2;  // read ptr  -> wclk
    logic [ADDR_WIDTH:0] wgray_rsync1, wgray_rsync2;  // write ptr -> rclk

    logic wr_acc, rd_acc;
    assign wr_acc = wr_en && !full;
    assign rd_acc = rd_en && !empty;

    logic [ADDR_WIDTH:0] wbin_next, wgray_next;
    logic [ADDR_WIDTH:0] rbin_next, rgray_next;

    assign wbin_next  = wbin + (ADDR_WIDTH+1)'(wr_acc);
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;
    assign rbin_next  = rbin + (ADDR_WIDTH+1)'(rd_acc);
    assign rgray_next = (rbin_next >> 1) ^ rbin_next;

    // ---------------- Write domain ----------------
    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin         <= '0;
            wgray        <= '0;
            rgray_wsync1 <= '0;
            rgray_wsync2 <= '0;
            full         <= 1'b0;
        end else begin
            if (wr_acc)
                mem[wbin[ADDR_WIDTH-1:0]] <= wr_data;

            wbin  <= wbin_next;
            wgray <= wgray_next;

            rgray_wsync1 <= rgray;
            rgray_wsync2 <= rgray_wsync1;

            // Full: next write gray == read gray with top two bits inverted.
            full <= (wgray_next ==
                     {~rgray_wsync2[ADDR_WIDTH:ADDR_WIDTH-1],
                       rgray_wsync2[ADDR_WIDTH-2:0]});
        end
    end

    // ---------------- Read domain ----------------
    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin         <= '0;
            rgray        <= '0;
            wgray_rsync1 <= '0;
            wgray_rsync2 <= '0;
            empty        <= 1'b1;
            rd_data      <= '0;
        end else begin
            if (rd_acc)
                rd_data <= mem[rbin[ADDR_WIDTH-1:0]];

            rbin  <= rbin_next;
            rgray <= rgray_next;

            wgray_rsync1 <= wgray;
            wgray_rsync2 <= wgray_rsync1;

            // Empty: next read gray == synchronized write gray.
            empty <= (rgray_next == wgray_rsync2);
        end
    end

endmodule
