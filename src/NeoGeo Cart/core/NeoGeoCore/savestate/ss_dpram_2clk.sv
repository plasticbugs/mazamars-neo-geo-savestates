// A true dual-port RAM with a clock per port, for savestates; port b is the
// 68k stub's. Written out as an altsyncram: an M10K with two read/write
// ports gives the new data on a write, not the old, and Quartus does not
// infer that from two always blocks. Nothing here reads a word in the cycle
// it writes it (the Z80 does not, nor the YM2610 shadow's snoop). A read on
// one port of a word the other writes is undefined.
module ss_dpram_2clk #(parameter ADDRWIDTH=8, DATAWIDTH=8)
(
	input							clock_a,
	input		[ADDRWIDTH-1:0]	address_a,
	input		[DATAWIDTH-1:0]	data_a,
	input							wren_a,
	output	[DATAWIDTH-1:0]	q_a,

	input							clock_b,
	input		[ADDRWIDTH-1:0]	address_b,
	input		[DATAWIDTH-1:0]	data_b,
	input							wren_b,
	output	[DATAWIDTH-1:0]	q_b
);

`ifdef VERILATOR
	reg [DATAWIDTH-1:0] memory [(2**ADDRWIDTH)-1:0];
	reg [DATAWIDTH-1:0] q_a_r, q_b_r;
	assign q_a = q_a_r;
	assign q_b = q_b_r;

	always @(posedge clock_a) begin
		if (wren_a) memory[address_a] <= data_a;
		q_a_r <= wren_a ? data_a : memory[address_a];
	end

	always @(posedge clock_b) begin
		if (wren_b) memory[address_b] <= data_b;
		q_b_r <= wren_b ? data_b : memory[address_b];
	end
`else
	altsyncram altsyncram_component (
				.address_a (address_a),
				.address_b (address_b),
				.clock0 (clock_a),
				.clock1 (clock_b),
				.data_a (data_a),
				.data_b (data_b),
				.wren_a (wren_a),
				.wren_b (wren_b),
				.q_a (q_a),
				.q_b (q_b),
				.aclr0 (1'b0),
				.aclr1 (1'b0),
				.addressstall_a (1'b0),
				.addressstall_b (1'b0),
				.byteena_a (1'b1),
				.byteena_b (1'b1),
				.clocken0 (1'b1),
				.clocken1 (1'b1),
				.clocken2 (1'b1),
				.clocken3 (1'b1),
				.eccstatus (),
				.rden_a (1'b1),
				.rden_b (1'b1));
	defparam
		altsyncram_component.address_reg_b = "CLOCK1",
		altsyncram_component.indata_reg_b = "CLOCK1",
		altsyncram_component.wrcontrol_wraddress_reg_b = "CLOCK1",
		altsyncram_component.numwords_a = 2**ADDRWIDTH,
		altsyncram_component.numwords_b = 2**ADDRWIDTH,
		altsyncram_component.widthad_a = ADDRWIDTH,
		altsyncram_component.widthad_b = ADDRWIDTH,
		altsyncram_component.width_a = DATAWIDTH,
		altsyncram_component.width_b = DATAWIDTH,
		altsyncram_component.width_byteena_a = 1,
		altsyncram_component.width_byteena_b = 1,
		altsyncram_component.clock_enable_input_a = "BYPASS",
		altsyncram_component.clock_enable_input_b = "BYPASS",
		altsyncram_component.clock_enable_output_a = "BYPASS",
		altsyncram_component.clock_enable_output_b = "BYPASS",
		altsyncram_component.intended_device_family = "Cyclone V",
		altsyncram_component.lpm_type = "altsyncram",
		altsyncram_component.operation_mode = "BIDIR_DUAL_PORT",
		altsyncram_component.outdata_aclr_a = "NONE",
		altsyncram_component.outdata_aclr_b = "NONE",
		altsyncram_component.outdata_reg_a = "UNREGISTERED",
		altsyncram_component.outdata_reg_b = "UNREGISTERED",
		altsyncram_component.power_up_uninitialized = "FALSE",
		altsyncram_component.read_during_write_mode_mixed_ports = "DONT_CARE",
		altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		altsyncram_component.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
`endif

endmodule
