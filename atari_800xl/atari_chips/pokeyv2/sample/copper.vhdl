---------------------------------------------------------------------------
-- PokeyMAX copper (part of the sample engine, generic ENABLE)
--
-- A small list processor: 8 threads play register-write programs from sample
-- RAM on a common tick, so music, sound effects and I/O sequences cost the
-- 6502 nothing per frame; with the copper++ instructions (an accumulator, 16
-- registers per thread, tables and branches) it also runs note engines for
-- any chip from a few parameters per note. See copper_spec.md (v0.7).
--
-- Host registers (cpu_addr is the sample engine's ADDR, $D280 + 0..31; the
-- copper's are 21..30 = $D295-$D29E, shown here as $D295 + 0..9):
--   0 CCTRL   W: bit 0 run (0 = freeze: each thread stops at its next instruction
--                outside a LOCK), bit 1 STOPALL strobe, bit 2 SYNC strobe
--             R: bit 0 run, bit 5 frozen (run is 0 and no thread is loaded: the
--                6502 may write the chips itself), bit 6 a start is waiting in the
--                latch, bit 7 any thread stopped by an error
--   1 CADDRL  W: start address low
--   2 CADDRH  W: start address high
--   3 CSTART  W: thread number: start it at CADDR with base CBASE and the
--                CPARAMs written since the last CSTART   R: running mask
--   4 CKILL   W: mask of threads to stop                  R: error mask
--   5 CSIG    W: mask of signal flags to clear            R: signal flags
--   6 CTICKL  W: tick period in scanlines, low byte (taken on the CTICKH write)
--   7 CTICKH  W: high byte; the period takes effect on this write.
--             0 = the default, DEFAULT_PERIOD (312: PAL; NTSC software writes 262)
--   8 CBASE   W: register base for CSTART
--   9 CPARAM  W: the next start parameter: R0, R1, ... R7 of the started thread
--
-- Timing (v0.7.1): the sample RAM's read data and ack, a chip read's data, the
-- chip address with its area check, and LDT's table address are registered, so
-- the RAM, the device read mux and the address adders never reach the next-state
-- logic in one clock. A RAM access takes 3 clocks (was 2), a chip access 2 more.
-- ram_req drops while its ack comes in, so a request is never granted twice.
--
-- A start waits in the latch until its thread is at rest (stopped, or waiting
-- at a WAIT): it never cuts a running program short. It is served between two
-- instructions of another thread, or between slices. The 6502 waits for CCTRL
-- bit 6 to be 0 before writing CPARAM or CSTART for the next start.
--
-- Instructions (first byte; operands follow):
--   00rrrrrr v        MOVE r,v      register base+r <= v
--   01nnnnnn          WAIT n+1      ticks
--   10nnnnnn lo hi    REF addr,n+1  execute n+1 instructions at addr, then go on
--   11000000 b        BASE b
--   11000001          LOCK          the slice doesn't end at the budget ...
--   11000010          UNLOCK        ... until UNLOCK or the end of the slice
--   11000100 n        WAITL n+1
--   11000101 lo hi n  REFL addr,n+1
--   11000110 lo hi    JUMP addr
--   11000111 lo hi    CALL addr     (until RET)
--   11001000          RET
--   1100101p r m      WAITBIT/WAITCLR: stall while (reg & m) /= 0 (p=0) or = 0 (p=1)
--   11010sss          SIGNAL s
--   11100ttt lo hi    FORK t,addr   (with this thread's base)
--   11101ttt          KILL t
--   11110000 r        MOVA r        register base+r <= ACC
--   11110001 n        STA Rn
--   1111001i x        LDA           ACC = x (i=0: #x, i=1: Rx)
--   1111010i x        ADD           ACC += x, C = carry
--   1111011i x        SUB           ACC -= x, C = borrow
--   11111000 lo hi    LDT addr      ACC = RAM[addr + ACC]
--   11111001 lo hi    JZ addr       (ACC = 0)   FA JNZ, FB JC, FC JNC
--   11111101 lo hi n  DJNZ addr,Rn  Rn -= 1, jump if Rn /= 0
--   11111111          STOP
--   others 11xxxxxx   reserved: the thread stops with its error flag set
--
-- Context area (sample RAM, 512 bytes at CTX_ADDR; thread t at CTX_ADDR + 64 t):
--   0,1 PC   2 wait (ticks left - 1; ready when a tick finds it 0)   3 base
--   4 bits 3..0 stack depth, bit 4 count bit 8, bit 5 carry, bit 6 running,
--     bit 7 error
--   5 count bits 7..0 (instructions left at this level; 0 = unlimited)
--   6 ACC    7..15 unused    16..31 R0..R15
--   32 + 4 d: stack slot d = return address low, high, outer count (byte 3 unused)
-- Only the running thread's context is in registers; the others live in RAM,
-- and R0-R15 are always in RAM (one access each).
--
-- Counting: every instruction executed at a counted level (inside a REF)
-- decrements its count, and the level returns when it runs out. A REF/CALL as
-- the last instruction of a counted level replaces that level (a tail call),
-- so a stored outer count is always 1..255, or 0 for an unlimited level.
--
-- Scheduling: a thread runs until WAIT, a stalled WAITBIT, STOP or 16
-- instructions (more while locked), then its context is saved and the next
-- ready thread (round robin) is loaded. On a tick every waiting thread's wait
-- byte is counted down (one read, maybe one write). A FORK of another thread
-- writes that thread's context directly.
--
-- Register accesses (bus_*): a device may hold bus_ack (e.g. AMY while its FIFO
-- is full): the copper waits, so a write is never dropped and no polling is
-- needed.  MOVE/MOVA writes and WAITBIT reads at base +
-- offset, after the copper-side decode: CONFIG ($0C, $1C), the copper's own
-- registers ($95-$9F) and $D0-$FF are never reached, nor an area whose area_en
-- bit is 0 (absent or restricted chips: the write is dropped, not sent to a
-- POKEY 1 shadow; a read gives 0). The integration must decode copper accesses
-- with the full map, whatever the 6502 has mapped: $10-$2F are POKEY 2 and 3.
--   area_en: 0 POKEY2 $10  1 POKEY3 $20  2 POKEY4 $30  3 SID1 $40  4 SID2 $60
--            5 COVOX/SAMPLE $80  6 PSG1 $A0  7 PSG2 $B0  8 AMY $C0
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity copper is
  generic (
    ENABLE   : boolean := true;
    CTX_ADDR : natural := 16#FE00#;                   -- context area: $FE00-$FFFF (512-byte aligned)
    DEFAULT_PERIOD : natural := 312                   -- tick period while CTICK is 0: one PAL frame
  );
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;

    tick_15k   : in  std_logic;                       -- one pulse per POKEY 15 kHz period (PHI2/114)

    -- host registers
    cpu_we     : in  std_logic;                       -- one clock per 6502 write
    cpu_addr   : in  std_logic_vector(4 downto 0);   -- $D280 + n: the copper decodes n = 21..30 itself
    cpu_di     : in  std_logic_vector(7 downto 0);
    cpu_do     : out std_logic_vector(7 downto 0);   -- 0 outside $D295-$D29E, so it can be ORed in

    -- signals: SAMIRQACT bit 4
    sig_any    : out std_logic;                       -- any signal flag set
    sig_clear  : in  std_logic := '0';                -- SAMIRQACT bit 4 written 0: clear all flags

    -- sample RAM (shared; the arbiter gives sample DMA and the 6502 priority)
    ram_req    : out std_logic;                       -- held until ram_ack
    ram_we     : out std_logic;
    ram_addr   : out std_logic_vector(15 downto 0);
    ram_wdata  : out std_logic_vector(7 downto 0);
    ram_ack    : in  std_logic;                       -- one clock; a read's data is valid with it
    ram_rdata  : in  std_logic_vector(7 downto 0);

    -- chip registers (the internal register bus, after the 6502)
    area_en    : in  std_logic_vector(8 downto 0);
    bus_req    : out std_logic;                       -- held until bus_ack
    bus_we     : out std_logic;
    bus_addr   : out std_logic_vector(7 downto 0);    -- $D2xx low byte
    bus_wdata  : out std_logic_vector(7 downto 0);
    bus_ack    : in  std_logic;                       -- one clock; a read's data is valid with it
    bus_rdata  : in  std_logic_vector(7 downto 0)
  );
end entity;

architecture vhdl of copper is
  type state_t is (st_idle, st_init, st_par, st_tick, st_tickw, st_load, st_fetch, st_opnd, st_exec,
                   st_chk, st_bus, st_busr, st_reg, st_regw, st_tab, st_waitw, st_push, st_pop, st_next,
                   st_after, st_save);
  signal state_reg, state_next : state_t := st_idle;

  constant BUDGET : unsigned(3 downto 0) := to_unsigned(15, 4);   -- 16 instructions a slice
  constant CTX_HI : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(CTX_ADDR / 512, 7));

  type par_t is array (0 to 7) of std_logic_vector(7 downto 0);

  -- host side
  signal run_reg, run_next       : std_logic := '0';
  signal caddr_reg, caddr_next   : std_logic_vector(15 downto 0) := (others => '0');
  signal cbase_reg, cbase_next   : std_logic_vector(7 downto 0) := (others => '0');
  signal tickl_reg, tickl_next   : std_logic_vector(7 downto 0) := (others => '0');
  signal period_reg, period_next : unsigned(15 downto 0) := (others => '0');
  -- the start latch
  signal spend_reg, spend_next   : std_logic := '0';                       -- a start is waiting
  signal st_t_reg, st_t_next     : unsigned(2 downto 0) := (others => '0');
  signal st_pc_reg, st_pc_next   : std_logic_vector(15 downto 0) := (others => '0');
  signal st_b_reg, st_b_next     : std_logic_vector(7 downto 0) := (others => '0');
  signal st_n_reg, st_n_next     : unsigned(3 downto 0) := (others => '0');    -- its parameters
  signal pcnt_reg, pcnt_next     : unsigned(3 downto 0) := (others => '0');    -- CPARAMs written
  signal par_reg, par_next       : par_t := (others => (others => '0'));

  -- tick: counts 15 kHz pulses up to the period
  signal div_reg, div_next       : unsigned(15 downto 0) := (others => '0');
  signal tpend_reg, tpend_next   : std_logic := '0';

  -- thread masks
  signal running_reg, running_next : std_logic_vector(7 downto 0) := (others => '0');
  signal ready_reg, ready_next     : std_logic_vector(7 downto 0) := (others => '0');
  signal err_reg, err_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal sig_reg, sig_next         : std_logic_vector(7 downto 0) := (others => '0');

  -- the running thread
  signal cur_reg, cur_next       : unsigned(2 downto 0) := (others => '0');
  signal pc_reg, pc_next         : unsigned(15 downto 0) := (others => '0');
  signal base_reg, base_next     : unsigned(7 downto 0) := (others => '0');
  signal depth_reg, depth_next   : unsigned(3 downto 0) := (others => '0');
  signal rem_reg, rem_next       : unsigned(8 downto 0) := (others => '0');    -- 0 = unlimited
  signal budget_reg, budget_next : unsigned(3 downto 0) := (others => '0');
  signal endsl_reg, endsl_next   : std_logic := '0';                           -- end the slice after this
  signal acc_reg, acc_next       : unsigned(7 downto 0) := (others => '0');
  signal c_reg, c_next           : std_logic := '0';
  signal lock_reg, lock_next     : std_logic := '0';

  -- the instruction
  signal op_reg, op_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal o1_reg, o1_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal o2_reg, o2_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal o3_reg, o3_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal oi_reg, oi_next         : unsigned(1 downto 0) := (others => '0');

  -- RAM operations
  signal idx_reg, idx_next       : unsigned(2 downto 0) := (others => '0');    -- byte of a multi-byte op
  signal tt_reg, tt_next         : unsigned(2 downto 0) := (others => '0');    -- init/tick: the other thread
  signal wv_reg, wv_next         : std_logic_vector(7 downto 0) := (others => '0');  -- wait / register byte to write
  signal iret_reg, iret_next     : std_logic_vector(1 downto 0) := (others => '0');  -- init: 0 host start between
                                                                                     -- slices, 1 FORK, 2 host start
                                                                                     -- between instructions
  -- combinational
  signal nops     : unsigned(1 downto 0);          -- operand bytes of op_reg
  signal acc_addr : unsigned(7 downto 0);          -- MOVE / MOVA / WAITBIT register address
  signal acc_ok   : std_logic;                     -- ... allowed

  -- timing: the RAM's read data and ack, the chip address and its check, and a chip read's data
  -- are registered, so none of them reaches the next-state logic (the PC above all) in the
  -- same clock: a RAM access then takes a clock more, a chip access two
  signal rack_reg     : std_logic := '0';
  signal rdat_reg     : std_logic_vector(7 downto 0) := (others => '0');
  signal ram_req_i    : std_logic;
  signal acc_ok_reg   : std_logic := '0';
  signal baddr_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal brd_reg      : std_logic_vector(7 downto 0) := (others => '0');
  signal tadr_reg     : unsigned(15 downto 0) := (others => '0');   -- LDT: the table byte's address
  signal target   : unsigned(15 downto 0);         -- REF/JUMP/CALL/FORK/LDT/branch address
  signal refn     : unsigned(8 downto 0);          -- REF/REFL count, 0 for CALL
  signal outer    : unsigned(7 downto 0);          -- push: the outer level's count after this instruction
  signal hdr_off  : unsigned(2 downto 0);          -- load/save: header byte 0, 1, 3, 4, 5, 6
  signal rn       : std_logic_vector(3 downto 0);  -- STA/LDA/ADD/SUB/DJNZ register
  signal is_wr    : boolean;                       -- MOVE or MOVA
  signal st_rest  : boolean;                       -- the latched start's thread is at rest
  signal ca       : natural range 0 to 15;         -- host register 0..9, 15 = not the copper's
  signal frozen   : std_logic;                     -- run = 0 and no thread loaded

  function allowed(a : unsigned(7 downto 0); en : std_logic_vector(8 downto 0)) return std_logic is
  begin
    if a = x"0C" or a = x"1C" then return '0'; end if;            -- CONFIG
    if a >= x"95" and a <= x"9F" then return '0'; end if;         -- the copper's registers
    case to_integer(a(7 downto 4)) is
      when 0      => return '1';                                   -- POKEY 1
      when 1      => return en(0);
      when 2      => return en(1);
      when 3      => return en(2);
      when 4 | 5  => return en(3);
      when 6 | 7  => return en(4);
      when 8 | 9  => return en(5);
      when 10     => return en(6);
      when 11     => return en(7);
      when 12     => return en(8);
      when others => return '0';                                   -- $D0-$FF reserved
    end case;
  end function;

  function nops_of(op : std_logic_vector(7 downto 0)) return unsigned is
  begin
    case op(7 downto 6) is
      when "00" => return "01";                                    -- MOVE r,v
      when "01" => return "00";                                    -- WAIT
      when "10" => return "10";                                    -- REF lo hi
      when others =>
        if op(5 downto 4) = "11" then                              -- $F0-$FF
          if op(3) = '0' then return "01"; end if;                 -- MOVA..SUB: one operand
          if op(2 downto 0) = "101" then return "11"; end if;      -- DJNZ lo hi n
          if op(2 downto 1) = "11" then return "00"; end if;       -- $FE, STOP
          return "10";                                             -- LDT, branches: lo hi
        end if;
        case op is
          when x"C0" | x"C4" => return "01";                       -- BASE, WAITL
          when x"C5" => return "11";                               -- REFL lo hi n
          when x"C6" | x"C7" | x"CA" | x"CB" => return "10";       -- JUMP, CALL, WAITBIT/CLR
          when others =>
            if op(7 downto 3) = "11100" then return "10"; end if;  -- FORK lo hi
            return "00";
        end case;
    end case;
  end function;

  function rr_pick(ready : std_logic_vector(7 downto 0); last : unsigned(2 downto 0)) return integer is
    variable t : unsigned(2 downto 0);
  begin
    for i in 1 to 8 loop
      t := last + to_unsigned(i mod 8, 3);
      if ready(to_integer(t)) = '1' then return to_integer(t); end if;
    end loop;
    return -1;
  end function;

begin

  g_on : if ENABLE generate

    process (clk, reset_n)
    begin
      if reset_n = '0' then
        state_reg   <= st_idle;
        run_reg     <= '0';
        caddr_reg   <= (others => '0');
        cbase_reg   <= (others => '0');
        tickl_reg   <= (others => '0');
        period_reg  <= (others => '0');
        spend_reg   <= '0';
        st_t_reg    <= (others => '0');
        st_pc_reg   <= (others => '0');
        st_b_reg    <= (others => '0');
        st_n_reg    <= (others => '0');
        pcnt_reg    <= (others => '0');
        par_reg     <= (others => (others => '0'));
        div_reg     <= (others => '0');
        tpend_reg   <= '0';
        running_reg <= (others => '0');
        ready_reg   <= (others => '0');
        err_reg     <= (others => '0');
        sig_reg     <= (others => '0');
        cur_reg     <= (others => '0');
        pc_reg      <= (others => '0');
        base_reg    <= (others => '0');
        depth_reg   <= (others => '0');
        rem_reg     <= (others => '0');
        budget_reg  <= (others => '0');
        endsl_reg   <= '0';
        acc_reg     <= (others => '0');
        c_reg       <= '0';
        rack_reg    <= '0';
        lock_reg    <= '0';
        op_reg      <= (others => '0');
        o1_reg      <= (others => '0');
        o2_reg      <= (others => '0');
        o3_reg      <= (others => '0');
        oi_reg      <= (others => '0');
        idx_reg     <= (others => '0');
        tt_reg      <= (others => '0');
        wv_reg      <= (others => '0');
        iret_reg    <= (others => '0');
      elsif rising_edge(clk) then
        state_reg   <= state_next;
        run_reg     <= run_next;
        caddr_reg   <= caddr_next;
        cbase_reg   <= cbase_next;
        tickl_reg   <= tickl_next;
        period_reg  <= period_next;
        spend_reg   <= spend_next;
        st_t_reg    <= st_t_next;
        st_pc_reg   <= st_pc_next;
        st_b_reg    <= st_b_next;
        st_n_reg    <= st_n_next;
        pcnt_reg    <= pcnt_next;
        par_reg     <= par_next;
        div_reg     <= div_next;
        tpend_reg   <= tpend_next;
        running_reg <= running_next;
        ready_reg   <= ready_next;
        err_reg     <= err_next;
        sig_reg     <= sig_next;
        cur_reg     <= cur_next;
        pc_reg      <= pc_next;
        base_reg    <= base_next;
        depth_reg   <= depth_next;
        rem_reg     <= rem_next;
        budget_reg  <= budget_next;
        endsl_reg   <= endsl_next;
        acc_reg     <= acc_next;
        c_reg       <= c_next;
        lock_reg    <= lock_next;
        op_reg      <= op_next;
        o1_reg      <= o1_next;
        o2_reg      <= o2_next;
        o3_reg      <= o3_next;
        oi_reg      <= oi_next;
        idx_reg     <= idx_next;
        tt_reg      <= tt_next;
        wv_reg      <= wv_next;
        iret_reg    <= iret_next;
        rack_reg    <= ram_ack;
        rdat_reg    <= ram_rdata;
        acc_ok_reg  <= acc_ok;
        baddr_reg   <= std_logic_vector(acc_addr);
        tadr_reg    <= target + resize(acc_reg, 16);         -- ready by st_tab (op, operands, ACC set in st_exec)
        if state_reg = st_bus and bus_ack = '1' then brd_reg <= bus_rdata; end if;
      end if;
    end process;

    ------------------------------------------------------------------ decode
    nops     <= nops_of(op_reg);
    is_wr    <= op_reg(7 downto 6) = "00" or op_reg = x"F0";
    acc_addr <= base_reg + resize(unsigned(op_reg(5 downto 0)), 8) when op_reg(7 downto 6) = "00" else
                base_reg + unsigned(o1_reg);
    acc_ok   <= allowed(acc_addr, area_en);
    target   <= unsigned(o2_reg) & unsigned(o1_reg);
    refn     <= (others => '0')                         when op_reg = x"C7" else      -- CALL
                resize(unsigned(o3_reg), 9) + 1         when op_reg = x"C5" else      -- REFL
                resize(unsigned(op_reg(5 downto 0)), 9) + 1;                          -- REF
    outer    <= (others => '0') when rem_reg = 0 else resize(rem_reg - 1, 8);
    rn       <= o3_reg(3 downto 0) when op_reg(3) = '1' else o1_reg(3 downto 0);      -- DJNZ: n is the 3rd operand
    st_rest  <= running_reg(to_integer(st_t_reg)) = '0' or ready_reg(to_integer(st_t_reg)) = '0';
    with to_integer(idx_reg) select hdr_off <=
      "000" when 0, "001" when 1, "011" when 2, "100" when 3, "101" when 4, "110" when others;

    ------------------------------------------------------------------ sample RAM
    -- address: the PC, a table byte, or a context byte (thread, offset)
    process (state_reg, pc_reg, idx_reg, tt_reg, cur_reg, hdr_off, depth_reg, running_reg, ready_reg,
             target, acc_reg, rn, tadr_reg)
      variable thr : std_logic_vector(2 downto 0);
      variable off : std_logic_vector(5 downto 0);
      variable d   : unsigned(2 downto 0);
    begin
      ram_req_i <= '0';
      ram_we  <= '0';
      thr := std_logic_vector(cur_reg);
      off := "000" & std_logic_vector(hdr_off);
      if state_reg = st_pop then d := depth_reg(2 downto 0) - 1; else d := depth_reg(2 downto 0); end if;
      case state_reg is
        when st_fetch | st_opnd | st_tab => ram_req_i <= '1';
        when st_init            => ram_req_i <= '1'; ram_we <= '1';
                                   thr := std_logic_vector(tt_reg); off := "000" & std_logic_vector(idx_reg);
        when st_par             => ram_req_i <= '1'; ram_we <= '1';
                                   thr := std_logic_vector(tt_reg); off := "010" & std_logic_vector(idx_reg);
        when st_reg             => ram_req_i <= '1'; off := "01" & rn;
        when st_regw            => ram_req_i <= '1'; ram_we <= '1'; off := "01" & rn;
        when st_tick            => ram_req_i <= running_reg(to_integer(tt_reg)) and not ready_reg(to_integer(tt_reg));
                                   thr := std_logic_vector(tt_reg); off := "000010";
        when st_tickw           => ram_req_i <= '1'; ram_we <= '1';
                                   thr := std_logic_vector(tt_reg); off := "000010";
        when st_waitw           => ram_req_i <= '1'; ram_we <= '1'; off := "000010";
        when st_load            => ram_req_i <= '1';
        when st_save            => ram_req_i <= '1'; ram_we <= '1';
        when st_push            => ram_req_i <= '1'; ram_we <= '1';
                                   off := '1' & std_logic_vector(d) & std_logic_vector(idx_reg(1 downto 0));
        when st_pop             => ram_req_i <= '1';
                                   off := '1' & std_logic_vector(d) & std_logic_vector(idx_reg(1 downto 0));
        when others             => null;
      end case;
      if state_reg = st_fetch or state_reg = st_opnd then
        ram_addr <= std_logic_vector(pc_reg);
      elsif state_reg = st_tab then
        ram_addr <= std_logic_vector(tadr_reg);
      else
        ram_addr <= CTX_HI & thr & off;
      end if;
    end process;

    process (state_reg, idx_reg, pc_reg, base_reg, rem_reg, depth_reg, running_reg, err_reg, cur_reg,
             outer, wv_reg, o1_reg, o2_reg, acc_reg, c_reg, iret_reg, st_pc_reg, st_b_reg, par_reg)
      variable sel : natural range 0 to 11;
      variable fk  : boolean;
    begin
      -- 0 PC low, 1 PC high, 2 base, 3 flags, 4 count, 5 outer count, 6 wait/register byte,
      -- 7 start address low, 8 high, 9 start base, 10 $40, 11 $00 / ACC
      sel := 6;
      fk := iret_reg = "01";
      case state_reg is
        when st_save =>
          case to_integer(idx_reg) is
            when 0 => sel := 0; when 1 => sel := 1; when 2 => sel := 2; when 3 => sel := 3;
            when 4 => sel := 4; when others => sel := 11;
          end case;
        when st_push =>
          case to_integer(idx_reg) is
            when 0 => sel := 0; when 1 => sel := 1; when others => sel := 5;
          end case;
        when st_init =>
          case to_integer(idx_reg) is
            when 0 => sel := 7; when 1 => sel := 8; when 3 => sel := 9; when 4 => sel := 10;
            when others => sel := 11;
          end case;
        when others => null;
      end case;
      case sel is
        when 0 => ram_wdata <= std_logic_vector(pc_reg(7 downto 0));
        when 1 => ram_wdata <= std_logic_vector(pc_reg(15 downto 8));
        when 2 => ram_wdata <= std_logic_vector(base_reg);
        when 3 => ram_wdata <= err_reg(to_integer(cur_reg)) & running_reg(to_integer(cur_reg)) & c_reg &
                               rem_reg(8) & std_logic_vector(depth_reg);
        when 4 => ram_wdata <= std_logic_vector(rem_reg(7 downto 0));
        when 5 => ram_wdata <= std_logic_vector(outer);
        when 7 => if fk then ram_wdata <= o1_reg; else ram_wdata <= st_pc_reg(7 downto 0); end if;
        when 8 => if fk then ram_wdata <= o2_reg; else ram_wdata <= st_pc_reg(15 downto 8); end if;
        when 9 => if fk then ram_wdata <= std_logic_vector(base_reg); else ram_wdata <= st_b_reg; end if;
        when 10 => ram_wdata <= x"40";
        when 11 => if state_reg = st_save then ram_wdata <= std_logic_vector(acc_reg); else ram_wdata <= x"00"; end if;
        when others =>
          if state_reg = st_par then ram_wdata <= par_reg(to_integer(idx_reg)); else ram_wdata <= wv_reg; end if;
      end case;
    end process;

    ------------------------------------------------------------------ chip registers
    bus_req   <= '1' when state_reg = st_bus else '0';
    bus_we    <= '1' when is_wr else '0';
    bus_addr  <= baddr_reg;
    -- a request is dropped while its ack comes in (ram_ack, then rack_reg), so it isn't granted twice
    ram_req   <= ram_req_i and not ram_ack and not rack_reg;
    bus_wdata <= o1_reg when op_reg(7) = '0' else std_logic_vector(acc_reg);

    ------------------------------------------------------------------ host reads
    ca <= to_integer(unsigned(cpu_addr)) - 21 when unsigned(cpu_addr) >= 21 and unsigned(cpu_addr) <= 30 else 15;

    -- frozen: no thread is loaded (a host start being served is not one)
    frozen <= '1' when run_reg = '0' and (state_reg = st_idle or
                                          ((state_reg = st_init or state_reg = st_par) and iret_reg = "00")) else '0';

    process (ca, run_reg, err_reg, running_reg, sig_reg, spend_reg, frozen)
    begin
      cpu_do <= (others => '0');
      case ca is
        when 0 =>
          cpu_do(0) <= run_reg;
          cpu_do(5) <= frozen;
          cpu_do(6) <= spend_reg;
          if err_reg /= x"00" then cpu_do(7) <= '1'; end if;
        when 3 => cpu_do <= running_reg;
        when 4 => cpu_do <= err_reg;
        when 5 => cpu_do <= sig_reg;
        when others => null;
      end case;
    end process;

    sig_any <= '0' when sig_reg = x"00" else '1';

    ------------------------------------------------------------------ next state
    process (state_reg, run_reg, caddr_reg, cbase_reg, tickl_reg, period_reg, spend_reg, st_t_reg,
             st_pc_reg, st_b_reg, st_n_reg, pcnt_reg, par_reg, div_reg, tpend_reg, running_reg,
             ready_reg, err_reg, sig_reg, cur_reg, pc_reg, base_reg, depth_reg, rem_reg, budget_reg,
             endsl_reg, acc_reg, c_reg, lock_reg, op_reg, o1_reg, o2_reg, o3_reg, oi_reg, idx_reg,
             tt_reg, wv_reg, iret_reg, nops, acc_ok_reg, brd_reg, target, refn, is_wr, st_rest,
             tick_15k, cpu_we, ca, cpu_di, sig_clear,
             rack_reg, rdat_reg, bus_ack)
      variable period : unsigned(15 downto 0);
      variable pick   : integer;
      variable t      : integer;
      variable u      : integer;
      variable stall  : boolean;
      variable take   : boolean;
      variable x      : unsigned(7 downto 0);
      variable s      : unsigned(8 downto 0);
      -- one change to the thread masks per clock: thread mt, action ma
      variable mt     : unsigned(2 downto 0);
      variable ma     : natural range 0 to 4;     -- 0 none, 1 start, 2 stop, 3 error, 4 wait (not ready)
      variable mrdy   : boolean;                  -- ... or set ready (the tick)
      variable oh     : std_logic_vector(7 downto 0);
    begin
      mt := cur_reg; ma := 0; mrdy := false;
      state_next   <= state_reg;
      run_next     <= run_reg;
      caddr_next   <= caddr_reg;
      cbase_next   <= cbase_reg;
      tickl_next   <= tickl_reg;
      period_next  <= period_reg;
      spend_next   <= spend_reg;
      st_t_next    <= st_t_reg;
      st_pc_next   <= st_pc_reg;
      st_b_next    <= st_b_reg;
      st_n_next    <= st_n_reg;
      pcnt_next    <= pcnt_reg;
      par_next     <= par_reg;
      div_next     <= div_reg;
      tpend_next   <= tpend_reg;
      running_next <= running_reg;
      ready_next   <= ready_reg;
      err_next     <= err_reg;
      sig_next     <= sig_reg;
      cur_next     <= cur_reg;
      pc_next      <= pc_reg;
      base_next    <= base_reg;
      depth_next   <= depth_reg;
      rem_next     <= rem_reg;
      budget_next  <= budget_reg;
      endsl_next   <= endsl_reg;
      acc_next     <= acc_reg;
      c_next       <= c_reg;
      lock_next    <= lock_reg;
      op_next      <= op_reg;
      o1_next      <= o1_reg;
      o2_next      <= o2_reg;
      o3_next      <= o3_reg;
      oi_next      <= oi_reg;
      idx_next     <= idx_reg;
      tt_next      <= tt_reg;
      wv_next      <= wv_reg;
      iret_next    <= iret_reg;

      t := to_integer(cur_reg);
      u := to_integer(unsigned(op_reg(2 downto 0)));

      ---------------------------------------------------------------- tick
      if period_reg = 0 then
        period := to_unsigned(DEFAULT_PERIOD, 16);
      else
        period := period_reg;
      end if;
      if tick_15k = '1' then
        if div_reg + 1 = period then
          div_next <= (others => '0');
          tpend_next <= '1';
        else
          div_next <= div_reg + 1;
        end if;
      end if;

      ---------------------------------------------------------------- the copper
      case state_reg is

        when st_idle =>
          idx_next <= (others => '0');
          if spend_reg = '1' and st_rest then                  -- a host start whose thread is at rest
            tt_next <= st_t_reg; iret_next <= "00";
            mt := st_t_reg; ma := 1;
            state_next <= st_init;
          elsif run_reg = '1' then
            if tpend_reg = '1' then                             -- count the waits down
              tpend_next <= '0';
              tt_next <= (others => '0');
              state_next <= st_tick;
            else
              pick := rr_pick(ready_reg and running_reg, cur_reg);
              if pick >= 0 then
                cur_next <= to_unsigned(pick, 3);
                budget_next <= BUDGET;
                lock_next <= '0';
                state_next <= st_load;
              end if;
            end if;
          end if;

        when st_init =>                                         -- write thread tt's context header
          if rack_reg = '1' then
            if idx_reg = 6 then
              idx_next <= (others => '0');
              if iret_reg /= "01" and st_n_reg /= 0 then
                state_next <= st_par;
              else
                if iret_reg /= "01" then spend_next <= '0'; end if;
                case iret_reg is
                  when "00" => state_next <= st_idle;
                  when "01" => state_next <= st_next;
                  when others => state_next <= st_after;
                end case;
              end if;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

        when st_par =>                                          -- ... and the start parameters, R0 on
          if rack_reg = '1' then
            if resize(idx_reg, 4) + 1 = st_n_reg then
              idx_next <= (others => '0');
              spend_next <= '0';
              if iret_reg = "00" then state_next <= st_idle; else state_next <= st_after; end if;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

        when st_tick =>
          if running_reg(to_integer(tt_reg)) = '0' or ready_reg(to_integer(tt_reg)) = '1' then
            if tt_reg = 7 then state_next <= st_idle; else tt_next <= tt_reg + 1; end if;
          elsif rack_reg = '1' then
            if rdat_reg = x"00" then
              mt := tt_reg; mrdy := true;
              if tt_reg = 7 then state_next <= st_idle; else tt_next <= tt_reg + 1; end if;
            else
              wv_next <= std_logic_vector(unsigned(rdat_reg) - 1);
              state_next <= st_tickw;
            end if;
          end if;

        when st_tickw =>
          if rack_reg = '1' then
            if tt_reg = 7 then state_next <= st_idle;
            else tt_next <= tt_reg + 1; state_next <= st_tick; end if;
          end if;

        when st_load =>                                         -- header bytes 0, 1, 3, 4, 5, 6
          if rack_reg = '1' then
            case to_integer(idx_reg) is
              when 0 => pc_next(7 downto 0) <= unsigned(rdat_reg);
              when 1 => pc_next(15 downto 8) <= unsigned(rdat_reg);
              when 2 => base_next <= unsigned(rdat_reg);
              when 3 => depth_next <= unsigned(rdat_reg(3 downto 0)); rem_next(8) <= rdat_reg(4);
                        c_next <= rdat_reg(5);
              when 4 => rem_next(7 downto 0) <= unsigned(rdat_reg);
              when others => acc_next <= unsigned(rdat_reg);
            end case;
            if idx_reg = 5 then
              idx_next <= (others => '0');
              state_next <= st_fetch;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

        when st_fetch =>
          if rack_reg = '1' then
            pc_next <= pc_reg + 1;
            op_next <= rdat_reg;
            endsl_next <= '0';
            oi_next <= (others => '0');
            if nops_of(rdat_reg) = 0 then state_next <= st_exec; else state_next <= st_opnd; end if;
          end if;

        when st_opnd =>
          if rack_reg = '1' then
            pc_next <= pc_reg + 1;
            case to_integer(oi_reg) is
              when 0 => o1_next <= rdat_reg;
              when 1 => o2_next <= rdat_reg;
              when others => o3_next <= rdat_reg;
            end case;
            if oi_reg + 1 = nops then
              state_next <= st_exec;
            else
              oi_next <= oi_reg + 1;
            end if;
          end if;

        when st_exec =>
          state_next <= st_next;                                -- most instructions: count them
          idx_next <= (others => '0');
          if op_reg(7 downto 6) = "00" or op_reg = x"F0" then   -- MOVE, MOVA
            state_next <= st_chk;
          elsif op_reg(7 downto 6) = "01" or op_reg = x"C4" then  -- WAIT, WAITL
            if op_reg(7) = '0' then wv_next <= "00" & op_reg(5 downto 0); else wv_next <= o1_reg; end if;
            ma := 4;
            endsl_next <= '1';
            state_next <= st_waitw;
          elsif op_reg(7 downto 6) = "10" or op_reg = x"C5" or op_reg = x"C7" then  -- REF, REFL, CALL
            if rem_reg = 1 then                                 -- last of a level: replace it
              pc_next <= target; rem_next <= refn;
              state_next <= st_after;
            elsif depth_reg = 8 then                            -- stack overflow
              ma := 3;
              state_next <= st_save;
            else
              state_next <= st_push;
            end if;
          elsif op_reg = x"C0" then                             -- BASE
            base_next <= unsigned(o1_reg);
          elsif op_reg = x"C1" or op_reg = x"C2" then           -- LOCK, UNLOCK
            lock_next <= not op_reg(1);
          elsif op_reg = x"C6" then                             -- JUMP
            pc_next <= target;
          elsif op_reg = x"C8" then                             -- RET
            if depth_reg = 0 then
              ma := 3;
              state_next <= st_save;
            else
              state_next <= st_pop;
            end if;
          elsif op_reg = x"CA" or op_reg = x"CB" then           -- WAITBIT, WAITCLR
            state_next <= st_chk;
          elsif op_reg = x"FF" then                             -- STOP
            ma := 2;
            state_next <= st_save;
          elsif op_reg(7 downto 3) = "11010" then               -- SIGNAL
            sig_next(u) <= '1';
          elsif op_reg(7 downto 3) = "11100" then               -- FORK
            if u = t then                                       -- onto itself: restart
              pc_next <= target; depth_next <= (others => '0'); rem_next <= (others => '0');
              state_next <= st_after;
            else                                                -- write its context, then count
              tt_next <= unsigned(op_reg(2 downto 0)); iret_next <= "01";
              mt := unsigned(op_reg(2 downto 0)); ma := 1;
              state_next <= st_init;
            end if;
          elsif op_reg(7 downto 3) = "11101" then               -- KILL
            mt := unsigned(op_reg(2 downto 0)); ma := 2;
            if u = t then state_next <= st_save; end if;
          elsif op_reg = x"F1" then                             -- STA
            wv_next <= std_logic_vector(acc_reg);
            state_next <= st_regw;
          elsif op_reg(7 downto 3) = "11110" then               -- LDA, ADD, SUB
            if op_reg(0) = '1' then
              state_next <= st_reg;                             -- Rn: read it first
            else
              x := unsigned(o1_reg);
              case op_reg(2 downto 1) is
                when "01" => acc_next <= x;
                when "10" => s := ('0' & acc_reg) + ('0' & x); acc_next <= s(7 downto 0); c_next <= s(8);
                when others => s := ('0' & acc_reg) - ('0' & x); acc_next <= s(7 downto 0); c_next <= s(8);
              end case;
            end if;
          elsif op_reg = x"F8" then                             -- LDT
            state_next <= st_tab;
          elsif op_reg(7 downto 3) = "11111" and op_reg(2 downto 0) /= "000" and op_reg(2 downto 1) /= "11" then
            if op_reg = x"FD" then                              -- DJNZ
              state_next <= st_reg;
            else                                                -- JZ JNZ JC JNC
              case op_reg(2 downto 0) is
                when "001" => take := acc_reg = 0;
                when "010" => take := acc_reg /= 0;
                when "011" => take := c_reg = '1';
                when others => take := c_reg = '0';
              end case;
              if take then pc_next <= target; end if;
            end if;
          else                                                  -- reserved
            ma := 3;
            state_next <= st_save;
          end if;

        when st_chk =>                                          -- the chip address, checked a clock ago
          state_next <= st_next;                                -- not allowed: MOVE, MOVA, WAITBIT go on
          if acc_ok_reg = '1' then
            state_next <= st_bus;
          elsif op_reg = x"CB" then                             -- reads 0: WAITCLR stalls
            pc_next <= pc_reg - 3;
            state_next <= st_save;
          end if;

        when st_bus =>
          if bus_ack = '1' then
            if is_wr then state_next <= st_next; else state_next <= st_busr; end if;
          end if;

        when st_busr =>                                         -- WAITBIT/WAITCLR: the byte read (brd_reg)
          if op_reg(0) = '0' then stall := (brd_reg and o2_reg) /= x"00";
          else stall := (brd_reg and o2_reg) = x"00"; end if;
          if stall then
            pc_next <= pc_reg - 3;                              -- try again on the next turn
            state_next <= st_save;
          else
            state_next <= st_next;
          end if;

        when st_reg =>                                          -- a register's value: ALU or DJNZ
          if rack_reg = '1' then
            x := unsigned(rdat_reg);
            if op_reg(3) = '1' then                             -- DJNZ
              wv_next <= std_logic_vector(x - 1);
              state_next <= st_regw;
            else
              case op_reg(2 downto 1) is
                when "01" => acc_next <= x;
                when "10" => s := ('0' & acc_reg) + ('0' & x); acc_next <= s(7 downto 0); c_next <= s(8);
                when others => s := ('0' & acc_reg) - ('0' & x); acc_next <= s(7 downto 0); c_next <= s(8);
              end case;
              state_next <= st_next;
            end if;
          end if;

        when st_regw =>                                         -- STA, DJNZ: write the register
          if rack_reg = '1' then
            if op_reg(3) = '1' and wv_reg /= x"00" then pc_next <= target; end if;
            state_next <= st_next;
          end if;

        when st_tab =>                                          -- LDT
          if rack_reg = '1' then
            acc_next <= unsigned(rdat_reg);
            state_next <= st_next;
          end if;

        when st_waitw =>
          if rack_reg = '1' then state_next <= st_next; end if;

        when st_push =>
          if rack_reg = '1' then
            if idx_reg = 2 then
              depth_next <= depth_reg + 1;
              pc_next <= target; rem_next <= refn;
              idx_next <= (others => '0');
              state_next <= st_after;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

        when st_pop =>
          if rack_reg = '1' then
            case to_integer(idx_reg) is
              when 0 => pc_next(7 downto 0) <= unsigned(rdat_reg);
              when 1 => pc_next(15 downto 8) <= unsigned(rdat_reg);
              when others => rem_next <= resize(unsigned(rdat_reg), 9);
            end case;
            if idx_reg = 2 then
              depth_next <= depth_reg - 1;
              idx_next <= (others => '0');
              state_next <= st_after;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

        when st_next =>                                         -- count the instruction
          idx_next <= (others => '0');
          if rem_reg = 1 then
            state_next <= st_pop;                               -- the level is done
          else
            if rem_reg /= 0 then rem_next <= rem_reg - 1; end if;
            state_next <= st_after;
          end if;

        when st_after =>                                        -- between instructions
          idx_next <= (others => '0');
          if spend_reg = '1' and st_t_reg /= cur_reg and st_rest then   -- serve a host start first
            tt_next <= st_t_reg; iret_next <= "10";
            mt := st_t_reg; ma := 1;
            state_next <= st_init;
          elsif endsl_reg = '1' or running_reg(t) = '0' or
                ((budget_reg = 0 or run_reg = '0') and lock_reg = '0') then
            state_next <= st_save;
          else
            if budget_reg /= 0 then budget_next <= budget_reg - 1; end if;
            state_next <= st_fetch;
          end if;

        when st_save =>                                         -- header bytes 0, 1, 3, 4, 5, 6
          if rack_reg = '1' then
            if idx_reg = 5 then
              idx_next <= (others => '0');
              state_next <= st_idle;
            else
              idx_next <= idx_reg + 1;
            end if;
          end if;

      end case;

      ---------------------------------------------------------------- the masks
      oh := (others => '0');
      oh(to_integer(mt)) := '1';
      case ma is
        when 1 => running_next <= running_reg or oh; ready_next <= ready_reg or oh; err_next <= err_reg and not oh;
        when 2 => running_next <= running_reg and not oh; ready_next <= ready_reg and not oh;
        when 3 => running_next <= running_reg and not oh; ready_next <= ready_reg and not oh; err_next <= err_reg or oh;
        when 4 => ready_next <= ready_reg and not oh;
        when others => null;
      end case;
      if mrdy then ready_next <= ready_reg or oh; end if;

      ---------------------------------------------------------------- host writes
      if cpu_we = '1' then
        case ca is
          when 0 =>
            run_next <= cpu_di(0);
            if cpu_di(2) = '1' then div_next <= (others => '0'); tpend_next <= '1'; end if;
          when 1 => caddr_next(7 downto 0) <= cpu_di;
          when 2 => caddr_next(15 downto 8) <= cpu_di;
          when 3 =>
            spend_next <= '1';
            st_t_next <= unsigned(cpu_di(2 downto 0));
            st_pc_next <= caddr_reg;
            st_b_next <= cbase_reg;
            st_n_next <= pcnt_reg;
            pcnt_next <= (others => '0');
          when 4 =>
            running_next <= running_reg and not cpu_di;
            ready_next <= ready_reg and not cpu_di;
          when 5 => sig_next <= sig_reg and not cpu_di;
          when 6 => tickl_next <= cpu_di;
          when 7 => period_next <= unsigned(cpu_di) & unsigned(tickl_reg);
          when 8 => cbase_next <= cpu_di;
          when 9 =>
            if pcnt_reg(3) = '0' then
              par_next(to_integer(pcnt_reg(2 downto 0))) <= cpu_di;
              pcnt_next <= pcnt_reg + 1;
            end if;
          when others => null;
        end case;
      end if;
      if sig_clear = '1' then
        sig_next <= (others => '0');
      end if;
      if cpu_we = '1' and ca = 0 and cpu_di(1) = '1' then                -- STOPALL
        running_next <= (others => '0');
        ready_next <= (others => '0');
        err_next <= (others => '0');
        sig_next <= (others => '0');
        spend_next <= '0';
        pcnt_next <= (others => '0');
      end if;
    end process;

  end generate;

  g_off : if not ENABLE generate
    cpu_do    <= (others => '0');
    sig_any   <= '0';
    ram_req   <= '0';
    ram_we    <= '0';
    ram_addr  <= (others => '0');
    ram_wdata <= (others => '0');
    bus_req   <= '0';
    bus_we    <= '0';
    bus_addr  <= (others => '0');
    bus_wdata <= (others => '0');
  end generate;

end architecture;
