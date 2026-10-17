// Savestates: the Z80's side (docs/savestate-design.md).
//
// The 68k stub asks for the Z80 (ZREQ). This module then makes the Z80 run
// ssz80_stub.asm at 0x0038:
//
//   running: at the next opcode fetch that starts an instruction, it answers
//            RST 38h (0xFF) in place of the opcode; the stub moves the
//            return address back over it.
//   halted:  it pulls INT. A HALT is left by an interrupt, and IM 1 (the
//            mode every NeoGeo sound driver uses) also goes to 0x0038; the
//            stub then knows IFF1 was set.
//
// From then until the stub's last RET it answers the Z80's memory reads
// below 0x0C00 (the game's ROM is not read; RAM at 0xF800 is):
//
//   0x0000-0x07FF  the stub
//   0x0800-0x09FF  the YM2610 register shadow: part A 0x00-0xFF, part B
//   0x0A00         read: ZCMD (0 wait, 1 resume, 2 load).  write: parked
//   0x0A01         read: bit 0, entered by INT.  write: done
//   0x0A02-0A03    read: the SP to load.  write: SP when parked
//   0x0A04         read: bit 0, NMI enabled; bit 1, the NMI line low;
//                  bit 2, the NMI input held low
//   0x0A05         read: the reply latch
//   0x0A06-0A09    read: the four ROM bank windows (zmc.v)
//   0x0A0A         write: the resume point, which save and load both pass
//   0x0A0B         write: pulse SDW (z80ctrl's nSDW, not the latch's), to
//                  set the NMI line low as a command does
//   0x0A0C         write: set the NMI hold from ZNMI bit 2 (1: held low)
//
// and holds INT off, so no game interrupt is taken inside the stub. The Z80
// runs (run) through the menu's halt meanwhile.
//
// NMI. It never enters while an NMI is pending or being handled (from the
// fetch at 0x0066 to the RETN, for at most ~16 ms): the RST would be lost to
// the NMI, or the stub would read IFF2 for IFF1. While the stub runs, the
// Z80's NMI input (NMI_N) is held where it was at entry; an NMI raised
// meanwhile is taken at the game's PC after the last RET, as it would have
// been. A load sets the hold as saved; if that lowers it, the NMI goes to the
// stub's 0x0066, which drops it.
//
// The 68k sees, at 0xE60000 (AUX, through ss_m68k), word n holding byte n:
//
//   0x0000-0x0FFF  Z80 RAM (Z80RAM's second port, outside this module)
//   0x1000-0x13FF  the YM2610 register shadow
//   0x2000         read: ZSTAT (bit 0 parked, bit 1 exited, since the last
//                  ZREQ/ZCMD; bit 2 the NMI line low, bit 3 the Z80's NMI
//                  input held low, now).  write: ZREQ
//   0x2002         read: SP when parked.  write: the SP to load
//   0x2004         write: ZCMD
//   0x2006-0x2010  write: NMI enable and line, reply latch, banks 0-3 (as
//                  above)
//   0x2012-0x2016  the YM2610's timers (jt10 ss_q), bits 15-0, 31-16, 39-32.
//                  read: as at the resume point of the last save.  write:
//                  what a load sets them to at its resume point
//
// The YM2610 shadow records every register write the Z80 makes, game's and
// stub's alike, by watching the bus. Writing the registers back cannot set
// the timers' counts, so they are read and set directly, at the same
// instruction in a save and a load; the chip is held (YM_RUN low) while the
// Z80 is parked, so it neither counts nor sounds while the 68k copies.

module ss_z80
(
	input					CLK_4M,
	input					nRESET,			// the Z80's reset

	// The Z80 bus
	input		[15:0]	SDA,
	input					nMREQ,			// refresh cycles excluded
	input					nIORQ,
	input					nRD,
	input					nWR,
	input					nM1,
	input					nHALT,
	input		[7:0]		SDD_OUT,
	input		[7:0]		SDD_IN,			// the machine's answer to a read
	input					n2610WR,
	input					nNMI_LINE,		// z80ctrl's NMI flop
	output				SDW,				// pulse: z80ctrl's nSDW low
	output				NMI_N,			// the Z80's NMI input

	// Overrides of the Z80's inputs
	output				DIN_EN,
	output	[7:0]		DIN,
	output				INT_FORCE,		// pull INT
	output				INT_MASK,		// hold INT off
	output				run,				// the Z80 runs although halted
	output				YM_RUN,			// so does the YM2610

	// The YM2610's timers, CLK_8M
	input					CLK_8M,
	input		[39:0]	YM_SS_Q,
	output				YM_SS_LOAD,
	output	[39:0]	YM_SS_D,

	// The 68k's side, CLK_24M (ss_m68k's AUX region)
	input					CLK_24M,
	input		[15:1]	AUX_ADDR,
	input					AUX_WE,
	input		[15:0]	AUX_WDATA,
	output	[15:0]	AUX_Q,			// one clock after AUX_ADDR
	output	[10:0]	ZRAM_ADDR,		// Z80RAM's second port
	output	[7:0]		ZRAM_WDATA,
	output				ZRAM_WE,
	input		[7:0]		ZRAM_Q
);

	wire [7:0] stub_q;
	ssz80_stub_rom stub_rom(CLK_4M, SDA[10:0], stub_q);

	// --- The 68k's side -------------------------------------------------

	wire aux_zram = (AUX_ADDR[15:12] == 4'h0);
	wire aux_ym   = (AUX_ADDR[15:10] == 6'b000100);
	wire aux_reg  = (AUX_ADDR[15:5] == 11'h100);

	assign ZRAM_ADDR = AUX_ADDR[11:1];
	assign ZRAM_WDATA = AUX_WDATA[7:0];
	assign ZRAM_WE = AUX_WE & aux_zram;

	reg req_t = 1'b0, cmd_t = 1'b0;
	reg [1:0] cmd = 2'd0;
	reg [15:0] sp_load;
	reg [7:0] nmi_en, rep, bank0, bank1, bank2, bank3;
	reg [39:0] ym_load;
	reg [39:0] ym_saved;
	assign YM_SS_D = ym_load;
	reg parked_seen = 1'b0, exited_seen = 1'b0;
	wire park_t, exit_t;
	reg [2:0] park_s = 3'b000, exit_s = 3'b000, line_s = 3'b111, hold_s = 3'b111;
	wire nmi_hold_t;
	reg [15:0] sp_parked_24;
	wire [15:0] sp_parked;
	wire [7:0] ym_q_b;

	always @(posedge CLK_24M) begin
		park_s <= {park_s[1:0], park_t};
		line_s <= {line_s[1:0], nNMI_LINE};
		hold_s <= {hold_s[1:0], nmi_hold_t};
		exit_s <= {exit_s[1:0], exit_t};
		if (park_s[2] ^ park_s[1]) begin
			parked_seen <= 1'b1;
			sp_parked_24 <= sp_parked;			// held by the Z80 side since before
		end
		if (exit_s[2] ^ exit_s[1]) exited_seen <= 1'b1;
		if (AUX_WE & aux_reg) case (AUX_ADDR[4:1])
			4'h0: begin req_t <= ~req_t; parked_seen <= 1'b0; exited_seen <= 1'b0; end
			4'h1: sp_load <= AUX_WDATA;
			4'h2: begin cmd <= AUX_WDATA[1:0]; cmd_t <= ~cmd_t; exited_seen <= 1'b0; end
			4'h3: nmi_en <= AUX_WDATA[7:0];
			4'h4: rep <= AUX_WDATA[7:0];
			4'h5: bank0 <= AUX_WDATA[7:0];
			4'h6: bank1 <= AUX_WDATA[7:0];
			4'h7: bank2 <= AUX_WDATA[7:0];
			4'h8: bank3 <= AUX_WDATA[7:0];
			4'h9: ym_load[15:0] <= AUX_WDATA;
			4'hA: ym_load[31:16] <= AUX_WDATA;
			4'hB: ym_load[39:32] <= AUX_WDATA[7:0];
			default: ;
		endcase
	end

	reg [15:0] reg_q;
	reg [1:0] aux_sel;
	always @(posedge CLK_24M) begin
		aux_sel <= {aux_ym | aux_reg, aux_reg};
		case (AUX_ADDR[4:1])
			4'h0: reg_q <= {12'd0, ~hold_s[2], ~line_s[2], exited_seen, parked_seen};
			4'h1: reg_q <= sp_parked_24;
			4'h9: reg_q <= ym_saved[15:0];		// still since the save's exit
			4'hA: reg_q <= ym_saved[31:16];
			4'hB: reg_q <= {8'd0, ym_saved[39:32]};
			default: reg_q <= 16'd0;
		endcase
	end
	assign AUX_Q = aux_sel[0] ? reg_q : aux_sel[1] ? {8'd0, ym_q_b} : {8'd0, ZRAM_Q};

	// --- The Z80's side --------------------------------------------------

	reg [2:0] req_s = 3'b000, cmd_s = 3'b000;
	localparam IDLE = 2'd0, ENTER = 2'd1, ACTIVE = 2'd2;
	reg [1:0] state = IDLE;
	reg by_int = 1'b0, done = 1'b0, cmd_seen = 1'b0;
	reg park_tr = 1'b0, exit_tr = 1'b0, resume_tr = 1'b0;
	reg parked = 1'b0;
	reg [1:0] sdw = 2'b00;					// two CLK_4M periods
	assign SDW = |sdw;
	reg [15:0] sp_p;
	assign park_t = park_tr;
	assign exit_t = exit_tr;
	assign sp_parked = sp_p;

	wire fetch = ~nM1 & ~nMREQ & ~nRD;			// an opcode fetch
	wire iack  = ~nM1 & ~nIORQ;					// an interrupt acknowledge
	wire mem_wr = ~nMREQ & ~nWR;
	reg fetch_r = 1'b0, mem_wr_r = 1'b0;
	reg last_prefix = 1'b0;

	// NMI: T80's edge detector, mirrored (pend), and whether its handler runs
	reg nmi_hold = 1'b1, nmi_old = 1'b1, pend = 1'b0, in_nmi = 1'b0;
	reg [7:0] prev_q = 8'd0;					// the opcode before fetch_q
	reg [15:0] nmi_wait = 16'd0;				// 16 ms at 4 MHz
	assign NMI_N = (state == ACTIVE) ? nmi_hold : nNMI_LINE;
	assign nmi_hold_t = nmi_hold;
	wire nmi_clear = ~pend & (~in_nmi | (&nmi_wait));

	// T80 takes an opcode at the clock edge where its fetch is first seen
	// here, or later after wait states (nWAIT, while a ROM read is fetched),
	// so RST 38h is answered at once and to the end of the fetch
	wire sub_start = (state == ENTER) & fetch & ~fetch_r & ~last_prefix & nHALT & nmi_clear;
	reg sub_r = 1'b0;
	wire sub = sub_start | (sub_r & fetch);

	assign run = (state != IDLE);
	assign YM_RUN = run & ~parked;
	assign INT_FORCE = (state == ENTER) & ~nHALT & nmi_clear;
	assign INT_MASK = (state == ACTIVE);

	// What the Z80 reads while the stub runs
	wire stub_area = (SDA[15:10] == 6'b000000) | (SDA[15:9] == 7'b0000100) | (SDA[15:4] == 12'h0A0);
	wire is_ym = (SDA[15:9] == 7'b0000100);
	wire [7:0] ym_q_a;
	reg [7:0] mbox_q;
	always @(*)
		case (SDA[3:0])
			4'h0: mbox_q = cmd_seen ? {6'd0, cmd} : 8'd0;
			4'h1: mbox_q = {7'd0, by_int};
			4'h2: mbox_q = sp_load[7:0];
			4'h3: mbox_q = sp_load[15:8];
			4'h4: mbox_q = nmi_en;
			4'h5: mbox_q = rep;
			4'h6: mbox_q = bank0;
			4'h7: mbox_q = bank1;
			4'h8: mbox_q = bank2;
			4'h9: mbox_q = bank3;
			default: mbox_q = 8'd0;
		endcase
	// The ROMs answer a clock after the address; the Z80 takes its data at
	// the start of T3, two clocks after it
	assign DIN_EN = ((state == ACTIVE) & ~nMREQ & ~nRD & stub_area) | sub;
	assign DIN = sub ? 8'hFF :
					 (SDA[15:10] == 6'b000000) ? stub_q :
					 is_ym ? ym_q_a : mbox_q;

	// The byte an opcode fetch got, and whether it came from the stub
	reg [7:0] fetch_q;
	reg fetch_stub;
	always @(posedge CLK_4M)
		if (fetch) begin
			fetch_q <= DIN_EN ? DIN : SDD_IN;
			fetch_stub <= DIN_EN;
		end

	always @(posedge CLK_4M or negedge nRESET) begin
		if (~nRESET) begin
			state <= IDLE;
			done <= 1'b0;
			cmd_seen <= 1'b0;
			parked <= 1'b0;
			last_prefix <= 1'b0;
			pend <= 1'b0;
			in_nmi <= 1'b0;
		end
		else begin
			req_s <= {req_s[1:0], req_t};
			cmd_s <= {cmd_s[1:0], cmd_t};
			fetch_r <= fetch;
			mem_wr_r <= mem_wr;
			sub_r <= sub;
			sdw <= {sdw[0], 1'b0};

			// The NMI's fetch at 0x0066 (outside the stub, where 0x0066 is
			// the stub's own) ends what is pending and starts the handler
			if (fetch & ~fetch_r & (SDA == 16'h0066) & (state != ACTIVE)) begin
				pend <= 1'b0;
				in_nmi <= 1'b1;
			end
			nmi_old <= NMI_N;
			if (nmi_old & ~NMI_N) pend <= 1'b1;
			if (cmd_s[2] ^ cmd_s[1]) begin
				cmd_seen <= 1'b1;
				parked <= 1'b0;
			end

			// At the end of each opcode fetch: does the next one start an
			// instruction? Was this the stub's last RET?
			if (fetch_r & ~fetch) begin
				last_prefix <= (fetch_q == 8'hCB) | (fetch_q == 8'hDD) |
									(fetch_q == 8'hED) | (fetch_q == 8'hFD);
				prev_q <= fetch_q;
				if ((prev_q == 8'hED) & ((fetch_q & 8'hC7) == 8'h45))
					in_nmi <= 1'b0;					// RETN (or RETI)
				if ((state == ACTIVE) & done & fetch_stub & (fetch_q == 8'hC9)) begin
					state <= IDLE;
					exit_tr <= ~exit_tr;
				end
			end

			case (state)
				IDLE: if (req_s[2] ^ req_s[1]) begin
					state <= ENTER;
					nmi_wait <= 16'd0;
					by_int <= 1'b0;
					done <= 1'b0;
					cmd_seen <= 1'b0;
				end
				ENTER: begin
					if (~&nmi_wait) nmi_wait <= nmi_wait + 1'd1;
					nmi_hold <= nNMI_LINE;		// as it is when the stub starts
					if (sub_start) state <= ACTIVE;	// it takes RST 38h
					else if (iack) begin
						by_int <= 1'b1;
						state <= ACTIVE;
					end
				end
				ACTIVE: begin
					if (mem_wr & ~mem_wr_r & (SDA[15:4] == 12'h0A0)) case (SDA[3:0])
						4'h0: begin park_tr <= ~park_tr; parked <= ~cmd_seen; end
						4'h1: done <= 1'b1;
						4'h2: sp_p[7:0] <= SDD_OUT;
						4'h3: sp_p[15:8] <= SDD_OUT;
						4'hA: resume_tr <= ~resume_tr;
						4'hB: sdw <= 2'b11;
						4'hC: nmi_hold <= ~nmi_en[2];
						default: ;
					endcase
				end
				default: state <= IDLE;
			endcase
		end
	end

	// The resume point, as one CLK_8M pulse. A load sets the timers on the
	// edge that ends it; a save reads them on the edge after, so the two see
	// the same state (and jt12_div's falling-edge enables, half a clock on)
	reg [1:0] resume_s = 2'b00;
	reg resume_p = 1'b0, resume_p_d = 1'b0;
	wire loading = (cmd == 2'd2);			// written long before
	always @(posedge CLK_8M) begin
		resume_s <= {resume_s[0], resume_tr};
		resume_p <= resume_s[1] ^ resume_s[0];
		resume_p_d <= resume_p;
		if (resume_p_d & ~loading) ym_saved <= YM_SS_Q;
	end
	assign YM_SS_LOAD = resume_p & loading;

	// The YM2610 shadow: port a here (bus writes, and the stub's reads),
	// port b the 68k's
	reg wr_r = 1'b1;
	reg [7:0] ym_addr_a = 8'd0, ym_addr_b = 8'd0;
	wire ym_data_wr = ~n2610WR & wr_r & SDA[0];
	always @(posedge CLK_4M) begin
		wr_r <= n2610WR;
		if (~n2610WR & wr_r & ~SDA[0]) begin
			if (SDA[1]) ym_addr_b <= SDD_OUT;
			else ym_addr_a <= SDD_OUT;
		end
	end
	wire [8:0] ym_port_a = ym_data_wr ? {SDA[1], SDA[1] ? ym_addr_b : ym_addr_a} : SDA[8:0];

	ss_dpram_2clk #(9, 8) ym_shadow(
		.clock_a		(CLK_4M),
		.address_a	(ym_port_a),
		.data_a		(SDD_OUT),
		.wren_a		(ym_data_wr),
		.q_a			(ym_q_a),
		.clock_b		(CLK_24M),
		.address_b	(AUX_ADDR[9:1]),
		.data_b		(AUX_WDATA[7:0]),
		.wren_b		(AUX_WE & aux_ym),
		.q_b			(ym_q_b)
	);

endmodule
