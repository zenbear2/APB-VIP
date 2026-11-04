`timescale 1ns / 1ps

package apb_vip_pkg;

    // =========================================================================
    // 1. Transaction Packet: 資料結構、隨機約束與 Deep Copy
    // =========================================================================
    class apb_pkt;
        rand logic [31:0] m_addr;
        rand logic [31:0] m_wdata;
        logic      [31:0] m_rdata;
        rand logic        m_write;
        logic             m_slverr;

        // 預設約束：4-byte 對齊位址 (Word-aligned) 且限制在合理測試範圍內
        constraint c_addr_align {
            soft m_addr[1:0] == 2'b00;
            soft m_addr inside {[32'h0000_0000 : 32'h0000_00FF]};
        }

        function new();
        endfunction

        function apb_pkt copy();
            copy = new();
            copy.m_addr   = this.m_addr;
            copy.m_wdata  = this.m_wdata;
            copy.m_rdata  = this.m_rdata;
            copy.m_write  = this.m_write;
            copy.m_slverr = this.m_slverr;
        endfunction

        virtual function string convert2string();
            return $sformatf("addr=0x%08h write=%0b wdata=0x%08h rdata=0x%08h slverr=%0b",
                             m_addr, m_write, m_wdata, m_rdata, m_slverr);
        endfunction
    endclass

    // =========================================================================
    // 2. Configuration: 封裝 Virtual Interface 與 VIP 設定
    // =========================================================================
    class apb_cfg;
        virtual apb_if vif;
        bit            vld_val_only;
        bit            is_active;

        function new(
            virtual apb_if vif,
            bit            vld_val_only = 1'b1,
            bit            is_active    = 1'b1
        );
            this.vif          = vif;
            this.vld_val_only = vld_val_only;
            this.is_active    = is_active;
        endfunction
    endclass

    // =========================================================================
    // 3. Sequence / Generator: 產生 APB 讀寫交易並放入 Mailbox
    // =========================================================================
    class apb_seq;
        mailbox #(apb_pkt) gen2drv;
        rand int           num;
        event              done;

        constraint c_num { soft num inside {[10:30]}; }

        function new(mailbox #(apb_pkt) gen2drv = null, int num = 16);
            this.gen2drv = gen2drv;
            this.num     = num;
        endfunction

        virtual task start(mailbox #(apb_pkt) mbx = null);
            if (mbx != null) begin
                this.gen2drv = mbx;
            end
            if (this.gen2drv == null) begin
                $fatal(1, "[SEQ] gen2drv mailbox is null!");
            end

            for (int i = 0; i < num; i++) begin
                apb_pkt m_pkt = new();
                if (!m_pkt.randomize()) begin
                    $fatal(1, "[SEQ] Randomization failed at item %0d!", i);
                end
                $display("[%0t] [SEQ] Generated item [%0d/%0d]: %s",
                         $time, i + 1, num, m_pkt.convert2string());
                gen2drv.put(m_pkt.copy());
            end
            ->done;
        endtask
    endclass

    // =========================================================================
    // 4. Monitor: 取樣 APB 介面握手訊號並送往 Scoreboard
    // =========================================================================
    class apb_monitor;
        apb_cfg            cfg;
        virtual apb_if     vif;
        mailbox #(apb_pkt) mon2scb;

        function new(
            apb_cfg            cfg,
            mailbox #(apb_pkt) mon2scb
        );
            this.cfg     = cfg;
            this.vif     = cfg.vif;
            this.mon2scb = mon2scb;
        endfunction

        virtual task run();
            forever begin
                @(vif.cb);
                if (vif.psel && vif.penable && vif.cb.pready && vif.presetn) begin
                    apb_pkt m_apb_pkt = new();
                    m_apb_pkt.m_addr   = vif.paddr;
                    m_apb_pkt.m_write  = vif.pwrite;
                    m_apb_pkt.m_slverr = vif.cb.pslverr;

                    if (cfg.vld_val_only) begin
                        if (m_apb_pkt.m_write)
                            m_apb_pkt.m_wdata = vif.pwdata;
                        else
                            m_apb_pkt.m_rdata = vif.cb.prdata;
                    end else begin
                        m_apb_pkt.m_wdata = vif.pwdata;
                        m_apb_pkt.m_rdata = vif.cb.prdata;
                    end

                    $display("[%0t] [MON] Captured transfer: %s", $time, m_apb_pkt.convert2string());
                    mon2scb.put(m_apb_pkt);
                end
            end
        endtask
    endclass

    // =========================================================================
    // 5. Driver: 從 Mailbox 取出封包並依 APB 兩階段協定驅動至介面
    // =========================================================================
    class apb_driver;
        virtual apb_if     vif;
        apb_cfg            cfg;
        mailbox #(apb_pkt) gen2drv;
        apb_pkt            m_apb_pkt;
        int                no_of_pkts;

        function new(
            apb_cfg            cfg,
            mailbox #(apb_pkt) gen2drv
        );
            this.cfg        = cfg;
            this.vif        = cfg.vif;
            this.gen2drv    = gen2drv;
            this.no_of_pkts = 0;
        endfunction

        virtual task reset();
            vif.cb.paddr   <= 0;
            vif.cb.psel    <= 0;
            vif.cb.pwdata  <= 0;
            vif.cb.penable <= 0;
            vif.cb.pwrite  <= 0;
            @(vif.cb);
        endtask

        virtual task run();
            reset();
            wait(vif.presetn);
            forever begin
                gen2drv.get(m_apb_pkt);
                driver(m_apb_pkt);
                no_of_pkts++;
            end
        endtask

        virtual task driver(apb_pkt m_pkt);
            // Setup Phase
            vif.cb.paddr   <= m_pkt.m_addr;
            vif.cb.psel    <= 1;
            vif.cb.pwrite  <= m_pkt.m_write;
            vif.cb.penable <= 0;
            if (cfg.vld_val_only) begin
                vif.cb.pwdata <= m_pkt.m_write ? m_pkt.m_wdata : 32'h0;
            end else begin
                vif.cb.pwdata <= m_pkt.m_wdata;
            end

            // Access Phase
            @(vif.cb);
            vif.cb.penable <= 1;

            do begin
                @(vif.cb);
            end while (!vif.cb.pready);

            // Read data capture & Return to Idle
            if (!m_pkt.m_write) begin
                m_pkt.m_rdata = vif.cb.prdata;
            end

            vif.cb.psel    <= 0;
            vif.cb.penable <= 0;
        endtask
    endclass

    // =========================================================================
    // 6. Scoreboard: 使用關聯陣列模擬 Golden Memory 比對讀寫結果
    // =========================================================================
    class base_scoreboard;
        mailbox #(apb_pkt) mon2scb;
        logic [31:0]       golden_mem [int unsigned];
        int                total_cnt;
        int                match_cnt;
        int                error_cnt;

        function new(mailbox #(apb_pkt) mon2scb);
            this.mon2scb   = mon2scb;
            this.total_cnt = 0;
            this.match_cnt = 0;
            this.error_cnt = 0;
        endfunction

        virtual task run();
            forever begin
                apb_pkt pkt;
                mon2scb.get(pkt);
                total_cnt++;

                if (pkt.m_write) begin
                    if (!pkt.m_slverr) begin
                        golden_mem[pkt.m_addr] = pkt.m_wdata;
                        $display("[%0t] [SCB] WRITE recorded: addr=0x%08h data=0x%08h",
                                 $time, pkt.m_addr, pkt.m_wdata);
                    end
                    match_cnt++;
                end else begin
                    logic [31:0] exp_data = golden_mem.exists(pkt.m_addr) ? golden_mem[pkt.m_addr] : 32'h0;
                    if (pkt.m_rdata !== exp_data) begin
                        $error("[%0t] [SCB] READ MISMATCH at addr=0x%08h! exp=0x%08h, act=0x%08h",
                               $time, pkt.m_addr, exp_data, pkt.m_rdata);
                        error_cnt++;
                    end else begin
                        $display("[%0t] [SCB] READ MATCH at addr=0x%08h: data=0x%08h",
                                 $time, pkt.m_addr, pkt.m_rdata);
                        match_cnt++;
                    end
                end
            end
        endtask

        virtual function void report();
            $display("========================================");
            $display("[SCB] APB VIP TEST SUMMARY:");
            $display("      Total Transfers : %0d", total_cnt);
            $display("      Passed          : %0d", match_cnt);
            $display("      Errors          : %0d", error_cnt);
            if (error_cnt == 0 && total_cnt > 0)
                $display("      STATUS          : *** TEST PASSED ***");
            else
                $display("      STATUS          : *** TEST FAILED ***");
            $display("========================================");
        endfunction
    endclass

    // =========================================================================
    // 7. Agent: 封裝 Driver 與 Monitor (Pure SystemVerilog 版)
    // =========================================================================
    class apb_agent;
        apb_cfg            m_cfg;
        apb_driver         m_drv;
        apb_monitor        m_mon;
        mailbox #(apb_pkt) gen2drv;
        mailbox #(apb_pkt) mon2scb;

        function new(
            apb_cfg            cfg,
            mailbox #(apb_pkt) gen2drv,
            mailbox #(apb_pkt) mon2scb
        );
            this.m_cfg   = cfg;
            this.gen2drv = gen2drv;
            this.mon2scb = mon2scb;

            if (m_cfg.is_active) begin
                m_drv = new(m_cfg, this.gen2drv);
            end
            m_mon = new(m_cfg, this.mon2scb);
        endfunction

        virtual task run();
            fork
                m_mon.run();
                if (m_cfg.is_active) begin
                    m_drv.run();
                end
            join_none
        endtask
    endclass

    // =========================================================================
    // 8. Environment: 連接 Agent 與 Scoreboard
    // =========================================================================
    class base_env;
        apb_cfg            m_cfg;
        apb_agent          m_apb_agent;
        base_scoreboard    m_base_scbd;
        mailbox #(apb_pkt) gen2drv;
        mailbox #(apb_pkt) mon2scb;

        function new(apb_cfg cfg);
            this.m_cfg       = cfg;
            this.gen2drv     = new();
            this.mon2scb     = new();
            this.m_apb_agent = new(m_cfg, gen2drv, mon2scb);
            this.m_base_scbd = new(mon2scb);
        endfunction

        virtual task run();
            fork
                m_apb_agent.run();
                m_base_scbd.run();
            join_none
        endtask
    endclass

    // =========================================================================
    // 9. Base Test: 初始化設定、Reset 控制與啟動測試流程
    // =========================================================================
    class base_test;
        virtual apb_if m_apb_vif;
        apb_cfg        m_apb_cfg;
        apb_seq        m_apb_seq;
        base_env       m_env;

        function new(virtual apb_if vif, bit vld_val_only = 1'b1);
            this.m_apb_vif = vif;
            this.m_apb_cfg = new(m_apb_vif, vld_val_only);
            this.m_env     = new(m_apb_cfg);
            this.m_apb_seq = new(m_env.gen2drv);
        endfunction

        virtual task reset_phase();
            $display("[%0t] [TEST] Applying reset...", $time);
            m_apb_vif.presetn <= 0;
            repeat(5) @(m_apb_vif.cb);
            m_apb_vif.presetn <= 1;
            repeat(2) @(m_apb_vif.cb);
            $display("[%0t] [TEST] Reset released.", $time);
        endtask

        virtual task main_phase();
            if (!m_apb_seq.randomize()) begin
                $fatal(1, "[TEST] Sequence randomization failed!");
            end
            m_apb_seq.start(m_env.gen2drv);
            wait(m_env.m_apb_agent.m_drv.no_of_pkts == m_apb_seq.num);
            repeat(5) @(m_apb_vif.cb);
        endtask

        virtual task run();
            m_env.run();
            reset_phase();
            main_phase();
            m_env.m_base_scbd.report();
        endtask
    endclass

endpackage
