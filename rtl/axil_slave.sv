//-----------------------------------------------------------------------------
// Module      : axil_slave
// Description : AXI4-Lite slave with a small control/status register file.
//
//   Register map (32-bit registers, word aligned)
//   ----------------------------------------------------------------------
//   Offset  Name        Access  Reset        Description
//   0x00    CTRL        RW      0x0000_0000  Control bits, driven on ctrl_o
//   0x04    STATUS      RO      -            Live value of status_i
//   0x08    SCRATCH     RW      0x0000_0000  Software scratch register
//   0x0C    IRQ_STATUS  RW1C    0x0000_0000  Set by irq_set_i, write 1 to clear
//   0x10    IRQ_ENABLE  RW      0x0000_0000  Interrupt mask
//   0x14    ID          RO      ID_VALUE     Fixed identification value
//   other   -           -       -            SLVERR response, read data 0
//
//   Protocol behaviour
//   - AW and W channels are independent: address and data may arrive in
//     either order or in the same cycle. Each is captured in its own
//     holding register; the write happens when both are present.
//   - The write response is issued only after both AW and W handshakes.
//   - BVALID / RVALID never wait for BREADY / RREADY, and stay asserted with
//     stable BRESP / RDATA / RRESP until the master accepts them.
//   - WSTRB byte enables are honoured on every writable register.
//   - Writes to read-only registers are ignored and answered with OKAY.
//   - Reads have no side effects.
//   - Synchronous active-low reset (AXI ARESETn convention).
//
//   status_i and irq_set_i must be synchronous to s_axi_aclk.
//-----------------------------------------------------------------------------
module axil_slave #(
  parameter int          ADDR_WIDTH = 8,               // byte address width, >= 5
  parameter logic [31:0] ID_VALUE   = 32'h4158_4C01    // "AXL" + version 01
) (
  input  logic                  s_axi_aclk,
  input  logic                  s_axi_aresetn,

  // Write address channel
  input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic [2:0]            s_axi_awprot,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,

  // Write data channel
  input  logic [31:0]           s_axi_wdata,
  input  logic [3:0]            s_axi_wstrb,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,

  // Write response channel
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,

  // Read address channel
  input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic [2:0]            s_axi_arprot,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,

  // Read data channel
  output logic [31:0]           s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready,

  // User / hardware side
  output logic [31:0]           ctrl_o,       // CTRL register contents
  input  logic [31:0]           status_i,     // read through STATUS
  input  logic [31:0]           irq_set_i,    // 1-cycle pulses set IRQ_STATUS bits
  output logic                  irq_o         // |(IRQ_STATUS & IRQ_ENABLE)
);

  localparam int IDX_W    = ADDR_WIDTH - 2;    // word index width
  localparam int NUM_REGS = 6;

  localparam int REG_CTRL       = 0;
  localparam int REG_STATUS     = 1;
  localparam int REG_SCRATCH    = 2;
  localparam int REG_IRQ_STATUS = 3;
  localparam int REG_IRQ_ENABLE = 4;
  localparam int REG_ID         = 5;

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // synthesis translate_off
  initial begin
    if (ADDR_WIDTH < 5)
      $fatal(1, "axil_slave: ADDR_WIDTH (%0d) must be >= 5", ADDR_WIDTH);
  end
  // synthesis translate_on

  //===========================================================================
  // Write path
  //===========================================================================
  logic                  aw_hold, w_hold;    // address / data captured
  logic [ADDR_WIDTH-1:0] awaddr_q;
  logic [31:0]           wdata_q;
  logic [3:0]            wstrb_q;
  logic                  do_write;           // perform the register write
  logic [IDX_W-1:0]      wr_idx;
  logic                  wr_ok;
  logic [31:0]           wr_mask;            // WSTRB expanded to a bit mask

  // Each channel is ready whenever its holding register is free
  assign s_axi_awready = ~aw_hold;
  assign s_axi_wready  = ~w_hold;

  // Write once both halves are present and the B channel can take a response
  assign do_write = aw_hold & w_hold & (~s_axi_bvalid | s_axi_bready);

  assign wr_idx  = awaddr_q[ADDR_WIDTH-1:2];
  assign wr_ok   = (wr_idx < NUM_REGS);
  assign wr_mask = {{8{wstrb_q[3]}}, {8{wstrb_q[2]}}, {8{wstrb_q[1]}}, {8{wstrb_q[0]}}};

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_hold  <= 1'b0;
      w_hold   <= 1'b0;
      awaddr_q <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_hold  <= 1'b1;
        awaddr_q <= s_axi_awaddr;
      end else if (do_write) begin
        aw_hold  <= 1'b0;
      end

      if (s_axi_wvalid && s_axi_wready) begin
        w_hold  <= 1'b1;
        wdata_q <= s_axi_wdata;
        wstrb_q <= s_axi_wstrb;
      end else if (do_write) begin
        w_hold  <= 1'b0;
      end
    end
  end

  //===========================================================================
  // Register file
  //===========================================================================
  logic [31:0] reg_ctrl, reg_scratch, reg_irq_status, reg_irq_en;
  logic [31:0] irq_clear;

  // Write-1-to-clear, only on bytes enabled by WSTRB
  assign irq_clear = (do_write && wr_idx == REG_IRQ_STATUS) ? (wdata_q & wr_mask) : '0;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      reg_ctrl       <= '0;
      reg_scratch    <= '0;
      reg_irq_status <= '0;
      reg_irq_en     <= '0;
    end else begin
      if (do_write) begin
        case (wr_idx)
          REG_CTRL:       reg_ctrl    <= (reg_ctrl    & ~wr_mask) | (wdata_q & wr_mask);
          REG_SCRATCH:    reg_scratch <= (reg_scratch & ~wr_mask) | (wdata_q & wr_mask);
          REG_IRQ_ENABLE: reg_irq_en  <= (reg_irq_en  & ~wr_mask) | (wdata_q & wr_mask);
          default: ;      // STATUS, ID are read-only; IRQ_STATUS handled below;
                          // unmapped addresses are ignored (SLVERR response)
        endcase
      end
      // A hardware event in the same cycle as a clear wins: no event is lost
      reg_irq_status <= (reg_irq_status & ~irq_clear) | irq_set_i;
    end
  end

  assign ctrl_o = reg_ctrl;
  assign irq_o  = |(reg_irq_status & reg_irq_en);

  //===========================================================================
  // Write response channel
  //===========================================================================
  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= RESP_OKAY;
    end else if (do_write) begin
      s_axi_bvalid <= 1'b1;
      s_axi_bresp  <= wr_ok ? RESP_OKAY : RESP_SLVERR;
    end else if (s_axi_bready) begin
      s_axi_bvalid <= 1'b0;
    end
  end

  //===========================================================================
  // Read path
  //===========================================================================
  logic [IDX_W-1:0] rd_idx;
  logic             rd_ok;
  logic             rd_fire;
  logic [31:0]      rd_mux;

  // Accept a new read only when no read response is waiting
  assign s_axi_arready = ~s_axi_rvalid;
  assign rd_fire       = s_axi_arvalid & s_axi_arready;
  assign rd_idx        = s_axi_araddr[ADDR_WIDTH-1:2];
  assign rd_ok         = (rd_idx < NUM_REGS);

  always_comb begin
    case (rd_idx)
      REG_CTRL:       rd_mux = reg_ctrl;
      REG_STATUS:     rd_mux = status_i;
      REG_SCRATCH:    rd_mux = reg_scratch;
      REG_IRQ_STATUS: rd_mux = reg_irq_status;
      REG_IRQ_ENABLE: rd_mux = reg_irq_en;
      REG_ID:         rd_mux = ID_VALUE;
      default:        rd_mux = '0;
    endcase
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      s_axi_rresp  <= RESP_OKAY;
    end else if (rd_fire) begin
      s_axi_rvalid <= 1'b1;
      s_axi_rdata  <= rd_mux;
      s_axi_rresp  <= rd_ok ? RESP_OKAY : RESP_SLVERR;
    end else if (s_axi_rready) begin
      s_axi_rvalid <= 1'b0;
    end
  end

  //===========================================================================
  // Intentionally unused inputs (protection bits, byte offset)
  //===========================================================================
  logic unused_ok;
  assign unused_ok = ^{s_axi_awprot, s_axi_arprot, awaddr_q[1:0], s_axi_araddr[1:0]};

endmodule
