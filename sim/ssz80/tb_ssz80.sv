// The Z80's side of savestates: cpu_z80 (T80, converted to Verilog by
// GHDL) running a game's M1 ROM, with the machine's own Z80 decode
// (z80ctrl.v), ROM banks (zmc.v), the YM2610 (jt10), Z80 RAM on a second
// port, the 68k/Z80 latches, and ss_z80, wired as in Neogeo.sv. The C++ side
// plays the 68k: sound commands, and the 68k stub's part of a save or load
// through ss_z80's AUX port.
module tb_ssz80(
	input					CLK_24M,
	input					CLK_4M,
	input					CLK_8M,
	input					nRESET,
	input					menu,				// halt, as osnotify_inmenu
	input					wait_all,		// wait states on RAM reads too (a stress)

	// The 68k's sound command: the latch, and the write strobe (nSDW)
	input		[7:0]		cmd_in,
	input					nSDW,

	// ss_z80's AUX port, as ss_m68k drives it
	input		[15:1]	AUX_ADDR,
	input					AUX_WE,
	input		[15:0]	AUX_WDATA,
	output	[15:0]	AUX_Q,

	// The bus, for the trace
	output	[15:0]	SDA,
	output	[7:0]		DIN,				// what the Z80 reads
	output	[7:0]		SDD_OUT,
	output				nMREQ,
	output				nIORQ,
	output				nRD,
	output				nWR,
	output				nM1,
	output	[31:0]	Z80_TIME,
	output				RUN
);

	reg [1:0] halt_4m_sr = 2'b00, halt_8m_sr = 2'b00;
	always @(posedge CLK_4M) halt_4m_sr <= {halt_4m_sr[0], menu};
	always @(posedge CLK_8M) halt_8m_sr <= {halt_8m_sr[0], menu};
	wire HALT_4M = halt_4m_sr[1], HALT_8M = halt_8m_sr[1];

	reg [7:0] rom [0:524287];				// the M1 ROM, from the C++ side
	reg [18:0] rom_mask = 19'h1FFFF;

	wire [7:0] SDD_IN;
	wire nHALT, nZ80INT, nZ80NMI;
	wire ss_din_en, ss_int_force, ss_int_mask, ss_run, ss_ym_run, ss_ym_load, ss_sdw;
	wire [39:0] ym_ss_q, ym_ss_d;
	wire [7:0] ss_din;
	wire ss_nmi_n;
	assign RUN = ss_run;

	cpu_z80 Z80CPU(
		.CLK_4M	(CLK_4M),
		.nRESET	(nRESET),
		.SDA		(SDA),
		.SDD_IN	(DIN),
		.SDD_OUT	(SDD_OUT),
		.nIORQ	(nIORQ),
		.nMREQ	(nMREQ),
		.nRD		(nRD),
		.nWR		(nWR),
		.nINT		(ss_int_force ? 1'b0 : (nZ80INT | ss_int_mask)),
		.nNMI		(ss_nmi_n),
		.nWAIT	(nWAIT),
		.CEN		(~HALT_4M | ss_run),
		.nM1		(nM1),
		.nHALT	(nHALT)
	);
	assign DIN = ss_din_en ? ss_din : SDD_IN;

	// Wait states on reads below 0xF800, as cram_16bit's z80_ready makes
	// them while the M1 ROM comes from PSRAM: 0-3, from the address, so a
	// run's pattern follows its code (the stub's own fetches included)
	wire rom_rd = ~nMREQ & ~nRD & ((SDA[15:11] != 5'b11111) | wait_all);
	wire [1:0] rom_waits = wait_all ? 2'd2 : SDA[1:0] ^ SDA[3:2];
	reg rom_rd_r = 1'b0;
	reg [1:0] wait_left = 2'd0;
	always @(posedge CLK_4M) begin
		rom_rd_r <= rom_rd;
		if (rom_rd & ~rom_rd_r) wait_left <= rom_waits;
		else if (wait_left != 2'd0) wait_left <= wait_left - 1'd1;
	end
	wire nWAIT = ~(rom_rd & (rom_rd_r ? (wait_left != 2'd0) : (rom_waits != 2'd0)));

	// The machine's Z80 decode and banks
	wire nSDZ80R, nSDZ80W, nSDZ80CLR, nSDROM, nSDMRD, nSDMWR, SDRD0, SDRD1;
	wire n2610CS, n2610RD, n2610WR, nZRAMCS;
	wire nNMI_EN_Q;
	z80ctrl Z80CTRL(SDA[4:2], SDA[15:11], nRD, nWR, nMREQ, nIORQ, nSDW & ~ss_sdw, nRESET, nZ80NMI, nSDZ80R, nSDZ80W,
				nSDZ80CLR, nSDROM, nSDMRD, nSDMWR, SDRD0, SDRD1, n2610CS, n2610RD, n2610WR, nZRAMCS,
				nNMI_EN_Q);
	wire [18:11] MA;
	zmc ZMC(.nRESET(nRESET), .nSDRD0(SDRD0), .SDA_L(SDA[1:0]), .SDA_U(SDA[15:8]), .MA(MA), .WINDOWS());

	// The latches (c1_regs.v): the command, which a port 0 write clears,
	// and the reply
	reg [7:0] cmd_latch = 8'd0, rep_latch = 8'd0;
	always @(negedge nSDW or negedge nSDZ80CLR)
		if (!nSDZ80CLR) cmd_latch <= 8'd0;
		else cmd_latch <= cmd_in;
	always @(posedge nSDZ80W) rep_latch <= SDD_OUT;

	// Z80 RAM, its second port for the 68k stub through ss_z80
	wire [7:0] ram_q;
	wire [10:0] zram_addr;
	wire [7:0] zram_wdata, zram_q;
	wire zram_we;
	ss_dpram_2clk #(11, 8) Z80RAM(
		.clock_a		(CLK_4M),
		.address_a	(SDA[10:0]),
		.data_a		(SDD_OUT),
		.wren_a		(~(nZRAMCS | nSDMWR)),
		.q_a			(ram_q),
		.clock_b		(CLK_24M),
		.address_b	(zram_addr),
		.data_b		(zram_wdata),
		.wren_b		(zram_we),
		.q_b			(zram_q)
	);

	wire [7:0] ym_dout;
	jt10 YM2610(
		.rst					(~nRESET),
		.clk					(CLK_8M),
		.cen					(~HALT_8M | ss_ym_run),
		.addr					(SDA[1:0]),
		.din					(SDD_OUT),
		.dout					(ym_dout),
		.cs_n					(n2610CS),
		.wr_n					(n2610WR),
		.irq_n				(nZ80INT),
		.adpcma_addr		(),
		.adpcma_bank		(),
		.adpcma_roe_n		(),
		.adpcma_data		(8'd0),
		.adpcmb_addr		(),
		.adpcmb_roe_n		(),
		.adpcmb_data		(8'd0),
		.snd_right			(),
		.snd_left			(),
		.snd_enable			(),
		.ch_enable			(6'h3F),
		.ss_q					(ym_ss_q),
		.ss_load				(ss_ym_load),
		.ss_d					(ym_ss_d)
	);

	wire [7:0] rom_q = rom[{MA, SDA[10:0]} & rom_mask];
	assign SDD_IN = (~nSDZ80R) ? cmd_latch :
						 (~nSDMRD & ~nSDROM) ? rom_q :
						 (~nSDMRD & ~nZRAMCS) ? ram_q :
						 (~n2610CS & ~n2610RD) ? ym_dout :
						 8'b00000000;

	ss_z80 ss(
		.CLK_4M			(CLK_4M),
		.nRESET			(nRESET),
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
		.nNMI_LINE		(nZ80NMI),
		.SDW				(ss_sdw),
		.NMI_N			(ss_nmi_n),
		.DIN_EN			(ss_din_en),
		.DIN				(ss_din),
		.INT_FORCE		(ss_int_force),
		.INT_MASK		(ss_int_mask),
		.run				(ss_run),
		.YM_RUN			(ss_ym_run),
		.CLK_8M			(CLK_8M),
		.YM_SS_Q			(ym_ss_q),
		.YM_SS_LOAD		(ss_ym_load),
		.YM_SS_D			(ym_ss_d),
		.CLK_24M			(CLK_24M),
		.AUX_ADDR		(AUX_ADDR),
		.AUX_WE			(AUX_WE),
		.AUX_WDATA		(AUX_WDATA),
		.AUX_Q			(AUX_Q),
		.ZRAM_ADDR		(zram_addr),
		.ZRAM_WDATA		(zram_wdata),
		.ZRAM_WE			(zram_we),
		.ZRAM_Q			(zram_q)
	);

	reg [31:0] z80_time = 32'd0;
	assign Z80_TIME = z80_time;
	always @(posedge CLK_4M)
		if (!nRESET) z80_time <= 32'd0;
		else if (~HALT_4M | ss_run) z80_time <= z80_time + 1'd1;

endmodule
