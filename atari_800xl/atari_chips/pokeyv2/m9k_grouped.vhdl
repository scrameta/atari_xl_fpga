---------------------------------------------------------------------------
-- (c) 2026 mark watson
-- I am happy for anyone to use this for non-commercial use.
-- If my vhdl files are used commercially or otherwise sold,
-- please contact me for explicit permission at scrameta (gmail).
-- This applies for source and binary form and derived works.
--
-- v2: indexed bank/group selection, avoiding large selected-OR reductions.
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
		q       : OUT std_logic_vector(7 DOWNTO 0)
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
	SIGNAL write_data_ram_wide : ram_data_t;
	SIGNAL sel_ram             : std_logic_vector(0 TO TOTAL_RAM_BLOCKS-1);
	SIGNAL wide_ram            : std_logic;
	SIGNAL we_ram              : std_logic;

	SIGNAL address_ram         : std_logic_vector(RAM_ADDR_BITS-1 DOWNTO 0);
	SIGNAL address_used        : std_logic_vector(ADDR_BITS-1 DOWNTO 0);

	SIGNAL state_next          : std_logic_vector(0 DOWNTO 0);
	SIGNAL state_reg           : std_logic_vector(0 DOWNTO 0);
	constant state_idle        : std_logic_vector(0 DOWNTO 0) := "0";
	constant state_write       : std_logic_vector(0 DOWNTO 0) := "1";

	SIGNAL data_next           : std_logic_vector(7 DOWNTO 0);
	SIGNAL data_reg            : std_logic_vector(7 DOWNTO 0);

	SIGNAL address_next        : std_logic_vector(ADDR_BITS-1 DOWNTO 0);
	SIGNAL address_reg         : std_logic_vector(ADDR_BITS-1 DOWNTO 0);
BEGIN

	-- During idle/read, the RAMs see the live bus address.
	-- During the write cycle, they see the latched write address.
	address_used <= address_reg WHEN state_reg = state_write ELSE address;
	address_ram  <= address_used(RAM_ADDR_BITS-1 DOWNTO 0);

	PROCESS(clock, reset_n)
	BEGIN
		IF reset_n = '0' THEN
			state_reg   <= state_idle;
			data_reg    <= (others => '0');
			address_reg <= (others => '0');
		ELSIF rising_edge(clock) THEN
			state_reg   <= state_next;
			data_reg    <= data_next;
			address_reg <= address_next;
		END IF;
	END PROCESS;

	-- Latch write address/data for one-cycle read-modify-write.
	PROCESS(state_reg, we, data, address, data_reg, address_reg)
	BEGIN
		state_next   <= state_reg;
		data_next    <= data_reg;
		address_next <= address_reg;
		we_ram       <= '0';

		CASE state_reg IS
			WHEN state_idle =>
				IF we = '1' THEN
					data_next    <= data;
					address_next <= address;
					state_next   <= state_write;
				END IF;

			WHEN state_write =>
				we_ram     <= '1';
				state_next <= state_idle;

			WHEN others =>
				state_next <= state_idle;
		END CASE;
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
			data    => write_data_ram_wide(i),
			address => address_ram,
			we      => sel_ram(i) AND we_ram,
			q       => q_ram_wide(i)
		);
	END GENERATE m9k_loop;

	-- Decode only the write-enable selection and the mode.
	-- Reads use direct indexed muxes rather than sel_ram-masked OR reductions.
	PROCESS(address_used)
		VARIABLE page       : natural RANGE 0 TO 2**PAGE_BITS-1;
		VARIABLE wide_group : natural RANGE 0 TO BYTE_BITS-1;
		VARIABLE extra      : natural RANGE 0 TO EXTRA_RAM_BLOCKS;
	BEGIN
		page       := to_integer(unsigned(address_used(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS)));
		wide_group := to_integer(unsigned(address_used(12 DOWNTO 10)));

		wide_ram <= '0';
		sel_ram  <= (others => '0');

		-- 64 KiB example:
		--   pages 0..55  : normal 8-bit access to RAM blocks 0..55
		--   pages 56..62 : wide access using bit 8 of RAM blocks 0..55
		--   page  63     : normal 8-bit access to RAM block 56
		IF page < NORMAL_RAM_BLOCKS THEN
			sel_ram(page) <= '1';

		ELSIF page < GROUP_RAM_PAGES THEN
			wide_ram <= '1';
			IF wide_group < NUM_GROUPS THEN
				FOR bt IN 0 TO BYTE_BITS-1 LOOP
					sel_ram((wide_group * BYTE_BITS) + bt) <= '1';
				END LOOP;
			END IF;

		ELSIF page < TOTAL_MAPPED_PAGES THEN
			extra := page - GROUP_RAM_PAGES;
			sel_ram(NORMAL_RAM_BLOCKS + extra) <= '1';
		END IF;
	END PROCESS;

	-- RAM write data.
	-- Only the selected RAMs are written, so unselected RAM data inputs are don't-care.
	-- The assignments below avoid copying every full RAM word back to its input.
	write_data_loop: FOR i IN 0 TO TOTAL_RAM_BLOCKS-1 GENERATE
		PROCESS(wide_ram, address_used, data_reg, q_ram_wide)
			VARIABLE wide_group : natural RANGE 0 TO BYTE_BITS-1;
		BEGIN
			wide_group := to_integer(unsigned(address_used(12 DOWNTO 10)));

			write_data_ram_wide(i) <= (others => '0');

			IF wide_ram = '0' THEN
				-- Normal byte write: replace bits 0..7, preserve the packed wide bit.
				write_data_ram_wide(i)(BYTE_BITS-1 DOWNTO 0) <= data_reg;
				write_data_ram_wide(i)(WIDE_BIT) <= q_ram_wide(i)(WIDE_BIT);
			ELSE
				-- Wide write: selected group of 8 RAMs stores one bit each in bit 8.
				-- Preserve the normal byte only for RAMs in the selected group.
				IF i < NORMAL_RAM_BLOCKS THEN
					IF wide_group = (i / BYTE_BITS) THEN
						write_data_ram_wide(i)(BYTE_BITS-1 DOWNTO 0) <= q_ram_wide(i)(BYTE_BITS-1 DOWNTO 0);
						write_data_ram_wide(i)(WIDE_BIT) <= data_reg(i MOD BYTE_BITS);
					END IF;
				END IF;
			END IF;
		END PROCESS;
	END GENERATE write_data_loop;

	-- Read mux. This replaces the previous 57-way selected OR-reduction fabric.
	PROCESS(address_used, q_ram_wide)
		VARIABLE page       : natural RANGE 0 TO 2**PAGE_BITS-1;
		VARIABLE wide_group : natural RANGE 0 TO BYTE_BITS-1;
		VARIABLE extra      : natural RANGE 0 TO EXTRA_RAM_BLOCKS;
	BEGIN
		page       := to_integer(unsigned(address_used(ADDR_BITS-1 DOWNTO RAM_ADDR_BITS)));
		wide_group := to_integer(unsigned(address_used(12 DOWNTO 10)));

		q <= (others => '0');

		IF page < NORMAL_RAM_BLOCKS THEN
			q <= q_ram_wide(page)(BYTE_BITS-1 DOWNTO 0);

		ELSIF page < GROUP_RAM_PAGES THEN
			IF wide_group < NUM_GROUPS THEN
				FOR bt IN 0 TO BYTE_BITS-1 LOOP
					q(bt) <= q_ram_wide((wide_group * BYTE_BITS) + bt)(WIDE_BIT);
				END LOOP;
			END IF;

		ELSIF page < TOTAL_MAPPED_PAGES THEN
			extra := page - GROUP_RAM_PAGES;
			q <= q_ram_wide(NORMAL_RAM_BLOCKS + extra)(BYTE_BITS-1 DOWNTO 0);
		END IF;
	END PROCESS;

END rtl;
