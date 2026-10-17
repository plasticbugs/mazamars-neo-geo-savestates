// 68k savestate round trip: see tb_ss68k.sv.
//
//   obj/Vtb_ss68k <bios.rom> save <at bus cycle> <log cycles> <state.bin> > a.txt
//   obj/Vtb_ss68k <bios.rom> load <at bus cycle> <log cycles> <state.bin> > b.txt
//
// save: run to the given bus cycle, run the save stub, write the window to
//       state.bin, then log the bus cycles that follow the stub's RTE.
// load: run to the given bus cycle, overwrite work RAM with noise, fill the
//       window from state.bin, run the load stub, log what follows its RTE.
// The two logs must be identical: one line per bus cycle, with CPU time
// counted from the first cycle after the stub.
//
//   obj/Vtb_ss68k <bios.rom> loadsave <at bus cycle> 0 <state.bin> <state2.bin>
//
// loadsave: load as above, then save again at once: requested as the load
//       stub's RTE pops the frame, so the interrupt is taken when the RTE
//       ends, before another instruction runs,
//       so state2.bin must equal state.bin byte for byte (registers, USP,
//       SSP, frame and work RAM). This checks every register, which the
//       trace comparison only does as far as the code it runs reads them.
#include "Vtb_ss68k.h"
#include "Vtb_ss68k___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char **argv) {
	if (argc < 6) { fprintf(stderr, "usage: %s bios save|load at log state.bin\n", argv[0]); return 2; }
	const bool loadsave = !strcmp(argv[2], "loadsave");
	const bool load = loadsave || !strcmp(argv[2], "load");
	if (loadsave && argc < 7) { fprintf(stderr, "loadsave needs state2.bin\n"); return 2; }
	const long at = atol(argv[3]), want = atol(argv[4]);
	const char *state = argv[5];

	auto *ctx = new VerilatedContext;
	auto *m = new Vtb_ss68k{ctx};
	auto *r = m->rootp;

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 2; }
	std::vector<uint8_t> bios(131072);
	if (fread(bios.data(), 1, bios.size(), f) != bios.size()) { fprintf(stderr, "short BIOS\n"); return 2; }
	fclose(f);
	for (int i = 0; i < 65536; i++) r->tb_ss68k__DOT__rom[i] = bios[2*i] | (bios[2*i+1] << 8);

	const int WIN_WORDS = 262144;
	long cycles = 0, bus = 0, logged = 0;
	int prev_as = 1, phase = 0;		// 0 run to `at`, 1 stub, 2 log
	uint32_t t0 = 0, t_start = 0, addr = 0; int rw = 1, uds = 1, lds = 1; uint16_t data = 0;

	m->nRESET = 0; m->ss_start = 0; m->ss_load = load; m->CLK_24M = 0;
	while ((loadsave || logged < want) && cycles < 400000000L) {
		if (cycles == 200) m->nRESET = 1;
		if (phase != 4) m->ss_start = 0;
		else if (m->ss_start && m->ss_busy) m->ss_start = 0;
		if (phase == 0 && bus == at && m->nAS) {
			if (load) {
				uint32_t x = 0x12345678;
				for (int i = 0; i < 32768; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; r->tb_ss68k__DOT__ram[i] = x; }
				// And the CPU's registers: D0-D7, A0-A6, USP (FX68K slots 0-15) to noise,
				// SSP (16) to somewhere else in work RAM, so a register the load
				// stub forgot cannot match by luck.
				auto &rl = r->tb_ss68k__DOT__dut__DOT__FX68K__DOT__excUnit__DOT__regs68L;
				auto &rh = r->tb_ss68k__DOT__dut__DOT__FX68K__DOT__excUnit__DOT__regs68H;
				for (int i = 0; i < 16; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; rl[i] = x; rh[i] = x >> 16; }
				x ^= x << 13; x ^= x >> 17; x ^= x << 5;
				rh[16] = 0x0010; rl[16] = 0x1000 + (x & 0xDFFE);
				FILE *s = fopen(state, "rb");
				if (!s) { perror(state); return 2; }
				std::vector<uint16_t> w(WIN_WORDS);
				if (fread(w.data(), 2, WIN_WORDS, s) != (size_t)WIN_WORDS) { fprintf(stderr, "short state\n"); return 2; }
				fclose(s);
				for (int i = 0; i < WIN_WORDS; i++) r->tb_ss68k__DOT__win[i] = w[i];
			}
			m->ss_start = 1;
			phase = 1;
			fprintf(stderr, "%s: stub requested at bus cycle %ld, clock %ld\n", load ? "load" : "save", bus, cycles);
		}

		m->CLK_24M = 1; m->eval();
		m->CLK_24M = 0; m->eval();
		cycles++;

		if (phase == 4 && m->ss_done) {
			FILE *s = fopen(argv[6], "wb");
			std::vector<uint16_t> w(WIN_WORDS);
			for (int i = 0; i < WIN_WORDS; i++) w[i] = r->tb_ss68k__DOT__win[i];
			fwrite(w.data(), 2, WIN_WORDS, s);
			fclose(s);
			fprintf(stderr, "loadsave: second save finished at clock %ld\n", cycles);
			break;
		}
		if (phase == 1 && m->ss_done) {
			phase = 2;
			fprintf(stderr, "stub finished at clock %ld\n", cycles);
			if (!load) {
				FILE *s = fopen(state, "wb");
				std::vector<uint16_t> w(WIN_WORDS);
				for (int i = 0; i < WIN_WORDS; i++) w[i] = r->tb_ss68k__DOT__win[i];
				fwrite(w.data(), 2, WIN_WORDS, s);
				fclose(s);
			}
		}

		if (prev_as && !m->nAS) {
			t_start = m->CPU_TIME; addr = m->ADDR << 1; rw = m->RW; uds = 1; lds = 1;
		}
		if (!m->nAS && (!m->nUDS || !m->nLDS)) {
			uds = m->nUDS; lds = m->nLDS; data = m->RW ? m->DIN : m->DOUT;
		}
		if (!prev_as && m->nAS) {
			bus++;
			// Log from the first cycle outside the stub's region after it finished
			if (phase == 2 && logged == 0 && (addr >> 20) != 0xE) {
				phase = 3; t0 = t_start;
				if (loadsave) {		// the RTE's first pop: ask for the save now
					m->ss_load = 0;
					m->ss_start = 1;
					phase = 4;
				}
			}
			if (phase == 3) {
				printf("%10u %06x %c %d%d %04x\n", t_start - t0, addr, rw ? 'R' : 'W', uds, lds, data);
				logged++;
			}
		}
		prev_as = m->nAS;
	}
	fprintf(stderr, "%s: %ld bus cycles logged, %ld clocks\n", load ? "load" : "save", logged, cycles);
	m->final();
	delete m;
	delete ctx;
	return (loadsave || logged == want) ? 0 : 1;
}
