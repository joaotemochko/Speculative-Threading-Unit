`include "stu_pkg.sv"

`timescale 1ns/1ps

/**
 * @module stu_memory_tracker
 * @brief O Rastreador de Conflitos de Memória (Versão Adaptativa).
 *
 * @details Este módulo SÓ é ativado quando uma tarefa de Nível 2
 * (Otimista) está em andamento.
 *
 * MODIFICAÇÃO (Linux): As entradas de endereço agora são
 * Endereços Físicos (PAs) vindos de *depois* da MMU/TLB do núcleo.
 * Isso previne falhas de detecção por 'aliasing' de Endereço Virtual.
 */
module stu_memory_tracker #(
  parameter int READ_SET_DEPTH = 16 // Tamanho da tabela CAM
)(
  input  logic clk,
  input  logic rst,

  // --- Sinais de Controle (Do Forker) ---
  input  logic               l2_spec_task_active_in, // 1 = Nível 2 está ativo
  input  stu_pkg::core_id_t  master_core_id_in,    // Sempre Core 0
  input  stu_pkg::core_id_t  l2_spec_core_id_in,     // Qual worker (1, 2, ou 3)
  
  // --- Barramento de Monitoramento de Memória (MODIFICADO) ---
  // (Estes são Endereços Físicos (PAs) 'snooped' pós-MMU)
  input  stu_pkg::addr_t   [stu_pkg::NUM_CORES-1:0] core_mem_pa_in, // MUDANÇA
  input  logic             [stu_pkg::NUM_CORES-1:0] core_mem_is_store_in,
  input  logic             [stu_pkg::NUM_CORES-1:0] core_mem_valid_in,

  // --- Sinais de Reset (Do Validator) ---
  input  logic [stu_pkg::NUM_CORES-1:0] squash_in,
  input  logic [stu_pkg::NUM_CORES-1:0] commit_in,

  // --- Saída Principal ---
  output logic             violation_out // 1 = VIOLAÇÃO DE DADOS!
);

  localparam int PTR_WIDTH = $clog2(READ_SET_DEPTH);
  
  // --- Estrutura do Read-Set (CAM) ---
  // Armazena os Endereços Físicos (PAs) que foram lidos
  stu_pkg::addr_t   read_set_addr [stu_pkg::NUM_CORES][0:READ_SET_DEPTH-1];
  logic             read_set_valid[stu_pkg::NUM_CORES][0:READ_SET_DEPTH-1];
  logic [PTR_WIDTH-1:0] write_ptr [stu_pkg::NUM_CORES];

  // --- Lógica de Gravação no Read-Set (Sequencial) ---
  
  genvar i;
  generate
    for (i = 0; i < stu_pkg::NUM_CORES; i++) begin : gen_read_set_table
      
      const stu_pkg::core_id_t CURRENT_CORE_ID = stu_pkg::core_id_t'(i);

      always_ff @(posedge clk or negedge rst) begin
        if (rst) begin
          read_set_valid[i] <= '{default: '0};
          write_ptr[i] <= '0;
        end 
        
        else if (squash_in[i] || commit_in[i]) begin
          read_set_valid[i] <= '{default: '0};
          write_ptr[i] <= '0;
        end
        
        // --- LÓGICA DE ECONOMIA DE ENERGIA ---
        // SÓ grave no Read-Set se...
        else if (l2_spec_task_active_in &&
                 (CURRENT_CORE_ID == l2_spec_core_id_in) && // 1. Nível 2 Ativo
                 core_mem_valid_in[i] &&                 // 2. Este é o Spec Core
                 !core_mem_is_store_in[i])              // 3. É um LOAD
        begin
          // Adicione o Endereço Físico (PA) lido ao Read-Set
          read_set_addr[i][write_ptr[i]] <= core_mem_pa_in[i]; // MUDANÇA
          read_set_valid[i][write_ptr[i]] <= 1'b1;
          
          write_ptr[i] <= write_ptr[i] + 1; 
        end
      end
      
    end
  endgenerate // gen_read_set_table

  
  // --- Lógica de Detecção de Violação (Combinacional) ---
  
  logic core_violation;

  always_comb begin
    violation_out = 1'b0;
    core_violation = 1'b0;

    // SÓ verifique violações se uma tarefa Nível 2 estiver ativa
    if (l2_spec_task_active_in) begin
    
      // Verifique se o Master está fazendo um STORE
      if (core_mem_valid_in[master_core_id_in] && 
          core_mem_is_store_in[master_core_id_in]) begin
        stu_pkg::addr_t master_store_pa; // PA do Master
        master_store_pa = core_mem_pa_in[master_core_id_in]; // MUDANÇA
        
        stu_pkg::core_id_t spec_core = l2_spec_core_id_in;
        
        // Busca na CAM: Compare o PA do Master com
        // todos os PAs no Read-Set do Speculative Core
        for (int entry = 0; entry < READ_SET_DEPTH; entry++) begin
          
          if (read_set_valid[spec_core][entry] && 
              (read_set_addr[spec_core][entry] == master_store_pa)) begin
          
            // VIOLAÇÃO DE DADOS! (Mesmo Endereço Físico)
            core_violation = 1'b1;
            break; 
          end
        end // loop de entrada (CAM)
      end
    
    violation_out = core_violation;
    
    end
  end
endmodule
