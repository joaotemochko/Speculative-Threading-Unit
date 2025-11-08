`include "stu_pkg.sv"

`timescale 1ns/1ps

/**
 * @module stu_top
 * @brief O módulo de topo da STU (Unidade de Threading Especulativo).
 *
 * @details Este módulo instancia e conecta os 4 componentes principais:
 * 1. stu_safety_filter
 * 2. stu_fork_controller
 * 3. stu_memory_tracker
 * 4. stu_validator
 *
 * MODIFICAÇÃO (Linux): As interfaces foram atualizadas para
 * suportar Endereços Físicos (PAs), Exceções e Cópia de Contexto.
 */
module stu_top #(
  parameter int BLOCK_SIZE = 4,
  parameter int NUM_CORES_L1_SPLIT = 2,
  parameter int READ_SET_DEPTH = 16,
  parameter int HPT_DEPTH = 64
)(
  input  logic clk,
  input  logic rst,

  // --- Entradas do Front-End (VAs) ---
  input  stu_pkg::addr_t   pc_in,                  
  input  stu_pkg::instr_t  [BLOCK_SIZE-1:0] block_in, 
  input  logic             block_valid_in,         

  // --- Entradas dos Núcleos (Monitoramento) ---
  input  logic [stu_pkg::NUM_CORES-1:0] core_busy_in,
  
  // Barramento de Endereço Físico (PAs) (Pós-MMU)
  input  stu_pkg::addr_t   [stu_pkg::NUM_CORES-1:0] core_mem_pa_in, // NOVO
  input  logic             [stu_pkg::NUM_CORES-1:0] core_mem_is_store_in,
  input  logic             [stu_pkg::NUM_CORES-1:0] core_mem_valid_in,
  
  // Sinais de "Pronto" (dos núcleos)
  input  logic             master_task_done_in, 
  input  logic [stu_pkg::NUM_CORES-1:0] spec_task_done_in,
  
  // Sinais de Exceção (dos núcleos)
  input  logic [stu_pkg::NUM_CORES-1:0] spec_exception_in, // NOVO
  
  // Handshake de Cópia de Contexto
  input  logic             l2_context_copy_done_in, // NOVO

  // --- Saídas de Controle (Para os Núcleos/SoC) ---
  
  // Nível 1 (Conservador)
  output logic [stu_pkg::NUM_CORES-1:0] l1_dispatch_valid_out, 
  output stu_pkg::instr_t [stu_pkg::NUM_CORES-1:0]
                           [BLOCK_SIZE/NUM_CORES_L1_SPLIT-1:0] l1_dispatch_data_out,

  // Nível 2 (Otimista)
  output stu_pkg::addr_t     l2_spec_pc_out,        
  output stu_pkg::core_id_t  l2_spec_core_id_out,  
  output logic               l2_spec_start_out,    
  output logic               l2_context_copy_start_out, // NOVO
  
  // Saídas de Veredito (L2)
  output logic [stu_pkg::NUM_CORES-1:0] squash_out, 
  output logic [stu_pkg::NUM_CORES-1:0] commit_out
);

  // --- Fios Internos (Conectando os 4 Módulos) ---

  stu_pkg::spec_level_t spec_level;

  stu_pkg::core_id_t  master_core_id;
  stu_pkg::core_id_t  l2_spec_core_id;
  logic               l2_spec_task_active;

  logic               violation;

  logic [stu_pkg::NUM_CORES-1:0] squash_signals;
  logic [stu_pkg::NUM_CORES-1:0] commit_signals;

  // --- 1. O Diretor (Filtro de Segurança) ---
  // (Inalterado. Opera em VAs/Opcodes.)
  stu_safety_filter #(
    .BLOCK_SIZE(BLOCK_SIZE)
  ) u_filter (
    .clk(clk), .rst(rst),
    .block_in(block_in),
    .block_valid_in(block_valid_in),
    .spec_level_out(spec_level) 
  );

  // --- 2. O Cérebro (Controlador de Fork) ---
  // (Modificado com FSM de Cópia de Contexto)
  stu_fork_controller #(
    .BLOCK_SIZE(BLOCK_SIZE),
    .NUM_CORES_L1_SPLIT(NUM_CORES_L1_SPLIT),
    .HPT_DEPTH(HPT_DEPTH)
  ) u_forker (
    .clk(clk), .rst(rst),
    
    .pc_in(pc_in),
    .block_in(block_in),
    .block_valid_in(block_valid_in),
    .spec_level_in(spec_level), 
    .core_busy_in(core_busy_in),
    .squash_in(squash_signals), 
    .commit_in(commit_signals), 
    .l2_context_copy_done_in(l2_context_copy_done_in), // NOVO
    
    .master_core_id_out(master_core_id), 
    
    .l1_dispatch_valid_out(l1_dispatch_valid_out),
    .l1_dispatch_data_out(l1_dispatch_data_out),
    
    .l2_spec_core_id_out(l2_spec_core_id),     
    .l2_spec_pc_out(l2_spec_pc_out),           
    .l2_spec_start_out(l2_spec_start_out),     
    .l2_spec_task_active_out(l2_spec_task_active),
    .l2_context_copy_start_out(l2_context_copy_start_out) // NOVO
  );
  
  assign l2_spec_core_id_out = l2_spec_core_id;

  // --- 3. O Espião (Rastreador de Memória) ---
  // (Modificado para usar PAs)
  stu_memory_tracker #(
    .READ_SET_DEPTH(READ_SET_DEPTH)
  ) u_tracker (
    .clk(clk), .rst(rst),
    
    .l2_spec_task_active_in(l2_spec_task_active), 
    .master_core_id_in(master_core_id),         
    .l2_spec_core_id_in(l2_spec_core_id),       
    
    .core_mem_pa_in(core_mem_pa_in), // NOVO (usando PAs)
    .core_mem_is_store_in(core_mem_is_store_in),
    .core_mem_valid_in(core_mem_valid_in),
    
    .squash_in(squash_signals), 
    .commit_in(commit_signals), 
    
    .violation_out(violation) 
  );

  // --- 4. O Juiz (Validador) ---
  // (Modificado para tratar Exceções)
  stu_validator u_validator (
    .clk(clk), .rst(rst),
    
    .l2_spec_task_active_in(l2_spec_task_active),     
    .master_task_done_in(master_task_done_in),
    .spec_task_done_in(spec_task_done_in[l2_spec_core_id]), 
    .violation_in(violation),                         
    .l2_spec_exception_in(spec_exception_in[l2_spec_core_id]), // NOVO
    
    .squash_out(squash_signals[l2_spec_core_id]),
    .commit_out(commit_signals[l2_spec_core_id])
  );
  
  // Roteia os sinais de squash/commit para o mundo exterior
  assign squash_out = squash_signals;
  assign commit_out = commit_signals;

endmodule
