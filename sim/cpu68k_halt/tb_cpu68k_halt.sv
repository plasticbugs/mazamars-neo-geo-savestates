// cpu_68k on a flat memory model, to check that HALT stops and resumes the
// CPU without skipping or repeating anything.
//
// The C++ side drives the clock, reset and HALT, logs every bus cycle, and
// compares a run with random halts against a run without: the same bus cycles,
// at the same CPU time (CLK_24M cycles in which the CPU was enabled).
//
// Memory: the BIOS at 0x000000 (vectors) and 0xC00000, 64 KB of work RAM at
// 0x100000, 0xFFFF everywhere else. DTACK is immediate. A level-7 interrupt
// (unmaskable: the BIOS runs with SR=2700) is raised every IRQ_PERIOD CPU
// cycles and dropped at its acknowledge, so exception processing is exercised
// too. With IPL2 low, cpu_68k gives no VPA, so the acknowledge reads vector
// 0xFF from the bus.
module tb_cpu68k_halt(
	input					CLK_24M,
	input					nRESET,
	input					HALT,
	output [23:1]		ADDR,
	output [15:0]		DOUT,
	output [15:0]		DIN,
	output				RW,
	output				nAS,
	output				nUDS,
	output				nLDS,
	output				CPU_EN,			// CPU was enabled this cycle
	output [31:0]		CPU_TIME
);

	localparam IRQ_PERIOD = 20000;

	reg [15:0] rom [0:65535];				// 128 KB, word-swapped on load by the C++ side
	reg [15:0] ram [0:32767];

	wire [15:0] FX68K_DATAIN, FX68K_DATAOUT;
	wire FC2, FC1, FC0;
	reg  IPL_n;

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
		.nDTACK			(nAS),
		.IPL2				(IPL_n),
		.IPL1				(IPL_n),
		.IPL0				(IPL_n),
		.FC2				(FC2),
		.FC1				(FC1),
		.FC0				(FC0),
		.nBG				(),
		.nBR				(1'b1),
		.nBGACK			(1'b1),
		.HALT				(HALT)
	);

	wire [23:0] byte_addr = {ADDR, 1'b0};
	wire is_rom = (byte_addr[23:17] == 7'h00) || (byte_addr[23:17] == 7'h60);
	wire is_ram = (byte_addr[23:16] == 8'h10);
	wire [15:0] rd = is_rom ? rom[byte_addr[16:1]] :
						  is_ram ? ram[byte_addr[15:1]] : 16'hFFFF;

	assign FX68K_DATAIN = RW ? rd : 16'h0000;
	assign DIN = rd;
	assign DOUT = FX68K_DATAOUT;

	always @(posedge CLK_24M)
		if (!nAS && !RW && is_ram) begin
			if (!nUDS) ram[byte_addr[15:1]][15:8] <= FX68K_DATAOUT[15:8];
			if (!nLDS) ram[byte_addr[15:1]][7:0]  <= FX68K_DATAOUT[7:0];
		end

	assign CPU_EN = dut.EN_PHI1 | dut.EN_PHI2;

	reg [31:0] cpu_time;
	assign CPU_TIME = cpu_time;
	wire iack = FC2 & FC1 & FC0 & ~nAS;

	always @(posedge CLK_24M)
		if (!nRESET) begin
			cpu_time <= 0;
			IPL_n <= 1'b1;
		end
		else begin
			if (CPU_EN) cpu_time <= cpu_time + 1;
			if (CPU_EN && cpu_time % IRQ_PERIOD == IRQ_PERIOD - 1) IPL_n <= 1'b0;
			if (iack) IPL_n <= 1'b1;
		end

endmodule
