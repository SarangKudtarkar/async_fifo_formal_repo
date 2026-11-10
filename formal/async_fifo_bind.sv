bind async_fifo async_fifo_checker #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH     (DEPTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) u_async_fifo_checker (.*);
