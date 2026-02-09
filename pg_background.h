#ifndef PG_BACKGROUND_H_
#define PG_BACKGROUND_H_

/* Various macros for backward compatibility */

/*
 * TupleDescAttr was introduced in 9.6.5 and 9.5.9.
 * Still needed for PG < 18.
 */
#if PG_VERSION_NUM < 180000
#ifndef TupleDescAttr
#define TupleDescAttr(tupdesc, i) (&(tupdesc)->attrs[(i)])
#endif
#endif

/*
 * shm_toc_lookup signature changed in PG 10 (before our minimum supported version).
 * For PG 14+, we always use the 3-argument version.
 */
#define shm_toc_lookup_compat(toc, key, noerr) shm_toc_lookup((toc), (key), (noerr))

/*
 * CreateCommandTag signature changed in PG 13.
 * For PG 14+, we always use the PG 13+ form with (Node *) cast.
 */
#define CreateCommandTag_compat(p) CreateCommandTag((Node *) (p))

/* 
 * In PG13+, CommandTag became an enum and QueryCompletion was introduced.
 * For PG 14+, we always use the PG 13+ form.
 */
typedef CommandTag CommandTag_compat;
#define set_ps_display_compat(tag) set_ps_display((tag))
#define BeginCommand_compat(tag, dest) BeginCommand((tag), (dest))
#define EndCommand_compat(qc, dest) EndCommand((qc), (dest), false)

/*
 * pg_analyze_and_rewrite signature changed in PG 15.
 */
#if PG_VERSION_NUM >= 150000
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite_fixedparams((parse), (string), (types), (num), (env))
#else
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite((parse), (string), (types), (num), (env))
#endif

#endif  /* PG_BACKGROUND_H_ */
