library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_ext_phase is end;
architecture sim of tb_ext_phase is
  signal freq : std_logic_vector(17 downto 0) := (others=>'0');
  signal detune, stoch : std_logic_vector(5 downto 0) := (others=>'0');
  signal rnd : std_logic_vector(7 downto 0) := (others=>'0');
  signal old_p, new_p : std_logic_vector(17 downto 0) := (others=>'0');
  signal en, white : std_logic := '0';
begin
  dut: entity work.amy1_ext_phase port map
    (freq_inc=>freq, detune=>detune, stochasticity=>stoch,
     random_byte=>rnd, old_phase=>old_p, ext_enable=>en, white=>white, new_phase=>new_p);
  process
  begin
    freq<=std_logic_vector(to_unsigned(16384,18));
    detune<="010000"; -- +16 / 64
    stoch<="000000";
    old_p<=std_logic_vector(to_unsigned(12345,18));
    wait for 1 ns;
    assert unsigned(new_p)=12345 report "disabled must bypass arithmetic" severity failure;
    en<='1';
    wait for 1 ns;
    assert unsigned(new_p)=12345+1024 report "fractional detune +16" severity failure;
    detune<="110000"; -- -16
    wait for 1 ns;
    assert unsigned(new_p)=12345-1024 report "fractional detune -16" severity failure;
    detune<="000000";
    -- exponential diffusion (C.3): step = r * (8 + s[2:0]) << s[5:3]
    stoch<="001000"; -- 8: step 16
    rnd<=x"20"; -- +32
    wait for 1 ns;
    assert unsigned(new_p)=12345+512 report "positive phase diffusion" severity failure;
    rnd<=x"E0"; -- -32
    wait for 1 ns;
    assert unsigned(new_p)=12345-512 report "negative phase diffusion" severity failure;
    stoch<="000001"; -- 1: step 9
    rnd<=x"20";
    wait for 1 ns;
    assert unsigned(new_p)=12345+288 report "diffusion s=1" severity failure;
    stoch<="111111"; -- 63: step 15 << 7 = 1920
    wait for 1 ns;
    assert unsigned(new_p)=(12345+61440) mod 262144 report "diffusion s=63" severity failure;
    stoch<="000000"; -- 0: no diffusion, whatever r is
    wait for 1 ns;
    assert unsigned(new_p)=12345 report "diffusion s=0 must be exact" severity failure;
    -- white noise (type 3): full-circle random step r << 10, detune/diffusion ignored
    white<='1'; detune<="010000"; stoch<="111111";
    rnd<=x"20";
    wait for 1 ns;
    assert unsigned(new_p)=12345+32768 report "white +32" severity failure;
    rnd<=x"E0";
    wait for 1 ns;
    assert unsigned(new_p)=(12345-32768+262144) mod 262144 report "white -32 (wraps)" severity failure;
    en<='0';
    wait for 1 ns;
    assert unsigned(new_p)=12345 report "white must also bypass while locked" severity failure;
    en<='1'; white<='0'; detune<="000000";
    stoch<="000000";
    old_p<=(others=>'1');
    detune<="000001";
    wait for 1 ns;
    assert unsigned(new_p)=63 report "phase addition must wrap modulo 2^18" severity failure;
    report "tb_ext_phase passed";
    wait;
  end process;
end architecture;
