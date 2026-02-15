module gowin_pll (
    input  clkin,   // 27MHz Crystal
    output clkout,  // 108MHz High Speed
    output lock     // High when speed is stable
);

    // Gowin rPLL Primitive
    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0),      // Input Div: /1 (27MHz)
        .FBDIV_SEL(3),     // Feedback Div: *4 (108MHz)
        .ODIV_SEL(8)       // Output Div: /8 (Standard V CO range)
    ) pll_inst (
        .CLKIN(clkin),
        .CLKOUT(clkout),
        .LOCK(lock),
        .RESET(1'b0),      // No reset needed
        .RESET_P(1'b0),
        .CLKFB(1'b0),      // Internal feedback
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

endmodule