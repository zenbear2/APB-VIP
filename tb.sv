`timescale 1ns / 1ps

import apb_vip_pkg::*;

module tb;
    bit clk;

    // 50 MHz 時鐘 (週期 20ns)
    always #10 clk = ~clk;

    // 實例化 APB Interface
    apb_if m_apb_if (.pclk(clk));

    // 預設無 Slave Error
    assign m_apb_if.pslverr = 1'b0;

    // 模擬 Slave 隨機產生 Wait States (pready)
    initial begin
        m_apb_if.pready <= 1'b0;
        forever begin
            repeat ($urandom_range(2, 6)) @(posedge clk);
            m_apb_if.pready <= ~m_apb_if.pready;
        end
    end

    // 模擬簡易 APB Slave Memory 模型 (256 words，支援寫入儲存與讀取回傳，供 Scoreboard 驗證)
    logic [31:0] slv_mem [0:255];

    // 當 Setup Phase 進入讀取時，準備對應位址的 prdata
    always @(*) begin
        if (m_apb_if.psel && !m_apb_if.pwrite) begin
            m_apb_if.prdata = slv_mem[m_apb_if.paddr[9:2]];
        end else begin
            m_apb_if.prdata = 32'h0;
        end
    end

    // 當 Write Access 握手成立時，將 pwdata 寫入 Slave Memory
    always @(posedge clk) begin
        if (!m_apb_if.presetn) begin
            for (int i = 0; i < 256; i++) begin
                slv_mem[i] <= 32'h0;
            end
        end else if (m_apb_if.psel && m_apb_if.penable && m_apb_if.pready && m_apb_if.pwrite) begin
            slv_mem[m_apb_if.paddr[9:2]] <= m_apb_if.pwdata;
        end
    end

    // 啟動 Pure SV APB Test
    base_test t0;

    initial begin
        clk = 0;
        t0 = new(m_apb_if);
        t0.run();
        $finish;
    end

    // 超時安全保護 (Watchdog)
    initial begin
        #100000;
        $display("[TB] Watchdog timeout reached!");
        $finish;
    end

    // 波形傾印 (Waveform Dump)
    initial begin
        $dumpfile("apb_tb.vcd");
        $dumpvars(0, tb);
    end

endmodule
