// A stand-in for opb_psram_v (the CRAM0 PSRAM and its controller) at its
// OPB port, for benches: an access starts on OPB_select's rise and ends,
// some clocks later, with Sln_xferAck high until the next one starts, as
// psram_controller.v does. 16-bit accesses use BE[3:2] ({upper, lower});
// 32-bit writes put DBus[31:16] at the even word and DBus[15:0] after it.
module opb_psram_v(
	input [23:0]			OPB_ABus,
	input [3:0]				OPB_BE,
	input 					OPB_Clk,
	input [31:0]			OPB_DBus,
	input 					OPB_32Bit,
	input 					OPB_RNW,
	input 					OPB_Rst,
	input 					OPB_select,
	output reg [31:0]		Sln_DBus,
	output reg				Sln_xferAck,
	output [21:16]			cram_a,
	inout	 [15:0]			cram_dq,
	input						cram_wait,
	output					cram_clk,
	output 					cram_adv_n,
	output 					cram_cre,
	output 					cram_ce0_n,
	output 					cram_ce1_n,
	output 					cram_oe_n,
	output 					cram_we_n,
	output				   cram_ub_n,
	output				   cram_lb_n
);
	parameter LATENCY = 12;					// psram_controller takes about this many

	reg [15:0] mem [0:4194303];			// 8 MB: OPB_ABus[22:1]
	reg sel_r = 1'b0;
	reg [7:0] cnt = 8'd0;
	reg [23:0] a;
	reg [31:0] d;
	reg [3:0] be;
	reg rnw, w32;

	always @(posedge OPB_Clk) begin
		sel_r <= OPB_select;
		if (OPB_select & ~sel_r) begin
			Sln_xferAck <= 1'b0;
			a <= OPB_ABus; d <= OPB_DBus; be <= OPB_BE; rnw <= OPB_RNW; w32 <= OPB_32Bit;
			cnt <= LATENCY;
		end
		else if (cnt == 8'd1) begin
			cnt <= 8'd0;
			Sln_xferAck <= 1'b1;
			if (rnw) Sln_DBus <= {2{mem[a[22:1]]}};
			else if (w32) begin
				mem[{a[22:2], 1'b0}] <= d[31:16];
				mem[{a[22:2], 1'b1}] <= d[15:0];
			end
			else begin
				if (be[3]) mem[a[22:1]][15:8] <= d[15:8];
				if (be[2]) mem[a[22:1]][7:0]  <= d[7:0];
			end
		end
		else if (cnt != 8'd0) cnt <= cnt - 1'd1;
	end

	assign {cram_a, cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n,
			  cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n} = '1;
endmodule
