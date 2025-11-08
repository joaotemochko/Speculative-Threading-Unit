`include "stu_pkg.sv"

`timescale 1ns/1ps

/**
 * @module stu_validator
 * @brief O "Juiz" da STU (Implementação Adaptativa).
 *
 * @details Esta FSM gerencia o ciclo de vida da tarefa de Nível 2
 * (Otimista). Ele permanece em IDLE durante os Níveis 0 e 1.
 *
 * MODIFICAÇÃO (Linux): Adicionada uma entrada 'l2_spec_exception_in'.
 * Qualquer exceção (ex: Page Fault) em um núcleo especulativo
 * força um SQUASH imediato, tratando-o como uma falha de especulação.
 */
module stu_validator (
  input  logic clk,
  input  logic rst,

  // --- Sinais de Controle de Estado (APENAS Nível 2) ---
  input  logic             l2_spec_task_active_in, 
  input  logic             master_task_done_in, 
  input  logic             spec_task_done_in,   
  input  logic             violation_in, // Do Tracker
  
  // --- NOVO: Entrada de Exceção (do Núcleo Spec) ---
  input  logic             l2_spec_exception_in, // 1 = Page Fault, Interrupção, etc.

  // --- Saídas Finais (para o ute_top rotear) ---
  output logic             squash_out,
  output logic             commit_out
);

  // A FSM tem 3 estados para gerenciar a tarefa L2 ativa:
  typedef enum logic [1:0] { 
    IDLE,           
    WAIT_MASTER,    
    WAIT_SPEC       
  } state_t;
  
  state_t state, next_state;

  // Registradores de Estado (Sequencial)
  always_ff @(posedge clk or negedge rst) begin
    if (rst)
      state <= IDLE;
    else
      state <= next_state;
  end

  // Lógica de Próximo Estado (Combinacional)
  
  logic force_squash; // NOVO: Agregador de falhas
  
  // REGRA 1: Forçar SQUASH se houver violação de dados OU exceção
  assign force_squash = violation_in || l2_spec_exception_in;

  always_comb begin
    // Padrões: Não faça nada
    next_state = state;
    squash_out = 1'b0;
    commit_out = 1'b0;

    case (state)
      
      IDLE: begin
        // Espera o Forker iniciar uma tarefa L2
        if (l2_spec_task_active_in) begin
          
          // Verificação no primeiro ciclo (REGRA 1)
          if (force_squash) begin
            squash_out = 1'b1;
            next_state = IDLE; // Falha imediata
          end else begin
            next_state = WAIT_MASTER; // Comece a esperar pelo Master
          end
        end
      end
      
      WAIT_MASTER: begin
        // REGRA 1: Violação ou Exceção = Squash imediato
        if (force_squash) begin
          squash_out = 1'b1;
          next_state = IDLE; // Falha, volte para IDLE
        end
        // Se a tarefa L2 foi cancelada (ex: pelo forker)
        else if (!l2_spec_task_active_in) begin
          next_state = IDLE;
        end
        // REGRA 2: Master terminou, sem falha
        else if (master_task_done_in) begin
          next_state = WAIT_SPEC; // Avance para o próximo estado
        end
        // else: Continue em WAIT_MASTER
      end

      WAIT_SPEC: begin
        // Master terminou e não houve falha (ainda).
        
        // REGRA 1: Violação ou Exceção ainda pode acontecer
        if (force_squash) begin
          squash_out = 1'b1;
          next_state = IDLE; // Falha
        end
        // REGRA 3: Sucesso! Spec também terminou, sem falha.
        else if (spec_task_done_in) begin
          commit_out = 1'b1;
          next_state = IDLE; // Sucesso, volte para IDLE
        end
        // else: Continue em WAIT_SPEC
      end
      
    endcase
  end

endmodule
