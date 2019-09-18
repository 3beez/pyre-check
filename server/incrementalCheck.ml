(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
module ModuleTracker = Analysis.ModuleTracker
open Ast
open Analysis
open State
open Configuration.Analysis
open Pyre

type errors = State.Error.t list [@@deriving show]

let recheck
    ~state:( {
               State.module_tracker;
               ast_environment;
               environment;
               errors;
               scheduler;
               open_documents;
               _;
             } as state )
    ~configuration:({ debug; incremental_style; _ } as configuration)
    paths
  =
  let timer = Timer.start () in
  Annotated.Class.AttributeCache.clear ();
  AstEnvironment.FromEmptyStubCache.clear ();
  let module_updates = ModuleTracker.update module_tracker ~configuration ~paths in
  let scheduler =
    Scheduler.with_parallel scheduler ~is_parallel:(List.length module_updates > 10)
  in
  Log.info "Parsing %d updated modules..." (List.length module_updates);
  StatusUpdate.warning
    ~message:"Reparsing updated modules..."
    ~short_message:(Some "[Reparsing]")
    ~state;
  Log.log
    ~section:`Server
    "Incremental Module Update %a"
    Sexp.pp
    [%message (module_updates : ModuleTracker.IncrementalUpdate.t list)];
  let ast_environment_update_result =
    AstEnvironment.update ~configuration ~scheduler ast_environment (Update module_updates)
  in
  let reparsed_sources = AstEnvironment.UpdateResult.reparsed ast_environment_update_result in
  Log.log
    ~section:`Server
    "Incremental Parser Update %s"
    (List.to_string ~f:Reference.show reparsed_sources);
  let legacy_dependency_tracker = Dependencies.create (AstEnvironment.read_only ast_environment) in
  (* Repopulate the environment. *)
  let invalidated_environment_qualifiers =
    match incremental_style with
    | FineGrained -> Reference.Set.of_list reparsed_sources
    | Shallow ->
        Dependencies.of_list legacy_dependency_tracker ~modules:reparsed_sources
        |> Reference.Set.union (Reference.Set.of_list reparsed_sources)
    | Transitive ->
        Dependencies.transitive_of_list legacy_dependency_tracker ~modules:reparsed_sources
        |> Reference.Set.union (Reference.Set.of_list reparsed_sources)
  in
  Log.info
    "Repopulating the environment for %d modules."
    (Set.length invalidated_environment_qualifiers);
  StatusUpdate.warning
    ~message:"Repopulating the environment"
    ~short_message:(Some "[Repopulating]")
    ~state;
  let recheck_modules =
    let unannotated_global_environment =
      UnannotatedGlobalEnvironment.create (AstEnvironment.read_only ast_environment)
    in
    let unannotated_global_environment_update_result =
      UnannotatedGlobalEnvironment.update
        unannotated_global_environment
        ~scheduler
        ~configuration
        ~ast_environment_update_result
        invalidated_environment_qualifiers
    in
    let alias_environment =
      AliasEnvironment.create
        (UnannotatedGlobalEnvironment.read_only unannotated_global_environment)
    in
    let alias_update_result =
      AliasEnvironment.update
        alias_environment
        ~scheduler
        ~configuration
        unannotated_global_environment_update_result
    in
    let class_hierarchy_update_result =
      let class_hierarchy_environment =
        ClassHierarchyEnvironment.create (AliasEnvironment.read_only alias_environment)
      in
      ClassHierarchyEnvironment.update
        class_hierarchy_environment
        ~scheduler
        ~configuration
        alias_update_result
    in
    let invalidated_environment_qualifiers = Set.to_list invalidated_environment_qualifiers in
    match incremental_style with
    | FineGrained ->
        let (), invalidated_type_checking_keys =
          let update () =
            Service.Environment.populate
              ~configuration
              ~scheduler
              ~update_result:class_hierarchy_update_result
              environment
              invalidated_environment_qualifiers;
            if debug then
              Analysis.Environment.check_class_hierarchy_integrity environment
          in
          Analysis.Environment.update_and_compute_dependencies
            environment
            invalidated_environment_qualifiers
            ~update
            ~update_result:class_hierarchy_update_result
        in
        let invalidated_type_checking_keys =
          let unannotated_global_environment_dependencies =
            UnannotatedGlobalEnvironment.UpdateResult.triggered_dependencies
              unannotated_global_environment_update_result
            |> UnannotatedGlobalEnvironment.DependencyKey.KeySet.elements
            |> List.filter_map ~f:(function
                   | UnannotatedGlobalEnvironment.TypeCheckSource source -> Some source
                   | _ -> None)
          in
          let alias_environment_dependencies =
            AliasEnvironment.UpdateResult.triggered_dependencies alias_update_result
            |> AliasEnvironment.DependencyKey.KeySet.elements
            |> List.filter_map ~f:(function
                   | AliasEnvironment.TypeCheckSource source -> Some source
                   | _ -> None)
          in
          let class_hierarchy_dependencies =
            ClassHierarchyEnvironment.UpdateResult.triggered_dependencies
              class_hierarchy_update_result
            |> ClassHierarchyEnvironment.DependencyKey.KeySet.elements
            |> List.filter_map ~f:(function
                   | ClassHierarchyEnvironment.TypeCheckSource source -> Some source
                   | _ -> None)
          in
          List.fold
            ( unannotated_global_environment_dependencies
            @ alias_environment_dependencies
            @ class_hierarchy_dependencies )
            ~f:(fun sofar element ->
              SharedMemoryKeys.ReferenceDependencyKey.KeySet.add element sofar)
            ~init:invalidated_type_checking_keys
        in
        let invalidated_type_checking_keys =
          List.fold
            invalidated_environment_qualifiers
            ~init:invalidated_type_checking_keys
            ~f:(fun sofar key -> SharedMemoryKeys.ReferenceDependencyKey.KeySet.add key sofar)
        in
        let invalidated_type_checking_keys =
          SharedMemoryKeys.ReferenceDependencyKey.KeySet.elements invalidated_type_checking_keys
        in
        let recheck_modules = invalidated_type_checking_keys in
        Log.log
          ~section:`Server
          "Incremental Environment Builder Update %s"
          (List.to_string ~f:Reference.show invalidated_type_checking_keys);
        recheck_modules
    | _ ->
        let () =
          Analysis.Environment.purge
            environment
            ~debug
            invalidated_environment_qualifiers
            ~update_result:class_hierarchy_update_result;
          Dependencies.purge legacy_dependency_tracker invalidated_environment_qualifiers;
          let re_environment_build_sources =
            let ast_environment = Analysis.AstEnvironment.read_only ast_environment in
            List.filter_map
              invalidated_environment_qualifiers
              ~f:(AstEnvironment.ReadOnly.get_source ast_environment)
          in
          Dependencies.register_all_dependencies
            legacy_dependency_tracker
            re_environment_build_sources;
          Service.Environment.populate
            ~configuration
            ~scheduler
            ~update_result:class_hierarchy_update_result
            environment
            invalidated_environment_qualifiers
        in
        Log.log
          ~section:`Server
          "(Old) Incremental Environment Builder Update %s"
          (List.to_string ~f:Reference.show invalidated_environment_qualifiers);
        invalidated_environment_qualifiers
  in
  Statistics.event
    ~section:`Memory
    ~name:"shared memory size"
    ~integers:["size", Memory.heap_size ()]
    ();

  (* Compute new set of errors. *)
  (* Clear all type resolution info from shared memory for all affected sources. *)
  ResolutionSharedMemory.remove recheck_modules;
  Coverage.SharedMemory.remove_batch (Coverage.SharedMemory.KeySet.of_list recheck_modules);

  (* Clean up all lookup data related to updated files. *)
  List.iter recheck_modules ~f:(LookupCache.evict ~state);
  let new_errors =
    Service.Check.analyze_sources
      ~open_documents:(Reference.Table.mem open_documents)
      ~scheduler
      ~configuration
      ~environment
      recheck_modules
  in
  (* Kill all previous errors for new files we just checked *)
  List.iter ~f:(Hashtbl.remove errors) recheck_modules;

  (* Associate the new errors with new files *)
  List.iter new_errors ~f:(fun error ->
      let key = Error.path error in
      Hashtbl.add_multi errors ~key ~data:error);

  let total_rechecked_functions =
    let map sofar modules =
      List.filter_map
        modules
        ~f:(AstEnvironment.ReadOnly.get_source (AstEnvironment.read_only ast_environment))
      |> List.sum (module Int) ~f:Preprocessing.count_defines
      |> fun added -> sofar + added
    in
    Scheduler.map_reduce
      scheduler
      ~configuration
      ~initial:0
      ~map
      ~reduce:(fun left right -> left + right)
      ~inputs:recheck_modules
      ()
  in
  Statistics.performance
    ~name:"incremental check"
    ~timer
    ~integers:
      [
        "number of changed files", List.length paths;
        "number of module tracker updates", List.length module_updates;
        "number of parser updates", Set.length invalidated_environment_qualifiers;
        "number of environment builder updates", List.length recheck_modules;
        "number of re-checked functions", total_rechecked_functions;
      ]
    ();
  StatusUpdate.information ~message:"Done recheck." ~short_message:(Some "Done recheck.") ~state;
  state, new_errors
