(*****************************************************************************)
(*  libCUDF - CUDF (Common Upgrade Description Format) manipulation library  *)
(*  Copyright (C) 2009  Stefano Zacchiroli <zack@pps.jussieu.fr>             *)
(*                                                                           *)
(*  This program is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU General Public License as published by     *)
(*  the Free Software Foundation, either version 3 of the License, or (at    *)
(*  your option) any later version.                                          *)
(*                                                                           *)
(*  This program is distributed in the hope that it will be useful, but      *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of               *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU        *)
(*  General Public License for more details.                                 *)
(*                                                                           *)
(*  You should have received a copy of the GNU General Public License        *)
(*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*****************************************************************************)

open ExtLib
open OUnit
open Printf

open Cudf

let cudf_test_path name = sprintf "./tests/%s.cudf" name

let good_cudfs = [	(* CUDF whose parsing must suceed *)
  "adjacent-stanzas" ;
]
let bad_cudfs = [	(* CUDF whose parsing must fail *)
]
let good_pkgs = [	(* universes whose parsing must suceed *)
  "conflict-comma-sep" ;
  "plus-in-pkgname" ;
]
let bad_pkgs = [	(* universes whose parsing must fail *)
  "weird-pkgname" ;
]

(** {5 Helpers} *)

(** {6 OUnit helpers}
    i.e., missing stuff which should better be integrated into OUnit *)

let assert_no_exn f = assert_equal true (try f () ; true with _ -> false)

let assert_raises' ?(cmp = (=)) ~exn f =
  assert_equal true (try f () ; false with exn' -> cmp exn exn')

(** {6 CUDF helpers} *)

let parse_test ~parse_fun name =
  let ic = open_in (cudf_test_path name) in
  let p = Cudf_parser.from_in_channel ic in
  let out = parse_fun p in
    close_in ic;
    out

let parse_cudf_test = parse_test ~parse_fun:Cudf_parser.parse_cudf
let parse_pkgs_test = parse_test ~parse_fun:Cudf_parser.parse_packages
let load_cudf_test = parse_test ~parse_fun:Cudf_parser.load_cudf
let load_univ_test = parse_test ~parse_fun:Cudf_parser.load_universe

(** {5 Test builders} *)

let good_parse ~parse_fun name = TestCase (fun _ ->
  assert_no_exn (fun () -> parse_test ~parse_fun name))

let bad_parse ~parse_fun name = TestCase (fun _ ->
  assert_raises'
    ~cmp:(fun e1 e2 ->
	    match e1, e2 with
	      | Cudf_parser.Parse_error _, Cudf_parser.Parse_error _ -> true
	      | _ -> false)
    ~exn:(Cudf_parser.Parse_error (0, ""))
    (fun () -> parse_test ~parse_fun name))

(** {5 Test suites} *)

(** {6 Big suites} *)

let good_cudf_parse_suite =
  "parsing of good CUDFs" >::: List.map
      (fun n -> n >: good_parse ~parse_fun:Cudf_parser.parse_cudf n)
      good_cudfs

let bad_cudf_parse_suite =
  "parsing of bad CUDFs" >::: List.map
      (fun n -> n >: bad_parse ~parse_fun:Cudf_parser.parse_cudf n)
      bad_cudfs

let good_pkgs_parse_suite =
  "parsing of good package universes" >::: List.map
      (fun n -> n >: good_parse ~parse_fun:Cudf_parser.parse_packages n)
      good_pkgs

let bad_pkgs_parse_suite =
  "parsing of bad package universes" >::: List.map
      (fun n -> n >: bad_parse ~parse_fun:Cudf_parser.parse_packages n)
      bad_pkgs

(** {6 Regression tests} *)

let or_dep =
  "disjunctive dependencies" >:: (fun () ->
    assert_equal
      (lookup_package (load_univ_test "or-dep") ("electric-engine", 1)).depends
      (FAnd [
	 FOr [FPkg ("solar-collector", None) ; FPkg ("huge-battery", None)]]))

let parse_reg_suite =
  "regression tests - parsing" >::: [
    or_dep ;
  ]

(** {6 New feature tests}
    i.e., kinda test-driven development *)

let status_filtering =
  "status projection" >:: (fun () ->
    "status projection returned an \"installed: false\" package" @?
      List.for_all
        (fun { installed = i } -> i)
        (get_packages (status (fst (load_cudf_test "legacy")))))

let inst_version_lookup =
  "lookup installed versions" >:: (fun () ->
    let univ = load_univ_test "multi-versions" in
    let versions pkg = List.map (fun p -> p.version) (get_installed univ pkg) in
      assert_equal (List.sort (versions "gasoline-engine")) [1; 2];
      assert_equal (versions "battery") [3];
      assert_equal (versions "not-installed") [];
      assert_equal (versions "not-existent") [])

let mem_installed =
  "check whether an installation satisfy a package constraint" >:: (fun () ->
    let univ, _ = load_cudf_test "legacy" in
    let mem = mem_installed ~include_features:true univ in
    let mem' = mem_installed ~include_features:false univ in
      "'car' unsatisfied" @? mem ("car", None);
      "'car = 1' unsatisfied" @? mem ("car", Some (`Eq, 1));
      "'car > 1' satisfied'" @? not (mem ("car", Some (`Gt, 1)));
      "'car >= 1' unsatisfied" @? mem ("car", Some (`Leq, 1));
      "'engine' unsatisfied w features" @? mem ("engine", None);
      "'engine' satisfied w/o features" @? not (mem' ("engine", None));
  )

let satisfy_formula =
  "check formula satisfaction" >:: (fun () ->
    let univ, _ = load_cudf_test "legacy" in
    let sat = Cudf_checker.satisfy_formula univ in
      "true unsatisfied (WTF?)" @? sat FTrue;
      "conjunction unsatisfied" @?
	sat (FAnd [FPkg ("battery", None); FPkg ("wheel", None)]) ;
      "disjunction unsatisfied" @?
	sat (FOr [FPkg ("solar-collectore", None); FPkg ("wheel", None)]) ;
      "unsat formula satisfied" @?
	not (sat (FOr [FPkg ("wheel", Some (`Gt, 2)); FPkg ("tire", None)])) ;
  )

let disjoint =
  "check package disjunction (i.e., conflicts)" >:: (fun () ->
    let univ, _ = load_cudf_test "legacy" in
    let disj = Cudf_checker.disjoint univ in
      "missing package reported as existing" @? disj ["fubar", None];
      "undetected conflict" @? not (disj ["door", Some (`Eq, 1)]);
      "undetected partial conflict" @?
	not (disj ["door", Some (`Gt, 1); "turbo", None]);
  )

let self_conflicts =
  "check self-conflicts" >:: (fun () ->
    let consist u = fst (Cudf_checker.is_consistent u) in
      "direct self-conflict" @? consist (load_univ_test "direct-self-conflict");
      "indirect self-conflict" @?
	consist (load_univ_test "indirect-self-conflict"))

let consistency =
  "check universe consistency" >::: [
    "legacy example consistency" >:: (fun () ->
      let univ, _ = load_cudf_test "legacy" in
	"inconsistent legacy example" @? fst (Cudf_checker.is_consistent univ))
  ]

let feature_suite =
  "new feature tests" >::: [
    status_filtering ;
    inst_version_lookup ;
    mem_installed ;
    satisfy_formula ;
    disjoint ;
    self_conflicts ;
    consistency ;
  ]

(** {5 Assemble and run tests} *)

let all =
  "all tests" >::: [
    good_cudf_parse_suite ;
    bad_cudf_parse_suite ;
    good_pkgs_parse_suite ;
    bad_pkgs_parse_suite ;
    parse_reg_suite ;
    feature_suite ;
  ]
