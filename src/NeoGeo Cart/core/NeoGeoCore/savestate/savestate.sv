// Savestates: the Pocket's save and load commands (docs/savestate-design.md).
//
// The Pocket asks for a save (0xA0) or a load (0xA4) through core_bridge_cmd.
// Either one runs the 68k stub (ss_m68k), which copies the machine's state
// to or from the buffer (ss_mem). For a save the Pocket then reads the buffer
// over the bridge at 0x80000000; for a load it has written it there first.
//
// The 68k runs the stub while the rest of the machine stays halted for the
// menu: run_68k overrides the CPU's halt from the request until the stub's
// RTE has begun. The CPU then halts inside the RTE and finishes it when the
// menu closes, or when the next request runs it.

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
	input					ss_ack
);

	// The command, clk_74a. A request crosses to CLK_24M as a toggle with
	// op_load held; the stub's end comes back the same way.
	reg start_r = 1'b0, load_r = 1'b0;
	reg active = 1'b0, op_load = 1'b0;
	reg req_t = 1'b0;
	reg [2:0] done_s = 3'b000;
	reg [26:0] timer;					// 1.8 s at 74.25 MHz
	wire done_t;

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
		.win_ack			(win_ack)
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
