// The savestate path end to end: see tb_savestate.sv. This side plays the
// Pocket, as core_bridge_cmd and the bridge would.
//
//   obj/Vtb_savestate <bios.rom> <m1rom> save <at> <log> <state.bin>      > a.txt
//   obj/Vtb_savestate <bios.rom> <m1rom> load <at> <log> <state.bin>      > b.txt
//   obj/Vtb_savestate <bios.rom> <m1rom> loadsave <at> 0 <state.bin> <state2.bin>
//
// save: run to 68k bus cycle <at>, open the menu (the CPUs halt), ask for a
//       save (0xA0), read the buffer over the bridge into state.bin, close
//       the menu and log the 68k bus cycles that follow the stub; the Z80's
//       go to z80_save.txt.
// load: run to <at>, scribble over work RAM, the CPU's registers and the
//       rest of what the stub restores (palette, VRAM, latch, LSPC registers,
//       P-ROM bank), open the menu, scribble over the Z80's (its RAM, banks,
//       NMI enable, the sound latches), write state.bin over the bridge, ask
//       for a load (0xA4), close the menu and log what follows the stubs
//       (the Z80's to z80_load.txt).
// loadsave: load as above, scribble over the buffer, then ask for a save
//       with the menu still open and read it into state2.bin.
// refuse: load at <at> as above but without the scribbling, with the ROM's
//       NGH number (0x000108) changed during the request as another game's
//       would be: the load must answer an error, and what follows the stub
//       (logged as for load; the Z80's to z80_refuse.txt) must be what
//       follows a save at the same <at>, the machine left as it was.
// idle: open and close the menu at <at> with no request; the Z80's bus
//       cycles after it go to z80_idle.txt, for refuse's to match (a save
//       takes the Z80 through its stub, which moves it in time).
//
// SS_QUICK: never open the menu, as the Pocket's Analogue + Up and Down
// save and load: the machine runs on but for the request itself. Every
// request must leave the game's watchdog (8 frames) unexpired.
// SS_NO_HOLD: the bench without savestate.sv's hold, to show it matters.
// SS_CHIP=<cart_pchip>: a cartridge chip in the PORT zone (2 PVC, 3-7 SMA),
// its state set to noise before the save and again before the load; its
// state after each request goes to chip_<mode>.txt.
//
// Bridge reads are pipelined, as Analogue documents them: the data for a
// read strobe is taken at the next transaction, just before its strobe.
// BRIDGE_GAP sets the clk_74a cycles from one strobe to the next address.
// Every bridge read and write is also checked against the PSRAM model.
#include "Vtb_savestate.h"
#include "Vtb_savestate___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_savestate *m;
static Vtb_savestate___024root *r;

// Clocks in picoseconds: clk_74a 74.25 MHz, clk_sys 96.64 MHz (CLK_24M = /4)
static const uint64_t HALF_74 = 6734, HALF_SYS = 5174;
static uint64_t now = 0, next_74 = HALF_74, next_sys = HALF_SYS;

// Bus monitor
static long bus = 0, logged = 0, want = 0;	// the bus cycles to log
static int prev_as = 1, phase = 0;		// 0 before, 1 command, 2 stub done, 3 logging
static uint32_t t0 = 0, t_start = 0, addr = 0;
static int rw = 1;
static uint16_t data = 0;

static void monitor() {
	if (prev_as && !m->nAS) { t_start = m->CPU_TIME; addr = m->ADDR << 1; rw = m->RW; }
	if (!m->nAS && (!m->nUDS || !m->nLDS)) data = m->RW ? m->DIN : m->DOUT;
	if (!prev_as && m->nAS) {
		bus++;
		if (phase == 2 && (addr >> 20) != 0xE) { phase = 3; t0 = t_start; }
		if (phase == 3 && logged < want) {
			printf("%10u %06x %c %04x\n", t_start - t0, addr, rw ? 'R' : 'W', data);
			logged++;
		}
	}
	prev_as = m->nAS;
}

// The Z80's bus, one line per cycle, once its stub has left
static FILE *ztrace;
static bool zlog = false;
static long zlogged = 0;
static int zprev = 1;
static uint32_t zt0 = 0;
static uint16_t za = 0;
static uint8_t zd = 0;
static char zkind[3] = "";

static void zmonitor() {
	int strobe = m->nRD & m->nWR;
	if (!strobe) {
		za = m->SDA;
		zd = m->nRD ? m->SDD_OUT : m->Z80_DIN;
		zkind[0] = !m->nMREQ ? (!m->nM1 ? 'F' : 'M') : !m->nIORQ ? 'I' : '?';
		zkind[1] = m->nRD ? 'W' : 'R';
	}
	if (!zprev && strobe && zlog && ztrace && logged < want) {	// over the same time
		if (!zlogged++) zt0 = m->Z80_TIME;
		fprintf(ztrace, "%10u %c%c %04x %02x\n", m->Z80_TIME - zt0, zkind[0], zkind[1], za, zd);
	}
	zprev = strobe;
}

// Advance to the next clock edge
static bool sys_rose = false;
static void edge() {
	sys_rose = false;
	if (next_74 <= next_sys) { now = next_74; next_74 += HALF_74; m->clk_74a = !m->clk_74a; }
	else { now = next_sys; next_sys += HALF_SYS; m->clk_sys = !m->clk_sys; sys_rose = m->clk_sys; }
	m->eval();
	monitor();
	zmonitor();
}

// Run up to just after the next rising edge of clk_74a
static void tick74() {
	for (;;) {
		bool rising = next_74 <= next_sys && !m->clk_74a;
		edge();
		if (rising) return;
	}
}

static const int WORDS = 131072;			// 512 KB in 32-bit bridge words
static const uint32_t SS_ADDR = 0x80000000;
static int gap = 40;

static uint16_t &model(uint32_t word) {		// a 16-bit word of the buffer
	return r->tb_savestate__DOT__cram__DOT__opb_psram_v__DOT__mem[0x140000 + word];
}

static void bridge_write(uint32_t a, uint32_t d) {
	m->bridge_addr = a; m->bridge_wr_data = d;
	for (int i = 0; i < 4; i++) tick74();
	m->bridge_wr = 1; tick74(); m->bridge_wr = 0;
	for (int i = 0; i < gap; i++) tick74();
}

// Pipelined read: returns the data of the previous strobe
static uint32_t bridge_read(uint32_t a) {
	m->bridge_addr = a;
	for (int i = 0; i < 4; i++) tick74();
	uint32_t d = m->bridge_rd_data;
	m->bridge_rd = 1; tick74(); m->bridge_rd = 0;
	for (int i = 0; i < gap; i++) tick74();
	return d;
}

static std::vector<uint32_t> read_buffer() {
	std::vector<uint32_t> w(WORDS);
	bridge_read(SS_ADDR);
	for (int i = 1; i < WORDS; i++) w[i - 1] = bridge_read(SS_ADDR + 4 * i);
	w[WORDS - 1] = bridge_read(SS_ADDR + 4 * (WORDS - 1));	// collects the last
	long bad = 0;
	for (int i = 0; i < WORDS; i++) {
		uint32_t want = (uint32_t)model(2 * i) << 16 | model(2 * i + 1);
		if (w[i] != want && bad++ < 5)
			fprintf(stderr, "bridge read: word %d is %08x, buffer has %08x\n", i, w[i], want);
	}
	if (bad) { fprintf(stderr, "bridge read: %ld words wrong\n", bad); exit(1); }
	return w;
}

static void write_buffer(const std::vector<uint32_t> &w) {
	for (int i = 0; i < WORDS; i++) bridge_write(SS_ADDR + 4 * i, w[i]);
	for (int i = 0; i < 64; i++) tick74();
	long bad = 0;
	for (int i = 0; i < WORDS; i++) {
		uint32_t got = (uint32_t)model(2 * i) << 16 | model(2 * i + 1);
		if (got != w[i] && bad++ < 5)
			fprintf(stderr, "bridge write: word %d is %08x in the buffer, wrote %08x\n", i, got, w[i]);
	}
	if (bad) { fprintf(stderr, "bridge write: %ld words wrong\n", bad); exit(1); }
}

// The watchdog resets the machine 8 frames (405504 CLK_24M cycles each)
// after its last kick; it may count the first frame from just before it
static const uint32_t WD_LIMIT = 7 * 405504;

// A save (load = false) or a load, the way core_bridge_cmd asks for one
static void command(bool load, bool refuse = false) {
	r->tb_savestate__DOT__wd_max = 0;
	const char *what = load ? "load" : "save";
	const int slatch = r->tb_savestate__DOT__slatch;
	(load ? m->savestate_load : m->savestate_start) = 1;
	int n = 0;
	while (!(load ? m->savestate_load_ack : m->savestate_start_ack)) {
		tick74();
		if (++n > 100) { fprintf(stderr, "%s: no ack\n", what); exit(1); }
	}
	(load ? m->savestate_load : m->savestate_start) = 0;
	tick74();
	if (!(load ? m->savestate_load_busy : m->savestate_start_busy)) { fprintf(stderr, "%s: not busy after ack\n", what); exit(1); }
	long t = 0;
	while (!(load ? m->savestate_load_ok || m->savestate_load_err : m->savestate_start_ok || m->savestate_start_err)) {
		tick74();
		if (++t > 200000000L) { fprintf(stderr, "%s: never finished\n", what); exit(1); }
	}
	const bool err = load ? m->savestate_load_err : m->savestate_start_err;
	if (refuse) {
		if (!err) { fprintf(stderr, "%s: ok, where it should have refused\n", what); exit(1); }
		fprintf(stderr, "%s: refused after %.2f ms\n", what, t * 2 * HALF_74 / 1e9);
		return;
	}
	if (err) { fprintf(stderr, "%s: error\n", what); exit(1); }
	// A save switches palette banks to copy both: it must put the game's back
	if (!load && r->tb_savestate__DOT__slatch != slatch) {
		fprintf(stderr, "save: system latch %02x afterwards, %02x before\n", r->tb_savestate__DOT__slatch, slatch);
		exit(1);
	}
	fprintf(stderr, "%s: ok after %.2f ms\n", what, t * 2 * HALF_74 / 1e9);
	if (m->WD_MAX > WD_LIMIT) {
		fprintf(stderr, "%s: the watchdog went %.1f frames unkicked: the machine would have reset\n",
				  what, m->WD_MAX / 405504.0);
		exit(1);
	}
}

static void write_file(const char *name, const std::vector<uint32_t> &w) {
	FILE *f = fopen(name, "wb");
	for (uint32_t x : w) { uint8_t b[4] = {(uint8_t)(x >> 24), (uint8_t)(x >> 16), (uint8_t)(x >> 8), (uint8_t)x}; fwrite(b, 1, 4, f); }
	fclose(f);
}

static std::vector<uint32_t> read_file(const char *name) {
	FILE *f = fopen(name, "rb");
	if (!f) { perror(name); exit(2); }
	std::vector<uint32_t> w(WORDS);
	for (int i = 0; i < WORDS; i++) {
		uint8_t b[4];
		if (fread(b, 1, 4, f) != 4) { fprintf(stderr, "short state\n"); exit(2); }
		w[i] = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
	}
	fclose(f);
	return w;
}

static uint32_t x = 0x12345678;
static uint32_t noise() { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

static void scribble_chip();

// Before a load: what the stubs restore, to noise
static void scribble_68k() {
	for (int i = 0; i < 32768; i++) r->tb_savestate__DOT__ram[i] = noise();
	// D0-D7, A0-A6, USP (FX68K slots 0-15) to noise, SSP (16) elsewhere in work RAM
	auto &rl = r->tb_savestate__DOT__dut__DOT__FX68K__DOT__excUnit__DOT__regs68L;
	auto &rh = r->tb_savestate__DOT__dut__DOT__FX68K__DOT__excUnit__DOT__regs68H;
	for (int i = 0; i < 16; i++) { uint32_t v = noise(); rl[i] = v; rh[i] = v >> 16; }
	rh[16] = 0x0010; rl[16] = 0x1000 + (noise() & 0xDFFE);
	// And the rest of what the stub restores
	r->tb_savestate__DOT__slatch = noise();
	for (int i = 0; i < 8192; i++) r->tb_savestate__DOT__pal[i] = noise();
	for (int i = 0; i < 32768; i++) r->tb_savestate__DOT__svram[i] = noise();
	for (int i = 0; i < 2048; i++) r->tb_savestate__DOT__fvram[i] = noise();
	r->tb_savestate__DOT__vramaddr = noise();
	r->tb_savestate__DOT__vrammod = noise();
	r->tb_savestate__DOT__lspcmode = noise();
	r->tb_savestate__DOT__p_bank = noise() & 15;
	scribble_chip();
}

// The cartridge chip's state to noise. The PVC's port registers are what
// the last writes to their ports left in its RAM, as on the chip, but for
// the bank, which reads back as itself
static int chip = 0;
static void scribble_chip() {
	if (chip >= 3) {
		r->tb_savestate__DOT__SMA__DOT__bank = noise() & 0xFFFFFF;
		r->tb_savestate__DOT__SMA__DOT__rng = noise();
	}
	else if (chip == 2) {
		auto &lo = r->tb_savestate__DOT__PVC__DOT__RAML__DOT__mem;
		auto &hi = r->tb_savestate__DOT__PVC__DOT__RAMU__DOT__mem;
		for (int i = 0; i < 4096; i++) { uint32_t v = noise(); lo[i] = v; hi[i] = v >> 8; }
		auto word = [&](int port) { return (unsigned)hi[0xFF0 + port] << 8 | lo[0xFF0 + port]; };
		unsigned w = word(0), a = word(4), b = word(5);
		r->tb_savestate__DOT__PVC__DOT__ub = (w & 15) << 1 | (w >> 12 & 1);
		r->tb_savestate__DOT__PVC__DOT__ug = (w >> 4 & 15) << 1 | (w >> 13 & 1);
		r->tb_savestate__DOT__PVC__DOT__ur = (w >> 8 & 15) << 1 | (w >> 14 & 1);
		r->tb_savestate__DOT__PVC__DOT__us = w >> 15 & 1;
		r->tb_savestate__DOT__PVC__DOT__pcol = (b >> 8 & 1) << 15 | (b & 1) << 14 | (a >> 8 & 1) << 13 |
			(a & 1) << 12 | (b >> 1 & 15) << 8 | (a >> 9 & 15) << 4 | (a >> 1 & 15);
		r->tb_savestate__DOT__PVC__DOT__bank = noise() & 0x7FFFFE;
	}
}

// What the chip holds, but for the PVC's RAM under the ports that read
// back other than it (1, 2, 6, 8, 9), which nothing can see
static void dump_chip(const char *mode) {
	if (!chip) return;
	char name[64];
	snprintf(name, sizeof name, "chip_%s.txt", mode);
	FILE *f = fopen(name, "w");
	if (chip >= 3)
		fprintf(f, "sma bank %06x rng %04x\n", r->tb_savestate__DOT__SMA__DOT__bank,
				  r->tb_savestate__DOT__SMA__DOT__rng);
	else {
		fprintf(f, "pvc bank %06x r %02x g %02x b %02x s %x pcol %04x\n", r->tb_savestate__DOT__PVC__DOT__bank,
				  r->tb_savestate__DOT__PVC__DOT__ur, r->tb_savestate__DOT__PVC__DOT__ug,
				  r->tb_savestate__DOT__PVC__DOT__ub, r->tb_savestate__DOT__PVC__DOT__us,
				  r->tb_savestate__DOT__PVC__DOT__pcol);
		for (int i = 0; i < 4096; i++) {
			int port = i - 0xFF0;
			if (port == 1 || port == 2 || port == 6 || port == 8 || port == 9) continue;
			fprintf(f, "%03x %02x%02x\n", i, r->tb_savestate__DOT__PVC__DOT__RAMU__DOT__mem[i],
					  r->tb_savestate__DOT__PVC__DOT__RAML__DOT__mem[i]);
		}
	}
	fclose(f);
}

static void scribble_z80() {
	for (int i = 0; i < 2048; i++) r->tb_savestate__DOT__Z80RAM__DOT__memory[i] = noise();
	r->tb_savestate__DOT__ZMC__DOT__WINDOW_0 = noise();
	r->tb_savestate__DOT__ZMC__DOT__WINDOW_1 = noise() & 0x7F;
	r->tb_savestate__DOT__ZMC__DOT__WINDOW_2 = noise() & 0x3F;
	r->tb_savestate__DOT__ZMC__DOT__WINDOW_3 = noise() & 0x1F;
	r->tb_savestate__DOT__Z80CTRL__DOT__nNMI_EN = noise() & 1;
	r->tb_savestate__DOT__cmd_latch = noise();
	r->tb_savestate__DOT__rep_latch = noise();
}

int main(int argc, char **argv) {
	if (argc < 7) { fprintf(stderr, "usage: %s bios m1rom save|load|loadsave at log state.bin [state2.bin]\n", argv[0]); return 2; }
	const char *mode = argv[3];
	const bool loadsave = !strcmp(mode, "loadsave");
	const bool refuse = !strcmp(mode, "refuse");
	const bool idle = !strcmp(mode, "idle");
	const bool load = loadsave || refuse || !strcmp(mode, "load");
	if (loadsave && argc < 8) { fprintf(stderr, "loadsave needs state2.bin\n"); return 2; }
	const long at = atol(argv[4]);
	want = atol(argv[5]);
	const char *state = argv[6], *state2 = argv[7];
	if (getenv("BRIDGE_GAP")) gap = atoi(getenv("BRIDGE_GAP"));

	auto *ctx = new VerilatedContext;
	m = new Vtb_savestate{ctx};
	r = m->rootp;

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 2; }
	std::vector<uint8_t> bios(131072);
	if (fread(bios.data(), 1, bios.size(), f) != bios.size()) { fprintf(stderr, "short BIOS\n"); return 2; }
	fclose(f);
	for (int i = 0; i < 65536; i++) r->tb_savestate__DOT__rom[i] = bios[2*i] | (bios[2*i+1] << 8);

	f = fopen(argv[2], "rb");
	if (!f) { perror(argv[2]); return 2; }
	std::vector<uint8_t> m1(524288);
	size_t n = fread(m1.data(), 1, m1.size(), f);
	fclose(f);
	unsigned mask = 1;
	while (mask < n) mask <<= 1;
	for (size_t i = 0; i < m1.size(); i++) r->tb_savestate__DOT__m1rom[i] = m1[i];
	r->tb_savestate__DOT__m1_mask = mask - 1;

	char zname[64];
	snprintf(zname, sizeof zname, "z80_%s.txt", mode);
	if (!loadsave && !(ztrace = fopen(zname, "w"))) { perror(zname); return 2; }

	// A falling edge on nRESET: the asynchronous resets (z80ctrl's NMI flop)
	// act on the edge here, though on the chip they follow the level
	const bool quick = getenv("SS_QUICK") != nullptr;
	m->no_hold = getenv("SS_NO_HOLD") != nullptr;
	if (getenv("SS_CHIP")) chip = atoi(getenv("SS_CHIP"));
	m->chip = chip;
	m->nRESET = 1; m->menu = 0; m->clk_74a = 0; m->clk_sys = 0;
	for (int i = 0; i < 20; i++) tick74();
	m->nRESET = 0;
	for (int i = 0; i < 200; i++) tick74();
	m->nRESET = 1;
	while (bus < at) tick74();
	while (!m->nAS) tick74();

	// With the menu, scribble over the 68k's side now and the Z80's once it
	// halts; without it, both just before the request, so that neither CPU
	// runs on noise for long first, which a real load never meets
	if (load && !quick && !refuse) scribble_68k();

	if (!quick) {
		m->menu = 1;
		for (int i = 0; i < 1000; i++) tick74();
		uint32_t halted_at = m->CPU_TIME;
		for (int i = 0; i < 100; i++) tick74();
		if (m->CPU_TIME != halted_at) { fprintf(stderr, "the menu did not halt the CPU\n"); return 1; }
	}
	fprintf(stderr, "%s: %s at bus cycle %ld\n", mode, quick ? "no menu" : "menu open", bus);

	if (idle) {
		phase = 2;
		zlog = true;
	}
	else if (!load) {
		scribble_chip();
		phase = 1;
		command(false);
		dump_chip(mode);
		phase = 2;
		zlog = true;
		write_file(state, read_buffer());
	}
	else {
		if (!quick && !refuse) scribble_z80();
		write_buffer(read_file(state));
		if (quick && !refuse) {
			while (!m->nAS) tick74();
			scribble_68k();
			scribble_z80();
		}
		if (refuse) r->tb_savestate__DOT__rom[0x84] ^= 1;	// the NGH number, 0x000108
		phase = 1;
		command(true, refuse);
		if (refuse) r->tb_savestate__DOT__rom[0x84] ^= 1;
		dump_chip(mode);
		phase = 2;
		zlog = true;
		if (loadsave) {
			for (int i = 0; i < 2 * WORDS; i++) model(i) = noise();
			phase = 0;
			command(false);
			write_file(state2, read_buffer());
			fprintf(stderr, "loadsave: saved again with the menu still open\n");
			delete m;
			return 0;
		}
	}

	// Close the menu at the same phase of the clocks in every run: the CPUs
	// then start again in the same relation to each other
	if (!quick) {
		for (int i = 0; i < 1000; i++) tick74();
		do edge(); while (!(sys_rose && m->DIV == 0));
		m->menu = 0;
	}
	while (logged < want) tick74();
	fclose(ztrace);
	fprintf(stderr, "%s: %ld bus cycles logged, %ld of the Z80's\n", mode, logged, zlogged);
	m->final();
	delete m;
	delete ctx;
	return 0;
}
