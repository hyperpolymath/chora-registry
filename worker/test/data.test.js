// SPDX-License-Identifier: MPL-2.0
// Contract tests for the committed registry snapshot (worker/data/*.json):
// enforce the 12-clade invariant and internal count/membership consistency,
// so snapshot drift (e.g. a repo added to repos.json but not re-indexed) fails CI.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, it, expect } from 'vitest';

import { VALID_CLADES } from '../src/validate.js';
import { primaryClade } from '../src/placements.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const load = (f) => JSON.parse(readFileSync(path.join(here, '../data', f), 'utf8'));

const repos = load('repos.json');
const clades = load('clades.json');
const index = load('index.json');

describe('clades.json', () => {
  it('defines exactly the 12 canonical clades', () => {
    expect(clades).toHaveLength(12);
    const codes = clades.map((c) => c.code).sort();
    expect(codes).toEqual([...VALID_CLADES].sort());
  });
});

describe('repos.json', () => {
  it('every repo has a name, a valid primary clade, and a github slug', () => {
    for (const repo of repos) {
      expect(typeof repo.name).toBe('string');
      expect(repo.name.length).toBeGreaterThan(0);
      expect(VALID_CLADES).toContain(primaryClade(repo));
      expect(typeof repo.github).toBe('string');
    }
  });

  it('repo names are unique', () => {
    const names = repos.map((r) => r.name);
    expect(new Set(names).size).toBe(names.length);
  });
});

describe('index.json consistency', () => {
  it('total_repos equals repos.json and by_name counts', () => {
    expect(index.total_repos).toBe(repos.length);
    expect(Object.keys(index.by_name)).toHaveLength(repos.length);
  });

  it('clade membership covers every repo exactly once', () => {
    const sum = index.clades.reduce((acc, c) => acc + c.member_count, 0);
    expect(sum).toBe(repos.length);
    for (const c of index.clades) {
      expect(c.members).toHaveLength(c.member_count);
      for (const name of c.members) expect(index.by_name[name]).toBeTruthy();
    }
  });
});

// Registry data-integrity invariants — the "proofs" a governance/registry repo can
// actually guarantee (this project has no formal ABI/FFI surface; see
// verification/README.adoc and PROOF-NEEDS.md).
describe('registry invariants', () => {
  it('each repo has one primary clade-12 placement, valid and distinct ranked ones', () => {
    for (const r of repos) {
      const inScheme = r.placements.filter((p) => p.scheme === 'clade-12');
      expect(inScheme.filter((p) => p.primary)).toHaveLength(1);
      const ranked = inScheme.filter((p) => !p.primary);
      expect(ranked.map((p) => p.rank)).toEqual(ranked.map((_, i) => i + 1));
      const codes = inScheme.map((p) => p.category);
      for (const code of codes) expect(VALID_CLADES).toContain(code);
      expect(new Set(codes).size).toBe(codes.length);
    }
  });

  it('no field retired from /v1 is served (prefixed, clade, secondary, uuid_v8)', () => {
    for (const r of repos) {
      for (const f of ['prefixed', 'clade', 'secondary', 'uuid_v8', 'uuid_v5']) {
        expect(r).not.toHaveProperty(f);
      }
    }
  });

  it('forge primary keys (github slugs) are unique', () => {
    const slugs = repos.map((r) => r.github);
    expect(new Set(slugs).size).toBe(slugs.length);
  });

  // uuid is the ADR-008 profile C UUIDv8 (version 8, variant 10) of the birth
  // path, in the domain recorded as minted_in (V9). No UUIDv5 is served: /v1
  // was reset before its first deploy (ADR 0004 amendment, 2026-11-14).
  it('uuids are present, UUIDv8 and unique, with a known minting domain', () => {
    const v8 = /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    const uuids = repos.map((r) => r.uuid);
    for (const u of uuids) expect(u).toMatch(v8);
    expect(new Set(uuids).size).toBe(uuids.length);
    for (const r of repos) expect(['gv-clade-index', 'chora-registry']).toContain(r.minted_in);
  });
});
