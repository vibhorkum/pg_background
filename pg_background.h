/*--------------------------------------------------------------------------
 *
 * pg_background.h
 *     Header file for pg_background extension.
 *
 * This file contains compatibility macros for supporting multiple
 * PostgreSQL versions (14-18).
 *
 * Copyright (c) 2014-2026, Vibhor Kumar
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without a written agreement
 * is hereby granted, provided that the above copyright notice and this
 * paragraph and the following two paragraphs appear in all copies.
 *
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOST
 * PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
 * EVEN IF THE COPYRIGHT HOLDER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 *
 * THE COPYRIGHT HOLDER SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT
 * NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
 * AND THE COPYRIGHT HOLDER HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE, SUPPORT,
 * UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 *
 * -------------------------------------------------------------------------
 */
#ifndef PG_BACKGROUND_H_
#define PG_BACKGROUND_H_

/*
 * ============================================================================
 * TUPLE DESCRIPTOR COMPATIBILITY
 * ============================================================================
 *
 * TupleDescAttr macro for accessing tuple descriptor attributes.
 * In PostgreSQL 18+, TupleDescAttr is provided by the system and the
 * TupleDescData structure changed (attrs is no longer a direct member).
 * Only define our fallback for older versions.
 */
#if PG_VERSION_NUM < 180000
#ifndef TupleDescAttr
#define TupleDescAttr(tupdesc, i) (&(tupdesc)->attrs[(i)])
#endif
#endif

/*
 * ============================================================================
 * SHARED MEMORY TOC COMPATIBILITY
 * ============================================================================
 *
 * shm_toc_lookup signature is stable since PG 10.
 * We use the 3-argument version (with noerror flag).
 */
#define shm_toc_lookup_compat(toc, key, noerr) shm_toc_lookup((toc), (key), (noerr))

/*
 * ============================================================================
 * COMMAND TAG COMPATIBILITY
 * ============================================================================
 *
 * CreateCommandTag changed in PG 13 to take Node* instead of specific types.
 * CommandTag became an enum and QueryCompletion was introduced.
 */
#define CreateCommandTag_compat(p) CreateCommandTag((Node *) (p))
typedef CommandTag CommandTag_compat;

/* Process status display */
#define set_ps_display_compat(tag) set_ps_display((tag))

/* Command lifecycle functions */
#define BeginCommand_compat(tag, dest) BeginCommand((tag), (dest))
#define EndCommand_compat(qc, dest) EndCommand((qc), (dest), false)

/*
 * ============================================================================
 * QUERY ANALYSIS COMPATIBILITY
 * ============================================================================
 *
 * pg_analyze_and_rewrite was renamed to pg_analyze_and_rewrite_fixedparams
 * in PostgreSQL 15 when pg_analyze_and_rewrite_varparams was added.
 */
#if PG_VERSION_NUM >= 150000
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite_fixedparams((parse), (string), (types), (num), (env))
#else
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite((parse), (string), (types), (num), (env))
#endif

#endif  /* PG_BACKGROUND_H_ */
