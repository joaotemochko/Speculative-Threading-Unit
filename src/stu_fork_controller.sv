`include "stu_pkg.sv"

`timescale 1ns/1ps

/**
 * stu_fork_controller
 * O "Cérebro" Adaptativo da STU com Preditor de Histórico (HPT).
 *
 * Esta FSM lê a decisão do 'stu_safety_filter' e decide
 * qual modo de paralelismo usar.
 *
 */
module stu_fork_controller #(
  parameter int BLOCK_SIZE = 4,
  parameter int NUM_CORES_L1_SPLIT = 2,
  parameter int HPT_DEPTH = 64,
  parameter int HPT_ADDR_BITS = 6
)(
  input  logic clk,
  input  logic rst,

  // --- Entradas do Front-End (VAs) ---
  input  stu_pkg::addr_t   pc_in,
  input  stu_pkg::instr_t  [BLOCK_SIZE-1:0] block_in,
  input  logic             block_valid_in,
  
  input  stu_pkg::spec_level_t spec_level_in,
  input  logic [stu_pkg::NUM_CORES-1:0] core_busy_in,

  // --- Feedback do Validator (L2) ---
  input  logic [stu_pkg::NUM_CORES-1:0] squash_in,
  input  logic [stu_pkg::NUM_CORES-1:0] commit_in,
  
  // --- Feedback do Gerenciador de Contexto (L2) ---
  input  logic             l2_context_copy_done_in, // 1 = Cópia de Registrador OK

  // === SAÍDAS ===
  output stu_pkg::core_id_t  master_core_id_out,
  
  // --- Saídas Nível 1 (Conservador) ---
  output logic [stu_pkg::NUM_CORES-1:0] l1_dispatch_valid_out,
  output stu_pkg::instr_t [stu_pkg::NUM_CORES-1:0]
                           [BLOCK_SIZE/NUM_CORES_L1_SPLIT-1:0] l1_dispatch_data_out,

  // --- Saídas Nível 2 (Otimista) ---
  output stu_pkg::core_id_t  l2_spec_core_id_out,
  output stu_pkg::addr_t     l2_spec_pc_out,        
  output logic               l2_spec_start_out,
  output logic               l2_spec_task_active_out,
  
  // --- Saída para Gerenciador de Contexto (L2) ---
  output logic               l2_context_copy_start_out
);

  // --- Lógica Nível 2: Detecção de Loop ---
  logic [6:0]       last_instr_opcode;
  logic [31:0]      imm_b;
  stu_pkg::addr_t   branch_target_addr;
  logic             is_backward_branch;
  logic             l2_fork_trigger;

  assign last_instr_opcode = block_in[BLOCK_SIZE-1][6:0]; [cite: 177]
  assign imm_b = { {20{block_in[BLOCK_SIZE-1][31]}}, 
                   block_in[BLOCK_SIZE-1][7], 
                   block_in[BLOCK_SIZE-1][30:25], 
                   block_in[BLOCK_SIZE-1][11:8], 1'b0 }; [cite: 177]
  assign branch_target_addr = (pc_in + (4*(BLOCK_SIZE-1))) + imm_b; [cite: 178]
  assign is_backward_branch = (last_instr_opcode == 7'b1100011) && 
                              (branch_target_addr < pc_in); [cite: 178]
  assign l2_fork_trigger = block_valid_in && is_backward_branch; [cite: 179]


  // --- Lógica de Alocação de Núcleo ---
  stu_pkg::core_id_t  idle_spec_core_l2;
  logic               idle_core_found_l2;
  stu_pkg::core_id_t  [NUM_CORES_L1_SPLIT-1:0] idle_spec_cores_l1;
  logic               idle_cores_found_l1;

  always_comb begin
    // (Lógica de busca por núcleo ocioso L2)
    idle_core_found_l2 = 1'b0;
    idle_spec_core_l2 = '0;
    for (int i = 1; i < stu_pkg::NUM_CORES; i++) begin
      if (!core_busy_in[i]) {
        idle_core_found_l2 = 1'b1;
        idle_spec_core_l2 = stu_pkg::core_id_t'(i);
        break;
      }
    end
    
    // (Lógica de busca por núcleos ocioso L1)
    idle_cores_found_l1 = 1'b0;
    idle_spec_cores_l1 = '{default: '0};
    int cores_encontrados = 0;
    for (int i = 1; i < stu_pkg::NUM_CORES; i++) begin
      if (!core_busy_in[i]) {
        idle_spec_cores_l1[cores_encontrados] = stu_pkg::core_id_t'(i);
        cores_encontrados++;
        if (cores_encontrados == NUM_CORES_L1_SPLIT) {
          idle_cores_found_l1 = 1'b1;
          break;
        }
      }
    end
  end
  

  // --- HPT: Preditor de Histórico de Falhas ---
  logic [1:0] hpt_table [0:HPT_DEPTH-1];
  logic [HPT_ADDR_BITS-1:0] hpt_index;
  logic [1:0] hpt_counter_current;
  logic [1:0] hpt_counter_next;
  logic       hpt_predict_fail;

  assign hpt_index = pc_in[HPT_ADDR_BITS+1:2]; [cite: 180]
  assign hpt_counter_current = hpt_table[hpt_index]; [cite: 180]
  assign hpt_predict_fail = (hpt_counter_current[1] == 1'b0); [cite: 180]
  
  logic update_hpt;
  logic update_hpt_is_commit;

  always_comb begin
    hpt_counter_next = hpt_counter_current;
    if (update_hpt) begin
      if (update_hpt_is_commit) begin
        if (hpt_counter_current != 2'b11)
          hpt_counter_next = hpt_counter_current + 1;
      end else begin
        if (hpt_counter_current != 2'b00)
          hpt_counter_next = hpt_counter_current - 1;
      end
    end
  end
  
  // --- FSM (Gerencia o estado L2) ---

  // NOVO: Estado para a cópia de contexto
  typedef enum logic [1:0] { 
    IDLE,           
    L2_CONTEXT_COPY,
    L2_SPEC_ACTIVE 
  } state_t;
  
  state_t state, next_state;

  stu_pkg::core_id_t  l2_spec_core_reg;
  stu_pkg::addr_t     l2_spec_pc_reg;
  stu_pkg::addr_t     l2_spec_trigger_pc_reg;
  
  assign master_core_id_out = stu_pkg::core_id_t'(0);
  assign l2_spec_core_id_out = l2_spec_core_reg;
  assign l2_spec_pc_out = l2_spec_pc_reg;
  
  // FSM Sequencial (só para L2)
  always_ff @(posedge clk or negedge rst) begin
    if (rst) begin
      state <= IDLE;
      l2_spec_core_reg <= '0;
      l2_spec_pc_reg <= '0;
      l2_spec_trigger_pc_reg <= '0;
    end else begin
      state <= next_state;
      
      if (next_state == L2_CONTEXT_COPY && state == IDLE) begin [cite: 182-184]
        l2_spec_core_reg <= idle_spec_core_l2;
        l2_spec_pc_reg <= branch_target_addr;
        l2_spec_trigger_pc_reg <= pc_in;
      end
    end
    
    // Atualiza HPT
    if (update_hpt) begin
      hpt_table[pc_in[HPT_ADDR_BITS+1:2]] <= hpt_counter_next; [cite: 185]
    end
  end

  // Lógica de Saída/FSM Combinacional
  
  always_comb begin
    // Padrões
    next_state = state;
    update_hpt = 1'b0;
    update_hpt_is_commit = 1'b0;
    l1_dispatch_valid_out = '{default: '0};
    l1_dispatch_data_out = '{default: '0};
    l2_context_copy_start_out = 1'b0;
    l2_spec_start_out = 1'b0;
    l2_spec_task_active_out = 1'b0;

    // --- O DIRETOR ADAPTATIVO (Lógica de IDLE) ---
    if (state == IDLE && block_valid_in) begin
    
      case (spec_level_in)
        
        // NÍVEL 1 (Conservador):
        stu_pkg::SPEC_LEVEL_1_CONSERVATIVE: begin
          if (idle_cores_found_l1) begin
            l1_dispatch_valid_out[idle_spec_cores_l1[0]] = 1'b1;
            l1_dispatch_data_out[idle_spec_cores_l1[0]][0] = block_in[0];
            l1_dispatch_data_out[idle_spec_cores_l1[0]][1] = block_in[2];
            
            l1_dispatch_valid_out[idle_spec_cores_l1[1]] = 1'b1;
            l1_dispatch_data_out[idle_spec_cores_l1[1]][0] = block_in[1];
            l1_dispatch_data_out[idle_spec_cores_l1[1]][1] = block_in[3]; [cite: 186-187]
          end
        end
        
        // NÍVEL 2 (Otimista):
        stu_pkg::SPEC_LEVEL_2_OPTIMISTIC: begin
          // Se for um gatilho E houver núcleo ocioso E o HPT prever sucesso
          if (l2_fork_trigger && idle_core_found_l2 && !hpt_predict_fail) begin [cite: 188]
            // ... inicie a CÓPIA DE CONTEXTO.
            l2_context_copy_start_out = 1'b1;
            l2_spec_task_active_out = 1'b1;
            next_state = L2_CONTEXT_COPY;
          end
          // Se hpt_predict_fail for 1, não fazemos nada (minimiza perda).
        end

        // NÍVEL 0 (BYPASS):
        stu_pkg::SPEC_LEVEL_0_BYPASS: begin
          // Não faz nada.
        end
        
      endcase
    end
    
    // --- LÓGICA DOS ESTADOS L2 ---
    
    // Esperando a cópia do registrador terminar
    else if (state == L2_CONTEXT_COPY) begin
      l2_spec_task_active_out = 1'b1;
      
      // Se o Validator der SQUASH durante a cópia (ex: exceção), aborte.
      if (squash_in[l2_spec_core_reg]) begin
        next_state = IDLE;
        l2_spec_task_active_out = 1'b0;
        update_hpt = 1'b1;
        update_hpt_is_commit = 1'b0;
      end
      // Se a cópia terminou, avance e inicie a execução.
      else if (l2_context_copy_done_in) begin
        l2_spec_start_out = 1'b1; // Diga ao núcleo para EXECUTAR
        next_state = L2_SPEC_ACTIVE;
      end
    end
    
    // Agora estamos executando
    else if (state == L2_SPEC_ACTIVE) begin
      l2_spec_task_active_out = 1'b1;
      
      if (squash_in[l2_spec_core_reg]) begin
        next_state = IDLE;
        l2_spec_task_active_out = 1'b0;
        update_hpt = 1'b1;
        update_hpt_is_commit = 1'b0;
      end 
      else if (commit_in[l2_spec_core_reg]) begin
        next_state = IDLE;
        l2_spec_task_active_out = 1'b0;
        update_hpt = 1'b1;
        update_hpt_is_commit = 1'b1;
      end
    end

  end

endmodule
