`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09.05.2026 16:55:59
// Design Name: 
// Module Name: ahb_master
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ahb_master#(
parameter MASTER_ID=0
    )
    (
    
    input logic HRESETn,
    input logic HCLK,
    output logic HBUSREQ,
    input logic HGRANT,
    output logic HLOCK,
    
    output logic [31:0] HADDR,
    output logic [1:0] HTRANS,
    output logic HWRITE,
    output logic [2:0] HSIZE,
    output logic [2:0] HBURST,
    output logic [31:0] HWDATA,
    input logic [31:0] HRDATA,
    input logic HREADY,
    input logic [1:0] HRESP, 
    
    input logic start_transfer,
    input logic [31:0] target_addr,
    input logic [31:0] write_data,
    input logic do_write
    );
    
    localparam IDLE = 2'd0;
    localparam REQUESTING = 2'd1;
    localparam TRANSFER = 2'd2;
    localparam WAIT = 2'd3;
    
    logic [1:0] state;
    
    
    always_ff@(posedge HCLK or negedge HRESETn)
    begin
    if(!HRESETn)
    
    begin
        state<= IDLE;
        HBUSREQ  <= 0;
        HLOCK    <= 0;
        HTRANS   <= 2'b00;
        HADDR    <= 0;
        HWRITE   <= 0;
        HWDATA   <= 0;
        HSIZE <= 3'b010;
        HBURST <= 3'b000;
    end
    else 
        begin
        case(state)
        
            IDLE: 
            begin    
                HTRANS <= 2'b00;
                
                if(start_transfer)
                begin
                    HBUSREQ<=1;
                    state <= REQUESTING;
                end    
            end
            
            REQUESTING:
            begin
            //address phase only
                if (HGRANT && HREADY)
                begin
                    HADDR <= target_addr;
                    HTRANS <=2'b10;
                    HWRITE <= do_write;
                    state <= TRANSFER;
                end
            end
            
            TRANSFER:
            begin
            if(HREADY)
            begin
                HWDATA <= write_data;
                if(HRESP == 2'b00)
                begin
                    HTRANS <=2'b00;
                    HBUSREQ <= 0;
                    state <= IDLE;
                end
                else
                begin
                    state<=WAIT;
                end
            end
            end
            
            WAIT:     
            begin
               HTRANS<=2'b00;
               if (HREADY)
               begin
                    HBUSREQ<=0;
                    state<= IDLE; 
                end
            end
        endcase
        end   
    end 

endmodule
