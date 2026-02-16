module gowin_pll (
    input  clkin,
    output clkout,  // 81MHz Logic Clock
    output clkoutp, // 81MHz Phase-Shifted (for RAM)
    output lock
);

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0),      // Input /1
        .FBDIV_SEL(2),     // Feedback *3 -> 81MHz
        .ODIV_SEL(8),      // Output /8
        .DYN_SDIV_SEL(2),  // No dynamic divider
        .PSDA_SEL("0100")  // Phase Shift -90 degrees
    ) pll_inst (
        .CLKIN(clkin),
        .CLKOUT(clkout),
        .CLKOUTP(clkoutp), // The shifted clock
        .LOCK(lock),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );
endmodule