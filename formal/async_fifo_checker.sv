module async_fifo_checker #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 8,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input logic                  wclk,
    input logic                  wrst_n,
    input logic                  wr_en,
    input logic [DATA_WIDTH-1:0] wr_data,
    input logic                  full,

    input logic                  rclk,
    input logic                  rrst_n,
    input logic                  rd_en,
    input logic [DATA_WIDTH-1:0] rd_data,
    input logic                  empty,

    // DUT internals used by the async-specific checks (connected by
    // name through the bind's .* ).
    input logic [ADDR_WIDTH:0]   wbin,          // write ptr, binary
    input logic [ADDR_WIDTH:0]   wgray,         // write ptr, gray
    input logic [ADDR_WIDTH:0]   rbin,          // read ptr, binary
    input logic [ADDR_WIDTH:0]   rgray,         // read ptr, gray
    input logic [ADDR_WIDTH:0]   rgray_wsync2,  // read ptr  synced into wclk
    input logic [ADDR_WIDTH:0]   wgray_rsync2   // write ptr synced into rclk
);

    // Counter wide enough that (wcnt - rcnt) <= DEPTH is unambiguous.
    localparam int CNT_W = $clog2(DEPTH) + 2;

    // Pointer width (one extra wrap bit).
    localparam int PTR_W = ADDR_WIDTH + 1;

    function automatic logic [PTR_W-1:0] gray2bin(input logic [PTR_W-1:0] g);
        logic [PTR_W-1:0] b;
        b[PTR_W-1] = g[PTR_W-1];
        for (int i = PTR_W-2; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // ---------------- Free (symbolic) variable ----------------
    // Left undriven on purpose: free input in JasperGold.
    // Index of the write (0-based, counted after reset) to track.
    logic [CNT_W-1:0] tracked_idx;

    am_idx_stable_w: assume property (
        @(posedge wclk) 1'b1 |-> $stable(tracked_idx)
    );
    am_idx_stable_r: assume property (
        @(posedge rclk) 1'b1 |-> $stable(tracked_idx)
    );

    // ---------------- Environment: resets only at start ----------------
    // Once released, a reset stays released (no mid-operation reset).
    am_wrst_once: assume property (
        @(posedge wclk) wrst_n |=> wrst_n
    );
    am_rrst_once: assume property (
        @(posedge rclk) rrst_n |=> rrst_n
    );

    // ---------------- Accepted transfers ----------------
    logic wr_acc, rd_acc;
    assign wr_acc = wr_en && !full;
    assign rd_acc = rd_en && !empty;

    // ---------------- Write-domain model ----------------
    logic [CNT_W-1:0]      wcnt;
    logic                  trk_wr_done;
    logic [DATA_WIDTH-1:0] trk_data;

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wcnt        <= '0;
            trk_wr_done <= 1'b0;
            trk_data    <= '0;
        end else begin
            if (wr_acc)
                wcnt <= wcnt + 1'b1;

            if (!trk_wr_done && wr_acc && (wcnt == tracked_idx)) begin
                trk_wr_done <= 1'b1;
                trk_data    <= wr_data;   // held after capture
            end
        end
    end

    // ---------------- Read-domain model ----------------
    logic [CNT_W-1:0] rcnt;
    logic             trk_rd_done;

    logic read_trk;   // this rclk edge accepts the read of the tracked item
    assign read_trk = rd_acc && (rcnt == tracked_idx) && !trk_rd_done;

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rcnt        <= '0;
            trk_rd_done <= 1'b0;
        end else begin
            if (rd_acc)
                rcnt <= rcnt + 1'b1;

            if (read_trk)
                trk_rd_done <= 1'b1;
        end
    end

    // ---------------- Assertions ----------------
    // Data integrity + ordering: rd_data is registered, so the value
    // appears the cycle AFTER the accepted read.
    as_data_order: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        (read_trk && trk_wr_done) |=> (rd_data == trk_data)
    );

    // No read of an item that has not been written (no underflow / bad empty).
    as_no_read_before_write: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        read_trk |-> trk_wr_done
    );

    // Occupancy bounds, checked from each side. Counters only grow, so a
    // stale view from the other domain can only make the check conservative.
    as_no_overflow: assert property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        (wcnt - rcnt) <= CNT_W'(DEPTH)
    );

    as_no_underflow: assert property (
        @(posedge rclk) disable iff (!wrst_n || !rrst_n)
        (wcnt - rcnt) <= CNT_W'(DEPTH)
    );

    // ================================================================
    //  Async-specific properties (gray pointers, synchronizers, flags)
    // ================================================================

    // --- 1. Gray-code pointers -------------------------------------
    // Binary and gray copies of each pointer agree.
    as_wgray_matches_wbin: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        wgray == ((wbin >> 1) ^ wbin)
    );
    as_rgray_matches_rbin: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        rgray == ((rbin >> 1) ^ rbin)
    );

    // The key CDC property: a gray pointer changes at most ONE bit per
    // clock, so a synchronizer sampling mid-change sees old or new value,
    // never a corrupt one.
    as_wgray_onebit: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        $onehot0(wgray ^ $past(wgray))
    );
    as_rgray_onebit: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        $onehot0(rgray ^ $past(rgray))
    );

    // Pointers advance only on an accepted transfer, by exactly one.
    as_wptr_moves_on_write: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        (wr_en && !full) |=> (wbin == $past(wbin) + PTR_W'(1))
    );
    as_wptr_holds_otherwise: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        !(wr_en && !full) |=> $stable(wbin)
    );
    as_rptr_moves_on_read: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        (rd_en && !empty) |=> (rbin == $past(rbin) + PTR_W'(1))
    );
    as_rptr_holds_otherwise: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        !(rd_en && !empty) |=> $stable(rbin)
    );

    // --- 2. Synchronizer lag bounds --------------------------------
    // A synchronized pointer is always an OLD value of the real pointer:
    // never ahead of it, and behind by at most DEPTH.
    as_wptr_sync_lag: assert property (
        @(posedge rclk) disable iff (!wrst_n || !rrst_n)
        (wbin - gray2bin(wgray_rsync2)) <= PTR_W'(DEPTH)
    );
    as_rptr_sync_lag: assert property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        (rbin - gray2bin(rgray_wsync2)) <= PTR_W'(DEPTH)
    );

    // Real occupancy (from the binary pointers) stays within [0, DEPTH].
    as_true_occupancy_w: assert property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        (wbin - rbin) <= PTR_W'(DEPTH)
    );
    as_true_occupancy_r: assert property (
        @(posedge rclk) disable iff (!wrst_n || !rrst_n)
        (wbin - rbin) <= PTR_W'(DEPTH)
    );

    // --- 3. Flags are SAFE (pessimistic) -----------------------------
    // Flags use stale synchronized pointers, so they may lag reality, but
    // only in the safe direction:
    //   !full  => there really is space   (no overflow)
    //   !empty => there really is data    (no underflow)
    as_full_never_false_negative: assert property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        !full |-> ((wbin - rbin) < PTR_W'(DEPTH))
    );
    as_empty_never_false_negative: assert property (
        @(posedge rclk) disable iff (!wrst_n || !rrst_n)
        !empty |-> ((wbin - rbin) != '0)
    );

    // --- 4. Async-specific covers (flag pessimism is real) ----------
    // full asserted although the reader has already freed space
    // (sync latency), and empty asserted although data is in flight.
    cv_full_pessimistic: cover property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        full && ((wbin - rbin) < PTR_W'(DEPTH))
    );
    cv_empty_pessimistic: cover property (
        @(posedge rclk) disable iff (!wrst_n || !rrst_n)
        empty && ((wbin - rbin) != '0)
    );
    cv_ptr_wrap_w: cover property (
        @(posedge wclk) disable iff (!wrst_n)
        wbin[ADDR_WIDTH] && $past(!wbin[ADDR_WIDTH])
    );
    cv_ptr_wrap_r: cover property (
        @(posedge rclk) disable iff (!rrst_n)
        rbin[ADDR_WIDTH] && $past(!rbin[ADDR_WIDTH])
    );

    // ---------------- Covers (reachability / sanity) ----------------
    cv_tracked_written: cover property (
        @(posedge wclk) disable iff (!wrst_n) trk_wr_done
    );
    cv_tracked_read: cover property (
        @(posedge rclk) disable iff (!rrst_n) trk_rd_done
    );
    cv_full: cover property (
        @(posedge wclk) disable iff (!wrst_n) full
    );
    cv_not_empty: cover property (
        @(posedge rclk) disable iff (!rrst_n) !empty
    );
    cv_tracked_deep: cover property (
        @(posedge wclk) disable iff (!wrst_n)
        trk_wr_done && !trk_rd_done && ((wcnt - tracked_idx) > CNT_W'(2))
    );
    cv_wr_and_rd_same_edge: cover property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n) wr_acc && rd_acc
    );

endmodule
