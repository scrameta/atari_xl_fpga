---------------------------------------------------------------------------
-- (c) 2026 mark watson
-- I am happy for anyone to use this for non-commercial use.
-- If my vhdl files are used commercially or otherwise sold,
-- please contact me for explicit permission at scrameta (gmail).
-- This applies for source and binary form and derived works.
--
-- v2: indexed bank/group selection, avoiding large selected-OR reductions.
-- v3: one write path shared by all RAMs. Each write stores a single RAM, so
--     its data no longer depends on that RAM's own output:
--       normal page: 1 write cycle, bit 8 kept via the shared read mux
--       wide page:   8 write cycles, one RAM of the group per cycle, its
--                    bits 7..0 kept via the shared read mux
--     BUSY is high during the write cycles: the RAMs see the latched write
--     address then, so a read presented in those cycles is not served
--     (sample_top holds the DMA's data_ready and record writes off).
--     Writes that arrive while BUSY are ignored; CPU writes are far apart.
--     Reads: the output mux follows the address the RAMs actually read (the one
--     given in the cycle before), as a plain synchronous RAM would. v2 used the
--     live address, so data was wrong if the address changed after the read
--     (e.g. a CPU access in the cycle the DMA used its data).
---------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY m9k_grouped IS
	GENERIC
	(
		-- 64K configuration:
		--   (7*8 + 7)*1024 = 63 KiB in 56 M9Ks using the 9th bit
		--   +1 KiB in one extra M9K
		NUM_GROUPS        : natural := 7;
		EXTRA_RAM_BLOCKS  : natural := 1

		-- 48K configuration:
		-- NUM_GROUPS        : natural := 5;
		-- EXTRA_RAM_BLOCKS  : natural := 3
	);
	PORT
	(
		clock   : IN  std_logic;
		reset_n : IN  std_logic := '1';
		data    : IN  std_logic_vector(7 DOWNTO 0);
		address : IN  std_logic_vector(15 DOWNTO 0);
		we      : IN  std_logic;
		q       : OUT std_logic_vector(7 DOWNTO 0);
		busy    : OUT std_logic   -- writing: reads presented now are not served
	);
END m9k_grouped;

ARCHITECTURE rtl OF m9k_grouped IS
	constant ADDR_BITS       : natural := 16;
	constant RAM_ADDR_BITS   : natural := 10; -- 1 KiB per RAM block
	constant PAGE_BITS       : natural := ADDR_BITS - RAM_ADDR_BITS; -- 6

	constant BYTE_BITS       : natural := 8;
	constant WIDE_BIT        : natural := 8;

	constant NORMAL_RAM_BLOCKS : natural := NUM_GROUPS * BYTE_BITS;
	constant GROUP_RAM_PAGES   : natural := NORMAL_RAM_BLOCKS + NUM_GROUPS;
	constant TOTAL_RAM_BLOCKS  : natural := NORMAL_RAM_BLOCKS + EXTRA_RAM_BLOCKS;
	constant TOTAL_MAPPED_PAGES: natural := GROUP_RAM_PAGES + EXTRA_RAM_BLOCKS;

	TYPE ram_data_t IS ARRAY(0 TO TOTAL_RAM_BLOCKS-1) OF std_logic_vector(8 DOWNTO 0);

	SIGNAL q_ram_wide          : ram_data_t;
	SIGNAL write_word          : std_logic_vector(8 DOWNTO 0);  -- the same for every RAM
	SIGNAL we_ram              : std_logic_vector(0 TO TOTAL_RAM_BLOCKS-1);

	SIGNAL address_ram         : std_logic_vector(RAM_ADDR_BITS-1 DOWNTO 0);
	SIGNAL address_used        : std_logic_vector(ADDR_BITS-1 DOWNTO 0);

	-- page decode: PAGE_* of the address in use (for starting a write), WR_* of the
	-- latched write address, RD_* of the address the RAM outputs belong to
	TYPE page_t IS RECORD
		normal : std_logic;   -- 8-bit page in a grouped RAM or an extra RAM
		wide   : std_logic;   -- 8-bit page made of a group's bit 8
		ram    : natural RANGE 0 TO TOTAL_RAM_BLOCKS-1;  -- its RAM (normal)
		grp    : natural RANGE 0 TO BYTE_BITS-1;         -- its group (wide)
	END RECORD;

	FUNCTION decode(a : std_logic_vector(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS)) RETURN page_t IS
		VARIABLE page : natural RANGE 0 TO 2**PAGE_BITS-1;
		VARIABLE r    : page_t;
	BEGIN
		page    := to_integer(unsigned(a));
		r.grp := to_integer(unsigned(a(12 DOWNTO 10)));
		r.normal := '0';
		r.wide   := '0';
		r.ram    := 0;
		-- 64 KiB example:
		--   pages 0..55  : normal 8-bit access to RAM blocks 0..55
		--   pages 56..62 : wide access using bit 8 of RAM blocks 0..55
		--   page  63     : normal 8-bit access to RAM block 56
		IF page < NORMAL_RAM_BLOCKS THEN
			r.normal := '1';
			r.ram    := page;
		ELSIF page < GROUP_RAM_PAGES THEN
			r.wide   := '1';
		ELSIF page < TOTAL_MAPPED_PAGES THEN
			r.normal := '1';
			r.ram    := NORMAL_RAM_BLOCKS + (page - GROUP_RAM_PAGES);
		END IF;
		RETURN r;
	END FUNCTION;

	SIGNAL pg, wr, rd          : page_t;
	SIGNAL rd_page_reg         : std_logic_vector(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS);

	SIGNAL sel_ram             : natural RANGE 0 TO TOTAL_RAM_BLOCKS-1;  -- RAM read by sel_q
	SIGNAL sel_q               : std_logic_vector(8 DOWNTO 0);

	TYPE state_t IS (state_idle, state_write, state_write_wide);
	SIGNAL state_next          : state_t;
	SIGNAL state_reg           : state_t;

	SIGNAL bit_next            : unsigned(2 DOWNTO 0);   -- wide write: RAM of the group
	SIGNAL bit_reg             : unsigned(2 DOWNTO 0);

	SIGNAL data_next           : std_logic_vector(7 DOWNTO 0);
	SIGNAL data_reg            : std_logic_vector(7 DOWNTO 0);

	SIGNAL address_next        : std_logic_vector(ADDR_BITS-1 DOWNTO 0);
	SIGNAL address_reg         : std_logic_vector(ADDR_BITS-1 DOWNTO 0);
BEGIN

	-- During idle/read, the RAMs see the live bus address.
	-- During the write cycles, they see the latched write address.
	address_used <= address WHEN state_reg = state_idle ELSE address_reg;
	address_ram  <= address_used(RAM_ADDR_BITS-1 DOWNTO 0);
	busy         <= '0' WHEN state_reg = state_idle ELSE '1';

	PROCESS(clock, reset_n)
	BEGIN
		IF reset_n = '0' THEN
			state_reg   <= state_idle;
			bit_reg     <= (others => '0');
			data_reg    <= (others => '0');
			address_reg <= (others => '0');
		ELSIF rising_edge(clock) THEN
			state_reg   <= state_next;
			bit_reg     <= bit_next;
			data_reg    <= data_next;
			address_reg <= address_next;
		END IF;
	END PROCESS;

	pg <= decode(address_used(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS));
	wr <= decode(address_reg(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS));
	rd <= decode(rd_page_reg);

	-- the page the RAMs read at this edge: their outputs belong to it next cycle
	PROCESS(clock)
	BEGIN
		IF rising_edge(clock) THEN
			rd_page_reg <= address_used(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS);
		END IF;
	END PROCESS;

	-- One write per cycle: idle -> state_write (normal page, 1 cycle)
	--                      idle -> state_write_wide (8 cycles, bit_reg = 0..7)
	PROCESS(state_reg, bit_reg, we, data, address, data_reg, address_reg, pg)
	BEGIN
		state_next   <= state_reg;
		bit_next     <= bit_reg;
		data_next    <= data_reg;
		address_next <= address_reg;

		CASE state_reg IS
			WHEN state_idle =>
				IF we = '1' THEN
					data_next    <= data;
					address_next <= address;
					bit_next     <= (others => '0');
					IF pg.wide = '1' THEN            -- address_used = address here
						state_next <= state_write_wide;
					ELSIF pg.normal = '1' THEN
						state_next <= state_write;
					END IF;                          -- unmapped: nothing to write
				END IF;

			WHEN state_write =>
				state_next <= state_idle;

			WHEN state_write_wide =>
				bit_next <= bit_reg + 1;
				IF bit_reg = BYTE_BITS-1 THEN
					state_next <= state_idle;
				END IF;
		END CASE;
	END PROCESS;

	-- The RAM read by the shared mux: in a wide write the group's RAM being
	-- written, in a normal write the page's RAM, else (reads) the RAM of the
	-- page the outputs belong to.
	sel_ram <= wr.grp * BYTE_BITS + to_integer(bit_reg)
	                WHEN state_reg = state_write_wide AND wr.grp < NUM_GROUPS
	           ELSE wr.ram WHEN state_reg = state_write
	           ELSE rd.ram;
	sel_q <= q_ram_wide(sel_ram);

	-- Write data, the same for every RAM (only one is written per cycle). The
	-- RAMs still output the word at the write address, read in the cycle before.
	PROCESS(state_reg, data_reg, bit_reg, sel_q)
	BEGIN
		IF state_reg = state_write_wide THEN
			write_word <= data_reg(to_integer(bit_reg)) & sel_q(BYTE_BITS-1 DOWNTO 0);
		ELSE
			write_word <= sel_q(WIDE_BIT) & data_reg;
		END IF;
	END PROCESS;

	PROCESS(state_reg, sel_ram)
	BEGIN
		we_ram <= (others => '0');
		IF state_reg /= state_idle THEN
			we_ram(sel_ram) <= '1';
		END IF;
	END PROCESS;

	m9k_loop: FOR i IN 0 TO TOTAL_RAM_BLOCKS-1 GENERATE
		sample_ram_inst : ENTITY work.generic_ram_infer
		GENERIC MAP
		(
			ADDRESS_WIDTH => RAM_ADDR_BITS,
			SPACE         => 1024,
			DATA_WIDTH    => 9
		)
		PORT MAP
		(
			clock   => clock,
			reset_n => reset_n,
			data    => write_word,
			address => address_ram,
			we      => we_ram(i),
			q       => q_ram_wide(i)
		);
	END GENERATE m9k_loop;

	-- Read data: the page's RAM (bits 7..0), or a group's bit 8 for a wide page.
	-- (In the write cycles the output is not used: BUSY.)
	PROCESS(rd, sel_q, q_ram_wide)
	BEGIN
		q <= (others => '0');
		IF rd.normal = '1' THEN
			q <= sel_q(BYTE_BITS-1 DOWNTO 0);
		ELSIF rd.wide = '1' AND rd.grp < NUM_GROUPS THEN
			FOR bt IN 0 TO BYTE_BITS-1 LOOP
				q(bt) <= q_ram_wide((rd.grp * BYTE_BITS) + bt)(WIDE_BIT);
			END LOOP;
		END IF;
	END PROCESS;

END rtl;
