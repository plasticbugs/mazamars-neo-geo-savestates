// Savestates: the Pocket's save and load commands (docs/savestate-design.md).
//
// The Pocket asks for a save (0xA0) or a load (0xA4) through core_bridge_cmd.
// Either one runs the 68k stub (ss_m68k), which copies the machine's state
// to or from the buffer (ss_mem). For a save the Pocket then reads the buffer
// over the bridge at 0x80000000; for a load it has written it there first.
//
// The 68k runs the stub while the rest of the machine stays halted: hold
// halts it as the menu does, from the request until the stub is done, for a
// save or load asked without the menu (the Pocket's Analogue + Up and Down);
// otherwise the game cannot kick its watchdog meanwhile, which resets the
// machine after 8 frames. run_68k overrides the CPU's halt from the request
// until the stub's RTE has begun. The CPU then halts inside the RTE and finishes it when the
// menu closes, or when the next request runs it. The 68k stub asks for the
// Z80 through ss_z80, which runs the Z80 (run_z80) and the YM2610 (YM_RUN)
// the same way.

module savestate
(
	input					clk_74a,
	input					clk_sys,
	input					CLK_24M,
	input					nRESET,			// the 68k's reset

	// core_bridge_cmd, clk_74a
	input					savestate_start,
	output reg			savestate_start_ack,
	output reg			savestate_start_busy,
	output reg			savestate_start_ok,
	output reg			savestate_start_err,
	input					savestate_load,
	output reg			savestate_load_ack,
	output reg			savestate_load_busy,
	output reg			savestate_load_ok,
	output reg			savestate_load_err,
	output				hold,				// halt the machine, as the menu does

	// The 68k bus, at the CPU
	input		[23:1]	M68K_ADDR,
	input					nAS,
	input					M68K_RW,
	input					nUDS,
	input					nLDS,
	input					FC2, FC1, FC0,
	input		[15:0]	M68K_DOUT,

	// Overrides of the CPU's inputs
	output				run_68k,			// the 68k runs although halted
	output				IPL7,
	output				DIN_EN,
	output	[15:0]	DIN,
	output				DTACK_EN,
	output				nDTACK,

	// The bridge, clk_74a
	input		[31:0]	bridge_addr,
	input					bridge_rd,
	input					bridge_wr,
	input		[31:0]	bridge_wr_data,
	output	[31:0]	bridge_rd_data,

	// cram_16bit's savestate port, clk_sys
	output				ss_rd,
	output				ss_wr,
	output	[18:1]	ss_addr,
	output	[15:0]	ss_data,
	output	[1:0]		ss_be,
	input		[15:0]	ss_q,
	input					ss_ack,

	// The machine's state the stub cannot reach over the bus (ss_m68k)
	input		[127:0]	SHADOW,
	output	[14:0]	VRAM_ADDR,
	output	[15:0]	VRAM_WDATA,
	output				SVRAM_WE,
	output				FVRAM_WE,
	input		[15:0]	SVRAM_Q,
	input		[15:0]	FVRAM_Q,
	input		[3:0]		CHIP_TYPE,		// the cartridge's chip (ss_m68k)
	input		[39:0]	CHIP_Q,
	output	[39:0]	CHIP_D,
	output				CHIP_LOAD,

	// The Z80 (ss_z80), CLK_4M and CLK_8M
	input					CLK_4M,
	input					CLK_8M,
	input					Z80_nRESET,
	input		[15:0]	SDA,
	input					nMREQ,			// refresh cycles excluded
	input					nIORQ,
	input					nRD,
	input					nWR,
	input					nM1,
	input					nHALT,
	input		[7:0]		SDD_OUT,
	input		[7:0]		SDD_IN,
	input					n2610WR,
	input					nNMI_LINE,
	output				Z80_SDW,
	output				Z80_NMI_N,
	output				Z80_DIN_EN,
	output	[7:0]		Z80_DIN,
	output				Z80_INT_FORCE,
	output				Z80_INT_MASK,
	output				run_z80,
	output				YM_RUN,
	input		[39:0]	YM_SS_Q,
	output				YM_SS_LOAD,
	output	[39:0]	YM_SS_D,
	output	[10:0]	ZRAM_ADDR,		// Z80 RAM's second port, CLK_24M
	output	[7:0]		ZRAM_WDATA,
	output				ZRAM_WE,
	input		[7:0]		ZRAM_Q
);

	// The command, clk_74a. A request crosses to CLK_24M as a toggle with
	// op_load held; the stub's end comes back the same way.
	reg start_r = 1'b0, load_r = 1'b0;
	reg active = 1'b0, op_load = 1'b0;
	reg req_t = 1'b0;
	reg [2:0] done_s = 3'b000;
	reg [26:0] timer;					// 1.8 s at 74.25 MHz
	wire done_t;
	assign hold = active;

	always @(posedge clk_74a) begin
		start_r <= savestate_start;
		load_r <= savestate_load;
		done_s <= {done_s[1:0], done_t};
		savestate_start_ack <= 1'b0;
		savestate_load_ack <= 1'b0;

		if (savestate_start & ~start_r) begin
			savestate_start_ack <= 1'b1;
			savestate_start_ok <= 1'b0;
			savestate_load_ok <= 1'b0;
			savestate_load_err <= 1'b0;
			if (active) savestate_start_err <= 1'b1;
			else begin
				savestate_start_err <= 1'b0;
				savestate_start_busy <= 1'b1;
				active <= 1'b1;
				op_load <= 1'b0;
				req_t <= ~req_t;
				timer <= 27'd0;
			end
		end
		else if (savestate_load & ~load_r) begin
			savestate_load_ack <= 1'b1;
			savestate_load_ok <= 1'b0;
			savestate_start_ok <= 1'b0;
			savestate_start_err <= 1'b0;
			if (active) savestate_load_err <= 1'b1;
			else begin
				savestate_load_err <= 1'b0;
				savestate_load_busy <= 1'b1;
				active <= 1'b1;
				op_load <= 1'b1;
				req_t <= ~req_t;
				timer <= 27'd0;
			end
		end
		else if (active) begin
			timer <= timer + 1'd1;
			if ((done_s[2] ^ done_s[1]) | &timer) begin
				active <= 1'b0;
				savestate_start_busy <= 1'b0;
				savestate_load_busy <= 1'b0;
				if (op_load) begin
					savestate_load_ok <= ~&timer;
					savestate_load_err <= &timer;
				end
				else begin
					savestate_start_ok <= ~&timer;
					savestate_start_err <= &timer;
				end
			end
		end
	end

	// CLK_24M
	reg [2:0] req_s = 3'b000;
	reg [1:0] load_s = 2'b00;
	reg start = 1'b0;
	reg done_tr = 1'b0;
	wire run, done;
	assign done_t = done_tr;

	always @(posedge CLK_24M) begin
		req_s <= {req_s[1:0], req_t};
		load_s <= {load_s[0], op_load};
		start <= req_s[2] ^ req_s[1];
		if (done) done_tr <= ~done_tr;
	end

	assign run_68k = run;

	wire win_rd, win_wr, win_ack;
	wire [18:1] win_addr;
	wire [15:0] win_wdata, win_rdata;
	wire [1:0] win_be;
	wire [15:1] aux_addr;
	wire aux_we;
	wire [15:0] aux_wdata, aux_q;

	ss_m68k ss_m68k(
		.CLK				(CLK_24M),
		.nRESET			(nRESET),
		.start			(start),
		.load				(load_s[1]),
		.busy				(),
		.done				(done),
		.run				(run),
		.M68K_ADDR		(M68K_ADDR),
		.nAS				(nAS),
		.M68K_RW			(M68K_RW),
		.nUDS				(nUDS),
		.nLDS				(nLDS),
		.FC2				(FC2),
		.FC1				(FC1),
		.FC0				(FC0),
		.M68K_DOUT		(M68K_DOUT),
		.IPL7				(IPL7),
		.DIN_EN			(DIN_EN),
		.DIN				(DIN),
		.DTACK_EN		(DTACK_EN),
		.nDTACK			(nDTACK),
		.win_rd			(win_rd),
		.win_wr			(win_wr),
		.win_addr		(win_addr),
		.win_wdata		(win_wdata),
		.win_be			(win_be),
		.win_rdata		(win_rdata),
		.win_ack			(win_ack),
		.SHADOW			(SHADOW),
		.VRAM_ADDR		(VRAM_ADDR),
		.VRAM_WDATA		(VRAM_WDATA),
		.SVRAM_WE		(SVRAM_WE),
		.FVRAM_WE		(FVRAM_WE),
		.SVRAM_Q			(SVRAM_Q),
		.FVRAM_Q			(FVRAM_Q),
		.AUX_ADDR		(aux_addr),
		.AUX_WE			(aux_we),
		.AUX_WDATA		(aux_wdata),
		.AUX_Q			(aux_q),
		.CHIP_TYPE		(CHIP_TYPE),
		.CHIP_Q			(CHIP_Q),
		.CHIP_D			(CHIP_D),
		.CHIP_LOAD		(CHIP_LOAD)
	);

	ss_z80 ss_z80(
		.CLK_4M			(CLK_4M),
		.nRESET			(Z80_nRESET),
		.SDA				(SDA),
		.nMREQ			(nMREQ),
		.nIORQ			(nIORQ),
		.nRD				(nRD),
		.nWR				(nWR),
		.nM1				(nM1),
		.nHALT			(nHALT),
		.SDD_OUT			(SDD_OUT),
		.SDD_IN			(SDD_IN),
		.n2610WR			(n2610WR),
		.nNMI_LINE		(nNMI_LINE),
		.SDW				(Z80_SDW),
		.NMI_N			(Z80_NMI_N),
		.DIN_EN			(Z80_DIN_EN),
		.DIN				(Z80_DIN),
		.INT_FORCE		(Z80_INT_FORCE),
		.INT_MASK		(Z80_INT_MASK),
		.run				(run_z80),
		.YM_RUN			(YM_RUN),
		.CLK_8M			(CLK_8M),
		.YM_SS_Q			(YM_SS_Q),
		.YM_SS_LOAD		(YM_SS_LOAD),
		.YM_SS_D			(YM_SS_D),
		.CLK_24M			(CLK_24M),
		.AUX_ADDR		(aux_addr),
		.AUX_WE			(aux_we),
		.AUX_WDATA		(aux_wdata),
		.AUX_Q			(aux_q),
		.ZRAM_ADDR		(ZRAM_ADDR),
		.ZRAM_WDATA		(ZRAM_WDATA),
		.ZRAM_WE			(ZRAM_WE),
		.ZRAM_Q			(ZRAM_Q)
	);

	ss_mem ss_mem(
		.clk_sys			(clk_sys),
		.CLK_24M			(CLK_24M),
		.win_rd			(win_rd),
		.win_wr			(win_wr),
		.win_addr		(win_addr),
		.win_wdata		(win_wdata),
		.win_be			(win_be),
		.win_rdata		(win_rdata),
		.win_ack			(win_ack),
		.bridge_addr	(bridge_addr),
		.bridge_rd		(bridge_rd),
		.bridge_wr		(bridge_wr),
		.bridge_wr_data(bridge_wr_data),
		.bridge_rd_data(bridge_rd_data),
		.ss_rd			(ss_rd),
		.ss_wr			(ss_wr),
		.ss_addr			(ss_addr),
		.ss_data			(ss_data),
		.ss_be			(ss_be),
		.ss_q				(ss_q),
		.ss_ack			(ss_ack)
	);

endmodule
