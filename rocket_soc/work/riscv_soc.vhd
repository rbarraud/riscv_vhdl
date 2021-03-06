-----------------------------------------------------------------------------
--! @file
--! @copyright  Copyright 2015 GNSS Sensor Ltd. All right reserved.
--! @author     Sergey Khabarov
--! @brief      Network on Chip design top level.
--! @details    RISC-V "Rocket"/"River" based system with the AMBA AXI4 (NASTI) 
--!             system bus and integrated peripheries.
------------------------------------------------------------------------------
--! Standard library
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

--! Data transformation and math functions library
library commonlib;
use commonlib.types_common.all;

--! Technology definition library.
library techmap;
--! Technology constants definition.
use techmap.gencomp.all;
--! "Virtual" PLL declaration.
use techmap.types_pll.all;
--! "Virtual" buffers declaration.
use techmap.types_buf.all;

--! AMBA system bus specific library
library ambalib;
--! AXI4 configuration constants.
use ambalib.types_amba4.all;

--! Rocket-chip specific library
library rocketlib;
--! SOC top-level component declaration.
use rocketlib.types_rocket.all;
--! Ethernet related declarations.
use rocketlib.grethpkg.all;

--! River CPU specific library
library riverlib;
--! River top level with AMBA interface module declaration
use riverlib.types_river.all;

 --! Top-level implementaion library
library work;
--! Target dependable configuration: RTL, FPGA or ASIC.
use work.config_target.all;
--! Target independable configuration.
use work.config_common.all;

--! @brief   SOC Top-level entity declaration.
--! @details This module implements full SOC functionality and all IO signals
--!          are available on FPGA/ASIC IO pins.
entity riscv_soc is port 
( 
  --! Input reset. Active High. Usually assigned to button "Center".
  i_rst     : in std_logic;

  --! Differential clock (LVDS) positive signal.
  i_sclk_p  : in std_logic;
  --! Differential clock (LVDS) negative signal.
  i_sclk_n  : in std_logic;
  --! DIP switch.
  i_dip     : in std_logic_vector(3 downto 0);
  --! LEDs.
  o_led     : out std_logic_vector(7 downto 0);
  --! UART1 signals:
  i_uart1_ctsn : in std_logic;
  i_uart1_rd   : in std_logic;
  o_uart1_td   : out std_logic;
  o_uart1_rtsn : out std_logic;
  --! Ethernet MAC PHY interface signals
  i_gmiiclk_p : in    std_ulogic;
  i_gmiiclk_n : in    std_ulogic;
  o_egtx_clk  : out   std_ulogic;
  i_etx_clk   : in    std_ulogic;
  i_erx_clk   : in    std_ulogic;
  i_erxd      : in    std_logic_vector(3 downto 0);
  i_erx_dv    : in    std_ulogic;
  i_erx_er    : in    std_ulogic;
  i_erx_col   : in    std_ulogic;
  i_erx_crs   : in    std_ulogic;
  i_emdint    : in std_ulogic;
  o_etxd      : out   std_logic_vector(3 downto 0);
  o_etx_en    : out   std_ulogic;
  o_etx_er    : out   std_ulogic;
  o_emdc      : out   std_ulogic;
  io_emdio    : inout std_logic;
  o_erstn     : out   std_ulogic
);
  --! @}

end riscv_soc;

--! @brief SOC top-level  architecture declaration.
architecture arch_riscv_soc of riscv_soc is

  --! @name Buffered in/out signals.
  --! @details All signals that are connected with in/out pads must be passed
  --!          through the dedicated buffere modules. For FPGA they are implemented
  --!          as an empty devices but ASIC couldn't be made without buffering.
  --! @{
  signal ib_rst     : std_logic;
  signal ib_clk_tcxo : std_logic;
  signal ib_sclk_n  : std_logic;
  signal ib_dip     : std_logic_vector(3 downto 0);
  signal ib_gmiiclk : std_logic;
  --! @}

  signal w_ext_reset : std_ulogic; -- External system reset or PLL unlcoked. MUST NOT USED BY DEVICES.
  signal w_glob_rst  : std_ulogic; -- Global reset active HIGH
  signal w_glob_nrst : std_ulogic; -- Global reset active LOW
  signal w_soft_rst : std_ulogic; -- Software reset (acitve HIGH) from DSU
  signal w_bus_nrst : std_ulogic; -- Global reset and Soft Reset active LOW
  signal w_clk_bus  : std_ulogic; -- bus clock from the internal PLL (100MHz virtex6/40MHz Spartan6)
  signal w_pll_lock : std_ulogic; -- PLL status signal. 0=Unlocked; 1=locked.
  
  signal uart1i : uart_in_type;
  signal uart1o : uart_out_type;

  --! Arbiter is switching only slaves output signal, data from noc
  --! is connected to all slaves and to the arbiter itself.
  signal aximi   : nasti_master_in_vector;
  signal aximo   : nasti_master_out_vector;
  signal axisi   : nasti_slave_in_vector;
  signal axiso   : nasti_slaves_out_vector;
  signal slv_cfg : nasti_slave_cfg_vector;
  signal mst_cfg : nasti_master_cfg_vector;
  signal core_irqs : std_logic_vector(CFG_CORE_IRQ_TOTAL-1 downto 0);
  signal dport_i : dport_in_type;
  signal dport_o : dport_out_type;
  signal wb_miss_addr : std_logic_vector(CFG_NASTI_ADDR_BITS-1 downto 0);
  signal wb_bus_util_w : std_logic_vector(CFG_NASTI_MASTER_TOTAL-1 downto 0);
  signal wb_bus_util_r : std_logic_vector(CFG_NASTI_MASTER_TOTAL-1 downto 0);
  
  signal eth_i : eth_in_type;
  signal eth_o : eth_out_type;
 
  signal irq_pins : std_logic_vector(CFG_IRQ_TOTAL-1 downto 1);
begin

  --! PAD buffers:
  irst0   : ibuf_tech generic map(CFG_PADTECH) port map (ib_rst, i_rst);
  dipx : for i in 0 to 3 generate
     idipz  : ibuf_tech generic map(CFG_PADTECH) port map (ib_dip(i), i_dip(i));
  end generate;

  iclk0 : idsbuf_tech generic map (CFG_PADTECH) port map (
         i_sclk_p, i_sclk_n, ib_clk_tcxo);

  igbebuf0 : igdsbuf_tech generic map (CFG_PADTECH) port map (
            i_gmiiclk_p, i_gmiiclk_n, ib_gmiiclk);


  --! @todo all other in/out signals via buffers:

  -- Nullify emty AXI-slots:  
  axiso(CFG_NASTI_SLAVE_ENGINE) <= nasti_slave_out_none;
  slv_cfg(CFG_NASTI_SLAVE_ENGINE)  <= nasti_slave_config_none;
  irq_pins(CFG_IRQ_GNSSENGINE)      <= '0';
  slv_cfg(CFG_NASTI_SLAVE_RFCTRL) <= nasti_slave_config_none;
  axiso(CFG_NASTI_SLAVE_RFCTRL) <= nasti_slave_out_none;
  slv_cfg(CFG_NASTI_SLAVE_FSE_GPS) <= nasti_slave_config_none;
  axiso(CFG_NASTI_SLAVE_FSE_GPS) <= nasti_slave_out_none;


  ------------------------------------
  -- @brief Internal PLL device instance.
  pll0 : SysPLL_tech generic map (
    tech => CFG_FABTECH
  ) port map (
    i_reset     => ib_rst,
    i_clk_tcxo	=> ib_clk_tcxo,
    o_clk_bus   => w_clk_bus,
    o_locked    => w_pll_lock
  );
  w_ext_reset <= ib_rst or not w_pll_lock;

  ------------------------------------
  --! @brief System Reset device instance.
  rst0 : reset_global port map (
    inSysReset  => w_ext_reset,
    inSysClk    => w_clk_bus,
    inPllLock   => w_pll_lock,
    outReset    => w_glob_rst
  );
  w_glob_nrst <= not w_glob_rst;
  w_bus_nrst <= not (w_glob_rst or w_soft_rst);

  --! @brief AXI4 controller.
  ctrl0 : axictrl generic map (
    watchdog_memop => 0
  ) port map (
    i_clk    => w_clk_bus,
    i_nrst   => w_glob_nrst,
    i_slvcfg => slv_cfg,
    i_slvo   => axiso,
    i_msto   => aximo,
    o_slvi   => axisi,
    o_msti   => aximi,
    o_miss_irq  => irq_pins(CFG_IRQ_MISS_ACCESS),
    o_miss_addr => wb_miss_addr,
    o_bus_util_w => wb_bus_util_w, -- Bus write access utilization per master statistic
    o_bus_util_r => wb_bus_util_r  -- Bus read access utilization per master statistic
  );

  --! @brief RISC-V Processor core (River or Rocket).
river_ena : if CFG_COMMON_RIVER_CPU_ENABLE generate
  cpu0 : river_amba port map ( 
    i_nrst   => w_bus_nrst,
    i_clk    => w_clk_bus,
    i_msti   => aximi(CFG_NASTI_MASTER_CACHED),
    o_msto   => aximo(CFG_NASTI_MASTER_CACHED),
    o_mstcfg => mst_cfg(CFG_NASTI_MASTER_CACHED),
    i_dport => dport_i,
    o_dport => dport_o,
    i_ext_irq => core_irqs(CFG_CORE_IRQ_MEIP)
  );
  aximo(CFG_NASTI_MASTER_UNCACHED) <= nasti_master_out_none;
  mst_cfg(CFG_NASTI_MASTER_UNCACHED) <= nasti_master_config_none;
end generate;

--! DSU doesn't support Rocket-chip CPU
river_dis : if not CFG_COMMON_RIVER_CPU_ENABLE generate
  --! Not imlpemented interrupts:
  core_irqs(CFG_CORE_IRQ_MTIP) <= '0'; -- timer's
  core_irqs(CFG_CORE_IRQ_MSIP) <= '0'; -- software's
  core_irqs(CFG_CORE_IRQ_SEIP) <= '0'; -- superuser external interrupt
  core_irqs(CFG_CORE_IRQ_DEBUG) <= '0';

  cpu0 : rocket_l1only generic map (
    hartid  => 0,
    reset_vector => 16#1000#
  ) port map ( 
    nrst      => w_bus_nrst,
    clk_sys   => w_clk_bus,
    msti1     => aximi(CFG_NASTI_MASTER_CACHED),
    msto1     => aximo(CFG_NASTI_MASTER_CACHED),
    mstcfg1   => mst_cfg(CFG_NASTI_MASTER_CACHED),
    msti2     => aximi(CFG_NASTI_MASTER_UNCACHED),
    msto2     => aximo(CFG_NASTI_MASTER_UNCACHED),
    mstcfg2   => mst_cfg(CFG_NASTI_MASTER_UNCACHED),
    interrupts => core_irqs
  );
end generate;

dsu_ena : if CFG_DSU_ENABLE generate
  ------------------------------------
  --! @brief Debug Support Unit with access to the CSRs
  --! @details Map address:
  --!          0x80080000..0x8009ffff (128 KB total)
  dsu0 : axi_dsu generic map (
    xaddr    => 16#80080#,
    xmask    => 16#fffe0#
  ) port map (
    clk    => w_clk_bus,
    nrst   => w_glob_nrst,
    o_cfg  => slv_cfg(CFG_NASTI_SLAVE_DSU),
    i_axi  => axisi(CFG_NASTI_SLAVE_DSU),
    o_axi  => axiso(CFG_NASTI_SLAVE_DSU),
    o_dporti => dport_i,
    i_dporto => dport_o,
    o_soft_rst => w_soft_rst,
    -- Run time platform statistic signals:
    i_miss_irq  => irq_pins(CFG_IRQ_MISS_ACCESS),
    i_miss_addr => wb_miss_addr,
    i_bus_util_w => wb_bus_util_w, -- Write access bus utilization per master statistic
    i_bus_util_r => wb_bus_util_r  -- Read access bus utilization per master statistic
  );
end generate;
dsu_dis : if not CFG_DSU_ENABLE generate
    slv_cfg(CFG_NASTI_SLAVE_DSU) <= nasti_slave_config_none;
    axiso(CFG_NASTI_SLAVE_DSU) <= nasti_slave_out_none;
    dport_i <= dport_in_none;
end generate;

  ------------------------------------
  --! @brief BOOT ROM module isntance with the AXI4 interface.
  --! @details Map address:
  --!          0x00000000..0x00001fff (8 KB total)
  boot0 : nasti_bootrom generic map (
    memtech  => CFG_MEMTECH,
    xaddr    => 16#00000#,
    xmask    => 16#ffffe#,
    sim_hexfile => CFG_SIM_BOOTROM_HEX
  ) port map (
    clk  => w_clk_bus,
    nrst => w_glob_nrst,
    cfg  => slv_cfg(CFG_NASTI_SLAVE_BOOTROM),
    i    => axisi(CFG_NASTI_SLAVE_BOOTROM),
    o    => axiso(CFG_NASTI_SLAVE_BOOTROM)
  );

  ------------------------------------
  --! @brief Firmware Image ROM with the AXI4 interface.
  --! @details Map address:
  --!          0x00100000..0x0013ffff (256 KB total)
  --! @warning Don't forget to change ROM_ADDR_WIDTH in rom implementation
  img0 : nasti_romimage generic map (
    memtech  => CFG_MEMTECH,
    xaddr    => 16#00100#,
    xmask    => 16#fffc0#,
    sim_hexfile => CFG_SIM_FWIMAGE_HEX
  ) port map (
    clk  => w_clk_bus,
    nrst => w_glob_nrst,
    cfg  => slv_cfg(CFG_NASTI_SLAVE_ROMIMAGE),
    i    => axisi(CFG_NASTI_SLAVE_ROMIMAGE),
    o    => axiso(CFG_NASTI_SLAVE_ROMIMAGE)
  );

  ------------------------------------
  --! Internal SRAM module instance with the AXI4 interface.
  --! @details Map address:
  --!          0x10000000..0x1007ffff (512 KB total)
  sram0 : nasti_sram generic map (
    memtech  => CFG_MEMTECH,
    xaddr    => 16#10000#,
    xmask    => 16#fff80#,            -- 512 KB mask
    abits    => (10 + log2(512)),     -- 512 KB address
    init_file => CFG_SIM_FWIMAGE_HEX  -- Used only for inferred
  ) port map (
    clk  => w_clk_bus,
    nrst => w_glob_nrst,
    cfg  => slv_cfg(CFG_NASTI_SLAVE_SRAM),
    i    => axisi(CFG_NASTI_SLAVE_SRAM),
    o    => axiso(CFG_NASTI_SLAVE_SRAM)
  );


  ------------------------------------
  --! @brief Controller of the LEDs, DIPs and GPIO with the AXI4 interface.
  --! @details Map address:
  --!          0x80000000..0x80000fff (4 KB total)
  gpio0 : nasti_gpio generic map (
    xaddr    => 16#80000#,
    xmask    => 16#fffff#,
    xirq     => 0
  ) port map (
    clk   => w_clk_bus,
    nrst  => w_glob_nrst,
    cfg   => slv_cfg(CFG_NASTI_SLAVE_GPIO),
    i     => axisi(CFG_NASTI_SLAVE_GPIO),
    o     => axiso(CFG_NASTI_SLAVE_GPIO),
    i_dip => ib_dip,
    o_led => o_led
  );
  
  
  ------------------------------------
  uart1i.cts   <= not i_uart1_ctsn;
  uart1i.rd    <= i_uart1_rd;

  --! @brief UART Controller with the AXI4 interface.
  --! @details Map address:
  --!          0x80001000..0x80001fff (4 KB total)
  uart1 : nasti_uart generic map (
    xaddr    => 16#80001#,
    xmask    => 16#FFFFF#,
	 xirq     => CFG_IRQ_UART1,
    fifosz   => 16
  ) port map (
    nrst   => w_glob_nrst, 
    clk    => w_clk_bus, 
    cfg    => slv_cfg(CFG_NASTI_SLAVE_UART1),
    i_uart => uart1i, 
    o_uart => uart1o,
    i_axi  => axisi(CFG_NASTI_SLAVE_UART1),
    o_axi  => axiso(CFG_NASTI_SLAVE_UART1),
    o_irq  => irq_pins(CFG_IRQ_UART1)
  );
  o_uart1_td  <= uart1o.td;
  o_uart1_rtsn <= not uart1o.rts;


  ------------------------------------
  --! @brief Interrupt controller with the AXI4 interface.
  --! @details Map address:
  --!          0x80002000..0x80002fff (4 KB total)
  irq0 : nasti_irqctrl generic map (
    xaddr      => 16#80002#,
    xmask      => 16#FFFFF#
  ) port map (
    clk    => w_clk_bus,
    nrst   => w_bus_nrst,
    i_irqs => irq_pins,
    o_cfg  => slv_cfg(CFG_NASTI_SLAVE_IRQCTRL),
    i_axi  => axisi(CFG_NASTI_SLAVE_IRQCTRL),
    o_axi  => axiso(CFG_NASTI_SLAVE_IRQCTRL),
    o_irq_meip => core_irqs(CFG_CORE_IRQ_MEIP)
  );

  --! @brief Timers with the AXI4 interface.
  --! @details Map address:
  --!          0x80005000..0x80005fff (4 KB total)
  gptmr0 : nasti_gptimers  generic map (
    xaddr     => 16#80005#,
    xmask     => 16#fffff#,
	 xirq      => CFG_IRQ_GPTIMERS,
    tmr_total => 2
  ) port map (
    clk    => w_clk_bus,
    nrst   => w_glob_nrst,
    cfg    => slv_cfg(CFG_NASTI_SLAVE_GPTIMERS),
    i_axi  => axisi(CFG_NASTI_SLAVE_GPTIMERS),
    o_axi  => axiso(CFG_NASTI_SLAVE_GPTIMERS),
    o_irq  => irq_pins(CFG_IRQ_GPTIMERS)
  );

  --! Gigabit clock phase rotator with buffers
  clkrot90 : clkp90_tech  generic map (
    tech    => CFG_FABTECH,
    freq    => 125000   -- KHz = 125 MHz
  ) port map (
    i_rst    => w_glob_rst,
    i_clk    => ib_gmiiclk,
    o_clk    => eth_i.gtx_clk,
    o_clkp90 => eth_i.tx_clk_90,
    o_clk2x  => open, -- used in gbe 'io_ref'
    o_lock   => open
  );


  --! @brief Ethernet MAC with the AXI4 interface.
  --! @details Map address:
  --!          0x80040000..0x8007ffff (256 KB total)
  --!          EDCL IP: 192.168.1.51 = C0.A8.01.33
  eth0_ena : if CFG_ETHERNET_ENABLE generate 
    eth_i.tx_clk <= i_etx_clk;
    eth_i.rx_clk <= i_erx_clk;
    eth_i.rxd <= i_erxd;
    eth_i.rx_dv <= i_erx_dv;
    eth_i.rx_er <= i_erx_er;
    eth_i.rx_col <= i_erx_col;
    eth_i.rx_crs <= i_erx_crs;
    eth_i.mdint <= i_emdint;
    
    mac0 : grethaxi generic map (
      xaddr => 16#80040#,
      xmask => 16#FFFC0#,
      xirq => CFG_IRQ_ETHMAC,
      memtech => CFG_MEMTECH,
      mdcscaler => 60,  --! System Bus clock in MHz
      enable_mdio => 1,
      fifosize => 16,
      nsync => 1,
      edcl => 1,
      edclbufsz => 16,
      macaddrh => 16#20789#,
      macaddrl => 16#123#,
      ipaddrh => 16#C0A8#,
      ipaddrl => 16#0033#,
      phyrstadr => 7,
      enable_mdint => 1,
      maxsize => 1518
   ) port map (
      rst => w_glob_nrst,
      clk => w_clk_bus,
      msti => aximi(CFG_NASTI_MASTER_ETHMAC),
      msto => aximo(CFG_NASTI_MASTER_ETHMAC),
      mstcfg => mst_cfg(CFG_NASTI_MASTER_ETHMAC),
      msto2 => open,    -- EDCL separate access is disabled
      mstcfg2 => open,  -- EDCL separate access is disabled
      slvi => axisi(CFG_NASTI_SLAVE_ETHMAC),
      slvo => axiso(CFG_NASTI_SLAVE_ETHMAC),
      slvcfg => slv_cfg(CFG_NASTI_SLAVE_ETHMAC),
      ethi => eth_i,
      etho => eth_o,
      irq => irq_pins(CFG_IRQ_ETHMAC)
    );
  
  end generate;
  --! Ethernet disabled
  eth0_dis : if not CFG_ETHERNET_ENABLE generate 
      slv_cfg(CFG_NASTI_SLAVE_ETHMAC) <= nasti_slave_config_none;
      axiso(CFG_NASTI_SLAVE_ETHMAC) <= nasti_slave_out_none;
      mst_cfg(CFG_NASTI_MASTER_ETHMAC) <= nasti_master_config_none;
      aximo(CFG_NASTI_MASTER_ETHMAC) <= nasti_master_out_none;
      irq_pins(CFG_IRQ_ETHMAC) <= '0';
      eth_o   <= eth_out_none;
  end generate;

 
  emdio_pad : iobuf_tech generic map(
      CFG_PADTECH
  ) port map (
      o  => eth_i.mdio_i,
      io => io_emdio,
      i  => eth_o.mdio_o,
      t  => eth_o.mdio_oe
  );
  o_egtx_clk <= eth_i.gtx_clk;--eth_i.tx_clk_90;
  o_etxd <= eth_o.txd;
  o_etx_en <= eth_o.tx_en;
  o_etx_er <= eth_o.tx_er;
  o_emdc <= eth_o.mdc;
  o_erstn <= w_glob_nrst;


  --! @brief Plug'n'Play controller of the current configuration with the
  --!        AXI4 interface.
  --! @details Map address:
  --!          0xfffff000..0xffffffff (4 KB total)
  pnp0 : nasti_pnp generic map (
    xaddr   => 16#fffff#,
    xmask   => 16#fffff#,
    tech    => CFG_MEMTECH,
    hw_id   => CFG_HW_ID
  ) port map (
    sys_clk => w_clk_bus, 
    adc_clk => '0',
    nrst   => w_glob_nrst,
    mstcfg => mst_cfg,
    slvcfg => slv_cfg,
    cfg    => slv_cfg(CFG_NASTI_SLAVE_PNP),
    i      => axisi(CFG_NASTI_SLAVE_PNP),
    o      => axiso(CFG_NASTI_SLAVE_PNP)
  );


end arch_riscv_soc;
