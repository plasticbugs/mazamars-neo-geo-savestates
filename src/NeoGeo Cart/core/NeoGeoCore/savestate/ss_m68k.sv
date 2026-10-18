// Savestates: make the 68000 run ss68k_stub.s (docs/savestate-design.md).
//
// start (one CLK_24M pulse) raises interrupt level 7. At its acknowledge the
// CPU autovectors through 0x00007C; this module answers that read with
// STUB_BASE, so the CPU runs the stub with the game's PC and SR stacked.
// From then on it answers the stub's own bus cycles:
//
//   0xE00000-0xE3FFFF  stub code (512 words, mirrored)
//   0xE40000-0xE4FFFF  slow VRAM, 32K words (the VRAM's second port)
//   0xE50000-0xE5FFFF  fast VRAM, 2K words, mirrored
//   0xE60000-0xE6FFFF  AUX: the Z80's side (ss_z80)
//   0xE7FF00           read: {15'b0, load}.  write: the stub is finished
//   0xE7FF10-0xE7FF1F  read: SHADOW, 8 words of write-only registers
//   0xE80000-0xEFFFFF  the window: win_* requests to the savestate buffer
//
// It drives the CPU's inputs directly (data in, DTACK, IPL), after the rest
// of the bus has resolved; nothing else in the machine decodes 0xE00000 and
// up. The region answers DTACK whether or not a stub is running, as an
// unmapped NeoGeo access is DTACKed anyway, so a prefetch past the stub's
// RTE completes; window writes outside a stub are ignored.

module ss_m68k
(
	input					CLK,				// CLK_24M, as the 68k
	input					nRESET,

	input					start,			// pulse: run the stub
	input					load,				// 0 save, 1 load; held while busy
	output reg			busy,
	output reg			done,				// pulse: the stub wrote CTRL
	output				run,				// the CPU must run: busy, then on into the RTE

	// The 68k bus, at the CPU
	input		[23:1]	M68K_ADDR,
	input					nAS,
	input					M68K_RW,
	input					nUDS,
	input					nLDS,
	input					FC2, FC1, FC0,
	input		[15:0]	M68K_DOUT,

	// Overrides of the CPU's inputs
	output reg			IPL7,				// force interrupt level 7
	output				DIN_EN,
	output	[15:0]	DIN,
	output				DTACK_EN,
	output				nDTACK,

	// The window onto the savestate buffer, 16-bit words
	output reg			win_rd,
	output reg			win_wr,
	output reg [18:1]	win_addr,
	output reg [15:0]	win_wdata,
	output reg [1:0]	win_be,			// {upper, lower}
	input		[15:0]	win_rdata,
	input					win_ack,			// one pulse per request

	// What the stub cannot read through the machine itself
	input		[127:0]	SHADOW,			// word n at 0xE7FF10 + 2n
	output	[14:0]	VRAM_ADDR,		// slow: [14:0], fast: [10:0]
	output	[15:0]	VRAM_WDATA,
	output reg			SVRAM_WE,
	output reg			FVRAM_WE,
	input		[15:0]	SVRAM_Q,			// one clock after VRAM_ADDR
	input		[15:0]	FVRAM_Q,

	// ss_z80's AUX port
	output	[15:1]	AUX_ADDR,
	output reg			AUX_WE,
	output	[15:0]	AUX_WDATA,
	input		[15:0]	AUX_Q				// one clock after AUX_ADDR
);

	localparam [23:0] STUB_BASE = 24'hE00000;

	wire region_e	= (M68K_ADDR[23:20] == 4'hE);
	wire is_win		= region_e & M68K_ADDR[19];
	wire is_stub	= region_e & ~M68K_ADDR[19] & ~M68K_ADDR[18];
	wire is_vram	= region_e & ~M68K_ADDR[19] & M68K_ADDR[18] & ~M68K_ADDR[17];
	wire is_fast	= M68K_ADDR[16];
	wire is_aux		= region_e & ~M68K_ADDR[19] & M68K_ADDR[18] & M68K_ADDR[17] & ~M68K_ADDR[16];
	wire is_ctrl	= region_e & (M68K_ADDR[19:1] == 19'h3FF80);
	wire is_shadow	= region_e & (M68K_ADDR[19:4] == 16'h7FF1);
	wire [15:0] shadow_q = SHADOW[{M68K_ADDR[3:1], 4'd0} +: 16];

	assign VRAM_ADDR = is_fast ? {4'd0, M68K_ADDR[11:1]} : M68K_ADDR[15:1];
	assign VRAM_WDATA = M68K_DOUT;
	assign AUX_ADDR = M68K_ADDR[15:1];
	assign AUX_WDATA = M68K_DOUT;
	reg [1:0] vram_wait;
	reg [15:0] vram_q;
	wire iack7		= FC2 & FC1 & FC0 & ~nAS & (M68K_ADDR[3:1] == 3'd7);
	wire strobe		= ~nAS & ~(nUDS & nLDS);

	// The vector fetch for the injected interrupt: 0x00007C, 0x00007E
	reg vec_pending, vec_last;
	wire is_vec		= vec_pending & ~nAS & M68K_RW & (M68K_ADDR[23:2] == 22'h00001F);

	// One window transfer per bus cycle
	reg cyc_started, cyc_ready;

	// After CTRL the stub's RTE must start before the CPU may halt: halted
	// between the write and the RTE, a new request would be taken there, in
	// the stub. The RTE's first bus cycle is its pop, outside region E.
	reg tail;
	assign run = busy | tail;
	reg [15:0] win_q;

	wire [15:0] stub_q;
	ss68k_stub_rom stub_rom(CLK, M68K_ADDR[9:1], stub_q);

	always @(posedge CLK or negedge nRESET) begin
		if (~nRESET) begin
			busy <= 1'b0;
			done <= 1'b0;
			tail <= 1'b0;
			IPL7 <= 1'b0;
			vec_pending <= 1'b0;
			vec_last <= 1'b0;
			cyc_started <= 1'b0;
			cyc_ready <= 1'b0;
			win_rd <= 1'b0;
			win_wr <= 1'b0;
			SVRAM_WE <= 1'b0;
			FVRAM_WE <= 1'b0;
			AUX_WE <= 1'b0;
			vram_wait <= 2'd0;
		end
		else begin
			done <= 1'b0;
			win_rd <= 1'b0;
			win_wr <= 1'b0;
			SVRAM_WE <= 1'b0;
			FVRAM_WE <= 1'b0;
			AUX_WE <= 1'b0;

			if (start & ~busy) begin
				busy <= 1'b1;
				IPL7 <= 1'b1;
			end

			if (tail & ~nAS & ~region_e)
				tail <= 1'b0;						// the RTE's first pop

			if (IPL7 & iack7) begin
				IPL7 <= 1'b0;
				vec_pending <= 1'b1;
			end
			if (is_vec & M68K_ADDR[1])
				vec_last <= 1'b1;					// the low word: last of the vector

			if (nAS) begin
				if (vec_last) begin				// hold the answer until the cycle ends
					vec_pending <= 1'b0;
					vec_last <= 1'b0;
				end
				cyc_started <= 1'b0;
				cyc_ready <= 1'b0;
			end
			else if (strobe & ~cyc_started) begin
				cyc_started <= 1'b1;
				if (is_win & busy) begin
					win_rd <= M68K_RW;
					win_wr <= ~M68K_RW;
					win_addr <= M68K_ADDR[18:1];
					win_wdata <= M68K_DOUT;
					win_be <= {~nUDS, ~nLDS};
				end
				else if ((is_vram | is_aux) & busy & M68K_RW)
					vram_wait <= 2'd2;			// the RAM's address is in by now
				else if (is_aux & busy) begin	// whole words, as for VRAM
					AUX_WE <= 1'b1;
					cyc_ready <= 1'b1;
				end
				else if (is_vram & busy) begin	// whole words: the stub moves no bytes there
					SVRAM_WE <= ~is_fast;
					FVRAM_WE <= is_fast;
					cyc_ready <= 1'b1;
				end
				else begin
					cyc_ready <= 1'b1;			// stub, CTRL, vector, idle window
					if (is_ctrl & ~M68K_RW & busy) begin
						busy <= 1'b0;
						tail <= 1'b1;
						done <= 1'b1;
					end
				end
			end
			else if (cyc_started & ~cyc_ready & win_ack) begin
				win_q <= win_rdata;
				cyc_ready <= 1'b1;
			end
			else if (vram_wait != 2'd0) begin
				vram_wait <= vram_wait - 1'd1;
				if (vram_wait == 2'd1) begin
					vram_q <= is_aux ? AUX_Q : is_fast ? FVRAM_Q : SVRAM_Q;
					cyc_ready <= 1'b1;
				end
			end
		end
	end

	assign DTACK_EN = region_e | is_vec;
	assign nDTACK = ~cyc_ready;
	assign DIN_EN = (region_e | is_vec) & M68K_RW;
	assign DIN = is_vec ? (M68K_ADDR[1] ? STUB_BASE[15:0] : {8'h00, STUB_BASE[23:16]}) :
					 is_ctrl ? {15'd0, load} :
					 is_shadow ? shadow_q :
					 is_stub ? stub_q :
					 (is_vram | is_aux) ? vram_q :
					 is_win ? win_q :
					 16'h0000;

endmodule
