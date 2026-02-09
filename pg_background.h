#ifndef PG_BACKGROUND_H_
#define PG_BACKGROUND_H_

/* Various macros for backward compatibility */

/*
 * TupleDescAttr was introduced in 9.6.5 and 9.5.9, so allow compilation
 * against those versions just in case.
 */
#if PG_VERSION_NUM < 180000
#ifndef TupleDescAttr
#define TupleDescAttr(tupdesc, i) (&(tupdesc)->attrs[(i)])
#endif
#endif

#if PG_VERSION_NUM < 100000
#define shm_toc_lookup_compat(toc, key, noerr) shm_toc_lookup((toc), (key))
#else
#define shm_toc_lookup_compat(toc, key, noerr) shm_toc_lookup((toc), (key), (noerr))
#endif

#if PG_VERSION_NUM < 100000 || PG_VERSION_NUM >= 130000
#define CreateCommandTag_compat(p) CreateCommandTag((Node *) (p))
#else
#define CreateCommandTag_compat(p) CreateCommandTag((p)->stmt)
#endif

/* 
 * In PG13+, CommandTag became an enum and QueryCompletion was introduced.
 * In PG12, CommandTag was const char* and there was no QueryCompletion.
 */
#if PG_VERSION_NUM < 130000
/* PG12: CommandTag is const char* */
typedef const char *CommandTag_compat;
#define GetCommandTagName(n)    (n)
#define set_ps_display_compat(tag) set_ps_display((tag), false)
#define BeginCommand_compat(tag, dest) BeginCommand((tag), (dest))
#define EndCommand_compat(tag, dest) EndCommand((tag), (dest))
/* COMPLETION_TAG_BUFSIZE is defined in tcop/dest.h in PG12 */
#ifndef COMPLETION_TAG_BUFSIZE
#define COMPLETION_TAG_BUFSIZE 64
#endif
#else
/* PG13+: CommandTag is an enum */
typedef CommandTag CommandTag_compat;
#define set_ps_display_compat(tag) set_ps_display((tag))
#define BeginCommand_compat(tag, dest) BeginCommand((tag), (dest))
#define EndCommand_compat(qc, dest) EndCommand((qc), (dest), false)
#endif

#if PG_VERSION_NUM >= 150000
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite_fixedparams((parse), (string), (types), (num), (env))
#elif PG_VERSION_NUM >= 100000
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite((parse), (string), (types), (num), (env))
#else
#define pg_analyze_and_rewrite_compat(parse, string, types, num, env) \
        pg_analyze_and_rewrite((parse), (string), (types), (num))
#endif

/* pg_background.h */
//extern long pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop);

/*
 * TimestampDifferenceMilliseconds changed signature in newer branches.
 * PG17+: long TimestampDifferenceMilliseconds(start, stop)
 * older: void TimestampDifferenceMilliseconds(start, stop, &ms)
 */
/* #if PG_VERSION_NUM >= 170000
static inline long
pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop)
{
	return TimestampDifferenceMilliseconds(start, stop);
}
#else
static inline long
pgbg_timestamp_diff_ms(TimestampTz start, TimestampTz stop)
{
	long ms = 0;
	TimestampDifferenceMilliseconds(start, stop, &ms);
	return ms;
}
#endif */

#endif  /* PG_BACKGROUND_H_ */
