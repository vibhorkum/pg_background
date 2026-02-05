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

#if PG_VERSION_NUM < 130000
#define GetCommandTagName(n)    (n)
#define set_ps_display_compat(tag) set_ps_display((tag), false)
#else
#define set_ps_display_compat(tag) set_ps_display((tag))
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
