---------------------------------------------------------------------------
-- (c) 2020 mark watson
-- I am happy for anyone to use this for non-commercial use.
-- If my vhdl files are used commercially or otherwise sold,
-- please contact me for explicit permission at scrameta (gmail).
-- This applies for source and binary form and derived works.
---------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
use work.AudioTypes.all;

-- Same filter as dc_blocker, but CHANNELS channels share one datapath.
-- AUDIO_IN is offset-binary unsigned audio (2**15 = zero).
--
-- Filter per channel:
--   y  = x - dc_old
--   dc = dc_old + (y / 2**K)       (once per ENABLE_CYCLE)
--
-- A channel counter visits one channel per clock. On each visit:
--   AUDIO_OUT(ch) <= saturate(x - dc)
--   dc(ch) is updated if an ENABLE_CYCLE has occurred since the last visit
--
-- The dc state and pending flags rotate one place per clock, so the visited
-- channel's state is always in slot 0 and needs no read mux.
--
-- So each output refreshes every CHANNELS clocks (instead of every clock),
-- and the dc update uses the input up to CHANNELS clocks after ENABLE_CYCLE.
-- ENABLE_CYCLE must be at least CHANNELS clocks apart (it is ~32 here).
ENTITY dc_blocker_shared IS
GENERIC
(
	CHANNELS   : positive := 4;
	EXTRA_BITS : positive := 4;
	K          : natural  := 10
);
PORT
(
	CLK          : IN  std_logic;
	RESET_N      : IN  std_logic;
	ENABLE_CYCLE : IN  std_logic;

	AUDIO_IN    : IN  UNSIGNED_AUDIO_TYPE(CHANNELS-1 downto 0);
	AUDIO_OUT   : OUT SIGNED_AUDIO_TYPE(CHANNELS-1 downto 0)
);
END dc_blocker_shared;

ARCHITECTURE vhdl OF dc_blocker_shared IS
	constant BITS : positive := 16;
	constant ACC_WIDTH : positive := BITS + EXTRA_BITS;

	subtype acc_t is signed(ACC_WIDTH-1 downto 0);
	type acc_array_t is array(natural range<>) of acc_t;

	function saturate_to_bits(v : acc_t) return signed is
		variable r        : signed(BITS-1 downto 0);
		variable overflow : boolean := false;
		variable max_val  : signed(BITS-1 downto 0) := (others => '1');
		variable min_val  : signed(BITS-1 downto 0) := (others => '0');
	begin
		max_val(BITS-1) := '0';
		min_val(BITS-1) := '1';

		for i in BITS to ACC_WIDTH-1 loop
			if v(i) /= v(BITS-1) then
				overflow := true;
			end if;
		end loop;

		if overflow then
			if v(ACC_WIDTH-1) = '0' then
				r := max_val;
			else
				r := min_val;
			end if;
		else
			r := v(BITS-1 downto 0);
		end if;

		return r;
	end function;

	signal ch_reg  : integer range 0 to CHANNELS-1;
	signal ch_next : integer range 0 to CHANNELS-1;

	-- slot 0 holds the channel currently being visited (ch_reg)
	signal pending_reg  : std_logic_vector(CHANNELS-1 downto 0);
	signal pending_next : std_logic_vector(CHANNELS-1 downto 0);

	signal dc_reg  : acc_array_t(CHANNELS-1 downto 0);
	signal dc_next : acc_array_t(CHANNELS-1 downto 0);
	signal dc_new  : acc_t;

	signal audio_out_reg : SIGNED_AUDIO_TYPE(CHANNELS-1 downto 0);
	signal audio_out_new : signed(BITS-1 downto 0);
BEGIN
	-- channel sequencer
	process(ch_reg)
	begin
		if ch_reg = CHANNELS-1 then
			ch_next <= 0;
		else
			ch_next <= ch_reg + 1;
		end if;
	end process;

	-- Rotate state by one slot. ENABLE_CYCLE marks every channel pending;
	-- the visited channel (slot 0) consumes its flag and moves to the end.
	process(pending_reg, ENABLE_CYCLE, dc_reg, dc_new)
	begin
		for i in 0 to CHANNELS-2 loop
			pending_next(i) <= pending_reg(i+1) or ENABLE_CYCLE;
			dc_next(i)      <= dc_reg(i+1);
		end loop;
		pending_next(CHANNELS-1) <= ENABLE_CYCLE;
		dc_next(CHANNELS-1)      <= dc_new;
	end process;

	-- shared datapath
	process(AUDIO_IN, dc_reg, ch_reg, pending_reg)
		variable x_ext : acc_t;
		variable err   : acc_t;
	begin
		-- offset binary to signed: invert the MSB, sign extend
		x_ext := resize(signed(not(AUDIO_IN(ch_reg)(BITS-1)) & AUDIO_IN(ch_reg)(BITS-2 downto 0)), ACC_WIDTH);
		err   := x_ext - dc_reg(0);

		audio_out_new <= saturate_to_bits(err);
		if pending_reg(0) = '1' then
			dc_new <= dc_reg(0) + shift_right(err, K);
		else
			dc_new <= dc_reg(0);
		end if;
	end process;

	process(CLK, RESET_N)
	begin
		if RESET_N = '0' then
			ch_reg        <= 0;
			pending_reg   <= (others => '0');
			dc_reg        <= (others => (others => '0'));
			audio_out_reg <= (others => (others => '0'));
		elsif CLK'event and CLK = '1' then
			ch_reg      <= ch_next;
			pending_reg <= pending_next;
			dc_reg      <= dc_next;
			audio_out_reg(ch_reg) <= audio_out_new;
		end if;
	end process;

	AUDIO_OUT <= audio_out_reg;
END vhdl;
