// This file is part of the rust language runtime library.
// Copyright 2008-2010 Graydon Hoare <graydon@pobox.com>.
// Released under MIT license.
// See file COPYING for details.

#include "rust_internal.h"

uintptr_t
rust_crate::get_image_base() const {
  return ((uintptr_t)this + image_base_off);
}

ptrdiff_t
rust_crate::get_relocation_diff() const {
  return ((uintptr_t)this - self_addr);
}

activate_glue_ty
rust_crate::get_activate_glue() const {
  return (activate_glue_ty) ((uintptr_t)this + activate_glue_off);
}

uintptr_t
rust_crate::get_main_exit_task_glue() const {
  return ((uintptr_t)this + main_exit_task_glue_off);
}

uintptr_t
rust_crate::get_unwind_glue() const {
  return ((uintptr_t)this + unwind_glue_off);
}

uintptr_t
rust_crate::get_yield_glue() const {
  return ((uintptr_t)this + yield_glue_off);
}

rust_crate::mem_area::mem_area(rust_dom *dom, uintptr_t pos, size_t sz)
  : dom(dom),
    base(pos),
    lim(pos + sz)
{
  dom->log(LOG_MEM, "new mem_area [0x%" PRIxPTR ",0x%" PRIxPTR "]",
           base, lim);
}

rust_crate::mem_area
rust_crate::get_debug_info(rust_dom *dom) const {
  return mem_area(dom, ((uintptr_t)this + debug_info_off),
                  debug_info_sz);
}

rust_crate::mem_area
rust_crate::get_debug_abbrev(rust_dom *dom) const {
  return mem_area(dom, ((uintptr_t)this + debug_abbrev_off),
                  debug_abbrev_sz);
}

//
// Local Variables:
// mode: C++
// fill-column: 70;
// indent-tabs-mode: nil
// c-basic-offset: 4
// buffer-file-coding-system: utf-8-unix
// compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
// End: