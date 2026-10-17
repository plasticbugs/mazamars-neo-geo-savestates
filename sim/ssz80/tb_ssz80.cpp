// The Z80's side of savestates: see tb_ssz80.sv. This side plays the 68k.
//
//   obj/Vtb_ssz80 <m1rom> save <at> <log> <state.bin>       > a.txt
//   obj/Vtb_ssz80 <m1rom> load <at> <log> <state.bin>       > b.txt
//   obj/Vtb_ssz80 <m1rom> loadsave <at> 0 <state.bin> <state2.bin>
//
// The driver runs from reset, with a sound command every so often.
// save: at Z80 bus cycle <at> open the menu (the Z80 and YM2610 halt), do
//       the 68k stub's part of a save (ZREQ, wait parked, read SP, RAM, the
//       YM2610 shadow, then ZCMD resume), close the menu and log the bus
//       cycles after the stub.
// load: at <at>, scribble over Z80 RAM, then the 68k's part of a load (ZREQ,
//       wait parked, write RAM, the shadow and the latches, ZCMD load).
// loadsave: load, then save again with the menu still open.
//
// state.bin: SP, banks 0-3, NMI enable, reply, command, 0, the YM2610's
// timers (3 words), RAM (2 KB), the YM2610 shadow (512 B).
#include "Vtb_ssz80.h"
#include "Vtb_ssz80___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_ssz80 *m;
static Vtb_ssz80___024root *r;

static const uint64_t HALF_24 = 20690, HALF_4 = 125000, HALF_8 = 62500;
static uint64_t next_24 = HALF_24, next_4 = HALF_4, next_8 = HALF_8;

// Bus monitor: one line per Z80 bus cycle
static long bus = 0, logged = 0;
static bool logging = false, exited = false;
static long trace_stub = 0;			// bus cycles to print to stderr
static uint32_t t0 = 0;
static int prev_strobe = 1;
static uint16_t a = 0;
static uint8_t d = 0;
static char kind[3] = "";


static void monitor() {
	int strobe = m->nRD & m->nWR;
	if (!strobe) {
		a = m->SDA;
		d = m->nRD ? m->SDD_OUT : m->DIN;
		kind[0] = !m->nMREQ ? (!m->nM1 ? 'F' : 'M') : !m->nIORQ ? 'I' : '?';
		kind[1] = m->nRD ? 'W' : 'R';
	}
	if (!prev_strobe && strobe) {
		bus++;
		if (trace_stub > 0) {
			trace_stub--;
			fprintf(stderr, "  %c%c %04x %02x run %d\n", kind[0], kind[1], a, d, m->RUN);
		}
		if (exited && !logging) { logging = true; t0 = m->Z80_TIME; }
		if (logging) {
			printf("%10u %c%c %04x %02x\n", m->Z80_TIME - t0, kind[0], kind[1], a, d);
			logged++;
		}
	}
	prev_strobe = strobe;
}

// CLK_24M only matters while the 68k's side does something: without it
// the bench runs several times faster
static bool fast = false;
static const bool getenv_progress = getenv("SS_PROGRESS") != nullptr;

static void edge() {
	uint64_t t = next_4 < next_8 ? next_4 : next_8;
	if (fast) { if (next_24 <= t) next_24 = t + HALF_24; }
	else if (next_24 < t) t = next_24;
	if (t == next_24) { next_24 += HALF_24; m->CLK_24M = !m->CLK_24M; }
	if (t == next_4) { next_4 += HALF_4; m->CLK_4M = !m->CLK_4M; }
	if (t == next_8) { next_8 += HALF_8; m->CLK_8M = !m->CLK_8M; }
	m->eval();
	monitor();
	static uint64_t edges = 0;
	static long ss_traced = 0;
	if (trace_stub > 0 && t == next_4 - HALF_4 && m->CLK_4M && ss_traced < 80) {
		ss_traced++;
		fprintf(stderr, "    4M SDA %04x M1 %d MREQ %d RD %d DIN %02x | state %d fetch_q %02x fetch_r %d prefix %d req_s %d\n",
				m->SDA, m->nM1, m->nMREQ, m->nRD, m->DIN,
				r->tb_ssz80__DOT__ss__DOT__state, r->tb_ssz80__DOT__ss__DOT__fetch_q,
				r->tb_ssz80__DOT__ss__DOT__fetch_r, r->tb_ssz80__DOT__ss__DOT__last_prefix,
				r->tb_ssz80__DOT__ss__DOT__req_s);
	}
	static long traced = 0;
	if (getenv_progress && t == next_4 - HALF_4 && m->CLK_4M && traced < 120 && m->nRESET) {
		traced++;
		fprintf(stderr, "4M %3ld SDA %04x M1 %d MREQ %d IORQ %d RD %d WR %d DIN %02x DOUT %02x RUN %d\n", traced,
				m->SDA, m->nM1, m->nMREQ, m->nIORQ, m->nRD, m->nWR, m->DIN, m->SDD_OUT, m->RUN);
	}
	if (getenv_progress && !(++edges & 0xFFFFF))
		fprintf(stderr, "edges %llu bus %ld SDA %04x nM1 %d nMREQ %d nRD %d nWR %d nRESET %d time %u\n",
				(unsigned long long)edges, bus, m->SDA, m->nM1, m->nMREQ, m->nRD, m->nWR, m->nRESET, m->Z80_TIME);
}

static void tick24() {			// to just after the next CLK_24M rise
	for (;;) {
		bool rising = !m->CLK_24M && next_24 <= next_4 && next_24 <= next_8;
		edge();
		if (rising) return;
	}
}

static void tick4() {			// to just after the next CLK_4M rise
	for (;;) {
		bool rising = !m->CLK_4M && next_4 <= next_8 && (fast || next_4 <= next_24);
		edge();
		if (rising) return;
	}
}

static void ticks4(long n) {	// n CLK_4M periods
	for (long i = 0; i < n * 12; i++) tick24();
}

// ss_z80's AUX port, as ss_m68k drives it
static void aux_write(unsigned off, unsigned v) {
	m->AUX_ADDR = off >> 1; m->AUX_WDATA = v; m->AUX_WE = 1;
	tick24();
	m->AUX_WE = 0;
	tick24();
}
static unsigned aux_read(unsigned off) {
	m->AUX_ADDR = off >> 1;
	tick24(); tick24();
	return m->AUX_Q;
}

// The 68k's sound command, on CLK_4M edges: the latch and NMI need no
// clock, and so it reaches the Z80 at the same point in every run
static void command(uint8_t c) {
	tick4();
	m->cmd_in = c; m->nSDW = 0;
	tick4(); tick4();
	m->nSDW = 1;
	tick4(); tick4();
}

static void wait_status(unsigned bit, const char *what) {
	for (long n = 0; !(aux_read(0x2000) & bit); n++)
		if (n > 2000000) { fprintf(stderr, "the Z80 never %s\n", what); exit(1); }
}

struct State {
	uint16_t sp; uint8_t bank[4], nmi, rep, cmd, pad;
	uint16_t ym_timers[3];
	uint8_t ram[2048], ym[512];
};

static void hw_shadows(State &s) {	// what the 68k stub reads from SHADOW
	s.bank[0] = r->tb_ssz80__DOT__ZMC__DOT__WINDOW_0;
	s.bank[1] = r->tb_ssz80__DOT__ZMC__DOT__WINDOW_1;
	s.bank[2] = r->tb_ssz80__DOT__ZMC__DOT__WINDOW_2;
	s.bank[3] = r->tb_ssz80__DOT__ZMC__DOT__WINDOW_3;
	s.nmi = !r->tb_ssz80__DOT__Z80CTRL__DOT__nNMI_EN;	// bit 1, the line: from ss_z80
	s.rep = r->tb_ssz80__DOT__rep_latch;
	s.cmd = r->tb_ssz80__DOT__cmd_latch;
	s.pad = 0;
}

static void mailbox(const State &s) {
	aux_write(0x2002, s.sp);
	aux_write(0x2006, s.nmi);
	aux_write(0x2008, s.rep);
	for (int i = 0; i < 4; i++) aux_write(0x200A + 2 * i, s.bank[i]);
}

// What the NMI was doing when the 68k asked, and how long the entry waited
static void entry_report(const char *what) {
	fprintf(stderr, "%s: at the request NMI pending %d, in its handler %d;", what,
			  r->tb_ssz80__DOT__ss__DOT__pend, r->tb_ssz80__DOT__ss__DOT__in_nmi);
}

static State save() {
	State s;
	hw_shadows(s);
	entry_report("save");
	if (getenv_progress) trace_stub = 40;
	aux_write(0x2000, 1);					// ZREQ
	wait_status(1, "parked");
	fprintf(stderr, " the entry waited %u cycles\n", r->tb_ssz80__DOT__ss__DOT__nmi_wait);
	unsigned st = aux_read(0x2000);
	if (st & 4) s.nmi |= 2;				// the NMI line low
	if (st & 8) s.nmi |= 4;				// the Z80's NMI input held low
	s.sp = aux_read(0x2002);
	for (int i = 0; i < 2048; i++) s.ram[i] = aux_read(2 * i);
	for (int i = 0; i < 512; i++) s.ym[i] = aux_read(0x1000 + 2 * i);
	mailbox(s);
	aux_write(0x2004, 1);					// ZCMD: resume
	wait_status(2, "left the stub");
	for (int i = 0; i < 3; i++) s.ym_timers[i] = aux_read(0x2012 + 2 * i);
	fprintf(stderr, "save: SP %04x, banks %02x %02x %02x %02x, NMI %x, YM timers %02x%04x%04x\n",
			  s.sp, s.bank[0], s.bank[1], s.bank[2], s.bank[3], s.nmi,
			  s.ym_timers[2], s.ym_timers[1], s.ym_timers[0]);
	return s;
}

static void load(const State &s) {
	entry_report("load");
	aux_write(0x2000, 1);
	wait_status(1, "parked");
	fprintf(stderr, " the entry waited %u cycles\n", r->tb_ssz80__DOT__ss__DOT__nmi_wait);
	for (int i = 0; i < 2048; i++) aux_write(2 * i, s.ram[i]);
	for (int i = 0; i < 512; i++) aux_write(0x1000 + 2 * i, s.ym[i]);
	command(s.cmd);							// the Z80's NMI is off while parked
	mailbox(s);
	for (int i = 0; i < 3; i++) aux_write(0x2012 + 2 * i, s.ym_timers[i]);
	aux_write(0x2004, 2);					// ZCMD: load
	wait_status(2, "left the stub");
	fprintf(stderr, "load: done\n");
}

static uint32_t x = 0x12345678;
static uint32_t noise() { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

int main(int argc, char **argv) {
	if (argc < 6) { fprintf(stderr, "usage: %s m1rom save|load|loadsave at log state.bin [state2.bin]\n", argv[0]); return 2; }
	const bool loadsave = !strcmp(argv[2], "loadsave");
	const bool do_load = loadsave || !strcmp(argv[2], "load");
	const long at = atol(argv[3]), want = atol(argv[4]);

	auto *ctx = new VerilatedContext;
	m = new Vtb_ssz80{ctx};
	r = m->rootp;

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 2; }
	std::vector<uint8_t> rom(524288);
	size_t n = fread(rom.data(), 1, rom.size(), f);
	fclose(f);
	unsigned mask = 1;
	while (mask < n) mask <<= 1;
	for (size_t i = 0; i < rom.size(); i++) r->tb_ssz80__DOT__rom[i] = rom[i];
	r->tb_ssz80__DOT__rom_mask = mask - 1;

	// A falling edge on nRESET: the asynchronous resets (z80ctrl's NMI flop)
	// act on the edge here, though on the chip they follow the level
	m->nRESET = 1; m->menu = 0; m->nSDW = 1; m->cmd_in = 0;
	m->wait_all = getenv("SS_WAIT_ALL") != nullptr;	// RAM reads wait too
	ticks4(2);
	m->nRESET = 0;
	ticks4(100);
	m->nRESET = 1;

	// Commands every 20000 bus cycles: a soft reset, then music and effects
	const uint8_t cmds[] = {0x03, 0x01, 0x20, 0x21, 0x30, 0x41, 0x52, 0x63};
	unsigned next_cmd = 0;
	fast = true;
	while (bus < at) {
		edge();
		if (bus >= 20000 * (next_cmd + 1) && next_cmd < sizeof cmds) {
			command(cmds[next_cmd++]);
			fprintf(stderr, "bus cycle %ld\n", bus);
		}
	}
	while (!(m->nRD & m->nWR)) edge();
	fast = false;

	m->menu = 1;
	ticks4(50);
	fprintf(stderr, "%s: menu open at bus cycle %ld\n", argv[2], bus);

	if (!do_load) {
		State s = save();
		FILE *o = fopen(argv[5], "wb"); fwrite(&s, sizeof s, 1, o); fclose(o);
	}
	else {
		State s;
		FILE *i = fopen(argv[5], "rb");
		if (!i || fread(&s, sizeof s, 1, i) != 1) { fprintf(stderr, "bad state\n"); return 2; }
		fclose(i);
		for (int k = 0; k < 2048; k++) r->tb_ssz80__DOT__Z80RAM__DOT__memory[k] = noise();
		load(s);
		if (loadsave) {
			State s2 = save();
			FILE *o = fopen(argv[6], "wb"); fwrite(&s2, sizeof s2, 1, o); fclose(o);
			return 0;
		}
	}
	exited = true;
	ticks4(20);
	m->menu = 0;
	fast = true;
	bool sent = false;
	while (logged < want) {
		edge();
		if (logged == 30000 && !sent) {			// the same in every run
			command(0x63); sent = true;
		}
	}
	fprintf(stderr, "%s: %ld bus cycles logged\n", argv[2], logged);
	delete m;
	return 0;
}
