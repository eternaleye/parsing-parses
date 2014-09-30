(** * Definition of a [comp]-based non-computational CFG parser *)
Require Import Coq.Lists.List Coq.Program.Program Coq.Program.Wf Coq.Arith.Wf_nat Coq.Arith.Compare_dec Coq.Classes.RelationClasses Coq.Strings.String.
Require Import Parsers.ContextFreeGrammar Parsers.Specification.
Require Import Common Common.ilist.

Set Implicit Arguments.
(*(** We implement a generic recursive descent parser.  We parameterize
    over a number of parameters:

    - [T : Type] - the type of results of successful parsing.
      Parameterizing over this allows, e.g., higher-order parsing.

      TODO?: generalize this to use continuations instead, so we can
      do monadic side-effects when parsing.

    - [aggregate : String → T → String → T → T] - takes the results of
      two successful adjacent parses and combines them.

    - [pick_parses : String → nonterminal → list (list String)] - A
      non-terminal is a list of patterns.  This function will break up
      a string into a list of possible splits; a split is an
      assignment of a part of the string to each pattern.


    The basic idea is that

FIXME *)*)
(** TODO: rename pattern to production *)

Section wf.
  Section wf_prod.
    Context A B (RA : relation A) (RB : relation B).

    Definition prod_relation : relation (A * B)
      := fun ab a'b' =>
           RA (fst ab) (fst a'b') \/ (fst a'b' = fst ab /\ RB (snd ab) (snd a'b')).

    Fixpoint well_founded_prod_relation_helper
             a b
             (wf_A : Acc RA a) (wf_B : well_founded RB) {struct wf_A}
    : Acc prod_relation (a, b)
      := match wf_A with
           | Acc_intro fa => (fix wf_B_rec b' (wf_B' : Acc RB b') : Acc prod_relation (a, b')
                              := Acc_intro
                                   _
                                   (fun ab =>
                                      match ab as ab return prod_relation ab (a, b') -> Acc prod_relation ab with
                                        | (a'', b'') =>
                                          fun pf =>
                                            match pf with
                                              | or_introl pf'
                                                => @well_founded_prod_relation_helper
                                                     _ _
                                                     (fa _ pf')
                                                     wf_B
                                              | or_intror (conj pfa pfb)
                                                => match wf_B' with
                                                     | Acc_intro fb
                                                       => eq_rect
                                                            _
                                                            (fun a'' => Acc prod_relation (a'', b''))
                                                            (wf_B_rec _ (fb _ pfb))
                                                            _
                                                            pfa
                                                   end
                                            end
                                      end)
                             ) b (wf_B b)
         end.

    Definition well_founded_prod_relation : well_founded RA -> well_founded RB -> well_founded prod_relation.
    Proof.
      intros wf_A wf_B [a b]; hnf in *.
      apply well_founded_prod_relation_helper; auto.
    Defined.
  End wf_prod.

  Section wf_sig.
    Context A B (RA : relation A) (RB : forall a : A, relation (B a)).

    Definition sigT_relation : relation (sigT B)
      := fun ab a'b' =>
           RA (projT1 ab) (projT1 a'b') \/ (exists pf : projT1 a'b' = projT1 ab, RB (projT2 ab)
                                                                                    (eq_rect _ B (projT2 a'b') _ pf)).

    Fixpoint well_founded_sigT_relation_helper
             a b
             (wf_A : Acc RA a) (wf_B : forall a, well_founded (@RB a)) {struct wf_A}
    : Acc sigT_relation (existT _ a b).
    Proof.
      refine match wf_A with
               | Acc_intro fa => (fix wf_B_rec b' (wf_B' : Acc (@RB a) b') : Acc sigT_relation (existT _ a b')
                                  := Acc_intro
                                       _
                                       (fun ab =>
                                          match ab as ab return sigT_relation ab (existT _ a b') -> Acc sigT_relation ab with
                                            | existT a'' b'' =>
                                              fun pf =>
                                                match pf with
                                                  | or_introl pf'
                                                    => @well_founded_sigT_relation_helper
                                                         _ _
                                                         (fa _ pf')
                                                         wf_B
                                                  | or_intror (ex_intro pfa pfb)
                                                    => match wf_B' with
                                                         | Acc_intro fb
                                                           => _(*eq_rect
                                                            _
                                                            (fun a'' => Acc sigT_relation (existT B a'' _(*b''*)))
                                                            (wf_B_rec _ (fb _ _(*pfb*)))
                                                            _
                                                            pfa*)
                                                       end
                                                end
                                          end)
                                 ) b (wf_B a b)
             end;
      simpl in *.
      destruct pfa; simpl in *.
      exact (wf_B_rec _ (fb _ pfb)).
    Defined.

    Definition well_founded_sigT_relation : well_founded RA
                                            -> (forall a, well_founded (@RB a))
                                            -> well_founded sigT_relation.
    Proof.
      intros wf_A wf_B [a b]; hnf in *.
      apply well_founded_sigT_relation_helper; auto.
    Defined.
  End wf_sig.
End wf.

Local Open Scope string_like_scope.

Section recursive_descent_parser.
  Context CharType (String : string_like CharType) (G : grammar CharType).
  Context (nonterminal_listT : String -> Type)
          (initial_nonterminal_data : forall str, nonterminal_listT str)
          (is_valid_nonterminal : forall str, nonterminal_listT str -> nonterminal CharType -> bool)
          (remove_nonterminal : forall str, nonterminal_listT str -> nonterminal CharType -> nonterminal_listT str)
          (nonterminal_listT_R : forall str, nonterminal_listT str -> nonterminal_listT str -> Prop)
          (remove_nonterminal_dec : forall str ls nt, is_valid_nonterminal str ls nt = true
                                                  -> nonterminal_listT_R str (remove_nonterminal str ls nt) ls)
          (ntl_wf : forall str, well_founded (nonterminal_listT_R str)).
  Section generic.
    Context (T_success T_failure : String -> nonterminal CharType -> Type)
            (T_success_reverse_lookup : forall str name, T_success str (Lookup G name) -> T_success str [ [ NonTerminal _ name ] ])
            (T_failure_reverse_lookup : forall str name, T_failure str (Lookup G name) -> T_failure str [ [ NonTerminal _ name ] ])
            (transport_T_success_str : forall (s1 s2 : String) nt, s1 = s2 -> T_success s1 nt -> T_success s2 nt)
            (transport_T_failure_str : forall (s1 s2 : String) nt, s1 = s2 -> T_failure s1 nt -> T_failure s2 nt).
    Let T str nt := (T_success str nt + T_failure str nt)%type.
    Let transport_T_str (s1 s2 : String) nt (H : s1 = s2) (p : T s1 nt) : T s2 nt :=
      match p with
        | inl p' => inl (transport_T_success_str H p')
        | inr p' => inr (transport_T_failure_str H p')
      end.
    Let T_reverse_lookup str name (p : T str (Lookup G name)) : T str [ [ NonTerminal _ name ] ]
      :=  match p with
            | inl p' => inl (T_success_reverse_lookup _ p')
            | inr p' => inr (T_failure_reverse_lookup _ p')
          end.
    Context (parse_pattern_by_picking
             : forall str0
                      (parse_pattern_from_split_list'
                       : forall (strs : list { str : String | Length _ str < Length _ str0 \/ str = str0 })
                                (pat : pattern CharType),
                           ilist (fun sp => T (proj1_sig (fst sp)) [ [ snd sp ] ]) (combine strs pat))
                      (str : String)
                      (pf : Length _ str < Length _ str0 \/ str = str0)
                      (pat : pattern CharType),
                 T str [ pat ]).
    Context (decide_leaf : forall str ch, T str [ [ Terminal ch ] ]).
    Context (fold_patterns : forall str (pats : list (pattern CharType)),
                               ilist (fun pat => T str [ pat ]) pats
                               -> T str pats).
    Context (make_abort : forall str nt valid_list, @is_valid_nonterminal str valid_list nt = false -> T_failure str nt).


    Section parts.
      Section item.
        Context (str : String)
                (parse_nonterminal : forall nt, T str nt).

        Definition parse_item it : T str [ [ it ] ]
          := match it with
               | Terminal ch => decide_leaf str ch
               | NonTerminal name => T_reverse_lookup _ (parse_nonterminal (Lookup G name))
             end.
      End item.

      Section pattern.
        Variable str0 : String.
        Variable parse_nonterminal : forall (str : String)
                                            (pf : Length _ str < Length _ str0 \/ str = str0)
                                            nt, T str nt.

        Definition parse_pattern_from_split_list
                   (strs : list { str : String | Length _ str < Length _ str0 \/ str = str0 })
                   (pat : pattern CharType)
        : ilist (fun sp => T (proj1_sig (fst sp)) [ [ snd sp ] ]) (combine strs pat)
          := imap_list (fun sp => T (proj1_sig (fst sp)) [ [ snd sp ] ])
                       (fun sp => parse_item (@parse_nonterminal _ (proj2_sig (fst sp))) (snd sp))
                       (combine strs pat).

        Definition parse_pattern (str : String) (pf : Length _ str < Length _ str0 \/ str = str0) (pat : pattern CharType)
        : T str [ pat ]
          := parse_pattern_by_picking parse_pattern_from_split_list pf pat.
      End pattern.

      Section nonterminal.
        Section step.
          Variable str0 : String.
          Variable parse_nonterminal : forall (str : String)
                                              (pf : Length _ str < Length _ str0 \/ str = str0)
                                              nt, T str nt.

          Definition parse_nonterminal_step (str : String) (pf : Length _ str < Length _ str0 \/ str = str0) (nt : nonterminal CharType)
          : T str nt
            := fold_patterns (imap_list (fun pat => T str [ pat ])
                                        (parse_pattern parse_nonterminal pf)
                                        nt).
        End step.

        Section wf.
          Definition parse_nonterminal_or_abort str0 str (valid_list : forall str, nonterminal_listT str)
                     (pf : Length _ str < Length _ str0 \/ str = str0)
                     (nt : nonterminal CharType)
          : T str nt.
          Proof.
            revert str pf nt.
            change str0 with (projT1 (existT nonterminal_listT str0 (valid_list str0))).
            generalize (existT nonterminal_listT str0 (valid_list str0)); clear str0 valid_list.
            refine (@Fix (sigT nonterminal_listT) _ (@well_founded_sigT_relation
                                                       String
                                                       nonterminal_listT
                                                       _
                                                       _
                                                       (well_founded_ltof _ (Length String))
                                                       ntl_wf)
                         _ _).
            intros [str0 valid_list] parse_nonterminal str pf nt; simpl in *.
            destruct (lt_dec (Length _ str) (Length _ str0)) as [pf'|pf'];
              [ | assert (H : str0 = str) by intuition; apply (transport_T_str H); clear H ].
            { (** [str] got smaller, so we reset the valid nonterminals *)
              specialize (parse_nonterminal
                            (existT _ str (initial_nonterminal_data str))
                            (or_introl pf')); simpl in *.
              exact (parse_nonterminal_step parse_nonterminal (or_intror eq_refl) nt). }
            { (** [str] didn't get smaller, so we cache the fact that we've hit this nonterminal already *)
              case_eq (is_valid_nonterminal valid_list nt).
              { (** It was valid, so we can remove it *)
                intro H'.
                specialize (fun pf' => parse_nonterminal
                              (existT _ str0 (remove_nonterminal valid_list nt))
                              (or_intror (ex_intro _ eq_refl pf'))); simpl in *.
                specialize (parse_nonterminal (remove_nonterminal_dec H')).
                exact (parse_nonterminal_step parse_nonterminal (or_intror eq_refl) nt). }
              { (** oops, we already saw this nonterminal in the past.  ABORT! *)
                intro; right; eapply make_abort; eassumption. } }
          Defined.

          Definition parse_nonterminal str nt : T str nt
            := @parse_nonterminal_or_abort str str initial_nonterminal_data
                                           (or_intror eq_refl) nt.
        End wf.
      End nonterminal.
    End parts.
  End generic.

  Section parse_tree.
    Local Hint Constructors parse_of parse_of_pattern parse_of_item : parse_tree.
    Local Hint Resolve ParseHead ParsePatternSingleton : parse_tree.
    Local Hint Extern 1 => apply ParseHead : parse_tree.
    Local Hint Extern 0 (option (parse_of _ _ _ [])) => exact None : parse_tree.
    Context (pick_patterns
             : forall (str : String)
                      (pat : pattern CharType)
                      (patH : Datatypes.length pat > 0),
                 { ls : list { split : list { str_part : String | Length _ str_part < Length _ str \/ str_part = str }
                             | List.length split = List.length pat
                               /\ fold_right (Concat _) (Empty _) (map (@proj1_sig _ _) split) = str }
                 | List.length ls <> 0 }).

    Let aggregate str pats : list (parse_of String G str pats +
                                   option (parse_of String G str pats -> False))
                             -> parse_of String G str pats +
                                option (parse_of String G str pats -> False).
    Proof.
      intro ls.
      induction ls as [|x xs IHxs].
      { right; exact None. }
      { destruct x as [| [ ] ]; try solve [ left; assumption
                                          | right; apply Some; assumption ].
        apply IHxs. }
    Defined.

    Definition parse_tree_for : forall str nt, parse_of String G str nt + option (parse_of String G str nt -> False).
    Proof with auto with parse_tree nocore.
      apply (@parse_nonterminal (fun str nt => parse_of _ G str nt)
                                (fun str nt => option (parse_of _ G str nt -> False)))...
      { intros str name [np|]; [ apply Some | exact None ].
        revert np; clear; intros.
        abstract (repeat match goal with
                           | [ H : context[_ ++ Empty String] |- _ ] => rewrite RightId in H
                           | [ H : ?T, H' : ?T -> False |- _ ] => destruct (H' H)
                           | [ p : parse_of _ _ _ _ |- _ ] => (inversion p; subst; clear p)
                           | [ p : parse_of_pattern _ _ _ _ |- _ ] => (inversion p; subst; clear p)
                           | [ p : parse_of_item _ _ _ _ |- _ ] => (inversion p; subst; clear p)
                         end). }
        { intros; subst; assumption. }
        { intros; subst; assumption. }
        { intros str0 parse_pattern_from_split_list' str pf pat.
          pose proof (parse_pattern_from_split_list' ((exist _ str pf)::nil) pat) as parse_pattern_from_split_list''; simpl in *.
          destruct pat as [|pat0 [|pat1 pats] ]; simpl in *.
          { case_eq (str =s Empty _); intro H; [ left | right; exact None ]...
            apply bool_eq_correct in H; subst... }
          { destruct (ilist_hd parse_pattern_from_split_list'') as [tree|]; simpl in *; [ left | right ]; assumption. }
          { (** we need to split the string *)
            clear parse_pattern_from_split_list''.
            refine (aggregate _); clear aggregate.
            refine (map _ (proj1_sig (@pick_patterns str (pat0::pat1::pats) (Gt.gt_Sn_O _)))); clear pick_patterns.
            intros [ split [ split_length split_strings ] ].
            let T := match type of split with list ?T => constr:(T) end in
            set (f := (map (fun x' : T
                      => exist
                           (fun str => Length String str < Length String str0 \/ str = str0)
                           (proj1_sig x')
                           (match pf, proj2_sig x' with
                              | or_introl H0, or_introl H1 => or_introl (transitivity H1 H0)
                              | or_introl H0, or_intror H1 => or_introl (transitivity (R := le) (Le.le_n_S _ _ (NPeano.Nat.eq_le_incl _ _ (f_equal (Length String) H1))) H0)
                              | or_intror H0, or_introl H1 => or_introl (transitivity (R := le) H1 (NPeano.Nat.eq_le_incl _ _ (f_equal (Length String) H0)))
                              | or_intror H0, or_intror H1 => or_intror (transitivity H1 H0)
                            end)))).
            specialize (parse_pattern_from_split_list' (f split) (pat0 :: pat1 :: pats)).
            generalize dependent split.
            intro split.
            generalize (pat0::pat1::pats).
            clear pat0 pat1 pats.
            assert (H0 : Datatypes.length (f split) = Datatypes.length split)
              by (clear; abstract (induction split; simpl; auto)).
            assert (H1 : map (@proj1_sig _ _) (f split) = map (@proj1_sig _ _) split)
              by (clear; abstract (induction split; simpl; f_equal; auto)).
            rewrite <- H0; clear H0.
            rewrite <- H1; clear H1.
            generalize (f split); clear split; clear f.
            intros fsplit pats.
            clear pf.
            revert pats str.
            induction fsplit;
              intro pats; intros;
              destruct pats;
              repeat match goal with
                       | [ H : @eq nat _ _ |- _ ] => progress simpl in H
                       | [ H : @eq nat _ _ |- _ ] => exfalso; revert H; clear; intro H; abstract inversion H
                       | _ => progress subst
                       | [ H : S _ = S _ |- _ ] => apply (f_equal pred) in H
                       | [ H : ?x = ?x |- _ ] => clear H
                     end.
            { simpl in *; left; subst... }
            { simpl in *.
              let IHfsplit := match goal with
                                | [ IHfsplit : forall pats str,
                                                 ilist _ _ ->
                                                 _ = _ ->
                                                 fold_right _ _ _ = str ->
                                                 _ + _
                                                 |- _ ] => constr:IHfsplit
                              end in
              match goal with
                | [ H : Datatypes.length _ = Datatypes.length _ |- _ ]
                  => specialize (fun l => IHfsplit _ _ l H eq_refl)
              end;
                let ls := match goal with | [ ls : ilist _ (_::_) |- _ ] => constr:ls end in
                specialize (IHfsplit (ilist_tl ls));
                  let ls_hd := fresh "ls_hd" in
                  pose proof (ilist_hd ls) as ls_hd;
                    simpl in ls_hd;
                    clear ls;
                    refine (match ls_hd, IHfsplit with
                              | inl p1, inl p2 => inl (ParseApp p1 p2)
                              | inr _, _ => inr None
                              | _, inr _ => inr None
                            end). } } }
      { (** decide_leaf *)
        intros str ch.
        case_eq (str =s [[ch]]); intro H; [ apply bool_eq_correct in H; left | right; exact None ].
        subst... }
      { (** fold_patterns *)
        intros str pats parses; induction parses; simpl in *;
        repeat match goal with
                 | [ H : option _ |- _ ] => destruct H
                 | [ H : sum _ _ |- _ ] => destruct H
               end;
          try solve [ left; auto with parse_tree nocore
                    | left;
                      repeat match goal with
                               | _ => progress auto with parse_tree nocore
                               | [ H : parse_of _ _ _ _ |- _ ] => inversion H; clear H; subst
                             end
                    | match goal with
                        | [ H : parse_of _ _ _ _ |- _ ] => fail 1
                        | _ => idtac
                      end;
                      right; exact None
                    | right;
                      apply Some;
                      let p := fresh in
                      intro p; inversion p; clear p; subst;
                      auto with parse_tree nocore ]. }
      { (** make_abort *)
        intros; exact None. }
    Defined.
  End parse_tree.


(*  Section parse_tree_no_split.
    Local Hint Constructors parse_of parse_of_pattern parse_of_item : parse_tree.
    Local Hint Resolve ParseHead ParsePatternSingleton : parse_tree.
    Local Hint Extern 1 => apply ParseHead : parse_tree.
    Local Hint Extern 0 (option (parse_of _ _ _ [])) => exact None : parse_tree.

    Definition parse_tree_no_split_for : forall str nt, option (parse_of String G str nt).
    Proof with auto with parse_tree nocore.
      apply (@parse_nonterminal (fun str nt => option (parse_of _ G str nt))).
      { intros str name [p|]; [ apply Some | exact None ]... }
      { intros.
        specialize (parse_pattern_from_split_list' ((exist _ str pf)::nil) pat); simpl in *.
        destruct pat as [|pat0 [|pat1 pats] ]; simpl in *.
        { case_eq (str =s Empty _); intro H; [ apply Some | exact None ]...
          apply bool_eq_correct in H; subst... }
        { destruct (ilist_hd parse_pattern_from_split_list') as [tree|]; simpl in *; [ apply Some | exact None ]... }
        { (** we don't handle the case where we need to split the string *)
          exact None. } }
      { (** decide_leaf *)
        intros str ch.
        case_eq (str =s [[ch]]); intro H; [ apply bool_eq_correct in H; apply Some | exact None ].
        subst... }
      { (** fold_patterns *)
        intros str pats parses; induction parses; simpl in *...
        repeat match goal with H : option _ |- _ => destruct H end;
          try solve [ apply Some; auto with parse_tree nocore
                    | apply Some;
                      repeat match goal with
                               | _ => progress auto with parse_tree nocore
                               | [ H : parse_of _ _ _ _ |- _ ] => inversion H; clear H; subst
                             end
                    | match goal with
                        | [ H : parse_of _ _ _ _ |- _ ] => fail 1
                        | _ => idtac
                      end;
                      exact None ]. }
      { (** make_abort *)
        intros; exact None. }
    Defined.
  End parse_tree_no_split.




  Section generic_by_simple_listing.
    (** If we don't need to pass proofs down the tree, we can just ask for a list of splits. *)
    Context (T_success T_failure : String -> nonterminal CharType -> Type)
            (T_success_reverse_lookup : forall str name, T_success str (Lookup G name) -> T_success str [ [ NonTerminal _ name ] ])
            (T_failure_reverse_lookup : forall str name, T_failure str (Lookup G name) -> T_failure str [ [ NonTerminal _ name ] ])
            (transport_T_success_str : forall (s1 s2 : String) nt, s1 = s2 -> T_success s1 nt -> T_success s2 nt)
            (transport_T_failure_str : forall (s1 s2 : String) nt, s1 = s2 -> T_failure s1 nt -> T_failure s2 nt).
    Let T str nt := (T_success str nt + T_failure str nt)%type.
    Let transport_T_str (s1 s2 : String) nt (H : s1 = s2) (p : T s1 nt) : T s2 nt :=
      match p with
        | inl p' => inl (transport_T_success_str H p')
        | inr p' => inr (transport_T_failure_str H p')
      end.
    Context (pick_patterns
             : forall (str : String)
                      (pat : pattern CharType),
                 { ls : list { split : list { str_part : String | Length _ str_part < Length _ str \/ str_part = str }
                             | List.length split = List.length pat
                               /\ fold_right (Concat _) (Empty _) (map (@proj1_sig _ _) split) = str }
                 | List.length ls <> 0 }).
    Context (simple_fold_pattern_parts
             : forall str0
                      strs
                      (pat : pattern CharType)
                      (pf : List.length strs = List.length pat),
                 ilist (fun sp : {str1 : String |
                                  Length String str1 < Length String str0 \/
                                  str1 = str0} * item CharType
                        => T (proj1_sig (fst sp)) [ [ snd sp ] ])
                       (combine strs pat)
                 -> T (fold_left (Concat _) (map (@proj1_sig _ _) strs) (Empty _))
                      [ pat ]).
    Context (decide_leaf : forall str ch, T str [ [ Terminal ch ] ]).
    Context (fold_patterns : forall str (pats : list (pattern CharType)),
                               ilist (fun pat => T str [ pat ]) pats
                               -> T str pats).
    Context (make_abort : forall str nt valid_list, @is_valid_nonterminal str valid_list nt = false -> T_failure str nt).

    Definition parse_nonterminal_with_split_picker str nt : T str nt.
    Proof.
      refine (@parse_nonterminal T_success T_failure T_success_reverse_lookup T_failure_reverse_lookup transport_T_success_str transport_T_failure_str _ decide_leaf fold_patterns make_abort str nt).
      clear str nt.
      intros str0 parse_a_split str H pat.
      specialize (pick_patterns str pat).
      specialize (fun strs => parse_a_split strs pat).
      specialize (fun strs H =>
                    @simple_fold_pattern_parts _ _ _ H (parse_a_split strs)).
      clear parse_a_split.
      move simple_fold_pattern_parts at bottom.
      specialize (fun strs pf1 pf2 =>
                    @transport_T_str
                      _ str _ pf1
                      (@simple_fold_pattern_parts strs pf2)).
      clear simple_fold_pattern_parts.
      move pick_patterns at bottom.
      move transport_T_str at bottom.
      destruct pick_patterns as [ls H'].
      let T := match type of ls with list (@sig (list ?T) _) => constr:(T) end in
      set (f := (map (fun x' : T
                      => exist
                           (fun str => Length String str < Length String str0 \/ str = str0)
                           (proj1_sig x')
                           (match H, proj2_sig x' with
                              | or_introl H0, or_introl H1 => or_introl (transitivity H1 H0)
                              | or_introl H0, or_intror H1 => or_introl (transitivity (R := le) (Le.le_n_S _ _ (NPeano.Nat.eq_le_incl _ _ (f_equal (Length String) H1))) H0)
                              | or_intror H0, or_introl H1 => or_introl (transitivity (R := le) H1 (NPeano.Nat.eq_le_incl _ _ (f_equal (Length String) H0)))
                              | or_intror H0, or_intror H1 => or_intror (transitivity H1 H0)
                            end)))).
      pose proof (map f (map (@proj1_sig _ _) ls)).
      let T := match type of ls with list ?T => constr:(T) end in
      pose proof (@map
                    T _
                    f
                    ls).

      assert (forall B : Type, ({split
       : list
           {str_part : String |
           Length String str_part < Length String str \/ str_part = str} |
       Datatypes.length split = Datatypes.length pat /\
       fold_left (Concat String)
         (map
            (proj1_sig
               (P:=fun str_part : String =>
                   Length String str_part < Length String str \/
                   str_part = str)) split) (Empty String) = str} -> B)).
      intros B x.
      assert (list
    {str_part : String |
     Length String str_part < Length String str \/ str_part = str} ->
              list {str : String | Length String str < Length String str0 \/ str = str0}).
      refine .
      SearchAbout (_ <= _ -> S _ <= S _).

      refine (fun x' => _).
      refine (map _
                   pose proof (@transport_T_str (map (fun x' => exist _ (proj1_sig x') (proj1_sig x)).
 in parse



      apply simple_fold_pattern_parts.

      move pick_patterns at bottom.
      pose @imap_list.
            := @parse_nonterminal_or_abort str str initial_nonterminal_data
                                           (or_intror eq_refl) nt.

  Section parse_tree_no_split.
    Local Hint Constructors parse_of parse_of_pattern parse_of_item : parse_tree.
    Local Hint Resolve ParseHead ParsePatternSingleton : parse_tree.
    Local Hint Extern 1 => apply ParseHead : parse_tree.
    Local Hint Extern 0 (option (parse_of _ _ _ [])) => exact None : parse_tree.

    Definition parse_tree_no_split_for : forall str nt, option (parse_of String G str nt).
    Proof with auto with parse_tree nocore.
      apply (@parse_nonterminal (fun str nt => option (parse_of _ G str nt))).
      { intros str name [p|]; [ apply Some | exact None ]... }
      { intros.
        specialize (parse_pattern_from_split_list' ((exist _ str pf)::nil) pat); simpl in *.
        destruct pat as [|pat0 [|pat1 pats] ]; simpl in *.
        { case_eq (str =s Empty _); intro H; [ apply Some | exact None ]...
          apply bool_eq_correct in H; subst... }
        { destruct (ilist_hd parse_pattern_from_split_list') as [tree|]; simpl in *; [ apply Some | exact None ]... }
        { (** we don't handle the case where we need to split the string *)
          exact None. } }
      { (** decide_leaf *)
        intros str ch.
        case_eq (str =s [[ch]]); intro H; [ apply bool_eq_correct in H; apply Some | exact None ].
        subst... }
      { (** fold_patterns *)
        intros str pats parses; induction parses; simpl in *...
        repeat match goal with H : option _ |- _ => destruct H end;
          try solve [ apply Some; auto with parse_tree nocore
                    | apply Some;
                      repeat match goal with
                               | _ => progress auto with parse_tree nocore
                               | [ H : parse_of _ _ _ _ |- _ ] => inversion H; clear H; subst
                             end
                    | match goal with
                        | [ H : parse_of _ _ _ _ |- _ ] => fail 1
                        | _ => idtac
                      end;
                      exact None ]. }
      { (** make_abort *)
        intros; exact None. }
    Defined.
  End parse_tree_no_split.


  Section parse_tree_no_split.
    Local Hint Constructors parse_of parse_of_pattern parse_of_item : parse_tree.
    Local Hint Resolve ParseHead ParsePatternSingleton : parse_tree.
    Local Hint Extern 1 => apply ParseHead : parse_tree.
    Local Hint Extern 0 (option (parse_of _ _ _ [])) => exact None : parse_tree.

    Definition parse_tree_no_split_for : forall str nt, option (parse_of String G str nt).
    Proof with auto with parse_tree nocore.
      apply (@parse_nonterminal (fun str nt => option (parse_of _ G str nt))).
      { intros str name [p|]; [ apply Some | exact None ]... }
      { intros.
        specialize (parse_pattern_from_split_list' ((exist _ str pf)::nil) pat); simpl in *.
        destruct pat as [|pat0 [|pat1 pats] ]; simpl in *.
        { case_eq (str =s Empty _); intro H; [ apply Some | exact None ]...
          apply bool_eq_correct in H; subst... }
        { destruct (ilist_hd parse_pattern_from_split_list') as [tree|]; simpl in *; [ apply Some | exact None ]... }
        { (** we don't handle the case where we need to split the string *)
          exact None. } }
      { (** decide_leaf *)
        intros str ch.
        case_eq (str =s [[ch]]); intro H; [ apply bool_eq_correct in H; apply Some | exact None ].
        subst... }
      { (** fold_patterns *)
        intros str pats parses; induction parses; simpl in *...
        repeat match goal with H : option _ |- _ => destruct H end;
          try solve [ apply Some; auto with parse_tree nocore
                    | apply Some;
                      repeat match goal with
                               | _ => progress auto with parse_tree nocore
                               | [ H : parse_of _ _ _ _ |- _ ] => inversion H; clear H; subst
                             end
                    | match goal with
                        | [ H : parse_of _ _ _ _ |- _ ] => fail 1
                        | _ => idtac
                      end;
                      exact None ]. }
      { (** make_abort *)
        intros; exact None. }
    Defined.
  End parse_tree_no_split.*)
End recursive_descent_parser.

Section recursive_descent_parser_list.
  Context {CharType} {String : string_like CharType} {G : grammar CharType}.
  Variable (CharType_eq_dec : forall x y : CharType, {x = y} + {x <> y}).
  Definition rdp_list_nonterminal_listT : String -> Type := fun _ => list (nonterminal CharType).
  Definition rdp_list_is_valid_nonterminal : forall str, rdp_list_nonterminal_listT str -> nonterminal CharType -> bool
    := fun str ls nt => if in_dec (nonterminal_dec CharType_eq_dec) nt ls then true else false.
  Definition rdp_list_remove_nonterminal : forall str, rdp_list_nonterminal_listT str -> nonterminal CharType -> rdp_list_nonterminal_listT str
    := fun str ls nt =>
         filter (fun x => if nonterminal_dec CharType_eq_dec nt x then false else true) ls.
  Definition rdp_list_nonterminal_listT_R : forall str, rdp_list_nonterminal_listT str -> rdp_list_nonterminal_listT str -> Prop
    := fun _ => ltof _ (@List.length _).
  Lemma filter_list_dec {T} f (ls : list T) : List.length (filter f ls) <= List.length ls.
  Proof.
    induction ls; trivial; simpl in *.
    repeat match goal with
             | [ |- context[if ?a then _ else _] ] => destruct a; simpl in *
             | [ |- S _ <= S _ ] => solve [ apply Le.le_n_S; auto ]
             | [ |- _ <= S _ ] => solve [ apply le_S; auto ]
           end.
  Defined.
  Lemma rdp_list_remove_nonterminal_dec : forall str ls nt, @rdp_list_is_valid_nonterminal str ls nt = true
                                                            -> @rdp_list_nonterminal_listT_R str (@rdp_list_remove_nonterminal str ls nt) ls.
  Proof.
    intros.
    unfold rdp_list_is_valid_nonterminal, rdp_list_nonterminal_listT_R, rdp_list_remove_nonterminal, ltof in *.
    destruct (in_dec (nonterminal_dec CharType_eq_dec) nt ls); [ | discriminate ].
    match goal with
      | [ H : In ?nt ?ls |- context[filter ?f ?ls] ]
        => assert (~In nt (filter f ls))
    end.
    { intro H'.
      apply filter_In in H'.
      destruct H' as [? H'].
      destruct (nonterminal_dec CharType_eq_dec nt nt); congruence. }
    { match goal with
        | [ |- context[filter ?f ?ls] ] => generalize dependent f; intros
      end.
      induction ls; simpl in *; try congruence.
      repeat match goal with
               | [ |- context[if ?x then _ else _] ] => destruct x; simpl in *
               | [ H : _ \/ _ |- _ ] => destruct H
               | _ => progress subst
               | [ H : ~(_ \/ _) |- _ ] => apply Decidable.not_or in H
               | [ H : _ /\ _ |- _ ] => destruct H
               | [ H : ?x <> ?x |- _ ] => exfalso; apply (H eq_refl)
               | _ => apply Lt.lt_n_S
               | _ => apply Le.le_n_S
               | _ => apply filter_list_dec
               | [ H : _ -> _ -> ?G |- ?G ] => apply H; auto
             end. }
  Defined.
  Lemma rdp_list_ntl_wf : forall str, well_founded (@rdp_list_nonterminal_listT_R str).
  Proof.
    unfold rdp_list_nonterminal_listT_R.
    intro.
    apply well_founded_ltof.
  Defined.
End recursive_descent_parser_list.

(*

  Section parse_tree.
    Context (make_splits : forall (str : String) (pat : pattern CharType),
                             list
                               {str' : String |
                                Length String str' <= Length _ str}).
    Local Hint Constructors parse_of parse_of_pattern parse_of_item : parse_tree.
    Local Hint Resolve ParseHead ParsePatternSingleton : parse_tree.
    Local Hint Extern 1 => apply ParseHead : parse_tree.
    Local Hint Extern 0 (option (parse_of _ _ _ [])) => exact None : parse_tree.

    Definition parse_tree_for : forall str nt, option (parse_of String G str nt).
    Proof with auto with parse_tree nocore.
      apply (@parse_nonterminal (fun str nt => option (parse_of _ G str nt))).
      { intros str name [p|]; [ apply Some | exact None ]... }
      { intros.
        specialize (make_splits str).
        pose proof (fun pat => map (fun spf => exist (fun s => Length _ s <= max_len)
                                                     (proj1_sig spf)
                                                     (transitivity (R := le) (proj2_sig spf) pf))
                                   (make_splits pat)) as make_splits'.
        specialize (fun pat => parse_pattern_from_split_list' (make_splits' pat) pat).
Goal (fun x : nat => x) = (fun x : nat => x).
  match goal with
    | |- context[fun x => x] => pose (fun y : Set => y)
  end. (* success *)
  match goal with
    | |- context[fun y => y] => pose (fun y : Set => y)
  end. (* Toplevel input, characters 0-78:
Error: Ltac variable y is not bound to an identifier.
It cannot be used in a binder. *)
        Variable pick_splits : forall (str : String) (pat : pattern CharType),
                                 { strs : list { str' : String | Length _ str' <= Length _ str }
                                 | fold_left (fun sp acc => proj1_sig (fst sp) ++ acc) (Empty _) (combine strs pat) = str
                                   /\
        admit. }
      { (** decide_leaf *)
        intros str ch.
        case_eq (str =s [[ch]]); intro H; [ apply bool_eq_correct in H; apply Some | exact None ].
        subst... }
      { (** fold_patterns *)
        intros str pats parses; induction parses; simpl in *...
        repeat match goal with H : option _ |- _ => destruct H end;
          try solve [ apply Some; auto with parse_tree nocore
                    | apply Some;
                      repeat match goal with
                               | _ => progress auto with parse_tree nocore
                               | [ H : parse_of _ _ _ _ |- _ ] => inversion H; clear H; subst
                             end
                    | match goal with
                        | [ H : parse_of _ _ _ _ |- _ ] => fail 1
                        | _ => idtac
                      end;
                      exact None ]. }
      { (** make_abort *)
        intros; exact None. }
    Defined.
        {
        apply Some.
        apply ParseHead.
        inversion p; subst.
        try solve [ apply Some.. ].

        auto with parse_tree nocore.
        .

        exact (fun str ch =>
                 if str =s [ [ ch ] ] as b return (

Print Universes.
        apply ParsePatternSingleton.
        constructor.
        assumption.
        eapply ParsePatternCons.
        Print parse_of_pattern.
      Print parse_of.

End recursive_descent_parser.

Section
*)


Section example_parse_string_grammar.
  Fixpoint make_all_single_splits (str : string) : list { strs : string * string | (fst strs ++ snd strs = str)%string }.
  Proof.
    refine ((exist _ (""%string, str) eq_refl)::_).
    refine (match str with
              | ""%string => nil
              | String.String ch str' => map (fun p => exist _ (String.String ch (fst (proj1_sig p)),
                                                                snd (proj1_sig p))
                                                             _)
                                             (make_all_single_splits str')
            end).
    simpl; apply f_equal.
    apply proj2_sig.
  Defined.

  Lemma length_append (s1 s2 : string) : length (s1 ++ s2) = length s1 + length s2.
  Proof.
    revert s2.
    induction s1; simpl; trivial; [].
    intros.
    f_equal; auto.
  Qed.

  Fixpoint flatten1 {T} (ls : list (list T)) : list T
    := match ls with
         | nil => nil
         | x::xs => (x ++ flatten1 xs)%list
       end.

  Lemma flatten1_length_ne_0 {T} (ls : list (list T)) (H0 : Datatypes.length ls <> 0)
        (H1 : Datatypes.length (hd nil ls) <> 0)
  : Datatypes.length (flatten1 ls) <> 0.
  Proof.
    destruct ls as [| [|] ]; simpl in *; auto.
  Qed.

  Local Ltac t' :=
    match goal with
      | _ => progress simpl in *
      | _ => progress subst
      | [ H : ?a = ?b |- _ ] => progress subst a
      | [ H : ?a = ?b |- _ ] => progress subst b
      | _ => rewrite (LeftId string_stringlike _)
      | _ => rewrite (RightId string_stringlike _)
      | _ => reflexivity
      | _ => split
      | _ => right; reflexivity
      | _ => rewrite map_length
      | _ => rewrite map_map
      | _ => rewrite length_append
      | _ => progress destruct_head_hnf prod
      | _ => progress destruct_head_hnf and
      | _ => progress destruct_head_hnf or
      | _ => progress destruct_head_hnf sig
      | _ => progress auto with arith
      | _ => apply f_equal
      | _ => solve [ apply proj2_sig ]
      | _ => solve [ left; auto with arith ]
      | [ str : string |- _ ] => solve [ destruct str; simpl; auto with arith ]
      | [ str : string |- _ ] => solve [ left; destruct str; simpl; auto with arith ]
    end.
  Local Ltac t'' :=
    match goal with
      | _ => progress t'
      | [ str : string |- _ ] => solve [ destruct str; repeat t' ]
    end.
  Local Ltac t :=
    solve [ repeat t'' ].

  Local Hint Resolve NPeano.Nat.lt_lt_add_l NPeano.Nat.lt_lt_add_r NPeano.Nat.lt_add_pos_r NPeano.Nat.lt_add_pos_l : arith.

  Definition brute_force_splitter
  : forall (str : string_stringlike) (pat : pattern Ascii.ascii),
      Datatypes.length pat > 0 ->
      {ls
       : list
           {split
            : list
                {str_part : string_stringlike |
                 Length string_stringlike str_part < Length string_stringlike str \/
                 str_part = str} |
            Datatypes.length split = Datatypes.length pat /\
            fold_right (Concat string_stringlike) (Empty string_stringlike)
                       (map (@proj1_sig _ _) split) = str} |
       Datatypes.length ls <> 0}.
  Proof.
    simpl.
    intros str [|pat pats] H;
      [ exfalso; clear str; simpl in H; abstract inversion H
      | clear H ].
    revert str.
    induction pats; simpl in *; intros str.
    { (** We only get one thing in the list *)
      refine (exist _ ((exist _ ((exist _ str _)::nil) _)::nil) _).
      simpl; auto with arith. }
    { pose (make_all_single_splits str) as single_splits.
      pose proof (map (@proj1_sig _ _) single_splits).
      pose proof (fun str => map (map (@proj1_sig _ _)) (map (@proj1_sig _ _) (proj1_sig (IHpats str)))).
      let P := match goal with |- sig ?P => constr:P end in
      refine (exist
                P
                (flatten1
                   (map (fun s1s2p =>
                           map
                             (fun split_list => exist
                                                  _
                                                  (((exist _ (fst (proj1_sig s1s2p)) _)
                                                      ::(map (fun s => exist _ (proj1_sig s) _)
                                                             (proj1_sig split_list))))
                                                  _)
                             (proj1_sig (IHpats (snd (proj1_sig s1s2p)))))
                        single_splits))
                _).
      apply flatten1_length_ne_0; simpl.
      { rewrite !map_length; subst_body; simpl; clear;
        abstract (destruct str; simpl; auto with arith). }
      { subst_body;
        destruct str; simpl.
        { rewrite map_length; clear; abstract t. }
        { rewrite map_length; clear; abstract t. } } }
    Grab Existential Variables.
    { simpl. split.
      { rewrite map_length; clear; abstract t. }
      { subst_body; rewrite map_map; simpl; abstract t. } }
    { abstract t. }
    { abstract t. }
    { simpl; abstract t. }
    { abstract t. }
  Defined.

  Variable G : grammar Ascii.ascii.

  Definition brute_force_make_parse_of : forall str nt, parse_of string_stringlike G str nt
                                            + option (parse_of string_stringlike G str nt -> False).
  Proof.
    eapply parse_tree_for
    with (nonterminal_listT := rdp_list_nonterminal_listT)
           (is_valid_nonterminal := rdp_list_is_valid_nonterminal Ascii.ascii_dec)
           (remove_nonterminal := rdp_list_remove_nonterminal Ascii.ascii_dec)
           (nonterminal_listT_R := rdp_list_nonterminal_listT_R).
    { intros; exact [Lookup (trivial_grammar _) ""%string]. }
    { apply rdp_list_remove_nonterminal_dec. }
    { apply rdp_list_ntl_wf. }
    { apply brute_force_splitter. }
  Defined.
End example_parse_string_grammar.

Module example_parse_empty_grammar.
  Definition make_parse_of : forall str nt, parse_of string_stringlike (trivial_grammar _) str nt
                                            + option (parse_of string_stringlike (trivial_grammar _) str nt -> False)
    := brute_force_make_parse_of _.



  Definition parse : forall str : string,
                       (parse_of string_stringlike (trivial_grammar _) str (trivial_grammar _))
                       + option ((parse_of string_stringlike (trivial_grammar _) str (trivial_grammar _)) -> False)
    := fun str => make_parse_of str _.

  Eval hnf in if (parse "") then true else false.
  Eval hnf in if (parse "a") then true else false.

  Arguments eq_rect_r / .
  Arguments eq_rec_r / .
  Arguments eq_ind_r / .

  Goal True.
    pose (parse "") as X.
    hnf in X; simpl in X.
    pose (parse "a") as Y.
    hnf in Y; simpl in Y.
  Abort.
End example_parse_empty_grammar.

(*

Module example_parse_empty_grammar.
  Definition make_parse_of : forall str nt, parse_of string_stringlike (trivial_grammar _) str nt
                                            + option (parse_of string_stringlike (trivial_grammar _) str nt -> False).
  Proof.
    eapply parse_tree_for
    with (nonterminal_listT := rdp_list_nonterminal_listT)
           (is_valid_nonterminal := rdp_list_is_valid_nonterminal Ascii.ascii_dec)
           (remove_nonterminal := rdp_list_remove_nonterminal Ascii.ascii_dec)
           (nonterminal_listT_R := rdp_list_nonterminal_listT_R).
    { intros; exact [Lookup (trivial_grammar _) ""%string]. }
    { apply rdp_list_remove_nonterminal_dec. }
    { apply rdp_list_ntl_wf. }
    { simpl.
      intros str pat H.
      refine (exist _ (_::nil) _).
      exact (NPeano.Nat.neq_succ_0 _).
      Grab Existential Variables.
      hnf in pat.
      destruct pat as [|pat pats];
        simpl in *;
        [ exfalso; revert H; clear; intro H; abstract inversion H
        | clear H ].
      revert str.
      induction pats.
      { simpl; intros str.
        refine (exist _ ((exist _ str _)::nil) (conj eq_refl (RightId string_stringlike _))). }
      { simpl in *; intros str.
        destruct str as [|ch str].
        { specialize (IHpats ""%string).
          destruct IHpats as [split [H0 H1] ].
          exists ((exist _ ""%string (or_intror eq_refl))::split); simpl;
          split; f_equal; auto. }
        { specialize (IHpats str); simpl.
          destruct IHpats as [split [H0 H1] ].
          destruct str; simpl in *.
          { exists ((exist _ (String.String ch ""%string) (or_intror eq_refl))::split);
            split; simpl; try solve [ f_equal; auto ]. }
        simpl in *.
        simpl.
        exact .


      SearchAbout (_ ++ "")%string.
      simpl.
      SearchAbout (S _ <> 0).
  Defined.

  Definition parse : forall str : string,
                       option (parse_of string_stringlike (trivial_grammar _) str (trivial_grammar _))
    := fun str => make_parse_of str _.

  Eval hnf in if (parse "") then true else false.
  Eval hnf in if (parse "a") then true else false.

  Goal True.
    pose (parse "") as X.
    hnf in X; simpl in X.
    pose (parse "a") as Y.
    hnf in Y; simpl in Y.
  Abort.
End example_parse_empty_grammar.
*)
