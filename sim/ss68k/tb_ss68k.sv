// cpu_68k + ss_m68k on the flat memory model of sim/cpu68k_halt, with the
// savestate window backed by a RAM the C++ side can read and fill. Wired to
// the CPU the way Neogeo.sv wires it: ss_m68k's overrides go straight onto
// the CPU's data-in, DTACK and IPL inputs.
module tb_ss68k(
	input					CLK_24M,
	input					nRESET,
	input					ss_start,
	input					ss_load,
	output				ss_busy,
	output				ss_done,
	output [23:1]		ADDR,
	output [15:0]		DOUT,
	output [15:0]		DIN,
	output				RW,
	output				nAS,
	output				nUDS,
	output				nLDS,
	output [31:0]		CPU_TIME
);

	reg [15:0] rom [0:65535];				// BIOS, word-swapped on load by the C++ side
	reg [15:0] ram [0:32767];				// work RAM, 0x100000
	reg [15:0] win [0:262143];				// the savestate buffer

	wire [15:0] FX68K_DATAIN, FX68K_DATAOUT;
	wire FC2, FC1, FC0;

	wire ss_ipl7, ss_din_en, ss_dtack_en, ss_ndtack;
	wire [15:0] ss_din;
	wire win_rd, win_wr;
	wire [18:1] win_addr;
	wire [15:0] win_wdata;
	wire [1:0] win_be;
	reg  [15:0] win_rdata;
	reg  win_ack;

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
		.HALT				(1'b0)
	);

	ss_m68k ss(
		.CLK				(CLK_24M),
		.nRESET			(nRESET),
		.start			(ss_start),
		.load				(ss_load),
		.busy				(ss_busy),
		.done				(ss_done),
		.M68K_ADDR		(ADDR),
		.nAS				(nAS),
		.M68K_RW			(RW),
		.nUDS				(nUDS),
		.nLDS				(nLDS),
		.FC2				(FC2),
		.FC1				(FC1),
		.FC0				(FC0),
		.M68K_DOUT		(FX68K_DATAOUT),
		.IPL7				(ss_ipl7),
		.DIN_EN			(ss_din_en),
		.DIN				(ss_din),
		.DTACK_EN		(ss_dtack_en),
		.nDTACK			(ss_ndtack),
		.win_rd			(win_rd),
		.win_wr			(win_wr),
		.win_addr		(win_addr),
		.win_wdata		(win_wdata),
		.win_be			(win_be),
		.win_rdata		(win_rdata),
		.win_ack			(win_ack),
		.SHADOW			(128'd0),
		.VRAM_ADDR		(),
		.VRAM_WDATA		(),
		.SVRAM_WE		(),
		.FVRAM_WE		(),
		.SVRAM_Q			(16'd0),
		.FVRAM_Q			(16'd0),
		.CHIP_TYPE		(4'd0),				// no cartridge chip
		.CHIP_Q			(40'd0)
	);

	wire [23:0] byte_addr = {ADDR, 1'b0};
	wire is_rom = (byte_addr[23:17] == 7'h00) || (byte_addr[23:17] == 7'h60);
	wire is_ram = (byte_addr[23:16] == 8'h10);
	wire [15:0] rd = is_rom ? rom[byte_addr[16:1]] :
						  is_ram ? ram[byte_addr[15:1]] : 16'hFFFF;

	assign FX68K_DATAIN = ss_din_en ? ss_din : RW ? rd : 16'h0000;
	assign DIN = FX68K_DATAIN;
	assign DOUT = FX68K_DATAOUT;

	always @(posedge CLK_24M)
		if (!nAS && !RW && is_ram) begin
			if (!nUDS) ram[byte_addr[15:1]][15:8] <= FX68K_DATAOUT[15:8];
			if (!nLDS) ram[byte_addr[15:1]][7:0]  <= FX68K_DATAOUT[7:0];
		end

	// The window: a few clocks of latency, like a real memory behind a port
	reg [2:0] win_wait;
	reg win_pend, win_pend_wr;
	reg [18:1] win_pa;
	reg [15:0] win_pd;
	reg [1:0] win_pbe;
	always @(posedge CLK_24M) begin
		win_ack <= 1'b0;
		if (win_rd | win_wr) begin
			win_pend <= 1'b1;
			win_pend_wr <= win_wr;
			win_pa <= win_addr;
			win_pd <= win_wdata;
			win_pbe <= win_be;
			win_wait <= 3'd3;
		end
		else if (win_pend) begin
			if (win_wait != 0) win_wait <= win_wait - 1'd1;
			else begin
				win_pend <= 1'b0;
				win_ack <= 1'b1;
				if (win_pend_wr) begin
					if (win_pbe[1]) win[win_pa][15:8] <= win_pd[15:8];
					if (win_pbe[0]) win[win_pa][7:0]  <= win_pd[7:0];
				end
				else win_rdata <= win[win_pa];
			end
		end
	end

	reg [31:0] cpu_time;
	assign CPU_TIME = cpu_time;
	always @(posedge CLK_24M)
		if (!nRESET) cpu_time <= 0;
		else if (dut.EN_PHI1 | dut.EN_PHI2) cpu_time <= cpu_time + 1;

endmodule
