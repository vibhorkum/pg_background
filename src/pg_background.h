/*--------------------------------------------------------------------------
 *
 * pg_background.h
 *     Header file for pg_background extension.
 *
 * This file contains compatibility macros for supporting multiple
 * PostgreSQL versions (14-18).
 *
 * Copyright (c) 2014-2026, Vibhor Kumar and contributors
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * Licensed under the PostgreSQL License. See LICENSE file for details.
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
 * QUERY ANALYSIS COMPATIBILITY
 * ============================================================================
 *
 * pg_analyze_and_rewrite was renamed to pg_analyze_and_rewrite_fixedparams
 * in PostgreSQL 15 when pg_analyze_and_rewrite_varparams was added. This is
 * the only command-pipeline shim still pulling its weight; the older
 * shm_toc_lookup_compat / CreateCommandTag_compat / set_ps_display_compat /
 * Begin/EndCommand_compat / CommandTag_compat aliases were 1:1 with the
 * modern API on every PG ≥ 14 and have been inlined.
 */
#if PG_VERSION_NUM >= 150000
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite_fixedparams((parse), (string), (types), (num), (env))
#else
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite((parse), (string), (types), (num), (env))
#endif

#endif  /* PG_BACKGROUND_H_ */
