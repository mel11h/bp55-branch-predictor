// Minimal Verilator testbench for CVA6 (BP55 measurement harness, phase 1).
//
// Replaces the stock ariane_testharness (which needs Spike's libfesvr, a debug
// module, CLINT, PLIC, UART and an AXI crossbar) with:
//   - the cva6 core itself, instantiated as corev_apu/src/ariane.sv does it
//     (same type parameters, same CV-X-IF example coprocessor),
//   - one AXI4 slave in front of a flat memory held by the C++ driver
//     (bp55_cva6_main.cpp, through DPI), with a fixed, configurable latency,
//   - a monitor that classifies every committed instruction and every branch
//     resolution (DPI calls into the driver, which keeps the counters).
// There is no tohost polling through memory: console output and the exit code
// are taken from the store buffer's request port (every committed store, one
// at a time, in program order), because the write-through data cache may merge
// consecutive stores to tohost before they reach the AXI port.
//
// Plusargs (read here): +mem_lat=<n> (>= 1, default 1): an AR accepted at clock
// edge t gives its first R beat in the cycle after edge t+n; a write burst
// whose last W beat is accepted at edge t has B valid after edge t+n-1.

module bp55_cva6_tb
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(
        cva6_config_pkg::cva6_cfg
    )
) (
    input logic clk_i,
    input logic rst_ni
);

  // ---------------------------------------------------------------------------
  // Types, as in corev_apu/src/ariane.sv and the defaults of core/cva6.sv
  // ---------------------------------------------------------------------------
  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg);
  localparam type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t   csr;
    rvfi_probes_instr_t instr;
  };
  localparam type readregflags_t = `READREGFLAGS_T(CVA6Cfg);
  localparam type writeregflags_t = `WRITEREGFLAGS_T(CVA6Cfg);
  localparam type id_t = `ID_T(CVA6Cfg);
  localparam type hartid_t = `HARTID_T(CVA6Cfg);
  localparam type x_compressed_req_t = `X_COMPRESSED_REQ_T(CVA6Cfg, hartid_t);
  localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(CVA6Cfg);
  localparam type x_issue_req_t = `X_ISSUE_REQ_T(CVA6Cfg, hartid_t, id_t);
  localparam type x_issue_resp_t = `X_ISSUE_RESP_T(CVA6Cfg, writeregflags_t, readregflags_t);
  localparam type x_register_t = `X_REGISTER_T(CVA6Cfg, hartid_t, id_t, readregflags_t);
  localparam type x_commit_t = `X_COMMIT_T(CVA6Cfg, hartid_t, id_t);
  localparam type x_result_t = `X_RESULT_T(CVA6Cfg, hartid_t, id_t, writeregflags_t);
  localparam type cvxif_req_t =
      `CVXIF_REQ_T(CVA6Cfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t);
  localparam type cvxif_resp_t =
      `CVXIF_RESP_T(CVA6Cfg, x_compressed_resp_t, x_issue_resp_t, x_result_t);

  localparam int unsigned AW = CVA6Cfg.AxiAddrWidth;
  localparam int unsigned DW = CVA6Cfg.AxiDataWidth;
  localparam int unsigned IW = CVA6Cfg.AxiIdWidth;
  localparam int unsigned UW = CVA6Cfg.AxiUserWidth;

  typedef struct packed {
    logic [IW-1:0]    id;
    logic [AW-1:0]    addr;
    axi_pkg::len_t    len;
    axi_pkg::size_t   size;
    axi_pkg::burst_t  burst;
    logic             lock;
    axi_pkg::cache_t  cache;
    axi_pkg::prot_t   prot;
    axi_pkg::qos_t    qos;
    axi_pkg::region_t region;
    logic [UW-1:0]    user;
  } ar_chan_t;
  typedef struct packed {
    logic [IW-1:0]    id;
    logic [AW-1:0]    addr;
    axi_pkg::len_t    len;
    axi_pkg::size_t   size;
    axi_pkg::burst_t  burst;
    logic             lock;
    axi_pkg::cache_t  cache;
    axi_pkg::prot_t   prot;
    axi_pkg::qos_t    qos;
    axi_pkg::region_t region;
    axi_pkg::atop_t   atop;
    logic [UW-1:0]    user;
  } aw_chan_t;
  typedef struct packed {
    logic [DW-1:0]   data;
    logic [DW/8-1:0] strb;
    logic            last;
    logic [UW-1:0]   user;
  } w_chan_t;
  typedef struct packed {
    logic [IW-1:0]  id;
    axi_pkg::resp_t resp;
    logic [UW-1:0]  user;
  } b_chan_t;
  typedef struct packed {
    logic [IW-1:0]  id;
    logic [DW-1:0]  data;
    axi_pkg::resp_t resp;
    logic           last;
    logic [UW-1:0]  user;
  } r_chan_t;
  typedef struct packed {
    aw_chan_t aw;
    logic     aw_valid;
    w_chan_t  w;
    logic     w_valid;
    logic     b_ready;
    ar_chan_t ar;
    logic     ar_valid;
    logic     r_ready;
  } noc_req_t;
  typedef struct packed {
    logic    aw_ready;
    logic    ar_ready;
    logic    w_ready;
    logic    b_valid;
    b_chan_t b;
    logic    r_valid;
    r_chan_t r;
  } noc_resp_t;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  noc_req_t     noc_req;
  noc_resp_t    noc_resp;
  cvxif_req_t   cvxif_req;
  cvxif_resp_t  cvxif_resp;
  rvfi_probes_t rvfi_probes;

  cva6 #(
      .CVA6Cfg            (CVA6Cfg),
      .rvfi_probes_instr_t(rvfi_probes_instr_t),
      .rvfi_probes_csr_t  (rvfi_probes_csr_t),
      .rvfi_probes_t      (rvfi_probes_t),
      .axi_ar_chan_t      (ar_chan_t),
      .axi_aw_chan_t      (aw_chan_t),
      .axi_w_chan_t       (w_chan_t),
      .b_chan_t           (b_chan_t),
      .r_chan_t           (r_chan_t),
      .noc_req_t          (noc_req_t),
      .noc_resp_t         (noc_resp_t),
      .readregflags_t     (readregflags_t),
      .writeregflags_t    (writeregflags_t),
      .id_t               (id_t),
      .hartid_t           (hartid_t),
      .x_compressed_req_t (x_compressed_req_t),
      .x_compressed_resp_t(x_compressed_resp_t),
      .x_issue_req_t      (x_issue_req_t),
      .x_issue_resp_t     (x_issue_resp_t),
      .x_register_t       (x_register_t),
      .x_commit_t         (x_commit_t),
      .x_result_t         (x_result_t),
      .cvxif_req_t        (cvxif_req_t),
      .cvxif_resp_t       (cvxif_resp_t)
  ) i_cva6 (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .boot_addr_i  (CVA6Cfg.VLEN'(32'h8000_0000)),
      .hart_id_i    ('0),
      .irq_i        ('0),
      .ipi_i        (1'b0),
      .time_irq_i   (1'b0),
      .debug_req_i  (1'b0),
      .rvfi_probes_o(rvfi_probes),
      .cvxif_req_o  (cvxif_req),
      .cvxif_resp_i (cvxif_resp),
      .noc_req_o    (noc_req),
      .noc_resp_i   (noc_resp)
  );

  if (CVA6Cfg.CvxifEn) begin : gen_cvxif
    if (CVA6Cfg.CoproType == config_pkg::COPRO_EXAMPLE) begin : gen_COPRO_EXAMPLE
      cvxif_example_coprocessor #(
          .NrRgprPorts        (CVA6Cfg.NrRgprPorts),
          .XLEN               (CVA6Cfg.XLEN),
          .readregflags_t     (readregflags_t),
          .writeregflags_t    (writeregflags_t),
          .id_t               (id_t),
          .hartid_t           (hartid_t),
          .x_compressed_req_t (x_compressed_req_t),
          .x_compressed_resp_t(x_compressed_resp_t),
          .x_issue_req_t      (x_issue_req_t),
          .x_issue_resp_t     (x_issue_resp_t),
          .x_register_t       (x_register_t),
          .x_commit_t         (x_commit_t),
          .x_result_t         (x_result_t),
          .cvxif_req_t        (cvxif_req_t),
          .cvxif_resp_t       (cvxif_resp_t)
      ) i_cvxif_coprocessor (
          .clk_i       (clk_i),
          .rst_ni      (rst_ni),
          .cvxif_req_i (cvxif_req),
          .cvxif_resp_o(cvxif_resp)
      );
    end else begin : gen_COPRO_NONE
      assign cvxif_resp = '{compressed_ready: 1'b1, issue_ready: 1'b1, register_ready: 1'b1, default: '0};
    end
  end else begin : gen_no_cvxif
    assign cvxif_resp = '0;
  end

  // ---------------------------------------------------------------------------
  // AXI4 memory slave. One read burst and one write burst at a time; INCR and
  // FIXED bursts; every beat moves the 8-byte word that contains its address.
  // ---------------------------------------------------------------------------
  import "DPI-C" function longint unsigned tb_mem_read(input longint unsigned addr);
  import "DPI-C" function void tb_mem_write(input longint unsigned addr, input longint unsigned data,
                                            input byte unsigned strb);
  import "DPI-C" function void tb_axi_error(input int unsigned kind, input longint unsigned addr);

  int unsigned mem_lat;
  initial begin
    if (!$value$plusargs("mem_lat=%d", mem_lat)) mem_lat = 1;
    if (mem_lat < 1) $fatal(1, "+mem_lat must be >= 1");
  end

  // read channel (the data of each beat is read into r_data when the beat
  // becomes valid, so no DPI call sits in combinational logic)
  logic r_busy, r_ok;
  ar_chan_t ar_q;
  logic [7:0] r_beat;
  int unsigned r_wait;
  logic [AW-1:0] r_addr;
  logic [DW-1:0] r_data;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy <= 1'b0;
      r_beat <= '0;
      r_wait <= 0;
      r_addr <= '0;
      r_data <= '0;
      ar_q   <= '0;
    end else begin
      if (!r_busy && noc_req.ar_valid) begin
        r_busy <= 1'b1;
        ar_q   <= noc_req.ar;
        r_addr <= noc_req.ar.addr;
        r_beat <= '0;
        r_wait <= mem_lat;
        if (noc_req.ar.burst == axi_pkg::BURST_WRAP) tb_axi_error(1, noc_req.ar.addr);
      end else if (r_busy) begin
        if (r_wait > 1) r_wait <= r_wait - 1;
        else if (r_wait == 1) begin
          r_wait <= 0;
          r_data <= DW'(tb_mem_read(64'(r_addr)));
        end else if (noc_req.r_ready) begin
          logic [AW-1:0] next_addr;
          next_addr = (ar_q.burst != axi_pkg::BURST_FIXED) ? r_addr + (AW'(1) << ar_q.size) : r_addr;
          if (r_beat == ar_q.len) r_busy <= 1'b0;
          else r_data <= DW'(tb_mem_read(64'(next_addr)));
          r_beat <= r_beat + 1;
          r_addr <= next_addr;
        end
      end
    end
  end
  assign r_ok = r_busy && (r_wait == 0);
  assign noc_resp.ar_ready = !r_busy;
  assign noc_resp.r_valid = r_ok;
  assign noc_resp.r.id = ar_q.id;
  assign noc_resp.r.data = r_data;
  assign noc_resp.r.resp = axi_pkg::RESP_OKAY;
  assign noc_resp.r.last = r_ok && (r_beat == ar_q.len);
  assign noc_resp.r.user = '0;

  // write channel
  logic w_busy, b_pend;
  aw_chan_t aw_q;
  logic [AW-1:0] w_addr;
  int unsigned b_wait;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_busy <= 1'b0;
      b_pend <= 1'b0;
      b_wait <= 0;
      w_addr <= '0;
      aw_q   <= '0;
    end else begin
      if (!w_busy && !b_pend && noc_req.aw_valid) begin
        w_busy <= 1'b1;
        aw_q   <= noc_req.aw;
        w_addr <= noc_req.aw.addr;
        if (noc_req.aw.atop != '0) tb_axi_error(2, noc_req.aw.addr);
        if (noc_req.aw.burst == axi_pkg::BURST_WRAP) tb_axi_error(1, noc_req.aw.addr);
      end else if (w_busy && noc_req.w_valid) begin
        tb_mem_write(64'(w_addr), 64'(noc_req.w.data), 8'(noc_req.w.strb));
        if (aw_q.burst != axi_pkg::BURST_FIXED) w_addr <= w_addr + (AW'(1) << aw_q.size);
        if (noc_req.w.last) begin
          w_busy <= 1'b0;
          b_pend <= 1'b1;
          b_wait <= mem_lat > 0 ? mem_lat - 1 : 0;
        end
      end else if (b_pend) begin
        if (b_wait > 0) b_wait <= b_wait - 1;
        else if (noc_req.b_ready) b_pend <= 1'b0;
      end
    end
  end
  assign noc_resp.aw_ready = !w_busy && !b_pend;
  assign noc_resp.w_ready = w_busy;
  assign noc_resp.b_valid = b_pend && (b_wait == 0);
  assign noc_resp.b.id = aw_q.id;
  assign noc_resp.b.resp = axi_pkg::RESP_OKAY;
  assign noc_resp.b.user = '0;

  // ---------------------------------------------------------------------------
  // Monitor. Hierarchical references into the core; the driver keeps the
  // counters (see bp55_cva6_main.cpp for their definitions).
  // ---------------------------------------------------------------------------
  import "DPI-C" function void tb_cycle();
  import "DPI-C" function void tb_commit(input int unsigned pc, input int unsigned bp_cf,
                                         input int unsigned bp_valid, input int unsigned ex_valid);
  import "DPI-C" function void tb_resolve(input int unsigned pc, input int unsigned target,
                                          input int unsigned mispredict, input int unsigned taken,
                                          input int unsigned cf_type, input int unsigned bp_valid);
  import "DPI-C" function void tb_issue();
  import "DPI-C" function void tb_fe_push(input int unsigned pc, input int unsigned ras_op);
  import "DPI-C" function void tb_fe_flush();
  import "DPI-C" function void tb_bp55(input int unsigned flags);
  import "DPI-C" function void tb_flush(input int unsigned kind);
  import "DPI-C" function void tb_store(input int unsigned addr, input int unsigned data,
                                        input int unsigned be);
  import "DPI-C" function void tb_hw_counters(input longint unsigned mcycle,
                                              input longint unsigned minstret);

  // Single-issue, single-commit configurations only (cv32a60x family).
  if (CVA6Cfg.NrCommitPorts != 1 || CVA6Cfg.NrIssuePorts != 1) begin : gen_cfg_check
    $fatal(1, "bp55_cva6_tb supports NrCommitPorts == NrIssuePorts == 1");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      tb_cycle();
      if (i_cva6.commit_ack[0])
        tb_commit(32'(i_cva6.commit_instr_id_commit[0].pc),
                  32'(i_cva6.commit_instr_id_commit[0].bp.cf),
                  32'(i_cva6.commit_instr_id_commit[0].bp.valid),
                  32'(i_cva6.commit_instr_id_commit[0].ex.valid));
      if (i_cva6.resolved_branch.valid)
        tb_resolve(32'(i_cva6.resolved_branch.pc), 32'(i_cva6.resolved_branch.target_address),
                   32'(i_cva6.resolved_branch.is_mispredict), 32'(i_cva6.resolved_branch.is_taken),
                   32'(i_cva6.resolved_branch.cf_type), 32'(i_cva6.branch_predict_id_ex.valid));
      if (i_cva6.issue_stage_i.i_scoreboard.issue_ack_i[0]) tb_issue();
      // instructions entering the instruction queue, with the RAS operation the
      // frontend applied for them (ras push/pop are gated by instr_queue_consumed)
      // (with BP55 the stack operation is BP55's own speculative one, from its BTB view)
      if (i_cva6.i_frontend.instr_queue_consumed[0])
`ifdef BP55_PRED
        tb_fe_push(32'(i_cva6.i_frontend.addr[0]),
                   32'({i_cva6.i_frontend.bp55_sp_push, i_cva6.i_frontend.bp55_sp_pop}));
      tb_bp55({22'd0, i_cva6.i_frontend.bp55_f_busy,
               i_cva6.i_frontend.bp55_raw_fire & i_cva6.i_frontend.bp55_r_fire,      // contract violation
               i_cva6.i_frontend.instr_queue_consumed[0] & i_cva6.i_frontend.bp55_r_fire,
               i_cva6.i_frontend.bp55_ph_drop,
               i_cva6.i_frontend.bp55_u_ph,
               i_cva6.i_frontend.bp55_ex_u,
               i_cva6.i_frontend.bp55_fe_q & (i_cva6.i_frontend.bp55_ctrl | i_cva6.i_frontend.bp55_exr),
               i_cva6.i_frontend.bp55_fe_q & ~i_cva6.i_frontend.bp55_ctrl & ~i_cva6.i_frontend.bp55_exr,
               i_cva6.i_frontend.bp55_exr & ~i_cva6.i_frontend.bp55_ctrl,
               i_cva6.i_frontend.bp55_ctrl,
               i_cva6.i_frontend.bp55_f_fire});
`else
        tb_fe_push(32'(i_cva6.i_frontend.addr[0]),
                   32'({i_cva6.i_frontend.ras_push, i_cva6.i_frontend.ras_pop}));
`endif
      if (i_cva6.flush_ctrl_if) tb_fe_flush();
      // flushes other than branch mispredictions (kind: 1 = flush_ex from the
      // controller: fence, fence.i, CSR side effect, exception, eret)
      if (i_cva6.flush_ctrl_ex) tb_flush(1);
      if (i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_o.data_req &&
          i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_i.data_gnt)
        tb_store(32'({i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_o.address_tag,
                      i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_o.address_index}),
                 32'(i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_o.data_wdata),
                 32'(i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.req_port_o.data_be));
      tb_hw_counters(i_cva6.csr_regfile_i.cycle_q, i_cva6.csr_regfile_i.instret_q);
    end
  end

endmodule
