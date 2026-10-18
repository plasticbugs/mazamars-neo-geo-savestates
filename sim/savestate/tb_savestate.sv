// The savestate path end to end, wired as Neogeo.sv wires it: cpu_68k with
// savestate (ss_m68k, ss_mem) and cram_16bit, whose PSRAM is psram_model.sv.
// The CPU runs the BIOS from a flat ROM with flat work RAM, as in
// sim/ss68k, plus what the stub saves besides: the system latch, palette
// RAM in two banks, the LSPC's write-only registers, the P-ROM bank, and
// the VRAMs on their second port. The Z80 side is sim/ssz80's: T80 running
// a game's M1 ROM, with z80ctrl, zmc, Z80 RAM on a second port and jt10,
// and the sound latches on the 68k's bus at 0x320000 as c1_regs.v has them.
// The menu halts both CPUs and the YM2610 as in Neogeo.sv; the C++ side
// plays the Pocket: core_bridge_cmd's savestate signals and the bridge.
module tb_savestate(
	input					clk_74a,
	input					clk_sys,
	input					nRESET,
	input					menu,				// osnotify_inmenu

	input					savestate_start,
	output				savestate_start_ack,
	output				savestate_start_busy,
	output				savestate_start_ok,
	output				savestate_start_err,
	input					savestate_load,
	output				savestate_load_ack,
	output				savestate_load_busy,
	output				savestate_load_ok,
	output				savestate_load_err,

	input		[31:0]	bridge_addr,
	input					bridge_rd,
	input					bridge_wr,
	input		[31:0]	bridge_wr_data,
	output	[31:0]	bridge_rd_data,

	output				CLK_24M,
	output [23:1]		ADDR,
	output [15:0]		DOUT,
	output [15:0]		DIN,
	output				RW,
	output				nAS,
	output				nUDS,
	output				nLDS,
	output [31:0]		CPU_TIME,
	output				RUN_68K,

	// The Z80's bus, for its trace
	output	[15:0]	SDA,
	output	[7:0]		Z80_DIN,			// what the Z80 reads
	output	[7:0]		SDD_OUT,
	output				nMREQ,
	output				nIORQ,
	output				nRD,
	output				nWR,
	output				nM1,
	output	[31:0]	Z80_TIME,
	output	[4:0]		DIV				// clk_sys mod 24: the clocks' phase
);

	// CLK_24M, CLK_8M and CLK_4M from one divider, in phase as the core's
	// PLL gives them
	reg [4:0] div = 5'd0;
	reg CLK_8M = 1'b0, CLK_4M = 1'b0;
	always @(posedge clk_sys) begin
		div <= (div == 5'd23) ? 5'd0 : div + 1'd1;
		CLK_8M <= (div >= 5'd5 && div < 5'd11) || (div >= 5'd17 && div < 5'd23);
		CLK_4M <= (div >= 5'd11 && div < 5'd23);
	end
	assign CLK_24M = div[1];
	assign DIV = div;

	reg [1:0] halt_24m_sr = 2'b00, halt_4m_sr = 2'b00, halt_8m_sr = 2'b00;
	always @(posedge CLK_24M) halt_24m_sr <= {halt_24m_sr[0], menu};
	always @(posedge CLK_4M) halt_4m_sr <= {halt_4m_sr[0], menu};
	always @(posedge CLK_8M) halt_8m_sr <= {halt_8m_sr[0], menu};
	wire HALT_24M = halt_24m_sr[1], HALT_4M = halt_4m_sr[1], HALT_8M = halt_8m_sr[1];

	reg [15:0] rom [0:65535];				// BIOS, word-swapped on load by the C++ side
	reg [15:0] ram [0:32767];				// work RAM, 0x100000

	wire [15:0] FX68K_DATAIN, FX68K_DATAOUT;
	wire FC2, FC1, FC0;

	wire ss_run_68k, ss_ipl7, ss_din_en, ss_dtack_en, ss_ndtack;
	wire [15:0] ss_din;
	wire ss_rd, ss_wr, ss_ack;
	wire [18:1] ss_addr;
	wire [15:0] ss_data, ss_q;
	wire [1:0] ss_be;
	assign RUN_68K = ss_run_68k;

	// The Z80 side (below)
	wire [7:0] SDD_IN;
	wire nHALT, nZ80INT, nZ80NMI, nWAIT;
	wire ss_z80_din_en, ss_z80_int_force, ss_z80_int_mask, ss_run_z80, ss_ym_run, ss_ym_load, ss_z80_sdw;
	wire [39:0] ym_ss_q, ym_ss_d;
	wire [7:0] ss_z80_din;
	wire ss_z80_nmi_n;
	wire nSDZ80R, nSDZ80W, nSDZ80CLR, nSDROM, nSDMRD, nSDMWR, SDRD0, SDRD1;
	wire n2610CS, n2610RD, n2610WR, nZRAMCS;
	wire nNMI_EN_Q;
	wire [31:0] z80_windows;
	reg [7:0] cmd_latch = 8'd0, rep_latch = 8'd0;
	wire [10:0] zram_addr;
	wire [7:0] zram_wdata, zram_q;
	wire zram_we;

	cpu_68k dut(
		.CLK_24M			(CLK_24M),
		.nRESET			(nRESET),
		.M68K_ADDR		(ADDR),
		.FX68K_DATAIN	(FX68K_DATAIN),
		.FX68K_DATAOUT	(FX68K_DATAOUT),
		.nLDS				(nLDS),
		.nUDS				(nUDS),
		.nAS				(nAS),
		.M68K_RW			(RW),
		.nDTACK			(ss_dtack_en ? ss_ndtack : nAS),
		.IPL2				(~ss_ipl7),
		.IPL1				(~ss_ipl7),
		.IPL0				(~ss_ipl7),
		.FC2				(FC2),
		.FC1				(FC1),
		.FC0				(FC0),
		.nBG				(),
		.nBR				(1'b1),
		.nBGACK			(1'b1),
		.HALT				(HALT_24M & ~ss_run_68k)
	);

	// What the stub reaches besides work RAM, as the C++ side scribbles it
	reg [7:0] slatch = 8'd0;						// syslatch.v
	reg [15:0] pal [0:8191];						// {PALBNK, word}
	reg [15:0] vramaddr = 16'd0, vrammod = 16'd0, lspcmode = 16'd0;
	reg [3:0] p_bank = 4'd0;
	reg [15:0] svram [0:32767];
	reg [15:0] fvram [0:2047];
	wire [127:0] shadow = {{7'd0, ~nNMI_EN_Q, cmd_latch}, z80_windows, {12'd0, p_bank},
								  lspcmode, vrammod, vramaddr, {8'd0, slatch}};
	wire [14:0] vram_addr;
	wire [15:0] vram_wdata;
	wire svram_we, fvram_we;
	reg [15:0] svram_q, fvram_q;
	always @(posedge CLK_24M) begin
		if (svram_we) svram[vram_addr] <= vram_wdata;
		svram_q <= svram[vram_addr];
		if (fvram_we) fvram[vram_addr[10:0]] <= vram_wdata;
		fvram_q <= fvram[vram_addr[10:0]];
	end

	savestate ss(
		.clk_74a					(clk_74a),
		.clk_sys					(clk_sys),
		.CLK_24M					(CLK_24M),
		.nRESET					(nRESET),
		.savestate_start		(savestate_start),
		.savestate_start_ack	(savestate_start_ack),
		.savestate_start_busy(savestate_start_busy),
		.savestate_start_ok	(savestate_start_ok),
		.savestate_start_err	(savestate_start_err),
		.savestate_load		(savestate_load),
		.savestate_load_ack	(savestate_load_ack),
		.savestate_load_busy	(savestate_load_busy),
		.savestate_load_ok	(savestate_load_ok),
		.savestate_load_err	(savestate_load_err),
		.M68K_ADDR				(ADDR),
		.nAS						(nAS),
		.M68K_RW					(RW),
		.nUDS						(nUDS),
		.nLDS						(nLDS),
		.FC2						(FC2),
		.FC1						(FC1),
		.FC0						(FC0),
		.M68K_DOUT				(FX68K_DATAOUT),
		.run_68k					(ss_run_68k),
		.IPL7						(ss_ipl7),
		.DIN_EN					(ss_din_en),
		.DIN						(ss_din),
		.DTACK_EN				(ss_dtack_en),
		.nDTACK					(ss_ndtack),
		.bridge_addr			(bridge_addr),
		.bridge_rd				(bridge_rd),
		.bridge_wr				(bridge_wr),
		.bridge_wr_data		(bridge_wr_data),
		.bridge_rd_data		(bridge_rd_data),
		.ss_rd					(ss_rd),
		.ss_wr					(ss_wr),
		.ss_addr					(ss_addr),
		.ss_data					(ss_data),
		.ss_be					(ss_be),
		.ss_q						(ss_q),
		.ss_ack					(ss_ack),
		.SHADOW					(shadow),
		.VRAM_ADDR				(vram_addr),
		.VRAM_WDATA				(vram_wdata),
		.SVRAM_WE				(svram_we),
		.FVRAM_WE				(fvram_we),
		.SVRAM_Q					(svram_q),
		.FVRAM_Q					(fvram_q),
		.CLK_4M					(CLK_4M),
		.CLK_8M					(CLK_8M),
		.Z80_nRESET				(nRESET),
		.SDA						(SDA),
		.nMREQ					(nMREQ),
		.nIORQ					(nIORQ),
		.nRD						(nRD),
		.nWR						(nWR),
		.nM1						(nM1),
		.nHALT					(nHALT),
		.SDD_OUT					(SDD_OUT),
		.SDD_IN					(SDD_IN),
		.n2610WR					(n2610WR),
		.nNMI_LINE				(nZ80NMI),
		.Z80_SDW					(ss_z80_sdw),
		.Z80_NMI_N				(ss_z80_nmi_n),
		.Z80_DIN_EN				(ss_z80_din_en),
		.Z80_DIN					(ss_z80_din),
		.Z80_INT_FORCE			(ss_z80_int_force),
		.Z80_INT_MASK			(ss_z80_int_mask),
		.run_z80					(ss_run_z80),
		.YM_RUN					(ss_ym_run),
		.YM_SS_Q					(ym_ss_q),
		.YM_SS_LOAD				(ss_ym_load),
		.YM_SS_D					(ym_ss_d),
		.ZRAM_ADDR				(zram_addr),
		.ZRAM_WDATA				(zram_wdata),
		.ZRAM_WE					(zram_we),
		.ZRAM_Q					(zram_q)
	);

	// CRAM0's controller with only the savestate port in use
	wire [15:0] cram_dq;
	cram_16bit cram(
		.reset_l_main		(1'b1),
		.nRESET				(nRESET),
		.sys_clk				(clk_sys),
		.cram_clock			(clk_sys),
		.cram_a				(),
		.cram_dq				(cram_dq),
		.cram_wait			(1'b0),
		.cram_clk			(),
		.cram_adv_n			(),
		.cram_cre			(),
		.cram_ce0_n			(),
		.cram_ce1_n			(),
		.cram_oe_n			(),
		.cram_we_n			(),
		.cram_ub_n			(),
		.cram_lb_n			(),
		.word_rd				(1'b0),
		.word_wr				(1'b0),
		.word_32bit			(1'b0),
		.word_addr			(24'd0),
		.word_data			(32'd0),
		.word_q				(),
		.word_busy			(),
		.ss_rd				(ss_rd),
		.ss_wr				(ss_wr),
		.ss_addr				(ss_addr),
		.ss_data				(ss_data),
		.ss_be				(ss_be),
		.ss_q					(ss_q),
		.ss_ack				(ss_ack),
		.nSYSTEM_G			(1'b1),
		.SROM_MASK			(19'd0),
		.PBUS					(16'd0),
		.PCK2					(1'b0),
		.FIX_BANK			(2'd0),
		.SROM_DATA			(),
		.M68K_ADDR			(20'd0),
		.M68K_DATA			(16'd0),
		.nAS					(1'b1),
		.nLDS					(1'b1),
		.nUDS					(1'b1),
		.nROMOE				(1'b1),
		.nPORTOE				(1'b1),
		.nSROMOE				(1'b1),
		.DATA_TYPE			(1'b0),
		.P2ROM_ADDR			(25'd0),
		.PROM_DATA			(),
		.PROM_DATA_READY	(),
		.z80_clk				(1'b0),
		.z80_rdaddr			(19'd0),
		.z80_dout			(),
		.z80_nSDMRD			(1'b1),
		.z80_nSDROM			(1'b1),
		.z80_ready			()
	);

	wire [23:0] byte_addr = {ADDR, 1'b0};
	wire is_rom = (byte_addr[23:17] == 7'h00) || (byte_addr[23:17] == 7'h60);
	wire is_ram = (byte_addr[23:16] == 8'h10);
	wire is_pal = (byte_addr[23:22] == 2'b01);
	wire [12:0] pal_a = {slatch[7], byte_addr[12:1]};
	wire is_icom = (byte_addr[23:17] == 7'b0011001);	// 0x320000, REG_SOUND
	wire [15:0] rd = is_rom ? rom[byte_addr[16:1]] :
						  is_ram ? ram[byte_addr[15:1]] :
						  is_pal ? pal[pal_a] :
						  is_icom ? {rep_latch, 8'hFF} : 16'hFFFF;

	assign FX68K_DATAIN = ss_din_en ? ss_din : RW ? rd : 16'h0000;
	assign DIN = FX68K_DATAIN;
	assign DOUT = FX68K_DATAOUT;

	always @(posedge CLK_24M)
		if (!nAS && !RW && is_ram) begin
			if (!nUDS) ram[byte_addr[15:1]][15:8] <= FX68K_DATAOUT[15:8];
			if (!nLDS) ram[byte_addr[15:1]][7:0]  <= FX68K_DATAOUT[7:0];
		end

	// The rest, on the write's strobe edge
	reg wr_seen = 1'b0;
	always @(posedge CLK_24M) begin
		if (nAS) wr_seen <= 1'b0;
		else if (!RW && !(nUDS && nLDS) && !wr_seen) begin
			wr_seen <= 1'b1;
			if (is_pal) begin
				if (!nUDS) pal[pal_a][15:8] <= FX68K_DATAOUT[15:8];
				if (!nLDS) pal[pal_a][7:0]  <= FX68K_DATAOUT[7:0];
			end
			if (byte_addr[23:16] == 8'h3A && byte_addr[15:5] == 0 && !nLDS)
				slatch[byte_addr[3:1]] <= byte_addr[4];
			if (byte_addr[23:16] == 8'h3C) case (byte_addr[3:1])
				3'd0: vramaddr <= FX68K_DATAOUT;
				3'd2: vrammod <= FX68K_DATAOUT;
				3'd3: lspcmode <= FX68K_DATAOUT;
				default: ;
			endcase
			if (byte_addr[23:20] == 4'h2 && !nLDS) p_bank <= FX68K_DATAOUT[3:0];
		end
	end

	// The Z80 side, as Neogeo.sv has it (sim/ssz80/tb_ssz80.sv)
	cpu_z80 Z80CPU(
		.CLK_4M	(CLK_4M),
		.nRESET	(nRESET),
		.SDA		(SDA),
		.SDD_IN	(Z80_DIN),
		.SDD_OUT	(SDD_OUT),
		.nIORQ	(nIORQ),
		.nMREQ	(nMREQ),
		.nRD		(nRD),
		.nWR		(nWR),
		.nINT		(ss_z80_int_force ? 1'b0 : (nZ80INT | ss_z80_int_mask)),
		.nNMI		(ss_z80_nmi_n),
		.nWAIT	(nWAIT),
		.CEN		(~HALT_4M | ss_run_z80),
		.nM1		(nM1),
		.nHALT	(nHALT)
	);
	assign Z80_DIN = ss_z80_din_en ? ss_z80_din : SDD_IN;

	// Wait states on reads below 0xF800, as cram_16bit's z80_ready makes
	// them while the M1 ROM comes from PSRAM: 0-3, from the address
	wire rom_rd = ~nMREQ & ~nRD & (SDA[15:11] != 5'b11111);
	wire [1:0] rom_waits = SDA[1:0] ^ SDA[3:2];
	reg rom_rd_r = 1'b0;
	reg [1:0] wait_left = 2'd0;
	always @(posedge CLK_4M) begin
		rom_rd_r <= rom_rd;
		if (rom_rd & ~rom_rd_r) wait_left <= rom_waits;
		else if (wait_left != 2'd0) wait_left <= wait_left - 1'd1;
	end
	assign nWAIT = ~(rom_rd & (rom_rd_r ? (wait_left != 2'd0) : (rom_waits != 2'd0)));

	wire nICOM = nUDS | ~is_icom;			// REG_SOUND's even byte
	wire nSDW = RW | nICOM;
	z80ctrl Z80CTRL(SDA[4:2], SDA[15:11], nRD, nWR, nMREQ, nIORQ, nSDW & ~ss_z80_sdw, nRESET, nZ80NMI, nSDZ80R, nSDZ80W,
				nSDZ80CLR, nSDROM, nSDMRD, nSDMWR, SDRD0, SDRD1, n2610CS, n2610RD, n2610WR, nZRAMCS,
				nNMI_EN_Q);
	wire [18:11] MA;
	zmc ZMC(.nRESET(nRESET), .nSDRD0(SDRD0), .SDA_L(SDA[1:0]), .SDA_U(SDA[15:8]), .MA(MA), .WINDOWS(z80_windows));

	// The sound latches (c1_regs.v): a write to REG_SOUND loads the command
	// on nICOM's falling edge, a port 0 write clears it; the Z80's port 0x0C
	// write loads the reply.
	always @(negedge nICOM or negedge nSDZ80CLR)
		if (!nSDZ80CLR) cmd_latch <= 8'd0;
		else if (!RW) cmd_latch <= FX68K_DATAOUT[15:8];
	always @(posedge nSDZ80W) rep_latch <= SDD_OUT;

	wire [7:0] z80ram_q;
	ss_dpram_2clk #(11, 8) Z80RAM(
		.clock_a		(CLK_4M),
		.address_a	(SDA[10:0]),
		.data_a		(SDD_OUT),
		.wren_a		(~(nZRAMCS | nSDMWR)),
		.q_a			(z80ram_q),
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

	reg [7:0] m1rom [0:524287];				// the M1 ROM, from the C++ side
	reg [18:0] m1_mask = 19'h1FFFF;
	wire [7:0] m1_q = m1rom[{MA, SDA[10:0]} & m1_mask];
	assign SDD_IN = (~nSDZ80R) ? cmd_latch :
						 (~nSDMRD & ~nSDROM) ? m1_q :
						 (~nSDMRD & ~nZRAMCS) ? z80ram_q :
						 (~n2610CS & ~n2610RD) ? ym_dout :
						 8'b00000000;

	reg [31:0] z80_time = 32'd0;
	assign Z80_TIME = z80_time;
	always @(posedge CLK_4M)
		if (!nRESET) z80_time <= 32'd0;
		else if (~HALT_4M | ss_run_z80) z80_time <= z80_time + 1'd1;

	reg [31:0] cpu_time;
	assign CPU_TIME = cpu_time;
	always @(posedge CLK_24M)
		if (!nRESET) cpu_time <= 0;
		else if (dut.EN_PHI1 | dut.EN_PHI2) cpu_time <= cpu_time + 1;

endmodule
