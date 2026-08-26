# Review retry queue. Machine-written by the review harness when every reviewer in
# the chain fails. There is no automated drainer in this repository: drain the
# queue by re-running the review for each queued `commit` / `diff_sha` below, then
# delete the row and its matching `reviews/REVIEW-OUTAGE-*.md` file once the
# review completes.

- 2026-08-19T12:06Z | tier=E | primary=ALL | reason=RC_143 | fallback_used=NONE | commit=b13d958 | diff_sha=2a3fc7511af488c8407c073fb0036132067cfead7724928fe4724c264c1b4911
- 2026-08-26T06:35Z | tier=E | primary=ALL | reason=NOT_RECORDED | fallback_used=NONE | commit=4151131 | diff_sha=d7fbda45e2360f7fad987d0de3a70562d2304147b516533420b4b24d66c109e7
- 2026-08-26T06:56Z | tier=E | primary=ALL | reason=NOT_RECORDED | fallback_used=NONE | commit=bf21ebf | diff_sha=39794e630776f798e650b88e2394358785723bcfc7b93f35f7cf511a407aac7e
- 2026-08-26T17:23Z | tier=E | primary=ALL | reason=NOT_RECORDED | fallback_used=NONE | commit=9309de5 | diff_sha=dafd2bffe029eaa1c5229b1848ff3d9cce68069e1e1220f665059f9f42f5fbd1
- 2026-08-26T21:48Z | tier=E | primary=ALL | reason=USAGE_LIMIT | fallback_used=NONE | commit=7c61f7e | diff_sha=34af5de5ccf53834c4c85290b53fe2d6801489e3b18024fe9b87ac1e8a97baa7
