(* X86lite Simulator *)

(* See the documentation in the X86lite specification, available on the 
   course web pages, for a detailed explanation of the instruction
   semantics.
*)

open X86

(* simulator machine state -------------------------------------------------- *)

let mem_bot = 0x400000L          (* lowest valid address *)
let mem_top = 0x410000L          (* one past the last byte in memory *)
let mem_size = Int64.to_int (Int64.sub mem_top mem_bot)
let nregs = 17                   (* including Rip *)
let ins_size = 8L                (* assume we have a 8-byte encoding *)
let exit_addr = 0xfdeadL         (* halt when m.regs(%rip) = exit_addr *)

(* Your simulator should raise this exception if it tries to read from or
   store to an address not within the valid address space. *)
exception X86lite_segfault

(* The simulator memory maps addresses to symbolic bytes.  Symbolic
   bytes are either actual data indicated by the Byte constructor or
   'symbolic instructions' that take up four bytes for the purposes of
   layout.

   The symbolic bytes abstract away from the details of how
   instructions are represented in memory.  Each instruction takes
   exactly eight consecutive bytes, where the first byte InsB0 stores
   the actual instruction, and the next sevent bytes are InsFrag
   elements, which aren't valid data.

   For example, the two-instruction sequence:
        at&t syntax             ocaml syntax
      movq %rdi, (%rsp)       Movq,  [~%Rdi; Ind2 Rsp]
      decq %rdi               Decq,  [~%Rdi]

   is represented by the following elements of the mem array (starting
   at address 0x400000):

       0x400000 :  InsB0 (Movq,  [~%Rdi; Ind2 Rsp])
       0x400001 :  InsFrag
       0x400002 :  InsFrag
       0x400003 :  InsFrag
       0x400004 :  InsFrag
       0x400005 :  InsFrag
       0x400006 :  InsFrag
       0x400007 :  InsFrag
       0x400008 :  InsB0 (Decq,  [~%Rdi])
       0x40000A :  InsFrag
       0x40000B :  InsFrag
       0x40000C :  InsFrag
       0x40000D :  InsFrag
       0x40000E :  InsFrag
       0x40000F :  InsFrag
       0x400010 :  InsFrag
*)
type sbyte = InsB0 of ins       (* 1st byte of an instruction *)
           | InsFrag            (* 2nd - 7th bytes of an instruction *)
           | Byte of char       (* non-instruction byte *)

(* memory maps addresses to symbolic bytes *)
type mem = sbyte array

(* Flags for condition codes *)
type flags = { mutable fo : bool
             ; mutable fs : bool
             ; mutable fz : bool
             }

(* Register files *)
type regs = int64 array

(* Complete machine state *)
type mach = { flags : flags
            ; regs : regs
            ; mem : mem
            }

(* simulator helper functions ----------------------------------------------- *)

(* The index of a register in the regs array *)
let rind : reg -> int = function
  | Rip -> 16
  | Rax -> 0  | Rbx -> 1  | Rcx -> 2  | Rdx -> 3
  | Rsi -> 4  | Rdi -> 5  | Rbp -> 6  | Rsp -> 7
  | R08 -> 8  | R09 -> 9  | R10 -> 10 | R11 -> 11
  | R12 -> 12 | R13 -> 13 | R14 -> 14 | R15 -> 15

(* Helper functions for reading/writing sbytes *)

(* Convert an int64 to its sbyte representation *)
let sbytes_of_int64 (i:int64) : sbyte list =
  let open Char in 
  let open Int64 in
  List.map (fun n -> Byte (shift_right i n |> logand 0xffL |> to_int |> chr))
           [0; 8; 16; 24; 32; 40; 48; 56]

(* Convert an sbyte representation to an int64 *)
let int64_of_sbytes (bs:sbyte list) : int64 =
  let open Char in
  let open Int64 in
  let f b i = match b with
    | Byte c -> logor (shift_left i 8) (c |> code |> of_int)
    | _ -> 0L
  in
  List.fold_right f bs 0L

(* Convert a string to its sbyte representation *)
let sbytes_of_string (s:string) : sbyte list =
  let rec loop acc = function
    | i when i < 0 -> acc
    | i -> loop (Byte s.[i]::acc) (pred i)
  in
  loop [Byte '\x00'] @@ String.length s - 1

(* Serialize an instruction to sbytes *)
let sbytes_of_ins (op, args:ins) : sbyte list =
  let check = function
    | Imm (Lbl _) | Ind1 (Lbl _) | Ind3 (Lbl _, _) -> 
      invalid_arg "sbytes_of_ins: tried to serialize a label!"
    | o -> ()
  in
  List.iter check args;
  [InsB0 (op, args); InsFrag; InsFrag; InsFrag; InsFrag; InsFrag; InsFrag; InsFrag]

(* Serialize a data element to sbytes *)
let sbytes_of_data : data -> sbyte list = function
  | Quad (Lit i) -> sbytes_of_int64 i
  | Asciz s -> sbytes_of_string s
  | Quad (Lbl _) -> invalid_arg "sbytes_of_data: tried to serialize a label!"


(* It might be useful to toggle printing of intermediate states of your 
   simulator. *)
let debug_simulator = ref true

(* Interpret a condition code with respect to the given flags. *)
let interp_cnd {fo; fs; fz} : cnd -> bool = function
  | Eq -> if fz then true else false
  | Neq -> if not fz then true else false
  | Lt -> if fs <> fo then true else false
  | Le -> if (fs <> fo) || fz then true else false
  | Gt -> if (fs = fo) && (not fz) then true else false
  | Ge -> if (fs = fo) then true else false


(* Maps an X86lite address into Some OCaml array index,
   or None if the address is not within the legal address space. *)
let map_addr (addr:quad) : int option =
  if (addr < mem_bot) || (addr > mem_top) then None
  else Some ((Int64.to_int addr) - (Int64.to_int mem_bot))




let mem_read (m:mem) (addr:quad) : int64 =
  let addr_map = map_addr addr in
  begin match addr_map with
    |Some x -> int64_of_sbytes (Array.to_list (Array.sub m x 8))
    |None -> raise X86lite_segfault
  end
        
    (*    let check = function
    | Some x ->  x
    | None -> raise X86lite_segfault
  in 
  let read_quad = 
    Array.get m (check (map_addr addr)) 
  in
  int64_of_sbytes (Array.to_list read_quad)*)

let interpret_operand (m:mach) (op:operand) : int64 =      
  begin match op with
    | Imm (Lit x) -> x 
    | Reg x -> Array.get m.regs (rind x)
    | Ind1 (Lit x) -> mem_read m.mem x
    | Ind2 x -> mem_read m.mem (Array.get m.regs (rind x))
    | Ind3 (Lit offset, reg) -> mem_read m.mem (Int64.add (Array.get m.regs (rind reg)) offset )
    | _ -> invalid_arg "interpret_operand: tried to interpret a lable!"
  end




(* Simulates one step of the machine:
    - fetch the instruction at %rip
    - compute the source and/or destination information from the operands
    - simulate the instruction semantics
    - update the registers and/or memory appropriately
    - set the condition flags
*)
  
              
let set_flags (m:mach) (res:Int64_overflow.t) = 
  m.flags.fo <- res.Int64_overflow.overflow;
  m.flags.fs <- (res.Int64_overflow.value < 0L);
  m.flags.fz <- (res.Int64_overflow.value = 0L)

let set_flags_log (m:mach) (res:int64) =
  m.flags.fo <- false;
  m.flags.fs <- res < Int64.zero;
  m.flags.fz <- res = Int64.zero

      
let get_rip (m:mach) : ins =         
  let rip = map_addr(Array.get m.regs (rind Rip))
  in begin match rip with
    |Some x -> let sbytes = Array.get m.mem x
    in begin match sbytes with
      |InsB0 ins -> ins
      |InsFrag -> invalid_arg "rip not an instruction"
      |Byte byte -> invalid_arg "rip not an instruction"
    end
    |None -> invalid_arg "rip not in address space"
  end


(*Update all 8 bytes of a memory location, otherwise the result will be wrong.*)
let write_mem (m:mach) (dest:int64) (value:int64) = 
  let dest = map_addr dest in
  let data = sbytes_of_int64 value in 
  begin match dest with
    |Some dest -> 
      m.mem.(dest) <- List.nth data 0;
      m.mem.(dest + 1) <- List.nth data 1;
      m.mem.(dest + 2) <- List.nth data 2;      
      m.mem.(dest + 3) <- List.nth data 3;                           
      m.mem.(dest + 4) <- List.nth data 4;
      m.mem.(dest + 5) <- List.nth data 5;
      m.mem.(dest + 6) <- List.nth data 6;
      m.mem.(dest + 7) <- List.nth data 7;
    |None -> invalid_arg "Address not in memory";
  end

let write_res (m:mach) (dest:operand) (value:int64) = 
  begin match dest with
    |Reg x -> m.regs.(rind x) <- value
    |Ind1 (Lit x) -> write_mem m x value
    |Ind2 x -> write_mem m m.regs.(rind x) value
    |Ind3 ((Lit off), reg) -> write_mem m (Int64.add m.regs.(rind reg) off) value
    |_ -> invalid_arg "can not write to this address"
  end
 
let increment_rip (m:mach) = 
  let rip = m.regs.(rind Rip)
  in let new_rip = Int64.add rip 8L
  in m.regs.(rind Rip) <- new_rip

let sim_bin_op (m:mach) (op:opcode) (src:operand) (dest:operand) = 
  let src_int = interpret_operand m src in
  let dest_int = interpret_operand m dest in 
  begin match op with
    |Movq -> let res = src_int in write_res m dest res; increment_rip m 
    |Addq -> let res = Int64_overflow.add dest_int src_int in write_res m dest res.value; 
      increment_rip m; set_flags m res
    |Subq -> let res = Int64_overflow.sub dest_int src_int in write_res m dest res.value; 
      increment_rip m; set_flags m res
    |Xorq -> let res = Int64.logxor src_int dest_int in write_res m dest res; 
      increment_rip m; set_flags_log m res
    |Orq -> let res = Int64.logor src_int dest_int in write_res m dest res; 
      increment_rip m; set_flags_log m res
    |Andq -> let res = Int64.logand src_int dest_int in write_res m dest res; 
      increment_rip m; set_flags_log m res
    |Imulq -> let res = Int64_overflow.mul src_int dest_int in write_res m dest res.value; 
      increment_rip m; set_flags m res
    |Shlq -> let res = Int64.shift_left dest_int (Int64.to_int src_int) in write_res m dest res; 
      increment_rip m; set_flags_log m res
    |Sarq -> let res = Int64.shift_right dest_int (Int64.to_int src_int) in write_res m dest res;
      increment_rip m; set_flags_log m res
    |Shrq -> let res = Int64.shift_right_logical dest_int (Int64.to_int src_int) in write_res m dest res;
      increment_rip m; set_flags_log m res
    |Leaq -> write_res m dest src_int; increment_rip m
    |Cmpq -> let res = Int64_overflow.sub dest_int src_int in increment_rip; set_flags m res
    |_ -> failwith "Not yet implemented"
  end

let decrement_rsp (m:mach) =
  let rsp = m.regs.(rind Rsp) in
  let new_rsp = Int64.sub rsp 8L in 
  m.regs.(rind Rsp) <- new_rsp

let increment_rsp (m:mach) = 
  let rsp = m.regs.(rind Rsp) in 
  let new_rsp = Int64.add rsp 8L in
  m.regs.(rind Rsp) <- new_rsp

 
let sim_un_op (m:mach) (op:opcode) (src:operand) =
  let src_int = interpret_operand m src in
  begin match op with
    |Incq -> let res = Int64_overflow.add src_int 1L in write_res m src res.value; 
      increment_rip m; set_flags m res
    |Decq -> let res = Int64_overflow.sub src_int 1L in write_res m src res.value; 
      increment_rip m; set_flags m res
    |Negq -> let res = Int64_overflow.neg src_int in write_res m src res.value; 
      increment_rip m; set_flags m res
    |Notq -> let res = Int64.lognot src_int in write_res m src res; 
      increment_rip m; set_flags_log m res
    |Pushq -> decrement_rsp m; write_res m (Ind2 Rsp) src_int; increment_rip m 
    |Popq -> write_res m src (interpret_operand m (Ind2 Rsp)); increment_rsp m; increment_rip m
    |Jmp -> m.regs.(rind Rip) <- src_int
    |_ -> failwith "wrong opcode"
  end

let step (m:mach) : unit = 
  let rip = get_rip m in
  begin match rip with
    |(Movq, src::dest::_) -> sim_bin_op m Movq src dest
    |(Pushq, src::_) -> sim_un_op m Pushq src
    |(Popq, dest::_) -> sim_un_op m Popq dest
    |(Leaq, ind::dest::_) -> sim_bin_op m Leaq ind dest 
    |(Incq, src::_) -> sim_un_op m Incq src
    |(Decq, src::_) -> sim_un_op m Decq src
    |(Negq, dest::_) -> sim_un_op m Negq dest
    |(Notq, dest::_) -> sim_un_op m Notq dest
    |(Addq, src::dest::_) -> sim_bin_op m Addq src dest
    |(Subq, src::dest::_) -> sim_bin_op m Subq src dest
    |(Imulq, src::reg::_) -> sim_bin_op m Imulq src reg
    |(Xorq, src::dest::_) -> sim_bin_op m Xorq src dest
    |(Orq, src::dest::_) -> sim_bin_op m Orq src dest
    |(Andq, src::dest::_) -> sim_bin_op m Andq src dest
    |(Shlq, amt::dest::_) -> sim_bin_op m Shlq amt dest
    |(Sarq, amt::dest::_) -> sim_bin_op m Sarq amt dest
    |(Shrq, amt::dest::_) -> sim_bin_op m Shrq amt dest
    |(Jmp, src::_) -> sim_un_op m Jmp src
    |(J cc, src::_) -> if (interp_cnd m.flags cc) then (sim_un_op m Jmp src) else (increment_rip m)
    |(Cmpq, src1::src2::_) -> sim_bin_op m Cmpq src1 src2
    |(Set cc, dest::_) -> Printf.printf "Set"
    |(Callq, src::_) -> sim_un_op m Pushq (Reg Rip); sim_un_op m Jmp src
    |(Retq, _) -> sim_un_op m Popq (Reg Rip) 
    |_ -> invalid_arg "rip not an instruction"
  end

(* Runs the machine until the rip register reaches a designated
   memory address. *)
let run (m:mach) : int64 = 
  while m.regs.(rind Rip) <> exit_addr do step m done;
  m.regs.(rind Rax)

(* assembling and linking --------------------------------------------------- *)

(* A representation of the executable *)
type exec = { entry    : quad              (* address of the entry point *)
            ; text_pos : quad              (* starting address of the code *)
            ; data_pos : quad              (* starting address of the data *)
            ; text_seg : sbyte list        (* contents of the text segment *)
            ; data_seg : sbyte list        (* contents of the data segment *)
            }

(* Assemble should raise this when a label is used but not defined *)
exception Undefined_sym of lbl

(* Assemble should raise this when a label is defined more than once *)
exception Redefined_sym of lbl

(* Convert an X86 program into an object file:
   - separate the text and data segments
   - compute the size of each segment
      Note: the size of an Asciz string section is (1 + the string length)

   - resolve the labels to concrete addresses and 'patch' the instructions to 
     replace Lbl values with the corresponding Imm values.

   - the text segment starts at the lowest address
   - the data segment starts after the text segment

  HINT: List.fold_left and List.fold_right are your friends.
 *)
let assemble (p:prog) : exec =
failwith "assemble unimplemented"

(* Convert an object file into an executable machine state. 
    - allocate the mem array
    - set up the memory state by writing the symbolic bytes to the 
      appropriate locations 
    - create the inital register state
      - initialize rip to the entry point address
      - initializes rsp to the last word in memory 
      - the other registers are initialized to 0
    - the condition code flags start as 'false'

  Hint: The Array.make, Array.blit, and Array.of_list library functions 
  may be of use.
*)
let load {entry; text_pos; data_pos; text_seg; data_seg} : mach = 
failwith "load unimplemented"
