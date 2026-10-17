// Bench for cpu_68k's HALT: see tb_cpu68k_halt.sv.
//
//   obj/Vtb_cpu68k_halt <bios.rom> <halt: 0|1> <bus cycles> > trace.txt
//
// Prints one line per bus cycle: CPU time at its start, address, direction,
// strobes and data. With halt=1, HALT is raised for random stretches (1-64
// clocks, odd and even) about a third of the time; the trace must be identical
// to the halt=0 trace.
#include "Vtb_cpu68k_halt.h"
#include "Vtb_cpu68k_halt___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: %s bios.rom halt cycles\n", argv[0]); return 2; }
	const bool halts = atoi(argv[2]) != 0;
	const long want = atol(argv[3]);

	auto *ctx = new VerilatedContext;
	auto *m = new Vtb_cpu68k_halt{ctx};

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 2; }
	std::vector<uint8_t> bios(131072, 0xFF);
	size_t n = fread(bios.data(), 1, bios.size(), f);
	fclose(f);
	if (n != bios.size()) { fprintf(stderr, "%s: %zu bytes, expected 131072\n", argv[1], n); return 2; }
	for (int i = 0; i < 65536; i++)		// the file is little-endian words
		m->rootp->tb_cpu68k_halt__DOT__rom[i] = bios[2*i] | (bios[2*i+1] << 8);

	uint32_t lfsr = 0xACE1u;
	auto rnd = [&]() { lfsr ^= lfsr << 13; lfsr ^= lfsr >> 17; lfsr ^= lfsr << 5; return lfsr; };

	int halt_left = 0, run_left = 0;
	long cycles = 0, bus = 0, halted_clocks = 0, halt_events = 0;
	int prev_as = 1;
	uint32_t t_start = 0, addr = 0; int rw = 1, uds = 1, lds = 1; uint16_t data = 0;

	m->nRESET = 0; m->HALT = 0; m->CLK_24M = 0;
	while (bus < want && cycles < 400000000L) {
		if (cycles == 200) m->nRESET = 1;
		if (halts && cycles > 1000) {
			if (halt_left > 0) { if (--halt_left == 0) { m->HALT = 0; run_left = 1 + rnd() % 128; } }
			else if (run_left > 0) run_left--;
			else { m->HALT = 1; halt_left = 1 + rnd() % 64; halt_events++; }
		}
		halted_clocks += m->HALT;

		m->CLK_24M = 1; m->eval();
		m->CLK_24M = 0; m->eval();
		cycles++;

		if (prev_as && !m->nAS) {
			t_start = m->CPU_TIME; addr = m->ADDR << 1; rw = m->RW; uds = 1; lds = 1;
		}
		if (!m->nAS && (!m->nUDS || !m->nLDS)) {
			uds = m->nUDS; lds = m->nLDS; data = m->RW ? m->DIN : m->DOUT;
		}
		if (!prev_as && m->nAS) {
			printf("%10u %06x %c %d%d %04x\n", t_start, addr, rw ? 'R' : 'W', uds, lds, data);
			bus++;
		}
		prev_as = m->nAS;
	}
	fprintf(stderr, "%s: %ld bus cycles in %ld clocks, %ld halts covering %ld clocks\n",
		halts ? "halted" : "free", bus, cycles, halt_events, halted_clocks);
	m->final();
	delete m;
	delete ctx;
	return bus == want ? 0 : 1;
}
