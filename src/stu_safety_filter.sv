`include "stu_pkg.sv"

`timescale 1ns/1ps

/**
 * @module stu_safety_filter
 * @brief O "Diretor de Fluxo" da STU (Versão Adaptativa).
 *
 * @details Este módulo é puramente combinacional. Ele analisa um *bloco*
 * de instruções (ex: 4) e o classifica em um dos 3 níveis.
 * A regra é "o pior nível vence":
 * - Se CUALQUER instrução for L0 (FENCE, etc) -> Bloco é L0 (BYPASS).
 * - Senão, se CUALQUER instrução for L2 (STORE, etc) -> Bloco é L2 (OTIMISTA).
 * - Senão (TODAS são L1) -> Bloco é L1 (CONSERVADOR).
 */
module stu_safety_filter #(
  parameter int BLOCK_SIZE = 4
)(
  input  logic clk,
  input  logic rst,
  
  // Entrada de Bloco
  input  stu_pkg::instr_t  [BLOCK_SIZE-1:0] block_in,
  input  logic             block_valid_in,

  // Saída de Classificação
  output stu_pkg::spec_level_t spec_level_out 
);

  // --- Opcodes de Nível 0 (Bypass de Segurança) ---
  // Sincronização e Sistema (NUNCA podem ser especulados)
  localparam OPCODE_SYSTEM = 7'b1110011;
  localparam OPCODE_FENCE  = 7'b0001111;
  localparam OPCODE_AMO    = 7'b0101111;

  // --- Opcodes de Nível 2 (Otimista) ---
  // A STU pode "apostar" nestes (STOREs e Fluxo de Controle)
  localparam OPCODE_STORE  = 7'b0100011;
  localparam OPCODE_BRANCH = 7'b1100011;
  localparam OPCODE_JALR   = 7'b1100111;
  localparam OPCODE_JAL    = 7'b1101111;
  
  // NOTA: Opcodes não listados (ex: LOAD, ADD, MUL) são
  // considerados Nível 1 (Conservador).

  // --- Lógica de Classificação (Combinacional) ---

  logic [BLOCK_SIZE-1:0] is_level0_instr; // Instrução é L0?
  logic [BLOCK_SIZE-1:0] is_level2_instr; // Instrução é L2?
  
  logic block_is_level0; // Bloco contém uma instrução L0?
  logic block_is_level2; // Bloco contém uma instrução L2?

  // Passo 1: Classifique cada instrução individualmente
  genvar i;
  generate
    for (i = 0; i < BLOCK_SIZE; i++) begin : gen_instr_check
      logic [6:0] opcode;
      assign opcode = block_in[i][6:0];
      
      // Verifica se é Nível 0
      assign is_level0_instr[i] = (opcode == OPCODE_SYSTEM) ||
                                  (opcode == OPCODE_FENCE)  ||
                                  (opcode == OPCODE_AMO);
                                  
      // Verifica se é Nível 2
      assign is_level2_instr[i] = (opcode == OPCODE_STORE)  ||
                                  (opcode == OPCODE_BRANCH) ||
                                  (opcode == OPCODE_JALR)   ||
                                  (opcode == OPCODE_JAL);
    end
  endgenerate

  // Passo 2: Agregue os resultados do bloco (O pior vence)
  // | (OR-reduce) significa "se *qualquer* bit for 1"
  assign block_is_level0 = |is_level0_instr; 
  assign block_is_level2 = |is_level2_instr;
  
  // Passo 3: Lógica de Decisão Final
  always_comb begin
    if (!block_valid_in) begin
      spec_level_out = stu_pkg::SPEC_LEVEL_0_BYPASS; // Padrão
    
    // REGRA 1: Se *qualquer* instrução for L0, o bloco é L0.
    end else if (block_is_level0) begin
      spec_level_out = stu_pkg::SPEC_LEVEL_0_BYPASS;
      
    // REGRA 2: Se não for L0, mas *qualquer* instrução for L2...
    end else if (block_is_level2) begin
      spec_level_out = stu_pkg::SPEC_LEVEL_2_OPTIMISTIC;
    
    // REGRA 3: Se não for L0 nem L2, significa que TODAS são L1.
    end else begin
      spec_level_out = stu_pkg::SPEC_LEVEL_1_CONSERVATIVE;
    end
  end

endmodule
