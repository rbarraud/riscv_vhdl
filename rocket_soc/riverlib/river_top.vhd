-----------------------------------------------------------------------------
--! @file
--! @copyright Copyright 2016 GNSS Sensor Ltd. All right reserved.
--! @author    Sergey Khabarov - sergeykhbr@gmail.com
--! @brief     "River" CPU Top level.
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
library commonlib;
use commonlib.types_common.all;
--! RIVER CPU specific library.
library riverlib;
--! RIVER CPU configuration constants.
use riverlib.river_cfg.all;

entity RiverTop is
  port (
    i_clk : in std_logic;                                             -- CPU clock
    i_nrst : in std_logic;                                            -- Reset. Active LOW.
    -- Memory interface:
    i_req_mem_ready : in std_logic;                                   -- AXI request was accepted
    o_req_mem_valid : out std_logic;                                  -- AXI memory request is valid
    o_req_mem_write : out std_logic;                                  -- AXI memory request is write type
    o_req_mem_addr : out std_logic_vector(BUS_ADDR_WIDTH-1 downto 0); -- AXI memory request address
    o_req_mem_strob : out std_logic_vector(BUS_DATA_BYTES-1 downto 0);-- Writing strob. 1 bit per Byte
    o_req_mem_data : out std_logic_vector(BUS_DATA_WIDTH-1 downto 0); -- Writing data
    i_resp_mem_data_valid : in std_logic;                             -- AXI response is valid
    i_resp_mem_data : in std_logic_vector(BUS_DATA_WIDTH-1 downto 0); -- Read data
    -- Interrupt line from external interrupts controller (PLIC).
    i_ext_irq : in std_logic;
    -- Debug interface:
    o_timer : out std_logic_vector(RISCV_ARCH-1 downto 0);            -- Timer.
    o_step_cnt : out std_logic_vector(63 downto 0)                 -- Number of valid executed instructions
  );
end;
 
architecture arch_RiverTop of RiverTop is

  type RegistersType is record
      timer : std_logic_vector(RISCV_ARCH-1 downto 0);
  end record;

  signal r, rin : RegistersType;
  -- Control path:
  signal w_req_ctrl_ready : std_logic;
  signal w_req_ctrl_valid : std_logic;
  signal wb_req_ctrl_addr : std_logic_vector(BUS_ADDR_WIDTH-1 downto 0);
  signal w_resp_ctrl_valid : std_logic;
  signal wb_resp_ctrl_addr : std_logic_vector(BUS_ADDR_WIDTH-1 downto 0);
  signal wb_resp_ctrl_data : std_logic_vector(31 downto 0);
  signal w_resp_ctrl_ready : std_logic;
  -- Data path:
  signal w_req_data_ready : std_logic;
  signal w_req_data_valid : std_logic;
  signal w_req_data_write : std_logic;
  signal wb_req_data_addr : std_logic_vector(BUS_ADDR_WIDTH-1 downto 0);
  signal wb_req_data_size : std_logic_vector(1 downto 0);
  signal wb_req_data_data : std_logic_vector(RISCV_ARCH-1 downto 0);
  signal w_resp_data_valid : std_logic;
  signal wb_resp_data_addr : std_logic_vector(BUS_ADDR_WIDTH-1 downto 0);
  signal wb_resp_data_data : std_logic_vector(RISCV_ARCH-1 downto 0);
  signal w_resp_data_ready : std_logic;

begin

    proc0 : Processor port map (
        i_clk => i_clk,
        i_nrst => i_nrst,
        i_req_ctrl_ready => w_req_ctrl_ready,
        o_req_ctrl_valid => w_req_ctrl_valid,
        o_req_ctrl_addr => wb_req_ctrl_addr,
        i_resp_ctrl_valid => w_resp_ctrl_valid,
        i_resp_ctrl_addr => wb_resp_ctrl_addr,
        i_resp_ctrl_data => wb_resp_ctrl_data,
        o_resp_ctrl_ready => w_resp_ctrl_ready,
        i_req_data_ready => w_req_data_ready,
        o_req_data_valid => w_req_data_valid,
        o_req_data_write => w_req_data_write,
        o_req_data_addr => wb_req_data_addr,
        o_req_data_size => wb_req_data_size,
        o_req_data_data => wb_req_data_data,
        i_resp_data_valid => w_resp_data_valid,
        i_resp_data_addr => wb_resp_data_addr,
        i_resp_data_data => wb_resp_data_data,
        o_resp_data_ready => w_resp_data_ready,
        i_ext_irq => i_ext_irq,
        o_step_cnt => o_step_cnt);

    cache0 :  CacheTop port map (
        i_clk => i_clk,
        i_nrst => i_nrst,
        i_req_ctrl_valid => w_req_ctrl_valid,
        i_req_ctrl_addr => wb_req_ctrl_addr,
        o_req_ctrl_ready => w_req_ctrl_ready,
        o_resp_ctrl_valid => w_resp_ctrl_valid,
        o_resp_ctrl_addr => wb_resp_ctrl_addr,
        o_resp_ctrl_data => wb_resp_ctrl_data,
        i_resp_ctrl_ready => w_resp_ctrl_ready,
        i_req_data_valid => w_req_data_valid,
        i_req_data_write => w_req_data_write,
        i_req_data_addr => wb_req_data_addr,
        i_req_data_size => wb_req_data_size,
        i_req_data_data => wb_req_data_data,
        o_req_data_ready => w_req_data_ready,
        o_resp_data_valid => w_resp_data_valid,
        o_resp_data_addr => wb_resp_data_addr,
        o_resp_data_data => wb_resp_data_data,
        i_resp_data_ready => w_resp_data_ready,
        i_req_mem_ready => i_req_mem_ready,
        o_req_mem_valid => o_req_mem_valid,
        o_req_mem_write => o_req_mem_write,
        o_req_mem_addr => o_req_mem_addr,
        o_req_mem_strob => o_req_mem_strob,
        o_req_mem_data => o_req_mem_data,
        i_resp_mem_data_valid => i_resp_mem_data_valid,
        i_resp_mem_data => i_resp_mem_data);

  comb : process(i_nrst, r)
    variable v : RegistersType;
  begin

    v.timer := r.timer + 1;
    if i_nrst = '0' then
        v.timer := (others => '0');
    end if;

    rin <= v;
  end process;

  o_timer <= r.timer;

  -- registers:
  regs : process(i_clk)
  begin 
     if rising_edge(i_clk) then 
        r <= rin;
     end if; 
  end process;

end;
