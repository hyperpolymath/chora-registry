// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// A repo carries placements in the registry's classification schemes
// (A7 W10): [{scheme, category, primary: true} | {scheme, category, rank}].
// clade-12 is the first scheme, and the one the clade routes read.

/** The repo's primary placement in clade-12 (its clade code), or ''. */
export function primaryClade(repo) {
  const p = (repo.placements || []).find((x) => x.scheme === 'clade-12' && x.primary);
  return p ? p.category : '';
}

/** Every clade-12 category the repo is placed in, primary first. */
export function cladeCodes(repo) {
  return (repo.placements || [])
    .filter((x) => x.scheme === 'clade-12')
    .sort((a, b) => (a.primary ? -1 : b.primary ? 1 : (a.rank || 0) - (b.rank || 0)))
    .map((x) => x.category);
}
