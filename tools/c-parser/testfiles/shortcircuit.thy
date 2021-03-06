(*
 * Copyright 2020, Data61, CSIRO (ABN 41 687 119 230)
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *)

theory shortcircuit
imports "CParser.CTranslation"
begin

external_file "shortcircuit.c"
install_C_file "shortcircuit.c"


context shortcircuit
begin

  thm f_body_def
  thm deref_body_def
  thm test_deref_body_def
  thm imm_deref_body_def
  thm simple_body_def
  thm condexp_body_def

lemma semm: "\<Gamma> \<turnstile> \<lbrace> \<acute>p = NULL \<rbrace> Call test_deref_'proc \<lbrace> \<acute>ret__int = 0 \<rbrace>"
apply vcg
apply simp
done

lemma condexp_semm:
  "\<Gamma> \<turnstile> \<lbrace> \<acute>i = 10 & \<acute>ptr = NULL & \<acute>ptr2 = NULL \<rbrace>
                    Call condexp_'proc
                  \<lbrace> \<acute>ret__int = 23 \<rbrace>"
apply vcg
apply (simp add: word_sless_def word_sle_def)
done

end (* context *)

end (* theory *)
