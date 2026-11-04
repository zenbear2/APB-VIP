`timescale 1ns / 1ps

interface apb_if(
    input logic pclk
);

localparam ADDR_WIDTH = 32;
localparam DATA_WIDTH = 32;

logic                  presetn;
logic [ADDR_WIDTH-1:0] paddr;
logic                  psel;
logic                  penable;
logic                  pwrite;
logic [DATA_WIDTH-1:0] pwdata;
logic                  pready;
logic [DATA_WIDTH-1:0] prdata;
logic                  pslverr;

clocking cb @(posedge pclk);
    default input #1step output #1ns;
    input  pready, prdata, pslverr;
    output paddr, psel, penable, pwrite, pwdata;
endclocking

endinterface
