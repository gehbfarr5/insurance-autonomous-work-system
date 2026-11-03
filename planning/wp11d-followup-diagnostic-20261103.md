# WP11-D value-free follow-up diagnostic

Date: 2026-11-03
Package under inspection: 0.8.1
Code commit: `1aeb7cb7b04c4e4853d750b181800fbbacf71fab`

## Scope and outcome

MUSE used only the existing protected WP10 structured result and the 0.8.1 isolated worktree. The diagnostic did not rerun OCR, access other samples, call Baidu/iCloud, inspect production code for execution, change files, or export protected content. MUSE reported no external operations and no production change.

The diagnostic request completed, but it did not pass the release gate. It found no evidence to loosen the geometric acceptance rules. It identified potential targeted parser cases, while confirming that the protected sample still lacks unique assignments for required fields.

## Aggregate geometry evidence

| Field | Exact labels | Shape candidates | Nearest source | Unique under 0.8.1 | Main rejection evidence |
| --- | ---: | --- | --- | --- | --- |
| Name | 1 | 1 | Same row | No | One candidate is near-tied between two field labels; all candidates were rejected for geometry ambiguity. |
| Mobile | 1 | 2+ | Next visual row | No | One overlap rejection. The farther confirmed candidate has unknown row distance, no intervening field label, and no unique horizontal column. |
| Explicit birthday | 2 | 2+ | Same row | No | One overlap rejection and one label with no candidate. |
| Identity number | 1 | 2+ | Next visual row | No | One overlap rejection. Composite fragment count is unknown and the composite did not pass checksum. A separate full ID-shaped block passed an internal checksum, but competes with another field label; a primary-field label intervenes. |
| Address | 1 | 2+ | Same row | Yes | The unique candidate is rejected because it is shorter than the minimum length. |
| Gender | — | — | — | No | Structured OCR has no independent, decidable checkbox-state signal. |

For identity number, the earlier protected diagnostic also found same-row fragments without an intervening label, but their horizontal column was not unique; their internal concatenation passed checksum. These facts do not establish which field cell owns the value.

## Acceptance-set inventory

MUSE checked only the protected sample inventory metadata and reported:

- Sample count: `<30`
- Authorization: `NOT_CONFIRMED`
- Required reference annotations complete: `NO`

The 30-card accuracy gate cannot run until an authorized, labeled set is available.

## Decision

Do not expand the phone search radius, remove tie/overlap rejection, select the checksum-valid ID by content alone, or accept the short address fragment. The current evidence cannot support a safe automatic mapping. The 0.8.1 fail-closed result remains valid: name, mobile, identity number, explicit birthday, and gender do not match; address matches only because the reviewed draft intentionally omitted it.

Potential targeted work can be evaluated after more evidence: better handling of overlapping label geometry and identity candidate search that still requires unique field ownership. The existing sample does not justify making either candidate a trusted match. A template-aware visual extraction route would be a separate design choice and requires an authorized representative test set.
