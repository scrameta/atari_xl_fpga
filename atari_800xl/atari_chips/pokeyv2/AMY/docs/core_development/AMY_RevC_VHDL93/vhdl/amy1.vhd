-------------------------------------------------------------------------------
-- AMY1: the core with its memories.
--
-- clk, ce: ce is one AMY internal clock (4 MHz at the spec's 8 MHz CLOCK). It must be low
-- on the clk before each ce (the memories read in between); the packed memory layout
-- needs it low on the two clks before each ce.
-- Registers (addr 0 command, 1 A, 2 B, 3 C): we writes wdata at the clk edge, rdata is the
-- addressed register. rdy is INT/RDY: in READY mode high when no command is pending or
-- running; in INT mode a pulse at the end of each command.
-- sample: the 17-bit two's complement sum, new in the clock sample_stb is high (one per
-- sample period in SUM mode, one per voice in INDIVIDUAL mode, sample_v0 marking voice 0).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1 is
  generic (
    -- Repair the noise generators' pseudo-random registers (see the README). false = the
    -- netlist as drawn, where A, B and C get no feedback and freeze within 15 updates.
    NOISE_FIX : boolean := true;
    -- memory layout: true = packed into 4 M9Ks (needs ce low on the two clks before each
    -- ce), false = one block per memory (ce low on the clk before each ce)
    MEM_PACKED : boolean := true
  );
  port (
    clk        : in  std_logic;
    ce         : in  std_logic;
    reset      : in  std_logic;                      -- synchronous, active high
    ext_enable : in  std_logic := '0';
    ext_we : in std_logic := '0';
    ext_kind : in std_logic_vector(1 downto 0) := "00";
    ext_index : in std_logic_vector(5 downto 0) := (others => '0');
    ext_value : in std_logic_vector(7 downto 0) := (others => '0');
    ext_clear : in std_logic := '0';
    ext_ack : out std_logic;               -- Rev C enable; default preserves legacy modes

    addr       : in  std_logic_vector(1 downto 0);
    we         : in  std_logic;
    wdata      : in  std_logic_vector(7 downto 0);
    rdata      : out std_logic_vector(7 downto 0);
    rdy        : out std_logic;

    sample     : out signed(16 downto 0);
    sample_stb : out std_logic;
    sample_v0  : out std_logic;

    -- memory load port (fill all memories before releasing reset): amy1_mem.hex / .bin,
    -- all addresses logical (the netlist's image has the envelope RAMs' words reversed)
    load_we   : in  std_logic;                      -- write one image word
    load_addr : in  std_logic_vector(10 downto 0);
    load_data : in  std_logic_vector(31 downto 0);
    -- auxiliary port on the VOICE block RAM (words 16..255; the packed layout only)
    aux_re    : in  std_logic := '0';
    aux_raddr : in  std_logic_vector(7 downto 0) := (others => '0');
    aux_rack  : out std_logic;
    aux_rdata : out std_logic_vector(35 downto 0);
    aux_we    : in  std_logic := '0';
    aux_waddr : in  std_logic_vector(7 downto 0) := (others => '0');
    aux_wdata : in  std_logic_vector(35 downto 0) := (others => '0');
    aux_wack  : out std_logic;
    -- auxiliary port 2 on the harmonic block RAM (words 128..255; the packed layout only)
    aux2_re    : in  std_logic := '0';
    aux2_raddr : in  std_logic_vector(6 downto 0) := (others => '0');
    aux2_rack  : out std_logic;
    aux2_rdata : out std_logic_vector(35 downto 0);
    aux2_we    : in  std_logic := '0';
    aux2_waddr : in  std_logic_vector(6 downto 0) := (others => '0');
    aux2_wdata : in  std_logic_vector(35 downto 0) := (others => '0');
    aux2_wack  : out std_logic
  );
end entity;

architecture rtl of amy1 is
  signal noise_init : std_logic;
  signal phaseram_addr : std_logic_vector(2 downto 0);
  signal phaseram_we : std_logic;
  signal phaseram_wdata, phaseram_q : std_logic_vector(19 downto 0);
  signal noise_addr : std_logic_vector(5 downto 0);
  signal noise_we : std_logic;
  signal noise_wdata, noise_wcore, noise_q : std_logic_vector(2 downto 0);
  signal harm_addr : std_logic_vector(5 downto 0);
  signal voice_addr : std_logic_vector(3 downto 0);
  signal lhpram_we : std_logic;
  signal lhpram_wdata, lhpram_q : std_logic_vector(0 downto 0);
  signal harmbrkpoint_we : std_logic;
  signal harmbrkpoint_wdata, harmbrkpoint_q : std_logic_vector(15 downto 0);
  signal harmcurntval_we : std_logic;
  signal harmcurntval_wdata, harmcurntval_q : std_logic_vector(12 downto 0);
  signal voice18_we : std_logic;
  signal voice18_wdata, voice18_q : std_logic_vector(17 downto 0);
  signal voice3_we : std_logic;
  signal voice3_wdata, voice3_q : std_logic_vector(2 downto 0);
  signal octspl_q : std_logic_vector(3 downto 0);
  signal detune_q, stoch_q : std_logic_vector(5 downto 0);
  signal offset_old_q, offset_new_q, offset_wdata : std_logic_vector(17 downto 0);
  signal freq_inc_q : std_logic_vector(17 downto 0);
  signal noise_random_q : std_logic_vector(7 downto 0);
  signal phase_slot_q : std_logic_vector(5 downto 0);
  signal offset_step_q : std_logic;
  signal ext_mem_ack, ext_att_ack : std_logic := '0';
  signal xrombs_addr : std_logic_vector(6 downto 0);
  signal xrombs_q : std_logic_vector(14 downto 0);
  signal xromint_addr : std_logic_vector(6 downto 0);
  signal xromint_q : std_logic_vector(4 downto 0);
  signal srombs_addr : std_logic_vector(7 downto 0);
  signal srombs_q : std_logic_vector(16 downto 0);
  signal sromint_addr : std_logic_vector(8 downto 0);
  signal sromint_q : std_logic_vector(4 downto 0);
  type nf_t is array (0 to 1) of std_logic_vector(2 downto 0);
  signal nf_acc, nf_fb : nf_t := (others => (others => '0'));
  signal nf_ok : std_logic_vector(1 downto 0) := "00";
begin
  -- Attenuation updates are local; harmonic writes wait for the packed RAM's
  -- scheduled RMW acknowledgement before the wrapper dequeues another command.
  process(clk)
  begin
    if rising_edge(clk) then
      ext_att_ack <= ext_we and not ext_kind(1) and not ext_kind(0);
    end if;
  end process;
  ext_ack <= ext_att_ack or ext_mem_ack;

  -- Noise generator PRB repair (NOISE_FIX): row 0 of each generator is written with the
  -- XOR of rows 0, 3, 8 and 14 from that generator's previous pass
  nf_p: process (noise_addr, noise_we, noise_wcore, noise_init, nf_ok, nf_fb)
    variable g : integer range 0 to 1;
  begin
    g := 0; if noise_addr(0) = '1' then g := 1; end if;
    noise_wdata <= noise_wcore;
    if NOISE_FIX and noise_init = '0' and noise_addr(5 downto 1) = "00000" and nf_ok(g) = '1' then
      noise_wdata <= nf_fb(g);
    end if;
  end process;

  nf_r: process (clk)
    variable g : integer range 0 to 1;
  begin
    if rising_edge(clk) then
      if ce = '1' then
        g := 0; if noise_addr(0) = '1' then g := 1; end if;
        if noise_init = '1' then
          nf_ok <= "00";
        elsif noise_we = '1' then
          case to_integer(unsigned(noise_addr(5 downto 1))) is
            when 0      => nf_acc(g) <= noise_wdata;
            when 3 | 8  => nf_acc(g) <= nf_acc(g) xor noise_wcore;
            when 14     => nf_fb(g) <= nf_acc(g) xor noise_wcore; nf_ok(g) <= '1';
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

  core: entity work.amy1_core port map (
    clk => clk, ce => ce, reset => reset, ext_enable => ext_enable,
    ext_we => ext_we, ext_kind => ext_kind, ext_index => ext_index,
    ext_value => ext_value, ext_clear => ext_clear,
    detune_q => detune_q, stoch_q => stoch_q, offset_old_q => offset_old_q,
    offset_new_q => offset_new_q, offset_wdata => offset_wdata,
    freq_inc_q => freq_inc_q, noise_random_q => noise_random_q,
    phase_slot => phase_slot_q, offset_step => offset_step_q,
    addr => addr, we => we, wdata => wdata, rdata => rdata, rdy => rdy,
    sample => sample, sample_stb => sample_stb, sample_v0 => sample_v0,
    noise_init => noise_init,
    phaseram_addr => phaseram_addr, phaseram_we => phaseram_we,
    phaseram_wdata => phaseram_wdata, phaseram_q => phaseram_q,
    noise_addr => noise_addr, noise_we => noise_we, noise_wdata => noise_wcore, noise_q => noise_q,
    harm_addr => harm_addr,
    lhpram_we => lhpram_we, lhpram_wdata => lhpram_wdata, lhpram_q => lhpram_q,
    harmbrkpoint_we => harmbrkpoint_we, harmbrkpoint_wdata => harmbrkpoint_wdata,
    harmbrkpoint_q => harmbrkpoint_q,
    harmcurntval_we => harmcurntval_we, harmcurntval_wdata => harmcurntval_wdata,
    harmcurntval_q => harmcurntval_q,
    voice_addr => voice_addr,
    voice18_we => voice18_we, voice18_wdata => voice18_wdata, voice18_q => voice18_q,
    voice3_we => voice3_we, voice3_wdata => voice3_wdata, voice3_q => voice3_q,
    xrombs_addr => xrombs_addr, xrombs_q => xrombs_q,
    xromint_addr => xromint_addr, xromint_q => xromint_q,
    srombs_addr => srombs_addr, srombs_q => srombs_q,
    sromint_addr => sromint_addr, sromint_q => sromint_q);

  mem_p: if MEM_PACKED generate
    mem: entity work.amy1_mem(packed) port map (
    clk => clk, ce => ce,
    ext_reset => reset or ext_clear, ext_enable => ext_enable,
    ext_we => ext_we, ext_kind => ext_kind, ext_index => ext_index,
    ext_value => ext_value, ext_ack => ext_mem_ack, phase_slot => phase_slot_q, offset_step => offset_step_q,
    detune_q => detune_q, stoch_q => stoch_q,
    offset_old_q => offset_old_q, offset_new_q => offset_new_q,
    offset_wdata => offset_wdata,
    load_we => load_we, load_addr => load_addr, load_data => load_data,
    aux_re => aux_re, aux_raddr => aux_raddr, aux_rack => aux_rack, aux_rdata => aux_rdata,
    aux_we => aux_we, aux_waddr => aux_waddr, aux_wdata => aux_wdata, aux_wack => aux_wack,
    aux2_re => aux2_re, aux2_raddr => aux2_raddr, aux2_rack => aux2_rack, aux2_rdata => aux2_rdata,
    aux2_we => aux2_we, aux2_waddr => aux2_waddr, aux2_wdata => aux2_wdata, aux2_wack => aux2_wack,
    phaseram_addr => phaseram_addr, phaseram_we => phaseram_we,
    phaseram_wdata => phaseram_wdata, phaseram_q => phaseram_q,
    noise_addr => noise_addr, noise_we => noise_we, noise_wdata => noise_wdata, noise_q => noise_q,
    lhpram_addr => harm_addr, lhpram_we => lhpram_we,
    lhpram_wdata => lhpram_wdata, lhpram_q => lhpram_q,
    harmbrkpoint_addr => harm_addr, harmbrkpoint_we => harmbrkpoint_we,
    harmbrkpoint_wdata => harmbrkpoint_wdata, harmbrkpoint_q => harmbrkpoint_q,
    harmcurntval_addr => harm_addr, harmcurntval_we => harmcurntval_we,
    harmcurntval_wdata => harmcurntval_wdata, harmcurntval_q => harmcurntval_q,
    voice18_addr => voice_addr, voice18_we => voice18_we,
    voice18_wdata => voice18_wdata, voice18_q => voice18_q,
    voice3_addr => voice_addr, voice3_we => voice3_we,
    voice3_wdata => voice3_wdata, voice3_q => voice3_q,
    octspl_addr => (others => '0'), octspl_q => octspl_q,
    xrombs_addr => xrombs_addr, xrombs_q => xrombs_q,
    xromint_addr => xromint_addr, xromint_q => xromint_q,
    srombs_addr => srombs_addr, srombs_q => srombs_q,
    sromint_addr => sromint_addr, sromint_q => sromint_q);
  end generate;
  mem_r: if not MEM_PACKED generate
    mem: entity work.amy1_mem(rtl) port map (
    clk => clk, ce => ce,
    ext_reset => reset or ext_clear, ext_enable => ext_enable,
    ext_we => ext_we, ext_kind => ext_kind, ext_index => ext_index,
    ext_value => ext_value, ext_ack => open, phase_slot => phase_slot_q, offset_step => offset_step_q,
    detune_q => open, stoch_q => open,
    offset_old_q => open, offset_new_q => open,
    offset_wdata => offset_wdata,
    load_we => load_we, load_addr => load_addr, load_data => load_data,
    aux_re => aux_re, aux_raddr => aux_raddr, aux_rack => aux_rack, aux_rdata => aux_rdata,
    aux_we => aux_we, aux_waddr => aux_waddr, aux_wdata => aux_wdata, aux_wack => aux_wack,
    aux2_re => aux2_re, aux2_raddr => aux2_raddr, aux2_rack => aux2_rack, aux2_rdata => aux2_rdata,
    aux2_we => aux2_we, aux2_waddr => aux2_waddr, aux2_wdata => aux2_wdata, aux2_wack => aux2_wack,
    phaseram_addr => phaseram_addr, phaseram_we => phaseram_we,
    phaseram_wdata => phaseram_wdata, phaseram_q => phaseram_q,
    noise_addr => noise_addr, noise_we => noise_we, noise_wdata => noise_wdata, noise_q => noise_q,
    lhpram_addr => harm_addr, lhpram_we => lhpram_we,
    lhpram_wdata => lhpram_wdata, lhpram_q => lhpram_q,
    harmbrkpoint_addr => harm_addr, harmbrkpoint_we => harmbrkpoint_we,
    harmbrkpoint_wdata => harmbrkpoint_wdata, harmbrkpoint_q => harmbrkpoint_q,
    harmcurntval_addr => harm_addr, harmcurntval_we => harmcurntval_we,
    harmcurntval_wdata => harmcurntval_wdata, harmcurntval_q => harmcurntval_q,
    voice18_addr => voice_addr, voice18_we => voice18_we,
    voice18_wdata => voice18_wdata, voice18_q => voice18_q,
    voice3_addr => voice_addr, voice3_we => voice3_we,
    voice3_wdata => voice3_wdata, voice3_q => voice3_q,
    octspl_addr => (others => '0'), octspl_q => octspl_q,
    xrombs_addr => xrombs_addr, xrombs_q => xrombs_q,
    xromint_addr => xromint_addr, xromint_q => xromint_q,
    srombs_addr => srombs_addr, srombs_q => srombs_q,
    sromint_addr => sromint_addr, sromint_q => sromint_q);
  end generate;

end architecture;
