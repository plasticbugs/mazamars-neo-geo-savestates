// Savestates: the buffer in CRAM0 (docs/savestate-design.md).
//
// Two users share cram_16bit's ss_* port, 512 KB at CRAM0 0xA80000:
//
//   the 68k stub's window (ss_m68k, CLK_24M), 16-bit words;
//   the Pocket, over the bridge at 0x80000000 (clk_74a), 32-bit words,
//   big-endian: bridge word n is {window word 2n, window word 2n+1}.
//
// They never run at once: the Pocket reads the buffer after a save has
// finished and writes it before it asks for a load.
//
// Bridge reads are pipelined: a read strobe's data has until the next read
// strobe to appear on bridge_rd_data. Each read starts a fetch of the word
// after it, so a sequential read is answered from that prefetch at once.

module ss_mem
(
	input					clk_sys,

	// The stub's window, CLK_24M (ss_m68k)
	input					CLK_24M,
	input					win_rd,
	input					win_wr,
	input		[18:1]	win_addr,			// held until the next request
	input		[15:0]	win_wdata,
	input		[1:0]		win_be,
	output reg	[15:0]	win_rdata,
	output reg			win_ack,

	// The bridge, clk_74a
	input		[31:0]	bridge_addr,
	input					bridge_rd,
	input					bridge_wr,
	input		[31:0]	bridge_wr_data,
	output reg	[31:0]	bridge_rd_data,

	// cram_16bit's savestate port, clk_sys
	output reg			ss_rd,
	output reg			ss_wr,
	output reg	[18:1]	ss_addr,
	output reg	[15:0]	ss_data,
	output reg	[1:0]		ss_be,
	input		[15:0]	ss_q,
	input					ss_ack
);

	// Window requests cross to clk_sys as a toggle; the address and data
	// are held by ss_m68k from before the toggle until after the ack.
	reg win_req_t = 1'b0, win_we = 1'b0;
	always @(posedge CLK_24M)
		if (win_rd | win_wr) begin
			win_req_t <= ~win_req_t;
			win_we <= win_wr;
		end

	reg [2:0] win_req_s = 3'b000;
	reg win_ack_t = 1'b0;
	reg [15:0] win_q;

	reg [2:0] win_ack_s = 3'b000;
	always @(posedge CLK_24M) begin
		win_ack_s <= {win_ack_s[1:0], win_ack_t};
		win_ack <= win_ack_s[2] ^ win_ack_s[1];
		if (win_ack_s[2] ^ win_ack_s[1]) win_rdata <= win_q;
	end

	// The bridge, synchronised the way ram_32_bit_sfix_state_controller does
	wire bridge_rd_f, bridge_wr_f;
	wire [31:0] bridge_addr_s, bridge_wr_data_s;
	synch_3 s00(bridge_rd, , clk_sys, , bridge_rd_f);
	synch_3 s01(bridge_wr, , clk_sys, , bridge_wr_f);
	synch_3 #(.WIDTH(32)) s02(bridge_addr, bridge_addr_s, clk_sys);
	synch_3 #(.WIDTH(32)) s03(bridge_wr_data, bridge_wr_data_s, clk_sys);
	wire bridge_ss = (bridge_addr_s[31:28] == 4'h8);

	localparam J_IDLE = 3'd0, J_WIN = 3'd1, J_BWR = 3'd2, J_BRD = 3'd3, J_PF = 3'd4;
	reg [2:0] job = J_IDLE;
	reg step;							// 0 the high word, 1 the low word

	reg win_pend = 1'b0;
	reg bwr_pend = 1'b0, brd_pend = 1'b0;
	reg [18:2] bwr_idx, brd_idx, cur_idx;
	reg [31:0] bwr_data;
	reg [15:0] lo_data, hi_q;

	reg pf_want = 1'b0, pf_valid = 1'b0;
	reg [18:2] pf_idx;
	reg [31:0] pf_data;

	always @(posedge clk_sys) begin
		ss_rd <= 1'b0;
		ss_wr <= 1'b0;

		win_req_s <= {win_req_s[1:0], win_req_t};
		if (win_req_s[2] ^ win_req_s[1]) win_pend <= 1'b1;
		if (bridge_wr_f & bridge_ss) begin
			bwr_pend <= 1'b1;
			bwr_idx <= bridge_addr_s[18:2];
			bwr_data <= bridge_wr_data_s;
		end
		if (bridge_rd_f & bridge_ss) begin
			brd_pend <= 1'b1;
			brd_idx <= bridge_addr_s[18:2];
		end

		case (job)
			J_IDLE: begin
				step <= 1'b0;
				if (win_pend) begin
					win_pend <= 1'b0;
					job <= J_WIN;
					ss_rd <= ~win_we;
					ss_wr <= win_we;
					ss_addr <= win_addr;
					ss_data <= win_wdata;
					ss_be <= win_be;
					if (win_we) pf_valid <= 1'b0;
				end
				else if (bwr_pend) begin
					bwr_pend <= 1'b0;
					pf_valid <= 1'b0;
					pf_want <= 1'b0;
					job <= J_BWR;
					ss_wr <= 1'b1;
					ss_addr <= {bwr_idx, 1'b0};
					ss_data <= bwr_data[31:16];
					ss_be <= 2'b11;
					lo_data <= bwr_data[15:0];
				end
				else if (brd_pend) begin
					brd_pend <= 1'b0;
					if (pf_valid && pf_idx == brd_idx) begin
						bridge_rd_data <= pf_data;
						pf_valid <= 1'b0;
						pf_want <= 1'b1;
						pf_idx <= brd_idx + 1'd1;
					end
					else begin
						job <= J_BRD;
						ss_rd <= 1'b1;
						ss_addr <= {brd_idx, 1'b0};
						cur_idx <= brd_idx;
					end
				end
				else if (pf_want) begin
					pf_want <= 1'b0;
					job <= J_PF;
					ss_rd <= 1'b1;
					ss_addr <= {pf_idx, 1'b0};
				end
			end

			default: if (ss_ack) begin
				if (job == J_WIN) begin
					win_q <= ss_q;
					win_ack_t <= ~win_ack_t;
					job <= J_IDLE;
				end
				else if (~step) begin			// the low word next
					step <= 1'b1;
					hi_q <= ss_q;
					ss_addr[1] <= 1'b1;
					ss_rd <= (job != J_BWR);
					ss_wr <= (job == J_BWR);
					ss_data <= lo_data;
				end
				else begin
					job <= J_IDLE;
					if (job == J_BRD) begin
						bridge_rd_data <= {hi_q, ss_q};
						pf_valid <= 1'b0;
						pf_want <= 1'b1;
						pf_idx <= cur_idx + 1'd1;
					end
					if (job == J_PF) begin
						pf_data <= {hi_q, ss_q};
						pf_valid <= 1'b1;
					end
				end
			end
		endcase
	end

endmodule
