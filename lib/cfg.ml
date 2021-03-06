type symbol =
  | T of string (* terminal symbol *)
  | N of string (* nonterminal symbol *)
  | Epsilon (* empty string *)
  | EOF (* eof mark *)

type production = (symbol * symbol list) list
type grammar = (string * string list) list

type cfg =
  { nts : symbol list
  ; ts : symbol list
  ; start : symbol
  ; prods : production
  }

module Symbol = struct
  type t = symbol

  let key s =
    match s with
    | T s -> "T" ^ s
    | N s -> "N" ^ s
    | Epsilon -> "ε"
    | EOF -> "$"
  ;;

  let compare s1 s2 = Stdlib.compare (key s1) (key s2)
end

module SymbolMap = Map.Make (Symbol)
module SymbolSet = Set.Make (Symbol)

let isNT = function
  | N _ -> true
  | _ -> false
;;

let isT = function
  | T _ | EOF -> true
  | _ -> false
;;

let ( ==> ) a b = a, [ b ]
let ( ||| ) (a, b) c = a, b @ [ c ]

(* [cfg_of_grammar cfg] return the [cfg] records of the grammar *)
let cfg_of_grammar (grammar : grammar) (entry : string) =
  let open List in
  let nts_str_list = map (fun x -> fst x |> String.trim) grammar in
  let ts_str_list =
    grammar
    |> concat_map (fun x -> x |> snd |> concat_map (String.split_on_char ' '))
    |> map String.trim
    |> filter (fun x -> String.empty <> x)
    |> sort_uniq Stdlib.compare
    |> filter (fun x -> not (mem x nts_str_list))
  in
  let symbol_of_string = function
    | "" -> Epsilon
    | "<<EOF>>" -> EOF
    | s when mem s nts_str_list -> N s
    | s when mem s ts_str_list -> T s
    | _ -> failwith "unknown symbol"
  in
  let symbol_list_of_string_list = map symbol_of_string in
  let symbol_list_of_string s =
    String.split_on_char ' ' s |> symbol_list_of_string_list
  in
  { nts = map (fun x -> N x) nts_str_list
  ; ts = map (fun x -> T x) ts_str_list
  ; start = N entry
  ; prods =
      grammar
      |> concat_map (fun (lhs, rhs) -> map (fun x -> N lhs, symbol_list_of_string x) rhs)
  }
;;

let groupby (f : 'a -> 'b) (l : 'a list) : ('b * 'a list) list =
  let open List in
  l
  |> fold_left
       (fun acc item ->
         let key = f item in
         if mem_assoc key acc
         then (
           let l = assoc key acc in
           let l' = cons item l in
           remove_assoc key acc |> cons (key, l'))
         else cons (key, [ item ]) acc)
       []
  |> rev
;;

let string_of_symbol = function
  | N s -> s
  | T s -> s
  | Epsilon -> "ε"
  | EOF -> "$"
;;

let string_of_symbol_list (l : symbol list) =
  l |> List.map string_of_symbol |> String.concat " "
;;

let string_of_cfg { nts = _; ts = _; start; prods } =
  prods
  |> groupby fst
  |> List.map (fun (lhs, rhs) ->
         let left = (if lhs = start then "*" else "") ^ string_of_symbol lhs in
         let left_len = String.length left in
         left
         ^ " ::= "
         ^ (rhs
           |> List.map (fun x -> string_of_symbol_list @@ snd x)
           |> fun l ->
           let indent = String.init left_len (Fun.const ' ') in
           match l with
           | [] -> failwith "body could not be empty"
           | h :: t -> List.fold_left (fun acc x -> acc ^ "\n" ^ indent ^ " |   " ^ x) h t
           ))
  |> List.fast_sort Stdlib.compare
  |> String.concat "\n"
;;

let string_of_a_prod prod =
  let s, l = prod in
  let lhs = string_of_symbol s in
  let rhs = string_of_symbol_list l in
  lhs ^ " 🠖 " ^ rhs
;;

let new_name sym nts =
  let name = ref (string_of_symbol sym) in
  while List.mem (N !name) nts do
    name := !name ^ "_"
  done;
  !name
;;

let has_left_recur sym bodys = List.exists (fun x -> List.hd x = sym) bodys

let eliminate_direct_left_recursion sym bodys nts =
  let open List in
  let recur, non_recur = partition (fun x -> hd x = sym) bodys in
  let new_name = new_name sym nts in
  let replaced_recur = map (fun x -> tl x @ [ N new_name ]) recur @ [ [ Epsilon ] ] in
  let replaced_nonrecur = map (fun x -> x @ [ N new_name ]) non_recur in
  new_name, replaced_recur, replaced_nonrecur
;;

let eliminate_left_recur { nts; ts; start; prods } =
  let open List in
  let nts = ref nts in
  let bodys = ref (prods |> groupby fst |> map (fun x -> fst x, map snd (snd x))) in
  let n = length !bodys in
  for i = 0 to n - 1 do
    let ai, ai_prods = nth !bodys i in
    let ai_prods_ref = ref ai_prods in
    for j = 0 to i - 1 do
      let aj, aj_prods = nth !bodys j in
      let recur, non_recur = ai_prods |> partition (fun x -> hd x = aj) in
      let replaced =
        recur
        |> map tl
        |> concat_map (fun t ->
               map (fun x -> if x = [ Epsilon ] then t else x @ t) aj_prods)
      in
      ai_prods_ref := replaced @ non_recur
    done;
    if has_left_recur ai !ai_prods_ref
    then (
      let new_name, replaced_recur, replaced_nonrecur =
        eliminate_direct_left_recursion ai !ai_prods_ref !nts
      in
      nts := cons (N new_name) !nts;
      bodys
        := !bodys
           |> mapi (fun k item -> if i = k then ai, replaced_nonrecur else item)
           |> fun x -> append x [ N new_name, replaced_recur ])
    else bodys := !bodys |> mapi (fun k item -> if i = k then ai, !ai_prods_ref else item)
  done;
  let prods =
    !bodys (* symbol * symbol list list *)
    |> map (fun (sym, sym_list_list) ->
           sym_list_list |> map (fun sym_list -> sym, sym_list))
    |> concat
    (* (symbol * symbol list) list *)
  in
  { nts = !nts; ts; start; prods }
;;

let string_of_symbol_set sym_set =
  "{ "
  ^ (sym_set |> SymbolSet.elements |> List.map string_of_symbol |> String.concat ", ")
  ^ " }"
;;

let print_set prompt set =
  set
  |> SymbolMap.iter (fun sym sym_set ->
         print_string @@ prompt ^ "(" ^ string_of_symbol sym ^ ")";
         print_string "= ";
         print_string @@ string_of_symbol_set sym_set;
         print_newline ())
;;

let print_first_set = print_set "First"
let print_follow_set = print_set "Follow"

(* [first cfg] return the first set of [cfg].
     require: [cfg] is LL(1)
  *)
let first cfg =
  let open List in
  let first = ref SymbolMap.empty in
  let makeSet l = SymbolSet.(empty |> add_seq (List.to_seq l)) in
  cfg.ts @ [ EOF; Epsilon ]
  |> iter (fun ts -> first := SymbolMap.(!first |> add ts @@ makeSet [ ts ]));
  cfg.nts |> iter (fun nt -> first := SymbolMap.(!first |> add nt @@ makeSet []));
  let changing = ref true in
  while !changing do
    changing := false;
    cfg.prods
    |> iter (fun (symbol, prod) ->
           let rhs =
             ref SymbolMap.(!first |> find (hd prod) |> SymbolSet.remove Epsilon)
           in
           let k = length prod in
           let break = ref false in
           let j = ref 1 in
           while !j < k && not !break do
             let b_j_1 = SymbolMap.(!first |> find (nth prod (!j - 1))) in
             let bj = SymbolMap.(!first |> find (nth prod !j)) in
             if SymbolSet.mem Epsilon b_j_1
             then rhs := SymbolSet.(union !rhs (bj |> remove Epsilon))
             else break := true;
             j := !j + 1
           done;
           let bk = SymbolMap.(!first |> find @@ nth prod (k - 1)) in
           if !j = k && SymbolSet.mem Epsilon bk then rhs := !rhs |> SymbolSet.add Epsilon;
           let first_a = !first |> SymbolMap.find symbol in
           let old_size = SymbolSet.cardinal first_a in
           let first_a = SymbolSet.union first_a !rhs in
           let new_size = SymbolSet.cardinal first_a in
           first := !first |> SymbolMap.add symbol first_a;
           changing := !changing || old_size <> new_size)
  done;
  !first
;;

let follow first cfg =
  let open List in
  let follow =
    ref
      SymbolMap.(
        empty
        |> add_seq
             (cfg.nts
             |> List.map (fun nt ->
                    if nt = cfg.start
                    then nt, SymbolSet.(empty |> add EOF)
                    else nt, SymbolSet.empty)
             |> List.to_seq))
  in
  let changing = ref true in
  while !changing do
    changing := false;
    cfg.prods
    |> List.iter (fun (a, prod) ->
           let trailer = ref (!follow |> SymbolMap.find a) in
           prod
           |> List.rev
           |> List.iter (fun b ->
                  match mem b cfg.nts with
                  | true ->
                    let old_set = !follow |> SymbolMap.find b in
                    let new_set = SymbolSet.union old_set !trailer in
                    follow := !follow |> SymbolMap.add b new_set;
                    changing
                      := !changing
                         || SymbolSet.cardinal old_set <> SymbolSet.cardinal new_set;
                    let first_b = SymbolMap.find b first in
                    if SymbolSet.mem Epsilon first_b
                    then trailer := SymbolSet.(union !trailer first_b |> remove Epsilon)
                    else trailer := first_b
                  | _ -> trailer := SymbolSet.(empty |> add b)))
  done;
  !follow
;;

let first_of_prod first l =
  let rec first_of_prod_help acc_set have_Ep = function
    | [] -> if have_Ep then acc_set else SymbolSet.remove Epsilon acc_set
    | x :: xs ->
      let first_of_x = SymbolMap.find x first in
      let x_has_Ep = SymbolSet.mem Epsilon first_of_x in
      if have_Ep
      then
        first_of_prod_help (SymbolSet.union first_of_x acc_set) (have_Ep && x_has_Ep) xs
      else SymbolSet.remove Epsilon acc_set
  in
  first_of_prod_help SymbolSet.empty true l
;;

module SymbolTuple = struct
  type t = symbol * symbol

  let compare (s1, s1') (s2, s2') =
    match Stdlib.compare (Symbol.key s1) (Symbol.key s2) with
    | 0 -> Stdlib.compare (Symbol.key s1') (Symbol.key s2')
    | i -> i
  ;;
end

module SymbolTupleMap = Map.Make (SymbolTuple)

(* [pred_analysis_tb cfg first follow] return the predict analysis table
   of the [cfg]
   require: [cfg] is LL
 *)
let pred_analysis_tb cfg first follow =
  let rec helper l acc =
    match l with
    | [] -> acc
    | (head, body) :: xs ->
      let frp = first_of_prod first body in
      let flp = SymbolMap.find head follow in
      let add_producion set acc =
        acc
        |> SymbolTupleMap.add_seq
             (set
             |> SymbolSet.to_seq
             |> Seq.filter isT
             |> Seq.map (fun s ->
                    ( (head, s)
                    , match SymbolTupleMap.find_opt (head, s) acc with
                      | Some l -> (head, body) :: l
                      | None -> [ head, body ] )))
      in
      helper
        xs
        (acc
        |> add_producion frp
        |>
        if SymbolSet.mem Epsilon frp
        then add_producion flp
        else add_producion SymbolSet.empty)
  in
  helper cfg.prods SymbolTupleMap.empty
;;

let surround_with tag attr x =
  match x with
  | "" -> "<" ^ tag ^ " " ^ attr ^ "/>\n"
  | _ -> "<" ^ tag ^ " " ^ attr ^ ">" ^ x ^ "</" ^ tag ^ ">\n"
;;

let string_of_predict_analysis_tb cfg tb =
  let head_sym = cfg.ts @ [ EOF ] in
  let th_el = surround_with "th" "style=\"border: 1px black solid;\"" in
  let td_el = surround_with "td" "style=\"border: 1px black solid;\"" in
  let tr_el = surround_with "tr" "style=\"border: 1px black solid;\"" in
  let tb_el = surround_with "table" "style=\"border: 1px black solid;\"" in
  let ( << ) f g x = x |> g |> f in
  let ( >> ) f g = g << f in
  let open List in
  let head =
    td_el "" ^ (head_sym |> map (string_of_symbol >> th_el) |> String.concat "\n")
    |> tr_el
  in
  let content =
    cfg.nts
    |> map (fun nt ->
           head_sym
           |> map (fun t ->
                  (match SymbolTupleMap.find_opt (nt, t) tb with
                  | Some p -> p |> map string_of_a_prod |> String.concat "</br>"
                  | _ -> "")
                  |> surround_with "td" "style=\"border: 1px black solid;\"")
           |> cons
                (surround_with
                   "td"
                   "style=\"border: 1px black solid;\""
                   (string_of_symbol nt))
           |> String.concat "\n"
           |> surround_with "tr" "style=\"border: 1px black solid;\"")
    |> String.concat "\n"
  in
  head ^ content |> tb_el
;;
