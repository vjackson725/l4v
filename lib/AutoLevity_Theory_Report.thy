(*
 * Copyright 2014, NICTA
 *
 * This software may be distributed and modified according to the terms of
 * the BSD 2-Clause license. Note that NO WARRANTY is provided.
 * See "LICENSE_BSD2.txt" for details.
 *
 * @TAG(NICTA_BSD)
 * 
 * Report generating for autolevity. Computes proof start/end ranges, tracks levity tags
 * and reports on lemma, const, type and theory dependencies.
 *)

theory AutoLevity_Theory_Report
imports AutoLevity_Base
begin
ML \<open>

val _ = Theory.setup(
ML_Antiquotation.inline @{binding string_record}
  (Scan.lift
    (Parse.name --|
      Parse.$$$ "=" --
      Parse.position Parse.string) >>
    (fn (name,(source,pos)) =>

    let

      val entries =
      let
        val chars = String.explode source
          |> filter_out (fn #"\n" => true | _ => false)

        val trim =
        String.explode
        #> take_prefix (fn #" " => true | _ => false)
        #> snd
        #> take_suffix (fn #" " => true | _ => false)
        #> fst
        #> String.implode

        val str = String.implode chars
          |> String.fields (fn #"," => true | #":" => true | _ => false)
          |> map trim


        fun pairify [] = []
          | pairify (a::b::l) = ((a,b) :: pairify l)
          | pairify _  = error ("Record syntax error" ^ Position.here pos)

      in
        pairify str
      end

      val typedecl =
      "type " ^ name ^ "= { "
      ^ (map (fn (nm,typ) => nm ^ ":" ^ typ) entries |> String.concatWith ",")
      ^ "};"

      val base_typs = ["string","int","bool", "string list"]


      val encodes = map snd entries |> distinct (op =)
        |> filter_out (member (op =) base_typs)

      val sanitize = String.explode
      #> map (fn #" " => #"_"
                | #"." => #"_"
                | #"*" => #"P"
                | #"(" => #"B"
                | #")" => #"R"
                | x => x)
      #> String.implode

      fun mk_encode typ =
      if typ = "string" 
      then "(fn s => quote (String.translate (fn #\"\\n\" => \"\\\\n\" | x => String.str x) s))"
      else if typ = "int"
      then "Int.toString"
      else if typ = "bool"
      then "Bool.toString"
      else if typ = "string list"
      then "(fn xs => (enclose \"[\" \"]\" (String.concatWith \", \" (map quote xs))))"
       else  (sanitize typ) ^ "_encode"


      fun mk_elem nm _ value =
        (ML_Syntax.print_string nm ^ "^ \" : \" ") ^ "^ (" ^ value ^ ")"

      fun mk_head body =
        "(\"" ^ "{\" ^ String.concatWith \", \" (" ^  body ^ ") ^ \"}\")"


      val global_head = if (null encodes) then "" else
      "fn (" ^ (map mk_encode encodes |> String.concatWith ",") ^ ") => "


      val encode_body =
        "fn {" ^ (map fst entries |> String.concatWith ",") ^ "} : " ^ name ^ " => " ^
        mk_head
        (ML_Syntax.print_list (fn (field,typ) => mk_elem field typ (mk_encode typ ^ " " ^ field)) entries)


      val val_expr =
      "val (" ^  name ^ "_encode) = ("
        ^ global_head ^ "(" ^ encode_body ^ "))"

      val _ = @{print} val_expr

    in
      typedecl  ^ val_expr
    end)))
\<close>

ML \<open>

@{string_record deps = "const_deps : string list, type_deps: string list"}
@{string_record location = "file : string, start_line : int, end_line : int"}
@{string_record levity_tag = "tag : string, location : location"}

@{string_record proof_command = 
  "command_name : string, location : location, subgoals : int, depth : int" }

@{string_record lemma_entry = 
  "name : string, command_name : string, levity_tag : levity_tag option, location : location,
   proof_commands : proof_command list,
   lemma_deps : string list, deps : deps"}

@{string_record dep_entry =
  "name : string, command_name : string, levity_tag : levity_tag option, location: location,
   deps : deps"}

@{string_record theory_entry =
  "name : string, file : string"}

fun encode_list enc x = "[" ^ (String.concatWith ", " (map enc x)) ^ "]"

fun encode_option enc (SOME x) = enc x
  | encode_option _ NONE = "{}"

val opt_levity_tag_encode = encode_option (levity_tag_encode location_encode);

val proof_command_encode = proof_command_encode (location_encode);

val lemma_entry_encode = lemma_entry_encode 
  (opt_levity_tag_encode, location_encode, encode_list proof_command_encode, deps_encode)

val dep_entry_encode = dep_entry_encode 
  (opt_levity_tag_encode, location_encode, deps_encode)

\<close>

ML \<open>

signature AUTOLEVITY_THEORY_REPORT =
sig
val get_reports_for_thy: theory -> 
  string * theory_entry list * lemma_entry list * dep_entry list * dep_entry list

val string_reports_of:
  string * theory_entry list * lemma_entry list * dep_entry list * dep_entry list
  -> string list

val setup_theory_hook: theory -> theory

  
end;

structure AutoLevity_Theory_Report : AUTOLEVITY_THEORY_REPORT =
struct

fun thms_of (PBody {thms,...}) = thms

fun proof_body_descend' f (ident,(nm,_,body)) deptab =
if f nm then
  ((fold (proof_body_descend' f) (thms_of (Future.join body)) 
    (Inttab.update_new (ident, NONE) deptab)) handle Inttab.DUP _ => deptab)
else
  (Inttab.update_new (ident, SOME nm) deptab handle Inttab.DUP _ => deptab)

fun used_facts' f thm =
  let
    val body = thms_of (Thm.proof_body_of thm)
  in fold (proof_body_descend' f) body Inttab.empty end

fun used_facts f thm =
  let
    val nm = Thm.get_name_hint thm
  in
    used_facts' (fn nm' => nm' = "" orelse nm' = nm orelse f nm) thm
    |> Inttab.dest |> map_filter snd
  end       

fun location_from_range (start_pos, end_pos) =
  let
    val start_file = Position.file_of start_pos |> the;
    val end_file = Position.file_of end_pos |> the;
    val _ = if start_file = end_file then () else raise Option;
    val start_line = Position.line_of start_pos |> the;
    val end_line = Position.line_of end_pos |> the;
  in
  SOME ({file = start_file, start_line = start_line, end_line = end_line} : location) end
  handle Option => NONE

fun get_command_ranges_of keywords thy_nm =
let
  fun is_ignored nm' = nm' = "<ignored>"
  fun is_levity_tag nm' = nm' = "levity_tag"

  val transactions =
          Symtab.lookup (AutoLevity_Base.get_transactions ()) thy_nm 
          |> the_default Postab_strict.empty
          |> Postab_strict.dest

  fun find_cmd_end last_pos ((pos', (nm', ext)) :: rest) =
    if is_ignored nm' then
       find_cmd_end pos' rest
    else (last_pos, ((pos', (nm', ext)) :: rest))
    | find_cmd_end last_pos [] = (last_pos, [])

  fun change_level nm level = 
    if Keyword.is_proof_open keywords nm then level + 1
    else if Keyword.is_proof_close keywords nm then level - 1
    else if Keyword.is_qed_global keywords nm then ~1
    else level

  
  fun find_proof_end level ((pos', (nm', ext)) :: rest) =
    let val level' = change_level nm' level in
     if level' > ~1 then
       let
         val (cmd_end, rest') = find_cmd_end pos' rest;
         val ((prf_cmds, prf_end), rest'') = find_proof_end level' rest'
       in (({command_name = nm', location = location_from_range (pos', cmd_end) |> the,
            depth = level,
            subgoals = #subgoals ext} :: prf_cmds, prf_end), rest'') end
     else
       let
         val (cmd_end, rest') = find_cmd_end pos' rest;
        in (([{command_name = nm', location = location_from_range (pos', cmd_end) |> the,
            depth = level, subgoals = #subgoals ext}], cmd_end), rest') end
     end
     | find_proof_end _ _ = (([], Position.none), [])


  fun find_ends tab tag ((pos,(nm, ext)) :: rest) = 
   let
     val (cmd_end, rest') = find_cmd_end pos rest;

     val ((prf_cmds, pos'), rest'') = 
       if Keyword.is_theory_goal keywords nm
       then find_proof_end 0 rest'
       else (([],cmd_end),rest');

     val tab' = Postab.cons_list (pos, (pos, nm, pos', tag, prf_cmds)) tab;

     val tag' = 
       if is_levity_tag nm then Option.map (rpair (pos,pos')) (#levity_tag ext) else NONE;

   in find_ends tab' tag' rest'' end
     | find_ends tab _ [] = tab

in find_ends Postab.empty NONE transactions end

fun cmd_entries_ord ((start_pos, _, _, _, _), (start_pos', _, _, _, _)) = 
  (pos_ord true (start_pos, start_pos'))

fun base_name_of nm = 
  let
    val (idx, rest) = space_explode "_" nm |> rev |> List.getItem |> the;
    val _ = Int.fromString idx |> the;
  in rest |> rev |> space_implode "_" end handle Option => nm

fun map_pos_line f pos =
let
  val line = Position.line_of pos |> the;
  val file = Position.file_of pos |> the;

  val line' = f line;

  val _ = if line' < 1 then raise Option else ();
  
in SOME (Position.line_file_only line' file) end handle Option => NONE

fun search_backwards f pos = 
  case f pos of 
   SOME x => SOME x
  | NONE => 
    (case (map_pos_line (fn i => i - 1) pos) of 
      SOME pos' => search_backwards f pos'
     | NONE => NONE)
  
fun make_deps (const_deps, type_deps) = 
  ({const_deps = distinct (op =) const_deps, type_deps = distinct (op =) type_deps} : deps)

fun make_tag (SOME (tag, range)) = (case location_from_range range 
  of SOME rng => SOME ({tag = tag, location = rng} : levity_tag)
  | NONE => NONE)
  | make_tag NONE = NONE



fun add_deps (((Defs.Const, nm), _) :: rest) = 
  let val (consts, types) = add_deps rest in
    (nm :: consts, types) end
  | add_deps (((Defs.Type, nm), _) :: rest) =
  let val (consts, types) = add_deps rest in
    (consts, nm :: types) end
  | add_deps _ = ([], [])

fun get_deps ({rhs, ...} : Defs.spec) = (add_deps rhs);

fun typs_of_typ (Type (nm, Ts)) = nm :: (map typs_of_typ Ts |> flat)
  | typs_of_typ _ = []

fun typs_of_term t = Term.fold_types (append o typs_of_typ) t []

fun deps_of_thm thm =
let                             
  val consts = Term.add_const_names (Thm.prop_of thm) [];
  val types = typs_of_term (Thm.prop_of thm);
in (consts, types) end

fun file_of_thy thy =
  let
    val path = Resources.master_directory thy;
    val name = Context.theory_name thy;
    val path' = Path.append path (Path.basic (name ^ ".thy"))
  in Path.smart_implode path' end;

fun entry_of_thy thy = ({name = Context.theory_name thy, file = file_of_thy thy} : theory_entry)

fun get_reports_for_thy thy =
  let
    val thy_nm = Context.theory_name thy;
    val all_facts = Global_Theory.facts_of thy;
    val fact_space = Facts.space_of all_facts;

    val tab = get_command_ranges_of (Thy_Header.get_keywords thy) thy_nm;

    val parent_facts = map Global_Theory.facts_of (Theory.parents_of thy);

    val lemmas =  Facts.dest_static false parent_facts (Global_Theory.facts_of thy)
    |> map_filter (fn (xnm, thms) =>
       let
          val {pos, theory_name, ...} = Name_Space.the_entry fact_space xnm;
          in
            if theory_name = thy_nm then
            let
             val thms' = map (Thm.transfer thy) thms;

             val (_, cmd_name, end_pos, tag, prf_cmds) = search_backwards (Postab.lookup tab) pos 
               |> the |> sort cmd_entries_ord |> List.getItem |> the |> fst

             val lemma_deps' = if cmd_name = "datatype" then [] else
                map (used_facts (not o can (Name_Space.the_entry fact_space) o base_name_of)) thms' 
                |> flat;

             val lemma_deps = map base_name_of lemma_deps' |> distinct (op =)
              
             val deps = 
               map deps_of_thm thms' |> ListPair.unzip |> apply2 flat |> make_deps

             val location = location_from_range (pos, end_pos) |> the;

             val (lemma_entry : lemma_entry) =  
              {name  = xnm, command_name = cmd_name, levity_tag = make_tag tag, 
               location = location, proof_commands = prf_cmds,
               deps = deps, lemma_deps = lemma_deps}
               
            in SOME (pos, lemma_entry) end
            else NONE end handle Option => NONE)
      |> Postab_strict.make_list
      |> Postab_strict.dest |> map snd |> flat 
                       
    val defs = Theory.defs_of thy;

    fun get_deps_of kind space xnms = xnms
    |> map_filter (fn xnm =>
      let
          val {pos, theory_name, ...} = Name_Space.the_entry space xnm;
          in
            if theory_name = thy_nm then
            let
              val specs = Defs.specifications_of defs (kind, xnm);
              
              val deps =
                map get_deps specs 
               |> ListPair.unzip
               |> (apply2 flat #> make_deps);

              val (_, cmd_name, end_pos, tag, _) = pos
               |> search_backwards (Postab.lookup tab) 
               |> the |> sort cmd_entries_ord |> List.getItem |> the |> fst
              
              val loc = location_from_range (pos, end_pos) |> the;

              val entry = 
                ({name = xnm, command_name = cmd_name, levity_tag = make_tag tag,
                  location = loc, deps = deps} : dep_entry)

            in SOME (pos, entry) end
            else NONE end handle Option => NONE)
      |> Postab_strict.make_list
      |> Postab_strict.dest |> map snd |> flat

    val {const_space, constants, ...} = Consts.dest (Sign.consts_of thy);

    val consts = get_deps_of Defs.Const const_space (map fst constants);
    
    val {types, ...} = Type.rep_tsig (Sign.tsig_of thy);

    val type_space = Name_Space.space_of_table types;
    val type_names = Name_Space.fold_table (fn (xnm, _) => cons xnm) types [];

    val types = get_deps_of Defs.Type type_space type_names;
                                   
    val thy_parents = map entry_of_thy (Theory.parents_of thy);

   in (thy_nm, thy_parents, lemmas, consts, types) end

fun add_commas (s :: s' :: ss) = s ^ "," :: (add_commas (s' :: ss))
  | add_commas [s] = [s]
  | add_commas _ = []


fun string_reports_of (thy_nm, thy_parents, lemmas, consts, types) =
      ["{theory_name : " ^ quote thy_nm ^ ",", 
        "theory_imports : ["] @
      add_commas (map (theory_entry_encode) thy_parents) @
      ["],","lemmas : ["] @
      add_commas (map (lemma_entry_encode) lemmas) @
      ["],","consts : ["] @
      add_commas (map ( dep_entry_encode) consts) @
      ["],","types : ["] @
      add_commas (map ( dep_entry_encode) types) @
      ["]}"]
      |> map (fn s => s ^ "\n")

structure Data = Theory_Data
  (
    type T = string list;
    val empty = [];
    val extend = I;
    fun merge ((a, b) : T * T) = union (op =) a b;
  );

fun theory_is_processed thy = member (op =) (Data.get thy) (Context.theory_name thy);
fun process_theory thy = Data.map (insert (op =) (Context.theory_name thy)) thy; 

val setup_theory_hook = Theory.at_end (fn thy => if theory_is_processed thy then NONE else
  let
    val reports = get_reports_for_thy thy;
    
    val lines = string_reports_of reports;

    val thy_nm = Context.theory_name thy;
    val file_path = Path.append (Resources.master_directory thy) (Path.basic (thy_nm ^ ".lev"));
    
    val _ = File.write_list file_path lines;
  in SOME (process_theory thy) end)

end

\<close>

end
