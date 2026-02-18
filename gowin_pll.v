module gowin_pll (
    input  clkin,
    output clkout,  // 81MHz
    output clkoutp, // 81MHz Phase Shifted -90/90 deg
    output lock
);

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0),       // Input / 1
        .FBDIV_SEL(2),      // Feedback * 3 -> 81MHz
        .ODIV_SEL(8),       // Output Divider (Default for range)
        .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),   // MUST BE FALSE (Use PLL)
        .CLKOUTP_BYPASS("false"),  // MUST BE FALSE (Use PLL Phase Shift)
        .CLKOUTD_BYPASS("true"),
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .PSDA_SEL("0100"),         // 90 Degree Shift (Standard for PSRAM)
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT")
    ) pll_inst (
        .CLKIN(clkin),
        .CLKOUT(clkout),
        .CLKOUTP(clkoutp),
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